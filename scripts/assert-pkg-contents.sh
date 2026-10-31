#!/usr/bin/env bash
# 断言打包产物的**包内文件清单**（不只看运行时存在性）。
#
# 用法: assert-pkg-contents.sh <ipk> <相对路径> [<相对路径>...]
#   例: assert-pkg-contents.sh dist/pigeonbox_1.2.3-1_x86_64.ipk usr/bin/p2pc usr/bin/p2pcweb
#
# 为什么要有这道断言（2026-10-26 审计 P1）：
#   「安装后 [ -x /usr/bin/p2pc ]」只能证明**装出来的那一份**有 p2pc；
#   而打包脚本漏装 p2pc 时，真正的发布物（走 release 流水线那份）同样漏装
#   ——CI 冒烟若只测自己那份，会与发布物脱节 ⇒ 包内文件清单必须单独断言。
#   ipk 结构（OpenWrt 23.05 起）：外层纯 tar.gz，内含 data.tar.gz
#   ⇒ 解外层再解 data.tar.gz 即可拿到全量文件清单。
#
# apk3（ADB 格式）无法用 tar 解 ⇒ apk 侧用容器内运行时断言
# （见 .github/workflows/ci.yml 的 smoke-openwrt-apk）。
set -euo pipefail

IPK="${1:?用法: assert-pkg-contents.sh <ipk> <相对路径> [...]}"
shift
[ $# -ge 1 ] || { echo "至少要给一个期望路径" >&2; exit 1; }
[ -f "$IPK" ] || { echo "找不到包: $IPK" >&2; exit 1; }

TMP="$(mktemp -d)"
OK=0
trap 'rc=$?; rm -rf "$TMP"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

tar -xzf "$IPK" -C "$TMP" 2>/dev/null \
  || { echo "✗ $IPK 不是合法的 ipk（外层 tar.gz 解不开）" >&2; exit 1; }
[ -f "$TMP/data.tar.gz" ] || { echo "✗ $IPK 内无 data.tar.gz" >&2; exit 1; }

LIST="$TMP/files.txt"
tar -tzf "$TMP/data.tar.gz" | sed 's#^\./##' | sort > "$LIST"

MISSING=""
for p in "$@"; do
  p="${p#/}"
  grep -qxF "$p" "$LIST" || MISSING="$MISSING $p"
done

if [ -n "$MISSING" ]; then
  echo "✗ $(basename "$IPK") 包内缺文件：$MISSING" >&2
  echo "  实际清单（前 40 行）:" >&2
  head -40 "$LIST" | sed 's/^/    /' >&2
  exit 1
fi

echo "✓ $(basename "$IPK") 包内含：$*"
OK=1
