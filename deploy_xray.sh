#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

readonly XRAY_BIN="/usr/local/bin/xray"
readonly XRAY_CONFIG_DIR="/usr/local/etc/xray"
readonly SERVER_CONFIG="${XRAY_CONFIG_DIR}/config.json"
readonly DEPLOY_DIR="/root/xray"
readonly INSTALLER_REPO="XTLS/Xray-install"
readonly INSTALLER_REF="${INSTALLER_REF:-main}"
readonly INSTALLER_API="https://api.github.com/repos/${INSTALLER_REPO}"

TEMP_DIR=""
CONFIG_COMMITTED=0
DEPLOY_SUCCEEDED=0
INSTALLER_EXECUTED=0
INSTALLER_COMMIT=""
HAD_PREVIOUS_CONFIG=0
BACKUP_CONFIG=""
XRAY_WAS_ACTIVE=0
XRAY_WAS_ENABLED=0

log() {
  printf '[xray-dual] %s\n' "$*"
}

die() {
  printf '[xray-dual] ERROR: %s\n' "$*" >&2
  exit 1
}

usage() {
  cat <<'EOF'
用法：
  sudo bash deploy_xray.sh

选项：
  -h       显示帮助

脚本会交互询问以下配置，直接回车使用缺省值；同名环境变量可预填缺省值：
  DEPLOY_MODE          部署模式：dual、vless 或 ss（默认 dual）
  SERVER_ADDRESS       客户端连接的服务器 IP 或域名（默认自动探测；失败时必填）
  VLESS_PORT           VLESS-TCP-REALITY 端口（默认 443，可输入 random 或 r）
  SS_PORT              Shadowsocks 2022 端口（无默认，必须输入或使用 random/r）
  REALITY_SERVER_NAME  REALITY 伪装域名/SNI（默认 yahoo.co.jp）
  REALITY_TARGET_PORT  伪装站 TLS 端口（默认 443）
  FALLBACK_PORT        本机防偷跑中转端口（默认 2443，可输入 random 或 r）
  SS_METHOD            SS2022 方法（默认 2022-blake3-aes-128-gcm）

所有默认、手动和随机端口都会检查当前 TCP/UDP 占用；random、r 或 R
生成范围为 10000-65535。

Xray 官方安装器：
  每次从 GitHub 解析 XTLS/Xray-install 最新 commit（默认分支 main）
  下载 install-release.sh 并用 git blob SHA 校验
  可用环境变量 INSTALLER_REF 覆盖分支/tag/commit
  执行参数：install -u root --logrotate "06:07:08"

支持的系统：
  Debian 12 / 13
  Ubuntu 24.04 / 26.04
EOF
}

cleanup() {
  if [[ -n "${TEMP_DIR}" && -d "${TEMP_DIR}" ]]; then
    rm -rf -- "${TEMP_DIR}"
  fi
}

rollback_deployment() {
  set +e
  log "部署失败，正在恢复原配置和服务状态..."
  if ((HAD_PREVIOUS_CONFIG == 1)) && [[ -f "${BACKUP_CONFIG}" ]]; then
    cp -a "${BACKUP_CONFIG}" "${SERVER_CONFIG}" ||
      log "警告：无法从 ${BACKUP_CONFIG} 恢复旧配置。"
  else
    rm -f -- "${SERVER_CONFIG}" ||
      log "警告：无法删除本次安装的配置 ${SERVER_CONFIG}。"
  fi
  systemctl daemon-reload
  if ((XRAY_WAS_ACTIVE == 1)); then
    if ! systemctl restart xray.service; then
      log "警告：旧配置已恢复，但 Xray 服务未能重新启动。"
    fi
  else
    systemctl stop xray.service >/dev/null 2>&1 || true
  fi
  if ((XRAY_WAS_ENABLED == 1)); then
    systemctl enable xray.service >/dev/null 2>&1 ||
      log "警告：未能恢复 Xray 的开机启用状态。"
  else
    systemctl disable xray.service >/dev/null 2>&1 ||
      log "警告：未能恢复 Xray 的开机禁用状态。"
  fi
}

on_exit() {
  local status=$?

  trap - EXIT
  if ((status != 0 && INSTALLER_EXECUTED == 1)); then
    log "注意：官方安装器已执行，Xray 二进制或服务单元可能已更新，且不会由本脚本回滚。"
  fi
  if ((status != 0 && CONFIG_COMMITTED == 1 && DEPLOY_SUCCEEDED == 0)); then
    rollback_deployment
  fi
  cleanup
  exit "${status}"
}
trap on_exit EXIT

while (($#)); do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "未知参数：$1"
      ;;
  esac
  shift
done

((EUID == 0)) || die "请使用 root 或 sudo 运行。"
printf '' >/dev/tty 2>/dev/null ||
  die "未检测到可用 TTY；请在交互式终端中运行。"

command -v systemctl >/dev/null 2>&1 || die "仅支持使用 systemd 的 Linux VPS。"
[[ -d /run/systemd/system ]] || die "systemd 当前未运行。"

assert_supported_os() {
  local os_id=""
  local version_id=""
  local version_major=""

  [[ -r /etc/os-release ]] ||
    die "无法读取 /etc/os-release；仅支持 Debian 12/13 与 Ubuntu 24.04/26.04。"
  # shellcheck disable=SC1091
  . /etc/os-release
  os_id="${ID:-}"
  version_id="${VERSION_ID:-}"
  version_major="${version_id%%.*}"

  case "${os_id}" in
    debian)
      case "${version_major}" in
        12|13) return 0 ;;
      esac
      ;;
    ubuntu)
      case "${version_id}" in
        24.04|26.04) return 0 ;;
      esac
      ;;
  esac

  die "不支持的系统：${PRETTY_NAME:-${os_id} ${version_id}}。仅支持 Debian 12/13 与 Ubuntu 24.04/26.04。"
}

assert_supported_os

if systemctl is-active --quiet xray.service; then
  XRAY_WAS_ACTIVE=1
fi
if systemctl is-enabled --quiet xray.service; then
  XRAY_WAS_ENABLED=1
fi

if [[ -e "${SERVER_CONFIG}" ]]; then
  printf '检测到现有配置 %s；继续会轮换凭据并覆盖配置。确认继续？[y/N]: ' \
    "${SERVER_CONFIG}" >/dev/tty
  IFS= read -r confirm_replace </dev/tty || die "读取确认失败。"
  case "${confirm_replace,,}" in
    y|yes)
      ;;
    *)
      log "已取消部署，现有配置未修改。"
      exit 0
      ;;
  esac
fi

install_dependencies() {
  if command -v curl >/dev/null 2>&1 &&
     command -v openssl >/dev/null 2>&1 &&
     command -v base64 >/dev/null 2>&1 &&
     command -v ss >/dev/null 2>&1 &&
     command -v python3 >/dev/null 2>&1; then
    return
  fi

  log "安装 curl、OpenSSL、CA 证书、python3 和端口检查工具..."
  if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y curl openssl ca-certificates coreutils iproute2 python3
  else
    die "未找到 apt-get；请先安装 curl、openssl、ca-certificates、coreutils、iproute2 和 python3。"
  fi
}

detect_server_address() {
  local detected=""

  detected="$(curl -4fsS --max-time 6 https://api.ipify.org 2>/dev/null || true)"
  if [[ ! "${detected}" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
    detected="$(curl -4fsS --max-time 6 https://ipv4.icanhazip.com 2>/dev/null |
      tr -d '[:space:]' || true)"
  fi
  if is_valid_ipv4 "${detected}"; then
    printf '%s' "${detected}"
  else
    printf ''
  fi
}

is_valid_ipv4() {
  local value="$1"
  local octets=()
  local octet=""

  [[ "${value}" =~ ^[0-9]+(\.[0-9]+){3}$ ]] || return 1
  IFS='.' read -r -a octets <<<"${value}"
  ((${#octets[@]} == 4)) || return 1
  for octet in "${octets[@]}"; do
    ((${#octet} <= 3)) || return 1
    [[ "${octet}" == "0" || ! "${octet}" =~ ^0 ]] || return 1
    ((10#${octet} <= 255)) || return 1
  done
}

is_valid_ipv6() {
  local value="$1"
  local expanded="${value}"
  local groups=()
  local group=""
  local group_count=0
  local after_compression=""

  [[ "${value}" == *:* ]] || return 1
  [[ "${value}" =~ ^[0-9A-Fa-f:]+$ ]] || return 1
  [[ "${value}" != *:::* ]] || return 1

  if [[ "${value}" == *::* ]]; then
    after_compression="${value#*::}"
    [[ "${after_compression}" != *::* ]] || return 1
    expanded="${value/::/:x:}"
  fi
  IFS=':' read -r -a groups <<<"${expanded}"
  for group in "${groups[@]}"; do
    [[ -z "${group}" ]] && continue
    [[ "${group}" == "x" || "${group}" =~ ^[0-9A-Fa-f]{1,4}$ ]] ||
      return 1
    group_count=$((group_count + 1))
  done
  if [[ "${value}" == *::* ]]; then
    ((group_count <= 8))
  else
    ((group_count == 8))
  fi
}

is_valid_domain() {
  local value="${1%.}"
  local labels=()
  local label=""

  ((${#value} >= 1 && ${#value} <= 253)) || return 1
  IFS='.' read -r -a labels <<<"${value}"
  for label in "${labels[@]}"; do
    ((${#label} >= 1 && ${#label} <= 63)) || return 1
    [[ "${label}" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?$ ]] ||
      return 1
  done
}

is_valid_server_address() {
  local value="$1"

  if [[ "${value}" == *:* ]]; then
    is_valid_ipv6 "${value}"
  elif [[ "${value}" =~ ^[0-9.]+$ ]]; then
    is_valid_ipv4 "${value}"
  else
    is_valid_domain "${value}"
  fi
}

prompt_value() {
  local variable_name="$1"
  local label="$2"
  local default_value="$3"
  local display_default="${default_value}"
  local value=""

  if (($# >= 4)); then
    display_default="$4"
  fi
  printf '%s [%s]: ' "${label}" "${display_default}" >/dev/tty
  IFS= read -r value </dev/tty || die "读取输入失败。"
  printf -v "${variable_name}" '%s' "${value:-${default_value}}"
}

select_server_address() {
  local default_value="${SERVER_ADDRESS:-${DETECTED_SERVER_ADDRESS}}"

  while true; do
    prompt_value SERVER_ADDRESS "服务器公网 IP 或域名" "${default_value}"
    if [[ "${SERVER_ADDRESS}" != *:* &&
          ! "${SERVER_ADDRESS}" =~ ^[0-9.]+$ ]]; then
      SERVER_ADDRESS="${SERVER_ADDRESS%.}"
    fi
    if is_valid_server_address "${SERVER_ADDRESS}"; then
      return
    fi
    printf '请输入有效的公网 IPv4、裸 IPv6 或域名；不要包含协议、方括号或端口。\n' \
      >/dev/tty
    default_value=""
  done
}

select_deploy_mode() {
  local default_value="${DEPLOY_MODE:-dual}"
  local value=""

  while true; do
    printf '部署模式（dual/vless/ss）[%s]: ' "${default_value}" >/dev/tty
    IFS= read -r value </dev/tty || die "读取部署模式失败。"
    value="${value:-${default_value}}"
    case "${value,,}" in
      dual|1)
        DEPLOY_MODE="dual"
        return
        ;;
      vless|vless-only|2)
        DEPLOY_MODE="vless"
        return
        ;;
      ss|ss2022|ss-only|3)
        DEPLOY_MODE="ss"
        return
        ;;
      *)
        printf '请输入 dual、vless 或 ss。\n' >/dev/tty
        ;;
    esac
  done
}

mode_has_vless() {
  [[ "${DEPLOY_MODE}" == "dual" || "${DEPLOY_MODE}" == "vless" ]]
}

mode_has_ss() {
  [[ "${DEPLOY_MODE}" == "dual" || "${DEPLOY_MODE}" == "ss" ]]
}

is_valid_port() {
  local value="$1"
  [[ "${value}" =~ ^[0-9]{1,5}$ ]] &&
    ((10#${value} >= 1 && 10#${value} <= 65535))
}

validate_port() {
  local name="$1"
  local value="$2"
  is_valid_port "${value}" || die "${name} 必须是 1-65535 之间的数字。"
}

SELECTED_PORTS=()

port_is_selected() {
  local port="$1"
  local selected=""

  for selected in "${SELECTED_PORTS[@]}"; do
    [[ "${port}" == "${selected}" ]] && return 0
  done
  return 1
}

port_is_in_use() {
  local port="$1"
  local usage=""

  usage="$(ss -H -lntup "sport = :${port}" 2>/dev/null)" || return 2
  [[ -n "${usage}" ]] || return 1
  if grep -qv 'users:(("xray",' <<<"${usage}"; then
    return 0
  fi
  return 3
}

select_local_port() {
  local variable_name="$1"
  local label="$2"
  local default_value="$3"
  local input=""
  local port=""
  local attempt=0
  local port_status=0

  while true; do
    if [[ -n "${default_value}" ]]; then
      printf '%s [%s，或输入 random/r]: ' \
        "${label}" "${default_value}" >/dev/tty
    else
      printf '%s [必填，或输入 random/r]: ' "${label}" >/dev/tty
    fi
    IFS= read -r input </dev/tty || die "读取端口输入失败。"
    input="${input:-${default_value}}"

    if [[ "${input,,}" == "random" || "${input,,}" == "r" ]]; then
      for ((attempt = 0; attempt < 500; attempt++)); do
        port=$((10000 + (RANDOM * 32768 + RANDOM) % 55536))
        port_is_selected "${port}" && continue
        if port_is_in_use "${port}"; then
          port_status=0
        else
          port_status=$?
        fi
        case "${port_status}" in
          0|3)
            continue
            ;;
          1)
            printf '已生成随机端口 %s，并确认当前 TCP/UDP 未占用。\n' \
              "${port}" >/dev/tty
            break
            ;;
          *)
            die "无法通过 ss 检查端口状态，不能确认随机端口是否被占用。"
            ;;
        esac
      done
      ((attempt < 500)) || die "尝试 500 次后仍未找到可用随机端口。"
    elif is_valid_port "${input}"; then
      port=$((10#${input}))
    else
      printf '请输入 1-65535 之间的端口，或输入 random/r。\n' >/dev/tty
      continue
    fi

    if port_is_selected "${port}"; then
      printf '端口 %s 已被本次部署的其他入站使用，请重新输入。\n' \
        "${port}" >/dev/tty
      continue
    fi

    if port_is_in_use "${port}"; then
      printf '端口 %s 已被非 Xray 进程占用，请重新输入。\n' \
        "${port}" >/dev/tty
      continue
    else
      port_status=$?
    fi
    case "${port_status}" in
      1)
        ;;
      3)
        printf '端口 %s 当前由 Xray 使用，将在重部署时复用。\n' \
          "${port}" >/dev/tty
        ;;
      *)
        die "无法检查端口 ${port} 的 TCP/UDP 占用状态。"
        ;;
    esac

    printf -v "${variable_name}" '%s' "${port}"
    SELECTED_PORTS+=("${port}")
    return
  done
}

install_dependencies

DETECTED_SERVER_ADDRESS="$(detect_server_address)"
select_deploy_mode
select_server_address
if mode_has_vless; then
  select_local_port VLESS_PORT "VLESS 监听端口" "${VLESS_PORT:-443}"
  select_local_port FALLBACK_PORT "本机 fallback 端口" "${FALLBACK_PORT:-2443}"
  prompt_value REALITY_SERVER_NAME "REALITY 伪装域名/SNI" \
    "${REALITY_SERVER_NAME:-yahoo.co.jp}"
  prompt_value REALITY_TARGET_PORT "REALITY 目标 TLS 端口" \
    "${REALITY_TARGET_PORT:-443}"
fi
if mode_has_ss; then
  select_local_port SS_PORT "Shadowsocks 监听端口" "${SS_PORT:-}"
  prompt_value SS_METHOD "Shadowsocks 2022 加密方法" \
    "${SS_METHOD:-2022-blake3-aes-128-gcm}"
fi

if mode_has_vless; then
  validate_port "REALITY_TARGET_PORT" "${REALITY_TARGET_PORT}"
  REALITY_TARGET_PORT=$((10#${REALITY_TARGET_PORT}))
  REALITY_SERVER_NAME="${REALITY_SERVER_NAME%.}"
  is_valid_domain "${REALITY_SERVER_NAME}" ||
    die "REALITY_SERVER_NAME 不是有效域名。"
fi

if mode_has_ss; then
  case "${SS_METHOD}" in
    2022-blake3-aes-128-gcm)
      SS_KEY_BYTES=16
      ;;
    2022-blake3-aes-256-gcm|2022-blake3-chacha20-poly1305)
      SS_KEY_BYTES=32
      ;;
    *)
      die "不支持的 SS_METHOD：${SS_METHOD}"
      ;;
  esac
fi

github_api_get() {
  curl -fsSL --retry 3 --connect-timeout 10 \
    -H "Accept: application/vnd.github+json" \
    -H "User-Agent: deploy_xray.sh" \
    "$@"
}

json_get() {
  local key="$1"
  python3 -c 'import json,sys; print(json.load(sys.stdin)[sys.argv[1]])' "${key}"
}

git_blob_sha1() {
  local path="$1"
  local size
  size="$(wc -c <"${path}" | tr -d '[:space:]')"
  { printf 'blob %s\0' "${size}"; cat -- "${path}"; } |
    openssl dgst -sha1 | awk '{print $NF}' | tr 'A-F' 'a-f'
}

fetch_official_installer() {
  local dest="$1"
  local commit_json=""
  local content_json=""
  local expected_blob=""
  local actual_blob=""

  log "获取 ${INSTALLER_REPO}@${INSTALLER_REF} 最新 commit..."
  commit_json="$(
    github_api_get "${INSTALLER_API}/commits/${INSTALLER_REF}"
  )" || die "无法解析 ${INSTALLER_REPO}@${INSTALLER_REF} 的最新 commit。"
  INSTALLER_COMMIT="$(
    json_get sha <<<"${commit_json}" 2>/dev/null
  )" || die "无法从 GitHub 响应解析 commit SHA。"
  [[ "${INSTALLER_COMMIT}" =~ ^[0-9a-f]{40}$ ]] ||
    die "GitHub 返回的 commit SHA 无效：${INSTALLER_COMMIT}"

  log "下载并校验 install-release.sh（${INSTALLER_COMMIT:0:12}）..."
  content_json="$(
    github_api_get \
      "${INSTALLER_API}/contents/install-release.sh?ref=${INSTALLER_COMMIT}"
  )" || die "无法获取 install-release.sh 元数据。"
  expected_blob="$(
    json_get sha <<<"${content_json}" 2>/dev/null
  )" || die "无法从 GitHub 响应解析安装器 blob SHA。"
  [[ "${expected_blob}" =~ ^[0-9a-f]{40}$ ]] ||
    die "GitHub 返回的安装器 blob SHA 无效：${expected_blob}"

  if ! python3 -c '
import base64, json, sys
obj = json.load(sys.stdin)
if obj.get("encoding") != "base64":
    raise SystemExit("unexpected encoding: %r" % (obj.get("encoding"),))
sys.stdout.buffer.write(base64.b64decode(obj["content"]))
' <<<"${content_json}" >"${dest}" 2>/dev/null; then
    die "无法从 GitHub 响应解析安装器内容。"
  fi

  actual_blob="$(git_blob_sha1 "${dest}")"
  [[ "${actual_blob}" == "${expected_blob}" ]] ||
    die "官方安装器 blob SHA 不匹配（got ${actual_blob}，want ${expected_blob}）。"
  log "已校验官方安装器 commit=${INSTALLER_COMMIT:0:12} blob=${expected_blob:0:12}"
}

logrotate_timer_schedule() {
  local schedule=""
  local unit_text=""

  schedule="$(
    systemctl show -p TimersCalendar --value logrotate@xray.timer 2>/dev/null || true
  )"
  if [[ -n "${schedule}" ]]; then
    printf '%s' "${schedule}"
    return 0
  fi

  unit_text="$(systemctl cat logrotate@xray.timer 2>/dev/null || true)"
  if [[ -n "${unit_text}" ]]; then
    grep -E '^OnCalendar=' <<<"${unit_text}" 2>/dev/null | tr '\n' ' ' || true
    return 0
  fi
  printf ''
}

logrotate_timer_needs_repair() {
  local schedule=""

  if ! systemctl cat logrotate@xray.timer >/dev/null 2>&1; then
    log "未找到 logrotate@xray.timer，需要由官方安装器修复。"
    return 0
  fi
  if ! systemctl is-enabled --quiet logrotate@xray.timer; then
    log "logrotate@xray.timer 未启用，需要由官方安装器修复。"
    return 0
  fi

  schedule="$(logrotate_timer_schedule)"
  if [[ -z "${schedule}" ]]; then
    log "无法读取 logrotate@xray.timer 的日历配置，需要由官方安装器修复。"
    return 0
  elif [[ "${schedule}" != *"06:07:08"* ]]; then
    log "logrotate@xray.timer 执行时间不是 06:07:08，需要由官方安装器修复。"
    return 0
  fi

  if ! systemctl is-active --quiet logrotate@xray.timer; then
    systemctl start logrotate@xray.timer >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet logrotate@xray.timer; then
      log "logrotate@xray.timer 未能处于 active 状态，需要由官方安装器修复。"
      return 0
    fi
  fi
  return 1
}

assert_logrotate_timer() {
  local schedule=""

  systemctl cat logrotate@xray.timer >/dev/null 2>&1 ||
    die "未找到 logrotate@xray.timer。"
  systemctl is-enabled --quiet logrotate@xray.timer ||
    die "logrotate@xray.timer 未启用。"

  schedule="$(logrotate_timer_schedule)"
  if [[ -z "${schedule}" ]]; then
    die "无法确认 logrotate@xray.timer 的 OnCalendar。"
  elif [[ "${schedule}" != *"06:07:08"* ]]; then
    die "logrotate@xray.timer 的执行时间不是 06:07:08。"
  fi

  if ! systemctl is-active --quiet logrotate@xray.timer; then
    systemctl start logrotate@xray.timer >/dev/null 2>&1 || true
    if ! systemctl is-active --quiet logrotate@xray.timer; then
      die "logrotate@xray.timer 未处于 active 状态。"
    fi
  fi
}

service_exec_start_is_expected() {
  local value="$1"
  local expected="$2"
  local argv="${value}"

  if [[ "${value}" == *"argv[]="* ]]; then
    argv="${value#*argv[]=}"
    argv="${argv%% ;*}"
  fi
  [[ "${argv}" == "${expected}" ]]
}

TEMP_DIR="$(mktemp -d)"
INSTALLER_FILE="${TEMP_DIR}/install-release.sh"

fetch_official_installer "${INSTALLER_FILE}"

log "运行官方安装器（User=root，日志轮换时间 06:07:08）..."
INSTALL_ARGS=(install -u root --logrotate "06:07:08")
INSTALLER_EXECUTED=1
bash "${INSTALLER_FILE}" "${INSTALL_ARGS[@]}"

[[ -x "${XRAY_BIN}" ]] || die "Xray 安装失败：未找到 ${XRAY_BIN}"

SERVICE_REPAIR_REQUIRED=0
INSTALLED_SERVICE_USER="$(
  systemctl show -p User --value xray.service 2>/dev/null || true
)"
INSTALLED_SERVICE_EXEC_START="$(
  systemctl show -p ExecStart --value xray.service 2>/dev/null || true
)"
EXPECTED_SERVICE_COMMAND="${XRAY_BIN} run -config ${SERVER_CONFIG}"

if ! systemctl cat xray.service >/dev/null 2>&1; then
  log "未找到有效的 xray.service，需要由官方安装器修复。"
  SERVICE_REPAIR_REQUIRED=1
fi
if [[ "${INSTALLED_SERVICE_USER:-root}" != "root" ]]; then
  log "xray.service 当前未以 root 运行，需要由官方安装器修复。"
  SERVICE_REPAIR_REQUIRED=1
fi
if ! service_exec_start_is_expected \
  "${INSTALLED_SERVICE_EXEC_START}" "${EXPECTED_SERVICE_COMMAND}"; then
  log "xray.service 当前未使用 ${SERVER_CONFIG}，需要由官方安装器修复。"
  SERVICE_REPAIR_REQUIRED=1
fi
if logrotate_timer_needs_repair; then
  SERVICE_REPAIR_REQUIRED=1
fi

if ((SERVICE_REPAIR_REQUIRED == 1)); then
  log "重新安装以修复 Xray 官方服务配置..."
  bash "${INSTALLER_FILE}" \
    install --reinstall -u root --logrotate "06:07:08"
  systemctl daemon-reload
fi

systemctl cat xray.service >/dev/null 2>&1 ||
  die "未找到有效的 xray.service。"
INSTALLED_SERVICE_USER="$(
  systemctl show -p User --value xray.service 2>/dev/null || true
)"
[[ "${INSTALLED_SERVICE_USER:-root}" == "root" ]] ||
  die "Xray systemd 服务未能切换为 root 用户。"
INSTALLED_SERVICE_EXEC_START="$(
  systemctl show -p ExecStart --value xray.service 2>/dev/null || true
)"
service_exec_start_is_expected \
  "${INSTALLED_SERVICE_EXEC_START}" "${EXPECTED_SERVICE_COMMAND}" ||
  die "xray.service 未使用预期配置文件 ${SERVER_CONFIG}。"
assert_logrotate_timer

UUID=""
PRIVATE_KEY=""
REALITY_PASSWORD=""
REALITY_PASSWORD_CANDIDATES=()
SHORT_ID=""
SS_PASSWORD=""

if mode_has_vless; then
  log "检查 REALITY 伪装目标 ${REALITY_SERVER_NAME}:${REALITY_TARGET_PORT}..."
  if ! TLS_PING_OUTPUT="$(
    "${XRAY_BIN}" tls ping "${REALITY_SERVER_NAME}:${REALITY_TARGET_PORT}" 2>&1
  )"; then
    printf '%s\n' "${TLS_PING_OUTPUT}" >&2
    die "REALITY 伪装目标连接检查失败。"
  fi
  printf '%s\n' "${TLS_PING_OUTPUT}"
  TLS_PING_SNI_OUTPUT="$(
    sed -n '/Pinging with SNI/,$p' <<<"${TLS_PING_OUTPUT}"
  )"
  [[ -n "${TLS_PING_SNI_OUTPUT}" ]] ||
    die "无法识别 xray tls ping 的 SNI 检查结果。"
  grep -Eq 'Handshake succeeded' <<<"${TLS_PING_SNI_OUTPUT}" ||
    die "REALITY 伪装目标未能成功完成 TLS 握手。"
  grep -Eq 'TLS Version:[[:space:]]+TLS 1\.3' <<<"${TLS_PING_SNI_OUTPUT}" ||
    die "REALITY 伪装目标不支持 TLS 1.3。"

  UUID="$("${XRAY_BIN}" uuid | tr -d '[:space:]')"
  KEY_OUTPUT="$("${XRAY_BIN}" x25519)"
  PRIVATE_KEY="$(sed -n 's/^PrivateKey:[[:space:]]*//p' <<<"${KEY_OUTPUT}")"
  mapfile -t REALITY_PASSWORD_CANDIDATES < <(
    sed -n -E \
      's/^(Password( \(PublicKey\))?|PublicKey):[[:space:]]*//p' <<<"${KEY_OUTPUT}"
  )
  ((${#REALITY_PASSWORD_CANDIDATES[@]} == 1)) ||
    die "Xray x25519 必须返回且只能返回一个客户端 password/public key。"
  REALITY_PASSWORD="${REALITY_PASSWORD_CANDIDATES[0]}"
  SHORT_ID="$(openssl rand -hex 8)"

  [[ "${UUID}" =~ ^[0-9a-fA-F-]{36}$ ]] ||
    die "Xray 未能生成有效 UUID。"
  [[ -n "${PRIVATE_KEY}" ]] || die "Xray 未能生成 REALITY 私钥。"
  [[ -n "${REALITY_PASSWORD}" ]] ||
    die "Xray 未能生成 REALITY 客户端 password/public key。"
  [[ "${SHORT_ID}" =~ ^[0-9a-f]{16}$ ]] ||
    die "未能生成有效 Short ID。"
fi

if mode_has_ss; then
  SS_PASSWORD="$(openssl rand -base64 "${SS_KEY_BYTES}" | tr -d '\r\n')"
  [[ -n "${SS_PASSWORD}" ]] || die "未能生成 SS2022 密钥。"
fi

SERVER_CONFIG_TMP="${TEMP_DIR}/server.json"

cat >"${SERVER_CONFIG_TMP}" <<EOF
{
  "log": {
    "loglevel": "warning",
    "error": "/var/log/xray/error.log",
    "access": "/var/log/xray/access.log"
  },
  "dns": {
    "servers": [
      {
        "address": "https+local://dns.cloudflare.com/dns-query",
        "queryStrategy": "UseIP"
      },
      {
        "address": "https+local://dns.google/dns-query",
        "queryStrategy": "UseIP"
      }
    ]
  },
  "inbounds": [
EOF

if mode_has_vless; then
  cat >>"${SERVER_CONFIG_TMP}" <<EOF
    {
      "listen": "127.0.0.1",
      "tag": "dokodemo-in",
      "port": ${FALLBACK_PORT},
      "protocol": "dokodemo-door",
      "settings": {
        "address": "${REALITY_SERVER_NAME}",
        "port": ${REALITY_TARGET_PORT},
        "network": "tcp"
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["tls"],
        "routeOnly": true
      }
    },
    {
      "listen": "0.0.0.0",
      "port": ${VLESS_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "dest": "127.0.0.1:${FALLBACK_PORT}",
          "serverNames": ["${REALITY_SERVER_NAME}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": [
            "${SHORT_ID}"
          ]
        }
      },
      "sniffing": {
        "enabled": true,
        "destOverride": ["http", "tls", "quic"],
        "routeOnly": true
      }
    }
EOF
fi

if [[ "${DEPLOY_MODE}" == "dual" ]]; then
  printf ',\n' >>"${SERVER_CONFIG_TMP}"
fi

if mode_has_ss; then
  cat >>"${SERVER_CONFIG_TMP}" <<EOF
    {
      "listen": "0.0.0.0",
      "port": ${SS_PORT},
      "protocol": "shadowsocks",
      "settings": {
        "method": "${SS_METHOD}",
        "password": "${SS_PASSWORD}",
        "network": "tcp,udp"
      },
      "tag": "ss-in"
    }
EOF
fi

cat >>"${SERVER_CONFIG_TMP}" <<EOF
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "streamSettings": {
        "sockopt": {
          "domainStrategy": "UseIP",
          "happyEyeballs": {
            "tryDelayMs": 250,
            "prioritizeIPv6": true,
            "interleave": 1,
            "maxConcurrentTry": 4
          }
        }
      },
      "tag": "direct"
    }
EOF

if mode_has_vless; then
  cat >>"${SERVER_CONFIG_TMP}" <<EOF
    ,
    {
      "protocol": "blackhole",
      "tag": "block"
    }
EOF
fi

cat >>"${SERVER_CONFIG_TMP}" <<EOF
  ]
EOF

if mode_has_vless; then
  cat >>"${SERVER_CONFIG_TMP}" <<EOF
  ,
  "routing": {
    "rules": [
      {
        "inboundTag": ["dokodemo-in"],
        "domain": ["full:${REALITY_SERVER_NAME}"],
        "outboundTag": "direct"
      },
      {
        "inboundTag": ["dokodemo-in"],
        "outboundTag": "block"
      }
    ]
  }
EOF
fi

cat >>"${SERVER_CONFIG_TMP}" <<EOF
}
EOF

log "校验服务端配置..."
"${XRAY_BIN}" run -test -config "${SERVER_CONFIG_TMP}"

mkdir -p "${DEPLOY_DIR}" "${XRAY_CONFIG_DIR}" /var/log/xray
chmod 700 "${DEPLOY_DIR}"

if [[ -e "${SERVER_CONFIG}" ]]; then
  mkdir -p "${DEPLOY_DIR}/backups"
  BACKUP_DIR="$(
    mktemp -d "${DEPLOY_DIR}/backups/$(date -u +%Y%m%dT%H%M%SZ).XXXXXX"
  )"
  BACKUP_CONFIG="${BACKUP_DIR}/server.json"
  cp -a "${SERVER_CONFIG}" "${BACKUP_CONFIG}"
  HAD_PREVIOUS_CONFIG=1
  log "旧配置已备份到 ${BACKUP_DIR}"
fi

SERVICE_USER="$(systemctl show -p User --value xray.service 2>/dev/null || true)"
SERVICE_USER="${SERVICE_USER:-root}"
if id "${SERVICE_USER}" >/dev/null 2>&1; then
  SERVICE_GROUP="$(id -gn "${SERVICE_USER}")"
else
  SERVICE_USER="root"
  SERVICE_GROUP="root"
fi

install -o root -g "${SERVICE_GROUP}" -m 0640 \
  "${SERVER_CONFIG_TMP}" "${SERVER_CONFIG}"
CONFIG_COMMITTED=1
touch /var/log/xray/access.log /var/log/xray/error.log
chown "${SERVICE_USER}:${SERVICE_GROUP}" /var/log/xray
chown "${SERVICE_USER}:${SERVICE_GROUP}" \
  /var/log/xray/access.log /var/log/xray/error.log
chmod 0750 /var/log/xray
chmod 0640 /var/log/xray/access.log /var/log/xray/error.log

URI_HOST="${SERVER_ADDRESS}"
if [[ "${URI_HOST}" == *:* && "${URI_HOST}" != \[*\] ]]; then
  URI_HOST="[${URI_HOST}]"
fi
SHARE_ADDRESS="$(
  printf '%s' "${SERVER_ADDRESS}" |
    tr -d '[]' |
    tr '.:' '__'
)"
VLESS_URI=""
SS_URI=""
if mode_has_vless; then
  VLESS_URI="vless://${UUID}@${URI_HOST}:${VLESS_PORT}?encryption=none&flow=xtls-rprx-vision&security=reality&sni=${REALITY_SERVER_NAME}&fp=chrome&pbk=${REALITY_PASSWORD}&sid=${SHORT_ID}&type=tcp&headerType=none#${SHARE_ADDRESS}-${VLESS_PORT}-vless"
fi
if mode_has_ss; then
  SS_USERINFO="$(
    printf '%s' "${SS_METHOD}:${SS_PASSWORD}" |
      openssl base64 -A |
      tr '+/' '-_' |
      tr -d '='
  )"
  SS_URI="ss://${SS_USERINFO}@${URI_HOST}:${SS_PORT}#${SHARE_ADDRESS}-${SS_PORT}-ss2022"
fi
XRAY_VERSION_TEXT="$("${XRAY_BIN}" version | sed -n '1p')"

systemctl daemon-reload
systemctl enable xray.service
systemctl restart xray.service
systemctl is-active --quiet xray.service ||
  die "Xray 服务启动失败，请运行 journalctl -u xray -n 100 --no-pager 查看日志。"

case "${DEPLOY_MODE}" in
  dual)
    DEPLOY_MODE_TEXT="双协议"
    FIREWALL_PORT_HINT="${VLESS_PORT}/tcp、${SS_PORT}/tcp、${SS_PORT}/udp"
    ;;
  vless)
    DEPLOY_MODE_TEXT="VLESS Only"
    FIREWALL_PORT_HINT="${VLESS_PORT}/tcp"
    ;;
  ss)
    DEPLOY_MODE_TEXT="SS2022 Only"
    FIREWALL_PORT_HINT="${SS_PORT}/tcp、${SS_PORT}/udp"
    ;;
esac

cat >/dev/tty <<EOF
============================================================
Xray ${DEPLOY_MODE_TEXT} 部署信息（仅显示一次，请立即保存）
生成时间（UTC）  : $(date -u +%Y-%m-%dT%H:%M:%SZ)
Xray 版本        : ${XRAY_VERSION_TEXT}
服务器地址       : ${SERVER_ADDRESS}
EOF

if mode_has_vless; then
  cat >/dev/tty <<EOF
---------------- VLESS-TCP-REALITY ----------------
端口             : ${VLESS_PORT}/tcp
UUID             : ${UUID}
Flow             : xtls-rprx-vision
Server Name / SNI: ${REALITY_SERVER_NAME}
Target           : ${REALITY_SERVER_NAME}:${REALITY_TARGET_PORT}
Reality 私钥     : ${PRIVATE_KEY}
Reality Password : ${REALITY_PASSWORD}
Short ID         : ${SHORT_ID}
Fingerprint      : chrome
Network          : tcp

VLESS 分享链接：
${VLESS_URI}
EOF
fi

if mode_has_ss; then
  cat >/dev/tty <<EOF
---------------- Shadowsocks 2022 ------------------
端口             : ${SS_PORT}/tcp+udp
Method           : ${SS_METHOD}
Password / PSK   : ${SS_PASSWORD}

SS2022 分享链接：
${SS_URI}
EOF
fi

cat >/dev/tty <<EOF
---------------- 文件 --------------------------------
服务端配置       : ${SERVER_CONFIG}
分享信息         : 未保存，仅本次显示
防火墙/安全组    : 脚本未修改，请手工放行 ${FIREWALL_PORT_HINT}
============================================================
EOF

DEPLOY_SUCCEEDED=1
log "脚本未修改防火墙；请确认 VPS 防火墙和云安全组已放行 ${FIREWALL_PORT_HINT}。"
