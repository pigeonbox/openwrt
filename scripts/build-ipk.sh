#!/usr/bin/env bash
# 组装 OpenWrt ipk 包(无 SDK:ar + tar.gz,与 OpenWrt buildroot 产物同构)。
#
# 用法: build-ipk.sh <arch> <version> [output_dir]
#   arch:    x86_64 | aarch64_generic (即 ipk Architecture 字段)
#   version: 包版本,如 0.1.0 (control 写作 <version>-1)
#
# 输入约定(相对仓库根):
#   dist/pigeonbox                      Go 静态二进制
#   dist/www/                              前端 dist(index.html + assets/)
#   openwrt/pigeonbox.init              procd init
#   openwrt/pigeonbox.config            UCI 默认配置
#   openwrt/pigeonbox.postinst/.prerm   控制脚本
#
# 产物: output_dir/pigeonbox_<version>-1_<arch>.ipk
set -euo pipefail

ARCH=${1:?用法: build-ipk.sh <arch> <version> [output_dir]}
VERSION=${2:?缺少版本号}
OUTDIR=${3:-dist}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$STAGING"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

[ -f "$ROOT/dist/pigeonbox" ] || { echo "缺 dist/pigeonbox(先 go build)"; exit 1; }
[ -f "$ROOT/dist/www/index.html" ] || { echo "缺 dist/www/index.html(先 build-frontend.sh)"; exit 1; }

# ---- 数据树 ----
DATA="$STAGING/data"
install -d "$DATA/usr/bin" \
	"$DATA/usr/share/pigeonbox/www" \
	"$DATA/etc/config" \
	"$DATA/etc/init.d" \
	"$DATA/usr/share/luci/menu.d" \
	"$DATA/usr/share/rpcd/acl.d" \
	"$DATA/www/luci-static/resources/view/pigeonbox"
install -m 0755 "$ROOT/dist/pigeonbox" "$DATA/usr/bin/pigeonbox"
# p2pc 设备直传随包(2026-10-14 P2b):dist/p2pc 存在才装,缺失优雅降级;
# supervisor 候选查找序含 /usr/bin/p2pc,init 脚本零改动。
# ⚠️ 2026-10-26 审计 P1:**本块曾被删掉**(只剩 p2pcweb)⇒ 装出来的 ipk 没有
# p2pc ⇒ OpenWrt 全系设备直传不可用,而发布物/流水线/README 仍宣称「随包 p2pc」
# ⇒ 三端(fnos/qnap 正常随包)行为不一致且无门禁能发现。
# ⇒ 恢复安装，并用 scripts/assert-pkg-contents.sh 断言**包内文件清单**含
#   usr/bin/p2pc（不只看运行时存在性：打包脚本漏装时发布物同样漏装）。
# p2pcweb(A2 内嵌)同规则:make p2pc 同批抓取,init beam 段按存在性启动。
if [ -f "$ROOT/dist/p2pc" ]; then
	install -m 0755 "$ROOT/dist/p2pc" "$DATA/usr/bin/p2pc"
fi
# pb CLI 随包(官方命令行客户端:doctor 部署自检等):
# dist/pb 存在才装,缺失优雅降级(同 p2pc 规则)⇒ 包内无 pb 时应用照常可用。
# ⚠️ 装到 /usr/bin/pb ⇒ **在 PATH 里** ⇒ 用户直接敲 `pb doctor` 即可,
#   不必记 /usr/bin/pb 的完整路径。
if [ -f "$ROOT/dist/pb" ]; then
	install -m 0755 "$ROOT/dist/pb" "$DATA/usr/bin/pb"
fi
if [ -f "$ROOT/dist/p2pcweb" ]; then
	install -m 0755 "$ROOT/dist/p2pcweb" "$DATA/usr/bin/p2pcweb"
fi
cp -R "$ROOT/dist/www/." "$DATA/usr/share/pigeonbox/www/"
install -m 0644 "$ROOT/openwrt/pigeonbox.config" "$DATA/etc/config/pigeonbox"
install -m 0755 "$ROOT/openwrt/pigeonbox.init" "$DATA/etc/init.d/pigeonbox"
# LuCI 入口页(服务→PigeonBox:状态+新窗口打开 UI)
install -m 0644 "$ROOT/luci/menu.d/luci-app-pigeonbox.json" "$DATA/usr/share/luci/menu.d/"
install -m 0644 "$ROOT/luci/acl.d/luci-app-pigeonbox.json" "$DATA/usr/share/rpcd/acl.d/"
install -m 0644 "$ROOT/luci/view/pigeonbox/page.js" "$DATA/www/luci-static/resources/view/pigeonbox/page.js"

# ---- 控制区 ----
CONTROL="$STAGING/CONTROL"
install -d "$CONTROL"
cat > "$CONTROL/control" <<EOF
Package: pigeonbox
Version: ${VERSION}-1
Depends: libc, redis-server
Architecture: ${ARCH}
Maintainer: PigeonBox <admin@pigeonbox.cc>
Section: net
Source: https://github.com/pigeonbox/openwrt
Description: PigeonBox - anonymous file and text sharing server (OpenWrt/iStoreOS native package)
EOF
echo "/etc/config/pigeonbox" > "$CONTROL/conffiles"
install -m 0755 "$ROOT/openwrt/pigeonbox.postinst" "$CONTROL/postinst"
install -m 0755 "$ROOT/openwrt/pigeonbox.prerm" "$CONTROL/prerm"

# ---- tar 属主统一 root:root(GNU/BSD tar 旗标不同;mac 须关 AppleDouble) ----
# 格式强制 ustar/gnu:macOS bsdtar 默认 pax-restricted,文件带扩展属性时写入
# 'x' 类型扩展头,opkg 的 tar 读取器不识别会整条跳过(实测踩坑)。
if tar --version 2>/dev/null | grep -q GNU; then
	TAROWN=(--owner=0 --group=0 --numeric-owner --format=gnu)
else
	TAROWN=(--uid 0 --gid 0 --uname root --gname root --format ustar)
fi
export COPYFILE_DISABLE=1

mkdir -p "$ROOT/$OUTDIR"
IPK="$ROOT/$OUTDIR/pigeonbox_${VERSION}-1_${ARCH}.ipk"
: > "$STAGING/debian-binary"
tar -czf "$STAGING/control.tar.gz" "${TAROWN[@]}" -C "$CONTROL" .
tar -czf "$STAGING/data.tar.gz" "${TAROWN[@]}" -C "$DATA" .

# ---- ipk 外层:OpenWrt 23.05 起为纯 tar.gz(内含 ./debian-binary + 两个 tar.gz),
# ---- 不再用 ar 包装(23.05 opkg 对 ar 档直接报 Malformed;已对官方 zlib ipk 实测核对)。
IPKROOT="$STAGING/ipk-root"
mkdir -p "$IPKROOT"
cp "$STAGING/debian-binary" "$STAGING/control.tar.gz" "$STAGING/data.tar.gz" "$IPKROOT/"
tar -czf "$IPK" "${TAROWN[@]}" -C "$IPKROOT" .

echo "✓ $IPK ($(du -h "$IPK" | cut -f1))"
OK=1
