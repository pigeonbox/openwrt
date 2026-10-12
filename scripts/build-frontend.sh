#!/usr/bin/env bash
# 构建前端 dist → dist/www(ipk/apk 内置 UI 的来源)。
#
# 来源(2026-10-09 拆仓:web 自包含在本仓 web/):
#   1. FRONTEND_DIR 环境变量指定的现成 dist 目录(直接拷贝,跳过构建)
#   2. 本仓 web/(neutral 构建:core 自带入口+默认无宿主适配器——OpenWrt 为
#      独立端口部署;frontend-core tgz 钉版在 web/package.json)
# 不再克隆 frontend 仓——ipk/apk web 内容随本仓提交可复现;
# 类型检查由本仓 CI 把守。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/dist/www"
rm -rf "$OUT"

if [ -n "${FRONTEND_DIR:-}" ]; then
	cp -R "$FRONTEND_DIR/." "$OUT"
	echo "→ 使用现成 dist: $FRONTEND_DIR"
else
	cd "$ROOT/web"
	[ -d node_modules ] || npm ci --no-audit --no-fund
	# APP_VERSION=页脚「前端版本」(缺省=web/package.json version,前端列车号)
	APP_VERSION="${APP_VERSION:-$(node -p "require('./package.json').version")}" \
		npx vite build --outDir "$OUT" --emptyOutDir
fi


# ── 版本戳自证(2026-10-12 版本幽灵根治) ──────────────────────────
# web 版本单一来源 = APP_VERSION 环境变量 / web/package.json;构建即写
# version.txt 并断言 dist 内戳一致,不一致=构建红。运维验收一条
# curl -s <host>/version.txt 即可验真,永别「页脚是几」猜谜与缓存伪影。
WEB_VERSION="${APP_VERSION:-$(node -p "require('$ROOT/web/package.json').version")}"
printf '%s\n' "$WEB_VERSION" > "$OUT/version.txt"
grep -rqF "$WEB_VERSION" "$OUT/assets" 2>/dev/null || { echo "✗ dist 未发现版本戳 $WEB_VERSION(__APP_VERSION__ 注入失效?)"; exit 1; }
echo "    版本自证 ✓ version.txt=$WEB_VERSION 与 dist 戳一致"
echo "✓ 前端构建完成: $OUT ($(du -sh "$OUT" | cut -f1))"
