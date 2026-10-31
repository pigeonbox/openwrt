#!/usr/bin/env bash
# 下载随包 p2pc + p2pcweb（设备直传二进制，版本=DEPS.env P2PC_REF 钉版）。
#
# 用法: fetch-p2pc.sh <triple> [输出目录]
#   triple:    x86_64-unknown-linux-gnu | aarch64-unknown-linux-gnu
#   输出目录:  默认 dist（产出 dist/p2pc 与 dist/p2pcweb）
#
# 为什么独立成脚本（2026-10-26 审计 P1）：
#   此前下载逻辑只内嵌在 Makefile 的 `p2pc` 目标里 ⇒ CI 冒烟与 release 流水线
#   各自复制一份 ⇒ **已经漂移过一次**：2026-10-22 起 build-ipk.sh 只装 p2pcweb
#   （漏了 p2pc），build-apk.sh 连 p2pcweb 都没有，而流水线照样下载+sha256
#   校验两个二进制 ⇒ 装出来的包**没有 p2pc** ⇒ OpenWrt 全系设备直传不可用，
#   而发布物看起来仍是「随包 p2pc」的（README 也这么写）⇒ 无门禁能发现。
#   ⇒ 下载/校验口径收敛到本脚本，Makefile / CI / release 共用同一份，
#     打包脚本按「dist/p2pc 存在才装」的优雅降级规则取用。
#
# 供应链:checksums.txt 侧车强制 sha256 校验（资产完整性）。
set -euo pipefail

TRIPLE="${1:?用法: fetch-p2pc.sh <triple> [输出目录]}"
OUTDIR="${2:-dist}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

REF=$(sed -n 's/^P2PC_REF=//p' DEPS.env | tr -d ' \r')
if [ -z "$REF" ]; then
  echo "(DEPS.env 无 P2PC_REF —— 跳过随包 p2pc/直传优雅降级)"
  OK=1
  exit 0
fi

BASE="https://github.com/pigeonbox/p2p/releases/download/${REF}"
TMP="$(mktemp -d)"
OK=0
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

fetch() { # <资产名>
  asset="$1"
  if curl -fsSL -m 300 -o "$TMP/$asset" "$BASE/$asset" 2>/dev/null; then
    return 0
  fi
  if command -v gh >/dev/null 2>&1; then
    gh release download "$REF" -R pigeonbox/p2p -p "$asset" -O "$TMP/$asset" --clobber
    return 0
  fi
  echo "✗ $asset 下载失败（curl/gh 均不可用）" >&2
  exit 1
}

verify() { # <资产名>
  if command -v sha256sum >/dev/null 2>&1; then
    (cd "$TMP" && grep " $1\$" checksums.txt | sha256sum -c - >/dev/null)
  else
    (cd "$TMP" && grep " $1\$" checksums.txt | shasum -a 256 -c - >/dev/null)
  fi
}

curl -fsSL -m 60 -o "$TMP/checksums.txt" "$BASE/p2pc-checksums.txt" 2>/dev/null \
  || { echo "✗ checksums.txt 下载失败" >&2; exit 1; }

mkdir -p "$OUTDIR"
for pair in "p2pc-${TRIPLE}:p2pc" "p2pc-web-${TRIPLE}:p2pcweb"; do
  asset="${pair%%:*}"
  dest="${pair##*:}"
  fetch "$asset"
  verify "$asset" || { echo "✗ $asset sha256 校验失败" >&2; exit 1; }
  install -m 0755 "$TMP/$asset" "$OUTDIR/$dest"
  echo "✓ $dest @ $REF ($TRIPLE)"
done
OK=1
