#!/usr/bin/env bash
# openwrt/preupgrade_backup（升级前业务库快照钩子,5.4.1）的自测 + 变异负对照。
#
# 为什么需要:这个钩子干一件「错了也不会有人喊」的事——
#   ① 它跑在包装完、服务已停的窗口里,失败**不会**让安装失败(有意设计);
#   ② 于是「快照根本没生成」与「快照生成了」在真机上看起来一样:升级都成功。
#   ⇒ 必须有**能判红的**机械化判据,否则「升级前自动备份」就是文档里的空头承诺。
#   另一面同样危险:钩子若在失败时返回非 0,会把安装搞挂(服务停在停机状态)。
#
# 本自测跑**真的钩子**(临时数据目录 + 假 uci/cp),判据:
#   C1 首次备份:生成 1 份、命名形态正确、与源库逐字节一致、退出码 0
#   C2 路径含空格:仍能备份(shell 引号回归守卫)
#   C3 轮转:5 份 ⇒ 留 3 份,且**留的是最新的三份**(删的必须是最旧那份)
#   C4 空间守卫:可用空间不足 ⇒ 不生成快照、源库不动、退出码仍 0、日志说明原因
#   C5 无存量库(全新安装)⇒ 不生成快照、退出码 0、日志说明原因
#   C6 拷贝失败 ⇒ **退出码仍 0**(绝不中止安装)、不留残缺文件、日志响亮报错
#   C7 拷贝被静默截断 ⇒ 校验捕获、删除残缺快照、退出码 0(静默截断的「备份」比没有更危险)
#   C8 按 UCI 固化的 data_dir 定位库(证明解析器真的查了 UCI,而不是只看 /etc)
#   C9 静态守卫:两个包钩子(postinst / post-install)**都调用**该文件,且调用排在
#      `init.d/pigeonbox restart` **之前**——排在之后拍的已是迁移过的库(等于没备份),
#      而"文件装了但没人调"同样会让功能静默消失。此条对着钩子而非被测文件,
#      故不参与变异负对照。
#
# --selfcheck 另跑 5 组**变异负对照**(改坏钩子的某一处,对应判据必须转红):
#   M1 关掉轮转 ⇒ C3 必红 · M2 关掉空间守卫 ⇒ C4 必红 · M3 失败时 exit 1 ⇒ C6 必红
#   M4 关掉字节校验 ⇒ C7 必红 · M5 不查 UCI ⇒ C8 必红
#
# 用法: bash scripts/preupgrade-backup-selftest.sh [--selfcheck]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HELPER="$SCRIPT_DIR/../openwrt/preupgrade_backup"
HELPER_UNDER_TEST="$HELPER"
QUIET=""
FAILFILE=""
CUR_CASE=""
TMPROOT="$(mktemp -d)"
OK=0
# shellcheck disable=SC2154  # rc 在 trap 体内赋值，shellcheck 看不见
trap 'rc=$?; rm -rf "$TMPROOT"; if [ "$rc" -ne 0 ]; then exit $rc; fi; if [ "${OK:-0}" != 1 ]; then exit 1; fi; exit 0' EXIT

[ -f "$HELPER" ] || { echo "✗ 找不到被测钩子: $HELPER"; exit 1; }

ok() { [ -n "$QUIET" ] || echo "  ✓ $1"; }
bad() {
	echo "  ✗ $1"
	echo "$CUR_CASE" >> "$FAILFILE"
}

# ── 运行钩子 ────────────────────────────────────────────────────────────────
# run_env <path_prefix|""> [ENV=VAL ...]  不预设 PB_PREUPGRADE_DB（走路径解析）
run_env() {
	rp="$1"; shift
	env -u PB_PREUPGRADE_DB -u PB_PREUPGRADE_KEEP -u PB_PREUPGRADE_MIN_FREE_KB \
		PATH="${rp:+$rp:}$PATH" "$@" sh "$HELPER_UNDER_TEST"
}
# run_db <db> [ENV=VAL ...]  直接指定库文件（隔离路径解析,专注快照逻辑）
run_db() {
	rd_db="$1"; shift
	run_env "" "PB_PREUPGRADE_DB=$rd_db" "$@"
}

backups() {
	for rd_f in "$1".bak-*; do
		[ -f "$rd_f" ] || continue
		echo "$rd_f"
	done | sort
}
count_backups() { backups "$1" | wc -l | tr -d ' '; }

# ── C1 首次备份 ────────────────────────────────────────────────────────────
case_c1() {
	CUR_CASE=C1
	rd_d="$(mktemp -d "$TMPROOT/c1.XXXXXX")"
	rd_db="$rd_d/fileCodeBox.db"
	echo "SQLite format 3 v1 payload" > "$rd_db"
	rd_out="$(run_db "$rd_db" 2>&1)"; rd_rc=$?
	rd_n="$(count_backups "$rd_db")"
	[ "$rd_rc" -eq 0 ] && ok "C1 退出码 0" || bad "C1 退出码 $rd_rc,应为 0"
	[ "$rd_n" -eq 1 ] && ok "C1 首跑生成 1 份快照" || bad "C1 首跑生成 $rd_n 份快照,应为 1"
	rd_bak="$(backups "$rd_db" | head -1)"
	if [ -n "$rd_bak" ] && cmp -s "$rd_db" "$rd_bak"; then
		ok "C1 快照与源库逐字节一致"
	else
		bad "C1 快照缺失或内容与源库不一致"
	fi
	case "$rd_bak" in
	"$rd_db".bak-[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]-[0-9][0-9][0-9][0-9][0-9][0-9])
		ok "C1 命名形态 <db>.bak-YYYYMMDD-HHMMSS"
		;;
	*) bad "C1 命名形态不对: $rd_bak" ;;
	esac
	echo "$rd_out" | grep -q "已生成升级前快照" && ok "C1 日志声明已生成快照" || bad "C1 日志未声明快照"
}

# ── C2 数据目录含空格 ──────────────────────────────────────────────────────
case_c2() {
	CUR_CASE=C2
	rd_d="$(mktemp -d "$TMPROOT/c2.XXXXXX")"
	mkdir -p "$rd_d/Configs My Dir"
	rd_db="$rd_d/Configs My Dir/fileCodeBox.db"
	echo "v2" > "$rd_db"
	run_db "$rd_db" >/dev/null 2>&1; rd_rc=$?
	rd_n="$(count_backups "$rd_db")"
	[ "$rd_rc" -eq 0 ] && ok "C2 路径含空格:退出码 0" || bad "C2 路径含空格:退出码 $rd_rc"
	[ "$rd_n" -eq 1 ] && ok "C2 路径含空格仍能备份" || bad "C2 路径含空格未生成快照(引号回归?)"
}

# ── C3 轮转:只留最近 3 份 ─────────────────────────────────────────────────
case_c3() {
	CUR_CASE=C3
	rd_d="$(mktemp -d "$TMPROOT/c3.XXXXXX")"
	rd_db="$rd_d/fileCodeBox.db"
	echo "v3" > "$rd_db"
	for rd_i in 1 2 3 4; do
		: > "$rd_db.bak-20200101-00000$rd_i"
	done
	run_db "$rd_db" >/dev/null 2>&1
	rd_n="$(count_backups "$rd_db")"
	[ "$rd_n" -eq 3 ] && ok "C3 轮转后只剩 3 份(原有 4 份 + 新 1 份)" || bad "C3 轮转后剩 $rd_n 份,应为 3"
	[ -f "$rd_db.bak-20200101-000001" ] && bad "C3 最旧的一份没被淘汰" || ok "C3 最旧的一份被淘汰"
	[ -f "$rd_db.bak-20200101-000002" ] && bad "C3 次旧的一份没被淘汰" || ok "C3 次旧的一份被淘汰"
	if [ -f "$rd_db.bak-20200101-000003" ] && [ -f "$rd_db.bak-20200101-000004" ]; then
		ok "C3 保留的是最新三份(两份较新的旧快照 + 本次新生成的)"
	else
		bad "C3 误删了较新的旧快照(不是「只删最旧」)"
	fi
}

# ── C4 空间守卫 ────────────────────────────────────────────────────────────
case_c4() {
	CUR_CASE=C4
	rd_d="$(mktemp -d "$TMPROOT/c4.XXXXXX")"
	rd_db="$rd_d/fileCodeBox.db"
	echo "v4" > "$rd_db"
	rd_before="$(cksum "$rd_db")"
	rd_out="$(run_db "$rd_db" "PB_PREUPGRADE_MIN_FREE_KB=999999999" 2>&1)"; rd_rc=$?
	rd_n="$(count_backups "$rd_db")"
	[ "$rd_rc" -eq 0 ] && ok "C4 空间不足:仍退出 0(不中止安装)" || bad "C4 退出码 $rd_rc,应为 0"
	[ "$rd_n" -eq 0 ] && ok "C4 空间不足:没有生成快照" || bad "C4 空间不足却生成了 $rd_n 份快照(守卫失效)"
	[ "$(cksum "$rd_db")" = "$rd_before" ] && ok "C4 源库未被改动" || bad "C4 源库被改动"
	echo "$rd_out" | grep -q "可用空间不足" && ok "C4 日志说明跳过原因" || bad "C4 日志未说明跳过原因"
}

# ── C5 全新安装:没有存量库 ────────────────────────────────────────────────
case_c5() {
	CUR_CASE=C5
	if [ -f /etc/pigeonbox/data/fileCodeBox.db ]; then
		echo "  - C5 跳过:本机存在 /etc/pigeonbox/data/fileCodeBox.db(解析器会命中它)"
		return 0
	fi
	rd_d="$(mktemp -d "$TMPROOT/c5.XXXXXX")"
	mkdir -p "$rd_d/shim"
	echo '#!/bin/sh' > "$rd_d/shim/uci"
	echo 'exit 0' >> "$rd_d/shim/uci"
	chmod +x "$rd_d/shim/uci"
	rd_out="$(run_env "$rd_d/shim" 2>&1)"; rd_rc=$?
	rd_n="$(count_backups "$rd_d/fileCodeBox.db")"
	[ "$rd_rc" -eq 0 ] && ok "C5 无存量库:退出码 0" || bad "C5 退出码 $rd_rc,应为 0"
	[ "$rd_n" -eq 0 ] && ok "C5 无存量库:没有生成快照" || bad "C5 无存量库却生成了 $rd_n 份快照"
	echo "$rd_out" | grep -q "没有存量业务库" && ok "C5 日志说明跳过原因" || bad "C5 日志未说明跳过原因"
}

# ── C6 拷贝失败绝不中止安装 ───────────────────────────────────────────────
case_c6() {
	CUR_CASE=C6
	rd_d="$(mktemp -d "$TMPROOT/c6.XXXXXX")"
	rd_db="$rd_d/fileCodeBox.db"
	echo "v6" > "$rd_db"
	mkdir -p "$rd_d/shim"
	echo '#!/bin/sh' > "$rd_d/shim/cp"
	echo 'exit 1' >> "$rd_d/shim/cp"
	chmod +x "$rd_d/shim/cp"
	rd_out="$(run_env "$rd_d/shim" "PB_PREUPGRADE_DB=$rd_db" 2>&1)"; rd_rc=$?
	rd_n="$(count_backups "$rd_db")"
	[ "$rd_rc" -eq 0 ] && ok "C6 拷贝失败:仍退出 0(绝不让升级失败)" || bad "C6 拷贝失败却返回 $rd_rc —— 会把安装搞挂"
	[ "$rd_n" -eq 0 ] && ok "C6 拷贝失败:没留下残缺文件" || bad "C6 拷贝失败却留下 $rd_n 个残留文件"
	echo "$rd_out" | grep -q "快照失败" && ok "C6 日志响亮报错(不是静默跳过)" || bad "C6 日志没报错(静默跳过)"
}

# ── C7 静默截断必须被校验捕获 ─────────────────────────────────────────────
case_c7() {
	CUR_CASE=C7
	rd_d="$(mktemp -d "$TMPROOT/c7.XXXXXX")"
	rd_db="$rd_d/fileCodeBox.db"
	echo "full-content-here-do-not-truncate" > "$rd_db"
	mkdir -p "$rd_d/shim"
	# 假 cp:只写前 3 字节,却**返回 0**(不报错) ⇒ 静默截断场景
	cat > "$rd_d/shim/cp" <<'SHIM'
#!/bin/sh
for rd_a in "$@"; do rd_dst="$rd_a"; done
echo tru > "$rd_dst"
exit 0
SHIM
	chmod +x "$rd_d/shim/cp"
	rd_out="$(run_env "$rd_d/shim" "PB_PREUPGRADE_DB=$rd_db" 2>&1)"; rd_rc=$?
	rd_n="$(count_backups "$rd_db")"
	[ "$rd_rc" -eq 0 ] && ok "C7 校验失败:退出码 0" || bad "C7 退出码 $rd_rc,应为 0"
	[ "$rd_n" -eq 0 ] && ok "C7 校验失败:残缺快照被删除" || bad "C7 校验失败却留下残缺快照(会冒充可用备份)"
	echo "$rd_out" | grep -q "校验失败" && ok "C7 日志声明校验失败" || bad "C7 日志未声明校验失败"
}

# ── C8 按 UCI 固化的 data_dir 定位 ────────────────────────────────────────
case_c8() {
	CUR_CASE=C8
	rd_d="$(mktemp -d "$TMPROOT/c8.XXXXXX")"
	rd_db="$rd_d/fileCodeBox.db"
	echo "v8" > "$rd_db"
	mkdir -p "$rd_d/shim"
	# 假 uci:只答 pigeonbox.main.data_dir(目录经独立文件传,免得为拼字符串跟引号打架)
	echo "$rd_d" > "$rd_d/shim/datadir"
	cat > "$rd_d/shim/uci" <<'SHIM'
#!/bin/sh
[ "$1" = "-q" ] && shift
[ "$1" = "get" ] || exit 0
if [ "$2" = "pigeonbox.main.data_dir" ]; then
	cat "$(dirname "$0")/datadir"
fi
exit 0
SHIM
	chmod +x "$rd_d/shim/uci"
	run_env "$rd_d/shim" 2>/dev/null; rd_rc=$?
	rd_n="$(count_backups "$rd_db")"
	[ "$rd_rc" -eq 0 ] && ok "C8 退出码 0" || bad "C8 退出码 $rd_rc,应为 0"
	[ "$rd_n" -eq 1 ] && ok "C8 按 UCI 固化的 data_dir 找到库并备份" || bad "C8 未按 UCI 解析到库(生成 $rd_n 份)"
}

# ── C9 静态守卫:钩子必须调它、且必须在 restart 之前 ────────────────────
case_c9() {
	CUR_CASE=C9
	for rd_hook in "$SCRIPT_DIR/../openwrt/pigeonbox.postinst" "$SCRIPT_DIR/../openwrt/pigeonbox.post-install"; do
		rd_name="$(basename "$rd_hook")"
		if [ ! -f "$rd_hook" ]; then
			bad "C9 找不到钩子文件 $rd_name"
			continue
		fi
		if ! grep -q "preupgrade_backup" "$rd_hook"; then
			bad "C9 $rd_name 没有调用快照钩子(文件装了却没人调 ⇒ 功能静默消失)"
			continue
		fi
		rd_call="$(grep -n "preupgrade_backup" "$rd_hook" | head -1 | cut -d: -f1)"
		rd_restart="$(grep -n "init.d/pigeonbox restart" "$rd_hook" | head -1 | cut -d: -f1)"
		if [ -n "$rd_call" ] && [ -n "$rd_restart" ] && [ "$rd_call" -lt "$rd_restart" ]; then
			ok "C9 $rd_name 在 restart 之前调用快照钩子"
		else
			bad "C9 $rd_name 调用位置不对(call=$rd_call restart=$rd_restart):必须早于 restart,否则拍到的是迁移后的库"
		fi
	done
}

# ── 套件 ───────────────────────────────────────────────────────────────────
run_suite() { # run_suite <helper> <quiet|"">
	HELPER_UNDER_TEST="$1"
	QUIET="$2"
	FAILFILE="$TMPROOT/fails.$(date +%s%N)"
	: > "$FAILFILE"
	case_c1
	case_c2
	case_c3
	case_c4
	case_c5
	case_c6
	case_c7
	case_c8
	case_c9
	rd_fails="$(wc -l < "$FAILFILE" | tr -d ' ')"
	SUITE_LAST_FAILS="$rd_fails"
}

# ── 变异引擎 ───────────────────────────────────────────────────────────────
mutate() { # mutate <name> <old> <new>
	python3 - "$HELPER" "$TMPROOT/mut.$1" "$2" "$3" <<'PY'
import sys
src, dst, old, new = sys.argv[1:5]
s = open(src, encoding="utf-8").read()
if old not in s:
    sys.exit("变异锚点未命中: " + old[:60])
open(dst, "w", encoding="utf-8").write(s.replace(old, new, 1))
PY
}

mut_expect() { # mut_expect <name> <expect_case> <old> <new> <desc>
	echo "── 变异 $1($5)⇒ 期望 $2 转红"
	if ! mutate "$1" "$3" "$4"; then
		echo "✗ 变异 $1 未生效(锚点没命中)⇒ 负对照无效"
		exit 1
	fi
	chmod +x "$TMPROOT/mut.$1"
	if ! sh -n "$TMPROOT/mut.$1"; then
		echo "✗ 变异 $1 语法已坏 ⇒ 负对照无效"
		exit 1
	fi
	run_suite "$TMPROOT/mut.$1" quiet
	if grep -qx "$2" "$FAILFILE"; then
		echo "  ✓ $2 如期转红(判据有牙齿)"
	else
		echo "  ✗ $2 没转红 ⇒ 该判据测不出这种回归"
		exit 1
	fi
}

if [ "$#" -gt 0 ] && [ "$1" = "--selfcheck" ]; then
	echo "== 基线(真钩子,全部判据必须绿)"
	run_suite "$HELPER" ""
	if [ "$SUITE_LAST_FAILS" -ne 0 ]; then
		echo "✗ 基线就红了($SUITE_LAST_FAILS 条)⇒ 自测自身失效,先修真钩子或真判据"
		exit 1
	fi
	echo "✓ 基线全绿"
	mut_expect M1 C3 \
		'	rm -f "$f"' \
		'	:' \
		'关掉轮转(全部保留)'
	mut_expect M2 C4 \
		'if [ "$avail_kb" -lt "$need_kb" ]; then' \
		'if false; then' \
		'关掉空间守卫'
	mut_expect M3 C6 \
		'	log "快照失败:${DB} -> ${BAK}(升级继续;业务库未改动)"' \
		'	log "快照失败:${DB} -> ${BAK}(升级继续;业务库未改动)"
	exit 1' \
		'失败时改成 exit 1'
	mut_expect M4 C7 \
		'cmp -s "$DB" "$BAK" || verify_ok=0' \
		'verify_ok=1' \
		'关掉字节校验'
	mut_expect M5 C8 \
		'		uci_dir="$(uci -q get pigeonbox.main.data_dir 2>/dev/null)"' \
		'		uci_dir=""' \
		'不查 UCI'
	echo "✓ 5 组变异负对照全部如期转红"
	OK=1
	exit 0
fi

echo "== openwrt/preupgrade_backup 判据(共 9 组)"
run_suite "$HELPER" ""
if [ "$SUITE_LAST_FAILS" -eq 0 ]; then
	echo "✓ 全部判据通过"
	OK=1
	exit 0
fi
echo "✗ $SUITE_LAST_FAILS 条判据失败,涉及用例: $(sort -u "$FAILFILE" | tr '\n' ' ')"
exit 1
