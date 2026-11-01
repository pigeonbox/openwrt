#!/usr/bin/env bash
# 组装 OpenWrt apk3 包(25.12+ apk-tools 3,ADB 格式;与 ipk 双轨覆盖新旧两代)。
#
# 用法: build-apk.sh <arch> <version> [output_dir]
#   arch:    x86_64 | aarch64_generic (apk Architecture 字段)
#   version: 包版本,如 0.2.0 (apk pkgver 写作 <version>-r0)
#
# 输入约定(相对仓库根):与 build-ipk.sh 完全一致
#   dist/pigeonbox  dist/www/  openwrt/pigeonbox.{init,config,post-install}
#
# 打包器:apk mkpkg 仅存在于完整版 apk-tools 3(OpenWrt rootfs 内裁剪版没有);
# 默认经 docker alpine:edge(自带 apk3)调用,本机已有可用 mkpkg 时设
# APK_BIN=<路径> 直跑。签名走全局选项 `apk --sign-key <私钥> mkpkg ...`
# (实测 adbsign 对未签名包报 UNTRUSTED 且静默写坏文件,勿用;mkpkg 出包即签,
# 用户侧只需预置公钥 keys/pigeonbox.pem 到 /etc/apk/keys/ 即免 --allow-untrusted)。
set -euo pipefail

ARCH=${1:?用法: build-apk.sh <arch> <version> [output_dir]}
VERSION=${2:?缺少版本号}
OUTDIR=${3:-dist}

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGING="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$STAGING"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

[ -f "$ROOT/dist/pigeonbox" ] || { echo "缺 dist/pigeonbox(先 go build)"; exit 1; }
[ -f "$ROOT/dist/www/index.html" ] || { echo "缺 dist/www/index.html(先 build-frontend.sh)"; exit 1; }

# ---- 数据树(与 ipk 相同布局) ----
DATA="$STAGING/data"
install -d "$DATA/usr/bin" \
	"$DATA/usr/share/pigeonbox/www" \
	"$DATA/etc/config" \
	"$DATA/etc/init.d" \
	"$DATA/usr/share/luci/menu.d" \
	"$DATA/usr/share/rpcd/acl.d" \
	"$DATA/www/luci-static/resources/view/pigeonbox"
install -m 0755 "$ROOT/dist/pigeonbox" "$DATA/usr/bin/pigeonbox"
# p2pc + p2pcweb 随包(与 ipk 同布局)。
# ⚠️ 2026-10-26 审计 P1:**apk 数据树此前连 p2pcweb 都没有** ⇒ apk3 装出来的
# 包既无 p2pc 也无 PigeonBeam 网页客户端 ⇒ 设备直传在 OpenWrt 全系不可用,
# 而发布物/流水线/README 仍宣称「随包 p2pc」⇒ 三端行为不一致且无门禁发现。
# ⇒ 恢复安装（存在才装,缺失优雅降级）。apk3 是 ADB 格式无法用 tar 解包,
#   故包内清单断言在容器内做（见 .github/workflows/ci.yml）。
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
# 出厂预接线脚本(Beam↔Box 地址与专用 API Key 预置)⇒ 与 p2pcweb 同在 /usr/bin
	install -m 0755 "$ROOT/openwrt/prewire_beam_box" "$DATA/usr/bin/prewire_beam_box"
fi
cp -R "$ROOT/dist/www/." "$DATA/usr/share/pigeonbox/www/"
install -m 0644 "$ROOT/openwrt/pigeonbox.config" "$DATA/etc/config/pigeonbox"
install -m 0755 "$ROOT/openwrt/pigeonbox.init" "$DATA/etc/init.d/pigeonbox"
# LuCI 入口页(服务→PigeonBox:状态+新窗口打开 UI)
install -m 0644 "$ROOT/luci/menu.d/luci-app-pigeonbox.json" "$DATA/usr/share/luci/menu.d/"
install -m 0644 "$ROOT/luci/acl.d/luci-app-pigeonbox.json" "$DATA/usr/share/rpcd/acl.d/"
install -m 0644 "$ROOT/luci/view/pigeonbox/page.js" "$DATA/www/luci-static/resources/view/pigeonbox/page.js"

POSTINST="$STAGING/post-install"
install -m 0755 "$ROOT/openwrt/pigeonbox.post-install" "$POSTINST"

mkdir -p "$ROOT/$OUTDIR"
APKOUT="$ROOT/$OUTDIR"
PKGVER="${VERSION}-r0"
OUT_APK="$APKOUT/pigeonbox-${PKGVER}_${ARCH}.apk"

INFO_ARGS=(
	--info "name:pigeonbox"
	--info "version:${PKGVER}"
	--info "arch:${ARCH}"
	--info "description:PigeonBox - anonymous file and text sharing server (OpenWrt/iStoreOS native package)"
	--info "url:https://github.com/pigeonbox/openwrt"
	--info "license:Apache-2.0"
	--info "maintainer:PigeonBox <admin@pigeonbox.cc>"
	--info "depends:libc"
	--info "depends:redis-server"
)

# ---- mkpkg ----
# post-install 只在全新安装时执行;apk3 升级走 post-upgrade——两者都必须挂同一个
# 重启脚本,否则升级后服务停留在旧进程/停机状态(真机踩坑,缺 post-upgrade 时
# 1.14.0→1.14.2 升级后服务不拉起)。
if [ -n "${APK_BIN:-}" ]; then
	SIGN_ARGS=()
	[ -n "${APK_SIGN_KEY:-}" ] && SIGN_ARGS=(--sign-key "$APK_SIGN_KEY")
	"$APK_BIN" "${SIGN_ARGS[@]}" mkpkg "${INFO_ARGS[@]}" \
		--files "$DATA" \
		--script "post-install:${POSTINST}" --script "post-upgrade:${POSTINST}" \
		--output "$OUT_APK"
else
	KEYMOUNT=()
	KEYARG=()
	if [ -n "${APK_SIGN_KEY:-}" ]; then
		KEYMOUNT=(-v "$(dirname "$APK_SIGN_KEY"):/keys:ro")
		KEYARG=(--sign-key "/keys/$(basename "$APK_SIGN_KEY")")
	fi
	docker run --rm --platform linux/amd64 \
		-v "$STAGING:/staging" -v "$APKOUT:/out" "${KEYMOUNT[@]}" \
		alpine:edge apk "${KEYARG[@]}" mkpkg "${INFO_ARGS[@]}" \
		--files "/staging/data" \
		--script "post-install:/staging/post-install" --script "post-upgrade:/staging/post-install" \
		--output "/out/$(basename "$OUT_APK")"
fi

echo "✓ $OUT_APK ($(du -h "$OUT_APK" | cut -f1))"
OK=1
