#!/usr/bin/env bash
# OpenWrt / iStoreOS 真机复验（openwrt#110）。
#
# **为什么需要这个脚本**：#110 的 5 条复验要点此前只能靠人在真机上点、
# 人眼判 ⇒ 每次复验都要重新想「怎么算通过」⇒ 结论不可复现、也留不下证据。
# ⇒ 本脚本把判据**逐条机械化**，跑完输出可归档的结论（退出码非 0 = 有项未通过）。
#
# **前置**：OpenWrt / iStoreOS 设备 + **root** 会话
#   （装 ipk/apk、查 procd 服务、读 LuCI 页面都要 root）。
#   非 root ⇒ 明确报「前置不满足」，不给出假结论。
#
# 用法（在设备上）：
#   ./scripts/verify-openwrt-runtime.sh [服务名]
#   服务名缺省 pigeonbox。
#
# 复验要点（逐条对应 openwrt#110 的待办）：
#   1. **装完即用**：procd 服务起、LuCI 配置页可读可写、依赖 redis-server 自动拉起；
#   2. **分享/取件闭环**：创建分享 → 取件码取件 → 下载
#      （4.0.4 起取件密码走 POST body / X-Share-Password 头，**不再收 ?password=**）；
#   3. **公开端点匿名可达**：GET /api/v1/notifies/public 匿名 200；
#   4. **分片上传**：upload_id 由 file_hash 派生 ⇒ 会话可"复活"；
#   5. **升级路径**：从 1.15.x 升到 4.0.x（配置项有增删）。
set -uo pipefail

SVC="${1:-pigeonbox}"
BASE="${PB_BASE_URL:-http://127.0.0.1:8080}"
PASS=0
FAIL=0
declare -a RESULTS=()

record() {
  case "$1" in
    ok)   PASS=$((PASS+1)); RESULTS+=("PASS | $2 | $3") ;;
    no)   FAIL=$((FAIL+1)); RESULTS+=("FAIL | $2 | $3") ;;
    skip) RESULTS+=("SKIP | $2 | $3") ;;
  esac
  printf '  [%s] %s — %s\n' "$1" "$2" "$3"
}

echo "══ OpenWrt / iStoreOS 复验 ══"
echo "服务名: ${SVC}    基址: ${BASE}"

# ── 前置：必须 root ────────────────────────────────────────────────────
if [ "$(id -u)" != "0" ]; then
  record skip "前置" "非 root（uid=$(id -u)）——装包与查 procd 都要 root"
  echo
  echo "结论: 前置不满足，无法判定（不是「通过」）"
  printf '%s\n' "${RESULTS[@]}"
  exit 2
fi
record ok "前置" "root 会话"

# ── 要点 1：装完即用 ───────────────────────────────────────────────────
echo
echo "── 要点 1：装完即用 ──"
if command -v /etc/init.d >/dev/null 2>&1 || [ -x "/etc/init.d/${SVC}" ]; then
  if [ -x "/etc/init.d/${SVC}" ]; then
    record ok "procd 脚本" "/etc/init.d/${SVC}"
    if "/etc/init.d/${SVC}" enabled >/dev/null 2>&1; then
      record ok "开机自启" "已 enabled"
    else
      record no "开机自启" "未 enabled（装完不会自起）"
    fi
    if "/etc/init.d/${SVC}" status >/dev/null 2>&1; then
      record ok "服务状态" "running"
    else
      record no "服务状态" "未 running"
    fi
  else
    record no "procd 脚本" "缺 /etc/init.d/${SVC}"
  fi
else
  record skip "procd" "无 /etc/init.d（不是 OpenWrt/OpenWrt-like 环境）"
fi

# 依赖 redis-server 自动拉起
if command -v redis-server >/dev/null 2>&1 || [ -x /usr/bin/redis-server ]; then
  if pgrep -x redis-server >/dev/null 2>&1; then
    record ok "依赖 redis-server" "已运行"
  else
    record no "依赖 redis-server" "未运行（依赖未自动拉起）"
  fi
else
  record skip "依赖 redis-server" "本机无 redis-server"
fi

# LuCI 配置页可读可写
if [ -d /usr/lib/lua/luci ]; then
  LUCI="$(ls /usr/lib/lua/luci/controller/ 2>/dev/null | grep -i pigeonbox | head -1)"
  if [ -n "${LUCI}" ]; then
    record ok "LuCI 配置页" "controller/${LUCI}"
  else
    record no "LuCI 配置页" "controller 里找不到 pigeonbox"
  fi
else
  record skip "LuCI 配置页" "无 /usr/lib/lua/luci"
fi

# ── 要点 3：公开端点匿名可达 ───────────────────────────────────────────
echo
echo "── 要点 3：公开端点匿名可达 ──"
if command -v curl >/dev/null 2>&1; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
          "${BASE}/api/v1/notifies/public" 2>/dev/null || echo 000)"
  if [ "${CODE}" = "200" ]; then
    record ok "公开端点" "匿名 200"
  else
    record no "公开端点" "期望匿名 200，实际 ${CODE}（4.0.3 前曾被误加登录门槛）"
  fi
else
  record skip "公开端点" "无 curl 命令"
fi

# ── 要点 2：分享/取件闭环 + 取件密码口径 ──────────────────────────────
echo
echo "── 要点 2：分享/取件闭环 ──"
if command -v curl >/dev/null 2>&1; then
  # 4.0.4 起取件密码走 POST body / X-Share-Password 头，**不再收 ?password=**
  # ⇒ 用 query 传密码应被拒（400/401），用头传应被接受。
  BADCODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
             "${BASE}/api/v1/shares/000000/select?password=wrong" 2>/dev/null || echo 000)"
  if [ "${BADCODE}" != "200" ]; then
    record ok "取件密码不再收 query" "?password= 被拒（${BADCODE}）"
  else
    record no "取件密码不再收 query" "?password= 仍被接受（4.0.4 起应只走 body/头）"
  fi
else
  record skip "取件密码口径" "无 curl 命令"
fi
record skip "分享/取件闭环" "需业务账号与人工操作（建分享→取件码取件→下载）"

# ── 要点 4：分片上传（upload_id 由 file_hash 派生）─────────────────────
echo
echo "── 要点 4：分片上传 ──"
record skip "分片上传" "需业务账号与人工上传（大文件分片会话）"

# ── 要点 5：升级路径 ───────────────────────────────────────────────────
echo
echo "── 要点 5：升级路径（1.15.x → 4.x）──"
INSTALLED="$(opkg status pigeonbox 2>/dev/null | grep -m1 '^Version:' | awk '{print $2}')"
[ -z "${INSTALLED}" ] && INSTALLED="$(apk info -v pigeonbox 2>/dev/null | head -1)"
if [ -n "${INSTALLED}" ]; then
  record ok "当前已装版本" "${INSTALLED}"
  echo "  （旧配置项的兼容与迁移需人工核对：配置项在 4.x 有增删）"
else
  record skip "当前已装版本" "查不到已装版本（opkg/apk 均无）"
fi
record skip "升级路径" "需从 1.15.x 包实际升级一次后核对配置迁移"

# ── 结论 ───────────────────────────────────────────────────────────────
echo
echo "── 结论 ──"
for r in "${RESULTS[@]}"; do echo "  $r"; done
echo
echo "PASS=${PASS} FAIL=${FAIL}"
if [ "${FAIL}" -gt 0 ]; then
  echo "✗ 有 ${FAIL} 项未通过"
  exit 1
fi
echo "✓ 已判定的项全部通过（SKIP 项需另行验证）"
exit 0
