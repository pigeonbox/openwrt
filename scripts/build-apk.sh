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

# ── shellkit（编译侧统一管道；**设备侧脚本一律不引**，见 C1） ───────────────
# third_party/shellkit 是上游镜像（由 hub 侧 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**。
# ⚠️ 落点是 third_party/ 而不是 vendor/：Go ≥1.14 见到**模块根**下有 vendor/ 就默认切
#    vendor 模式 ⇒ 缺 vendor/modules.txt ⇒ go build 报 "inconsistent vendoring"（实测现红）。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/third_party/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

ARCH=${1:?用法: build-apk.sh [arch] [version] [output_dir]}
VERSION=${2:?缺少版本号}
OUTDIR=${3:-dist}

STAGING="$(mktemp -d)"
# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）：处理器取 $? 后原样
# `exit "$__st"` ⇒ **退出码照旧透传**（C3）⇒ 与原手写 trap 等价。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'rm -rf "$STAGING"'
trap_install

[ -f "$REPO_ROOT/dist/pigeonbox" ] || die 1 "缺 dist/pigeonbox(先 go build)"
[ -f "$REPO_ROOT/dist/www/index.html" ] || die 1 "缺 dist/www/index.html(先 build-frontend.sh)"

# ---- 数据树(与 ipk 相同布局) ----
DATA="$STAGING/data"
install -d "$DATA/usr/bin" \
  "$DATA/usr/share/pigeonbox/www" \
  "$DATA/etc/config" \
  "$DATA/etc/init.d" \
  "$DATA/usr/lib/pigeonbox" \
  "$DATA/usr/share/luci/menu.d" \
  "$DATA/usr/share/rpcd/acl.d" \
  "$DATA/www/luci-static/resources/view/pigeonbox"
# shellkit POSIX 子集(设备侧唯一可用的 shellkit 形态)随包安装到 /usr/lib/pigeonbox/。
# ⚠️ 设备侧脚本(pigeonbox.init / postinst / post-install / prerm / preupgrade_backup)
#    都在顶部装载它 ⇒ **缺它 = 装的是不完整的包** ⇒ init 侧 fail-closed 退 5,
#    服务根本起不来(且 postinst 会把安装判红)。
# ⇒ 与 2026-10-26 那次 p2pc P1 同源教训:钩子依赖的文件必须显式装进包内。
install -m 0644 "$REPO_ROOT/openwrt/shellkit-posix.sh" "$DATA/usr/lib/pigeonbox/shellkit-posix.sh"
install -m 0755 "$REPO_ROOT/dist/pigeonbox" "$DATA/usr/bin/pigeonbox"
# p2pc + p2pcweb 随包(与 ipk 同布局)。
# ⚠️ 2026-10-26 审计 P1:**apk 数据树此前连 p2pcweb 都没有** ⇒ apk3 装出来的
# 包既无 p2pc 也无 PigeonBeam 网页客户端 ⇒ 设备直传在 OpenWrt 全系不可用,
# 而发布物/流水线/README 仍宣称「随包 p2pc」⇒ 三端行为不一致且无门禁发现。
# ⇒ 恢复安装（存在才装,缺失优雅降级）。apk3 是 ADB 格式无法用 tar 解包,
#   故包内清单断言在容器内做（见 .github/workflows/ci.yml）。
if [ -f "$REPO_ROOT/dist/p2pc" ]; then
  install -m 0755 "$REPO_ROOT/dist/p2pc" "$DATA/usr/bin/p2pc"
fi
# pb CLI 随包(官方命令行客户端:doctor 部署自检等):
# dist/pb 存在才装,缺失优雅降级(同 p2pc 规则)⇒ 包内无 pb 时应用照常可用。
# ⚠️ 装到 /usr/bin/pb ⇒ **在 PATH 里** ⇒ 用户直接敲 `pb doctor` 即可,
#   不必记 /usr/bin/pb 的完整路径。
if [ -f "$REPO_ROOT/dist/pb" ]; then
  install -m 0755 "$REPO_ROOT/dist/pb" "$DATA/usr/bin/pb"
fi
if [ -f "$REPO_ROOT/dist/p2pcweb" ]; then
  install -m 0755 "$REPO_ROOT/dist/p2pcweb" "$DATA/usr/bin/p2pcweb"
  # 出厂预接线脚本(Beam↔Box 地址与专用 API Key 预置)⇒ 与 p2pcweb 同在 /usr/bin
  install -m 0755 "$REPO_ROOT/openwrt/prewire_beam_box" "$DATA/usr/bin/prewire_beam_box"
fi
cp -R "$REPO_ROOT/dist/www/." "$DATA/usr/share/pigeonbox/www/"
install -m 0644 "$REPO_ROOT/openwrt/pigeonbox.config" "$DATA/etc/config/pigeonbox"
install -m 0755 "$REPO_ROOT/openwrt/pigeonbox.init" "$DATA/etc/init.d/pigeonbox"
# 升级前业务库快照(5.4.1):post-install/post-upgrade 在 restart 之前调用它。
# 同 ipk:钩子依赖的文件必须装进包,否则钩子静默跳过而没人发现。
install -m 0755 "$REPO_ROOT/openwrt/preupgrade_backup" "$DATA/usr/lib/pigeonbox/preupgrade_backup"
# LuCI 入口页(服务→PigeonBox:状态+新窗口打开 UI)
install -m 0644 "$REPO_ROOT/luci/menu.d/luci-app-pigeonbox.json" "$DATA/usr/share/luci/menu.d/"
install -m 0644 "$REPO_ROOT/luci/acl.d/luci-app-pigeonbox.json" "$DATA/usr/share/rpcd/acl.d/"
install -m 0644 "$REPO_ROOT/luci/view/pigeonbox/page.js" "$DATA/www/luci-static/resources/view/pigeonbox/page.js"

POSTINST="$STAGING/post-install"
install -m 0755 "$REPO_ROOT/openwrt/pigeonbox.post-install" "$POSTINST"

mkdir -p "$REPO_ROOT/$OUTDIR"
APKOUT="$REPO_ROOT/$OUTDIR"
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

log_ok "$OUT_APK ($(du -h "$OUT_APK" | cut -f1))"
