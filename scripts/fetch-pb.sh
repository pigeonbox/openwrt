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

TRIPLE="${1:?用法: fetch-pb.sh <triple> [输出目录]}"
OUTDIR="${2:-dist}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 1

case "$TRIPLE" in
  x86_64-unknown-linux-gnu) GOARCH=amd64 ;;
  aarch64-unknown-linux-gnu) GOARCH=arm64 ;;
  *) echo "不支持的 triple: $TRIPLE" >&2; exit 1 ;;
esac

# server 的同号 tag：取自**仓内 VERSION 文件**（列车写的真相源）。
#
# ⚠️ 不要用 `git describe`：CI 是浅克隆且无 tag ⇒ describe 退化成 commit 哈希
#   ⇒ 拼出的 "v<hash>" 在 GitHub 上不存在 ⇒ 检出必然失败。
# ⚠️ 也不要用环境变量 ${VERSION}：release 流水线注入的是 tag 名（v4.6.1），
#   而本地产物构建不注入 ⇒ 两处行为不一致。
VER="$(cat VERSION 2>/dev/null | tr -d ' \r\n')"
if [ -z "$VER" ]; then
  echo "(无 VERSION 文件 —— 跳过随包 pb)"
  exit 0
fi
REF="${PB_SERVER_REF:-v${VER}}"

mkdir -p "$OUTDIR"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> 构建 pb CLI（server ${REF} 源码, GOARCH=${GOARCH}）"
if ! git clone -q --depth 1 --branch "$REF" https://github.com/pigeonbox/server.git "$TMP/server" 2>/dev/null; then
  echo "    ✗ server ${REF} 源码检出失败 —— pb 优雅降级（包内无 pb）"
  exit 0
fi

if ! (cd "$TMP/server" && CGO_ENABLED=0 GOWORK=off GOOS=linux GOARCH="$GOARCH" \
      go build -trimpath -ldflags="-w -s" -o "$ROOT/$OUTDIR/pb" ./cmd/pb) 2>/dev/null; then
  echo "    ✗ pb 编译失败 —— pb 优雅降级（包内无 pb）"
  rm -f "$ROOT/$OUTDIR/pb"
  exit 0
fi

echo "    ✓ dist/pb（$(du -h "$ROOT/$OUTDIR/pb" | cut -f1)）"
