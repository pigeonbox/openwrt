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

# ── shellkit（编译侧统一管道；**设备侧脚本一律不引**，见 C1） ───────────────
# vendor/shellkit 是上游镜像（`shellkit vendor .` 的产物）⇒ **勿手改**。
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
. "$REPO_ROOT/vendor/shellkit/lib/bootstrap.sh"
export SHELLKIT_LANG="${SHELLKIT_LANG:-zh_CN}"

TRIPLE="${1:?用法: fetch-p2pc.sh <triple> [输出目录]}"
OUTDIR="${2:-dist}"

cd "$REPO_ROOT"

# ⚠️ DEPS.env 的钉版解析**保留手写**（不换 conf_get_any）：
#   conf_get_any 的取值序是「环境变量 > 配置层 > 文件」⇒ 会让外部环境变量
#   悄悄改掉钉版；且多行/带尾空白的口径与这里的 `tr -d ' \r'` 不同
#   ⇒ 语义会变（C2）⇒ 保持原样。
REF=$(sed -n 's/^P2PC_REF=//p' DEPS.env | tr -d ' \r')
if [ -z "$REF" ]; then
  log_info "(DEPS.env 无 P2PC_REF —— 跳过随包 p2pc/直传优雅降级)"
  exit 0
fi

BASE="https://github.com/pigeonbox/p2p/releases/download/${REF}"
TMP="$(mktemp -d)"
# 清理栈 + trap 安装（shellkit 接管 EXIT/INT/TERM/HUP）。
# ⚠️ 原来的手写 trap 由 `trap_install` 取代：处理器取 $? 后原样 `exit "$__st"`
#    ⇒ **退出码照旧透传**（C3）。本脚本所有失败出口都显式 `die 1`
#    ⇒ 与原「OK 哨兵」等价。
# shellcheck disable=SC2016  # 单引号是**故意的**：清理命令要在 trap 触发时再求值
trap_push 'rm -rf "$TMP"'
trap_install

# 从 checksums.txt 取某个资产的 sha256（stdout；找不到 ⇒ 空串）。
# ⚠️ 口径与原脚本的 `grep " <资产>$" | sha256sum -c -` 对齐：
#   只认「**空格 + 资产名结尾**」的行（二进制模式的 `*<资产名>` 不匹配，
#   与原脚本同）；这里用字面比较而不是正则 ⇒ 资产名里的正则元字符不会误伤。
_sha_of() { # <资产名>
  awk -v n=" $1" 'length($0) >= length(n) && substr($0, length($0) - length(n) + 1) == n { print $1; exit }' "$TMP/checksums.txt"
}

# 下载一个资产并做 sha256 校验。
# ⚠️ **兜底链保留**（原来就有）：curl 不通 ⇒ 换 `gh release download`。
#   shellkit 的 net_download 只认 curl/wget ⇒ gh 兜底仍要手写。
# ⚠️ 校验不匹配（SK_VERIFY）时**不兜底**：原脚本「下载成功但校验失败 ⇒ 直接判红」，
#   不会换 gh 重下（同一个 Release 换条路下到的还是同一个坏文件）。
fetch_asset() { # <资产名> <期望 sha256；空串 ⇒ 不校验>
  local asset=$1 sha=$2 dest rc
  dest="$TMP/${asset}"
  if [ -n "$sha" ]; then
    if net_download "${BASE}/${asset}" "$dest" "$sha"; then
      return 0
    else
      rc=$?
    fi
  else
    if net_download "${BASE}/${asset}" "$dest"; then
      return 0
    else
      rc=$?
    fi
  fi
  if [ "$rc" -eq "$SK_VERIFY" ]; then
    return "$SK_VERIFY"
  fi
  if ! command -v gh >/dev/null 2>&1; then
    return 1
  fi
  gh release download "$REF" -R pigeonbox/p2p -p "$asset" -O "$dest" --clobber || return 1
  if [ -n "$sha" ]; then
    net_verify "$dest" "$sha" || return "$SK_VERIFY"
  fi
  return 0
}

if ! net_download "${BASE}/p2pc-checksums.txt" "$TMP/checksums.txt"; then
  die 1 "checksums.txt 下载失败"
fi

mkdir -p "$OUTDIR"
for pair in "p2pc-${TRIPLE}:p2pc" "p2pc-web-${TRIPLE}:p2pcweb"; do
  asset="${pair%%:*}"
  dest="${pair##*:}"
  sha="$(_sha_of "$asset")"
  if [ -z "$sha" ]; then
    # ⚠️ 资产不在 checksums.txt 里 ⇒ 原脚本的 `grep | sha256sum -c` 拿到空输入、
    #    sha256sum 对空输入返回 0 ⇒ **实际一次校验都没做**却判绿（fail-open）。
    #    本次保持**逐字等价**（不校验 ⇒ 不失败），并在此显式告警。
    log_warn "checksums.txt 里没有 ${asset} ⇒ 不做 sha256 校验（原脚本同口径）"
  fi
  rc=0
  fetch_asset "$asset" "$sha" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq "$SK_VERIFY" ]; then
      die 1 "${asset} sha256 校验失败"
    fi
    die 1 "${asset} 下载失败（curl/gh 均不可用）"
  fi
  install -m 0755 "$TMP/${asset}" "$OUTDIR/${dest}"
  log_ok "${dest} @ ${REF} (${TRIPLE})"
done
