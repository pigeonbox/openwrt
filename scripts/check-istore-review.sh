#!/bin/sh
# iStore 上架 review（linkease/istore-repo#810，reviewer jannson）修复的机械守卫。
#
# 两类缺陷都曾在真机上复现、而当时的 CI **全绿**（形态上属于「错了也不会有人喊」）：
#   ① procd **没有 args 参数**——`procd_set_param args` 被静默忽略 ⇒ p2pcweb 的
#      端口/令牌文件/接收目录参数全部丢失 ⇒ /beam 入口 503；
#   ② LuCI ACL 的 uci 项写成 `"^pigeonbox$"` 被当作普通通配规则 ⇒ 匹配不到配置名，
#      仅获本应用权限的用户读写不了配置（root 全权限会掩盖问题）。
#
# usage: check-istore-review.sh [--selfcheck]
#   --selfcheck: 用变异副本驱动判据自己（正常态绿、每类违规态红）⇒ 证明判据有牙齿。
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
INIT_RELPATH="openwrt/pigeonbox.init"
ACL_RELPATH="luci/acl.d/luci-app-pigeonbox.json"

check_tree() {
	root="$1"
	init="$root/$INIT_RELPATH"
	acl="$root/$ACL_RELPATH"
	fail=0

	if [ ! -f "$init" ]; then
		echo "✗ 缺 $INIT_RELPATH"
		fail=1
	elif grep -n -E '^[[:space:]]*procd_set_param[[:space:]]+args([[:space:]]|$)' "$init"; then
		echo "✗ init 出现 procd_set_param args——procd 不支持该参数（会被静默忽略），参数必须并入 command"
		fail=1
	else
		echo "✓ init 无 procd_set_param args 调用"
	fi

	if [ ! -f "$acl" ]; then
		echo "✗ 缺 $ACL_RELPATH"
		fail=1
	elif grep -n '"uci"[[:space:]]*:[[:space:]]*\[[^]]*\^' "$acl"; then
		echo "✗ ACL uci 项含 ^…$ 形态——LuCI 按普通通配处理、匹配不到配置名，应写 \"pigeonbox\""
		fail=1
	else
		echo "✓ ACL uci 项无 ^…$ 形态"
	fi

	if [ -f "$acl" ] && python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$acl" 2>/dev/null; then
		echo "✓ ACL JSON 可解析"
	else
		echo "✗ ACL JSON 解析失败（或文件缺失）"
		fail=1
	fi

	return "$fail"
}

selfcheck() {
	tmp="$(mktemp -d)" || exit 1
	trap 'rm -rf "$tmp"' EXIT
	mkdir -p "$tmp/openwrt" "$tmp/luci/acl.d"

	ok=0

	# 正常态：与仓内同款 ⇒ 必须绿
	cp "$ROOT/$INIT_RELPATH" "$tmp/$INIT_RELPATH"
	cp "$ROOT/$ACL_RELPATH" "$tmp/$ACL_RELPATH"
	if check_tree "$tmp" >/dev/null; then
		echo "✓ 正常态 ⇒ 绿（判据不会无脑报红）"
	else
		echo "✗ 正常态被误判红"
		ok=1
	fi

	# 变异①：重新引入 procd_set_param args ⇒ init 判据必须红
	printf '\tprocd_set_param args --lost\n' >>"$tmp/$INIT_RELPATH"
	if check_tree "$tmp" >/dev/null; then
		echo "✗ 「procd_set_param args」未被判红"
		ok=1
	else
		echo "✓ 「procd_set_param args」⇒ 判红"
	fi
	cp "$ROOT/$INIT_RELPATH" "$tmp/$INIT_RELPATH"

	# 变异②：ACL uci 项退回 ^pigeonbox$ ⇒ ACL 判据必须红
	sed 's/"uci": \["pigeonbox"\]/"uci": ["^pigeonbox$"]/' "$ROOT/$ACL_RELPATH" >"$tmp/$ACL_RELPATH"
	if check_tree "$tmp" >/dev/null; then
		echo "✗ 「uci ^pigeonbox\$」未被判红"
		ok=1
	else
		echo "✓ 「uci ^pigeonbox\$」⇒ 判红"
	fi

	# 变异③：ACL JSON 损坏 ⇒ JSON 判据必须红
	printf '{broken\n' >"$tmp/$ACL_RELPATH"
	if check_tree "$tmp" >/dev/null; then
		echo "✗ 「ACL JSON 损坏」未被判红"
		ok=1
	else
		echo "✓ 「ACL JSON 损坏」⇒ 判红"
	fi

	if [ "$ok" -eq 0 ]; then
		echo "✓ 自证：正常态绿、每类违规态都红 ⇒ 判据有牙齿"
	fi
	return "$ok"
}

case "${1:-}" in
	--selfcheck)
		selfcheck
		;;
	*)
		check_tree "$ROOT"
		;;
esac
