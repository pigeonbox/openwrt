#!/usr/bin/env bash
# 门禁：openwrt 构建产物里的 core 版本必须 == DEPS.env CORE_PIN（钉版构建）。
#
# 缺陷实录（2026-10-26 审计 P2）：`make build` **没有 GOWORK=off** ⇒ 在 hub
# 工作区里跑会拾取上层 go.work 联编**本地 core** ⇒ 产出含未发布代码的二进制
# （又一次「版本幽灵」：仓里声明的版本与产物里的代码对不上）。注释里还硬编码
# 了一个早已过期的 core 版本号 ⇒ 误导人。
#
# 本门禁三条断言：
#   ① Makefile 的 build 目标必须带 GOWORK=off；
#   ② GOWORK=off 构建 ⇒ `go version -m` 显示的 core 版本 == DEPS.env CORE_PIN
#      （钉版与 go.mod 的一致性也顺带被守住）；
#   ③ **负对照**：在工作区里不带 GOWORK=off 构建 ⇒ core 版本必须是 (devel)
#      （≠ CORE_PIN）⇒ 证明「不加 GOWORK=off 就会联编本地 core」是真的，
#      门禁不是空转（单仓 checkout 时无 go.work ⇒ ③ 跳过并告警）。
#
# 用法: bash scripts/check-build-pin.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail() { echo "✗ $1" >&2; exit 1; }

CORE_PIN="$(sed -n 's/^CORE_PIN=//p' DEPS.env | tr -d ' \r')"
[ -n "$CORE_PIN" ] || fail "DEPS.env 无 CORE_PIN"

# ① Makefile 断言
if ! grep -qE '^\s*GOWORK=off go build' Makefile; then
  fail "Makefile 的 build 目标没有 GOWORK=off ⇒ 在 hub 工作区里会联编本地 core（版本幽灵）"
fi
echo "✓ Makefile build 目标带 GOWORK=off"

# go.mod 的钉版必须与 DEPS.env 一致（否则 CORE_PIN 本身就是错的）
GOMOD_CORE="$(grep -oE 'github\.com/pigeonbox/core v[0-9][^ ]*' go.mod | head -1 | awk '{print $2}')"
[ "$GOMOD_CORE" = "$CORE_PIN" ] || fail "go.mod 的 core 钉版(${GOMOD_CORE:-无}) ≠ DEPS.env CORE_PIN=${CORE_PIN}"
echo "✓ go.mod core 钉版 == DEPS.env CORE_PIN = ${CORE_PIN}"

core_version_of() { # <二进制>
  # go version -m 的行形如:  dep<TAB>github.com/pigeonbox/core<TAB>v0.32.15<TAB>h1:...
  # 工作区联编时该列为 (devel) ⇒ 取模块路径**后面**的那一列。
  go version -m "$1" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if ($i=="github.com/pigeonbox/core") {print $(i+1); exit}}'
}

# ② 钉版构建
GOWORK=off go build -o "$TMP/pigeonbox" ./cmd/pigeonbox
VER="$(core_version_of "$TMP/pigeonbox")"
[ "$VER" = "$CORE_PIN" ] || fail "钉版构建的 core 版本 = ${VER:-无} ≠ CORE_PIN=${CORE_PIN}"
echo "✓ 钉版构建产物 core 版本 = ${VER}"

# ③ 负对照：工作区构建（不 GOWORK=off）必须联编本地 core
WS="$(go env GOWORK 2>/dev/null || true)"
if [ -n "$WS" ]; then
  go build -o "$TMP/pigeonbox-ws" ./cmd/pigeonbox
  WVER="$(core_version_of "$TMP/pigeonbox-ws")"
  if [ "$WVER" = "$CORE_PIN" ]; then
    fail "负对照失效：工作区构建的 core 版本也是 ${CORE_PIN} ⇒ 断言抓不到「联编本地 core」"
  fi
  echo "✓ 负对照：工作区构建的 core 版本 = ${WVER:-无}（≠ ${CORE_PIN}）⇒ GOWORK=off 是必需的"
else
  echo "! 跳过负对照：当前不在 go 工作区内（单仓 checkout）⇒ 无本地 core 可联编"
fi

echo "✓ openwrt 钉版构建守卫通过（core == ${CORE_PIN}）"
