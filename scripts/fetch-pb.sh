#!/usr/bin/env bash
# 构建随包 pb CLI（官方命令行客户端：doctor 部署自检等）。
#
# 用法: fetch-pb.sh <triple> [输出目录]
#   triple:    x86_64-unknown-linux-gnu | aarch64-unknown-linux-gnu
#   输出目录:  默认 dist（产出 dist/pb）
#
# # 为什么从**源码**编译而不是下载 server Release 的二进制资产
#
# OpenWrt 与 server 的 Release 由**同号 tag 同时触发** ⇒ 若这里去下载 server
# Release 的 `pb_linux_amd64` 资产,就会与 server 的 Release 流水线**竞态**
# (资产还没构建完就下载 ⇒ 拿不到 ⇒ 包构建失败)。
# ⇒ 改为**检出 server 同号 tag 的源码**本地编译 ⇒ **git tag 立即可见**
# (不需要等任何流水线)⇒ 零竞态。
#
# # 版本对齐
#
# server 的 tag 与本包 tag **同号**(列车的 terminal.openwrt.tag = images.server
# 的号,如都是 v4.6.1)⇒ pb 的版本天然与包内服务端一致 ⇒ 不需要额外版本位。
#
# # 为什么 pb 适合这么干
#
# `cmd/pb` 是**纯 HTTP 客户端**:不链接 core(只用 oekit/pkg/cli)⇒
# 依赖极小(实测 199 个包 / 编译 3.5 秒 / 产物 6.5MB)⇒ 不拖慢打包。
#
# # 失败怎么办
#
# 编译失败 ⇒ **优雅降级**(包内无 pb,应用照常可用)⇒ 不阻断发布。
# (与 p2pc「dist/p2pc 存在才装」的优雅降级规则同款纪律。)
set -uo pipefail

# ── shellkit（编译侧统一管道；**设备侧脚本一律不引**，见 C1） ───────────────
# third_party/shellkit 是上游镜像（由 hub 侧 scripts/vendor-shellkit.sh 物化）⇒ **勿手改**。
# ⚠️ 落点是 third_party/ 而不是 vendor/：Go ≥1.14 见到**模块根**下有 vendor/ 就默认切
#    vendor 模式 ⇒ 缺 vendor/modules.txt ⇒ go build 报 "inconsistent vendoring"（实测现红）。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/third_party/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

TRIPLE="${1:?用法: fetch-pb.sh [triple] [输出目录]}"
OUTDIR="${2:-dist}"

cd "$REPO_ROOT" || exit 1

case "$TRIPLE" in
  x86_64-unknown-linux-gnu) GOARCH=amd64 ;;
  aarch64-unknown-linux-gnu) GOARCH=arm64 ;;
  *)
    log_error "不支持的 triple: ${TRIPLE}"
    exit 1
    ;;
esac

# server 的同号 tag：取自**仓内 VERSION 文件**（列车写的真相源）。
#
# ⚠️ 不要用 `git describe`：CI 是浅克隆且无 tag ⇒ describe 退化成 commit 哈希
#   ⇒ 拼出的 "v<hash>" 在 GitHub 上不存在 ⇒ 检出必然失败。
# ⚠️ 也不要用环境变量 ${VERSION}：release 流水线注入的是 tag 名（v4.6.1），
#   而本地产物构建不注入 ⇒ 两处行为不一致。
VER="$(cat VERSION 2>/dev/null | tr -d ' \r\n')"
if [ -z "$VER" ]; then
  log_info "(无 VERSION 文件 —— 跳过随包 pb)"
  exit 0
fi
REF="${PB_SERVER_REF:-v${VER}}"

mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"
# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）。
# ⚠️ 原来的手写 trap（`trap 'rc=$?; rm -rf …; …OK 哨兵…' EXIT`）由
#    `trap_install` 取代：它的处理器取 $? 后原样 `exit "$__st"`
#    ⇒ **退出码照旧透传**（C3），且顺带覆盖 INT/TERM/HUP（原来不清理）。
#    本脚本所有「exit 0」出口都显式退出 ⇒ 与原「OK 哨兵」等价。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'rm -rf "$TMP"'
trap_install

log_info "构建 pb CLI（server ${REF} 源码, GOARCH=${GOARCH}）"

# 检出 server 同号 tag 的源码；失败则**退避重试**——
# server 的 tag 可能比本仓的 tag 晚几秒可见（两仓 tag 由列车分批推送：
# frontend → server → 各终端）⇒ 重试即可覆盖这个窗口。
#
# 失败模式是**静默降级**（检出失败 ⇒ 不带 pb ⇒ 应用照常可用 ⇒ 只有门禁会发现）
# ⇒ 没有重试就意味着「这一趟车的包没有 pb」。
#
# ⚠️ 重试口径（2026-11-18 shellkit 改造）：原来是手写 `while` 循环 + `sleep 3`，
#    现在交给 shellkit 的 `retry`；退避参数**钉死成恒定 3s**
#    （DELAY=3 / BACKOFF=1 / MAX_DELAY=3）⇒ 与原来「最多 10 次、每次间隔 3s」对齐。
# ⚠️ `retry` 放弃时会在 stderr 打一行 [ERROR]（重试次数用尽）——本脚本对
#    「检出失败」是**优雅降级**（包内无 pb，应用照常可用）⇒ 该行属预期内。
export SHELLKIT_RETRY_DELAY=3
export SHELLKIT_RETRY_BACKOFF=1
export SHELLKIT_RETRY_MAX_DELAY=3

# clone 的 stderr 单独吞掉（原来就是 `2>/dev/null`）⇒ 放进函数里做，
# 否则重定向会把 shellkit 自己的重试日志一起吞掉。
_pb_clone() {
  git clone -q --depth 1 --branch "$REF" https://github.com/pigeonbox/server.git "$TMP/server" 2>/dev/null
}
retry 10 _pb_clone

if [ ! -d "$TMP/server/.git" ]; then
  log_warn "server ${REF} 源码检出失败 —— pb 优雅降级（包内无 pb）"
  exit 0
fi

if ! (cd "$TMP/server" && CGO_ENABLED=0 GOWORK=off GOOS=linux GOARCH="$GOARCH" \
  go build -trimpath -ldflags="-w -s" -o "$REPO_ROOT/$OUTDIR/pb" ./cmd/pb) 2>/dev/null; then
  log_error "pb 编译失败 —— pb 优雅降级（包内无 pb）"
  rm -f "$REPO_ROOT/$OUTDIR/pb"
  exit 0
fi

log_ok "dist/pb（$(du -h "$REPO_ROOT/$OUTDIR/pb" | cut -f1)）"
