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

# ── 外部探针可注入（默认仍是真命令）──────────────────────────────────────
# 为什么可注入：这份脚本是 **openwrt#110 关单的证据工具** ⇒ 判据必须能判红；
# 而判据依赖真机（/etc/init.d、redis、LuCI 目录、curl、pgrep、id）
# ⇒ 没法在 CI 里驱动它进「异常态」⇒ 把探针做成可注入
# ⇒ --selfcheck 用**假设备**证明每条判据都会红。
#
# ⚠️ **只认环境变量里的探针** ⇒ 真机上不设 ⇒ 行为与从前完全一致。
CMD_CURL="${PB_CMD_CURL:-curl}"
CMD_PGREP="${PB_CMD_PGREP:-pgrep}"
CMD_ID="${PB_CMD_ID:-id}"
INITD_DIR="${PB_INITD_DIR:-/etc/init.d}"
LUCI_DIR="${PB_LUCI_DIR:-/usr/lib/lua/luci}"
# redis 是否存在（默认按真机探测；自证时可显式设 0 模拟「本机无 redis-server」）
if [ -n "${PB_REDIS_PRESENT:-}" ]; then
  REDIS_PRESENT="$PB_REDIS_PRESENT"
elif command -v redis-server >/dev/null 2>&1 || [ -x /usr/bin/redis-server ]; then
  REDIS_PRESENT=1
else
  REDIS_PRESENT=0
fi

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

# ── 自证模式：证明每条判据**能判红** ──────────────────────────────────────
# 这份脚本是 **openwrt#110 关单的证据工具** ⇒ 判据必须能判红；
# 若某条判据因环境变化静默失效 ⇒ 脚本照样报「✓ 已判定的项全部通过」
# ⇒ **关单证据不可信**。
# ⇒ 用**假设备**（假 init.d、假 LuCI 目录、假 curl/pgrep/id）驱动**脚本自己**
#   （"$0" + 注入的探针 ⇒ 真实代码路径，不是副本）⇒ 每条判据都能被驱动进「异常态」。
if [ "${1:-}" = "--selfcheck" ]; then
  SELF_DIR="$(mktemp -d)"
  trap 'rm -rf "$SELF_DIR"' EXIT
  FAKE="$SELF_DIR/bin"
  INITD="$SELF_DIR/initd"
  LUCI="$SELF_DIR/luci"
  mkdir -p "$FAKE" "$INITD" "$LUCI/controller"

  # 假 procd 脚本：enabled/status 的成败由 PB_FAKE_* 决定
  cat > "$INITD/pigeonbox" <<'PROCD_EOF'
#!/bin/sh
case "$1" in
  enabled) [ "${PB_FAKE_ENABLED:-yes}" = "no" ] && exit 1; exit 0 ;;
  status)  [ "${PB_FAKE_RUNNING:-yes}" = "no" ] && exit 1; exit 0 ;;
esac
exit 0
PROCD_EOF
  # 假 curl：按 URL 返回状态码（模式由 PB_FAKE_CURL 决定）
  cat > "$FAKE/curl" <<'CURL_EOF'
#!/bin/sh
url=""
for a in "$@"; do url="$a"; done
case "$url" in
  *notifies/public*) code=200 ;;
  *password=*)       code=401 ;;
  *)                 code=200 ;;
esac
case "${PB_FAKE_CURL:-good}" in
  public401) case "$url" in *notifies/public*) code=401 ;; esac ;;
  query200)  case "$url" in *password=*) code=200 ;; esac ;;
esac
printf '%s' "$code"
CURL_EOF
  # 假 pgrep：PB_FAKE_REDIS=no ⇒ redis 没起来
  cat > "$FAKE/pgrep" <<'PGREP_EOF'
#!/bin/sh
[ "${PB_FAKE_REDIS:-yes}" = "no" ] && exit 1
exit 0
PGREP_EOF
  # 假 id：PB_FAKE_ID=1000 ⇒ 非 root
  cat > "$FAKE/id" <<'ID_EOF'
#!/bin/sh
[ "${1:-}" = "-u" ] && printf '%s\n' "${PB_FAKE_ID:-0}" && exit 0
printf 'uid=%s\n' "${PB_FAKE_ID:-0}"
ID_EOF
  chmod +x "$FAKE"/* "$INITD/pigeonbox"

  # 假 LuCI controller：PB_FAKE_LUCI=none ⇒ 目录里没有 pigeonbox
  : > "$LUCI/controller/pigeonbox.lua"

  run_case() { # run_case <额外 env 赋值...> ⇒ 打印退出码
    local out rc
    out=$(env "$@" \
      PB_CMD_CURL="$FAKE/curl" PB_CMD_PGREP="$FAKE/pgrep" PB_CMD_ID="$FAKE/id" \
      PB_INITD_DIR="$INITD" PB_LUCI_DIR="$LUCI" PB_REDIS_PRESENT=1 \
      bash "$0" pigeonbox 2>&1)
    rc=$?
    printf '%s' "$out"
    return $rc
  }

  fail=0
  # ① 一切正常 ⇒ 退出码 0
  out=$(run_case PB_FAKE_LUCI=yes); rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "  ✗ 正常态应退出 0，实际 $rc" >&2; printf '%s\n' "$out" | sed 's/^/      /' >&2; fail=1
  else
    echo "  ✓ 正常态 ⇒ 退出码 0（判据不会无脑报红）"
  fi

  # ②~⑦ 每条判据各驱动一次「异常态」⇒ 必须判红且退出码 1
  for spec in \
    "procd 未 enabled:PB_FAKE_ENABLED=no" \
    "procd 非 running:PB_FAKE_RUNNING=no" \
    "依赖 redis 未运行:PB_FAKE_REDIS=no" \
    "LuCI 缺 controller:PB_FAKE_LUCI=none" \
    "公开端点非 200:PB_FAKE_CURL=public401" \
    "?password= 仍被接受:PB_FAKE_CURL=query200"; do
    label="${spec%%:*}"
    kv="${spec#*:}"
    key="${kv%%=*}"
    val="${kv#*=}"
    # ⑤ 的 LuCI 用「目录里删掉 controller 文件」来表达
    if [ "$key" = "PB_FAKE_LUCI" ]; then
      mv "$LUCI/controller/pigeonbox.lua" "$SELF_DIR/pigeonbox.lua.bak"
      out=$(run_case PB_FAKE_LUCI=none); rc=$?
      mv "$SELF_DIR/pigeonbox.lua.bak" "$LUCI/controller/pigeonbox.lua"
    else
      out=$(run_case "$key=$val"); rc=$?
    fi
    if [ "$rc" -ne 1 ]; then
      echo "  ✗ 「${label}」应判红（退出码 1），实际 $rc" >&2
      printf '%s\n' "$out" | sed 's/^/      /' >&2
      fail=1
    else
      echo "  ✓ 「${label}」⇒ 判红且退出码 1"
    fi
  done

  # ⑧ 非 root ⇒ 退出码 2（无法判定 ≠ 通过）
  out=$(run_case PB_FAKE_ID=1000); rc=$?
  if [ "$rc" -ne 2 ]; then
    echo "  ✗ 非 root 应退出 2（无法判定），实际 $rc" >&2; fail=1
  else
    echo "  ✓ 非 root ⇒ 退出码 2（无法判定 ≠ 通过）"
  fi

  if [ "$fail" -ne 0 ]; then
    echo "✗ 自证失败：至少有一条判据没有区分力" >&2
    exit 1
  fi
  echo "✓ 自证：正常态绿、每条异常态都红、非 root 报无法判定 ⇒ 判据有牙齿"
  exit 0
fi

echo "══ OpenWrt / iStoreOS 复验 ══"
echo "服务名: ${SVC}    基址: ${BASE}"

# ── 前置：必须 root ────────────────────────────────────────────────────
if [ "$(${CMD_ID} -u)" != "0" ]; then
  record skip "前置" "非 root（uid=$(${CMD_ID} -u)）——装包与查 procd 都要 root"
  echo
  echo "结论: 前置不满足，无法判定（不是「通过」）"
  printf '%s\n' "${RESULTS[@]}"
  exit 2
fi
record ok "前置" "root 会话"

# ── 要点 1：装完即用 ───────────────────────────────────────────────────
echo
echo "── 要点 1：装完即用 ──"
if [ -d "${INITD_DIR}" ] || [ -x "${INITD_DIR}/${SVC}" ]; then
  if [ -x "${INITD_DIR}/${SVC}" ]; then
    record ok "procd 脚本" "${INITD_DIR}/${SVC}"
    if "${INITD_DIR}/${SVC}" enabled >/dev/null 2>&1; then
      record ok "开机自启" "已 enabled"
    else
      record no "开机自启" "未 enabled（装完不会自起）"
    fi
    if "${INITD_DIR}/${SVC}" status >/dev/null 2>&1; then
      record ok "服务状态" "running"
    else
      record no "服务状态" "未 running"
    fi
  else
    record no "procd 脚本" "缺 ${INITD_DIR}/${SVC}"
  fi
else
  record skip "procd" "无 ${INITD_DIR}（不是 OpenWrt/OpenWrt-like 环境）"
fi

# 依赖 redis-server 自动拉起
if [ "$REDIS_PRESENT" = "1" ]; then
  if ${CMD_PGREP} -x redis-server >/dev/null 2>&1; then
    record ok "依赖 redis-server" "已运行"
  else
    record no "依赖 redis-server" "未运行（依赖未自动拉起）"
  fi
else
  record skip "依赖 redis-server" "本机无 redis-server"
fi

# LuCI 配置页可读可写
if [ -d "${LUCI_DIR}" ]; then
  LUCI="$(ls "${LUCI_DIR}/controller/" 2>/dev/null | grep -i pigeonbox | head -1)"
  if [ -n "${LUCI}" ]; then
    record ok "LuCI 配置页" "controller/${LUCI}"
  else
    record no "LuCI 配置页" "controller 里找不到 pigeonbox"
  fi
else
  record skip "LuCI 配置页" "无 ${LUCI_DIR}"
fi

# ── 要点 3：公开端点匿名可达 ───────────────────────────────────────────
echo
echo "── 要点 3：公开端点匿名可达 ──"
if command -v "${CMD_CURL}" >/dev/null 2>&1; then
  CODE="$(${CMD_CURL} -s -o /dev/null -w '%{http_code}' --max-time 8 \
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
if command -v "${CMD_CURL}" >/dev/null 2>&1; then
  # 4.0.4 起取件密码走 POST body / X-Share-Password 头，**不再收 ?password=**
  # ⇒ 用 query 传密码应被拒（400/401），用头传应被接受。
  BADCODE="$(${CMD_CURL} -s -o /dev/null -w '%{http_code}' --max-time 8 \
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
