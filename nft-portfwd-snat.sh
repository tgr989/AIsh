#!/bin/bash
set -euo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
umask 027

#
# nftables 端口转发管理脚本（nft-portfwd-snat）
#
# - 管理独立表 table ip portfwd
# - DNAT + 静态 SNAT（SNAT 地址为本机默认路由出口 IPv4）
# - 协议 tcp/udp（可同时添加，默认 both）
# - 检查/持久化 ip_forward 与 nftables include
#

TABLE_FAMILY="ip"
TABLE_NAME="portfwd"
CHAIN_PREROUTING="prerouting"
CHAIN_POSTROUTING="postrouting"
SCRIPT_DISPLAY_NAME="nft-portfwd"
SCRIPT_VERSION="2.2.4"
SCRIPT_BASENAME="${BASH_SOURCE[0]##*/}"

CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/portfwd.conf"
MAIN_CONF="/etc/nftables.conf"
SYSCTL_FILE="/etc/sysctl.d/99-portfwd-ip-forward.conf"
RUNTIME_DIR="/run/nft-portfwd"
LOCK_FILE="${RUNTIME_DIR}/lock"
OWNER_CHAIN="nft_portfwd_owner"
TXN_CANDIDATE="${CONF_DIR}/.portfwd.conf.new"
TXN_ROLLBACK="${CONF_DIR}/.portfwd.rollback.nft"
TXN_MARKER="${CONF_DIR}/.portfwd.transaction"
CONF_MAGIC="# MANAGED-BY: nft-portfwd v2"

INCLUDE_GLOB="/etc/nftables.d/*.conf"
INCLUDE_LINE="include \"${INCLUDE_GLOB}\""
INCLUDE_CHECK_REGEX="^[[:space:]]*include[[:space:]]+[\"']?/etc/nftables\\.d/\\*\\.conf[\"']?([[:space:]]*;)?[[:space:]]*$"

readonly TABLE_FAMILY TABLE_NAME CHAIN_PREROUTING CHAIN_POSTROUTING SCRIPT_DISPLAY_NAME SCRIPT_VERSION
readonly SCRIPT_BASENAME
readonly CONF_DIR CONF_FILE MAIN_CONF SYSCTL_FILE
readonly RUNTIME_DIR LOCK_FILE OWNER_CHAIN
readonly TXN_CANDIDATE TXN_ROLLBACK TXN_MARKER
readonly CONF_MAGIC
readonly INCLUDE_GLOB INCLUDE_LINE INCLUDE_CHECK_REGEX

# 规则存储格式:
# listen_ip|lport|proto|dest_ip|dest_port|iif|source_cidr
# proto 仅存 tcp / udp；如果用户选 both，会展开成两条
# iif 为入口网卡名（如 eth0）或 *（不限制）
# source_cidr 默认为 0.0.0.0/0
declare -a RULES=()
SNAT_IP=""
LOCK_FD=""
CONFIG_LOAD_ERRORS=0
CLI_MODE="menu"
IPF_WANT_ENABLE=0
IPF_WANT_PERSIST=0
IPF_ORIGINAL_RUNTIME="0"
NFT_WANT_ENABLE=0

# ---------- logging & common helpers ----------
info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }

die() {
    err "$*"
    exit 1
}

read_or_cancel() {
    local __var_name="$1"
    local __prompt="$2"
    if ! read -rp "$__prompt" "$__var_name"; then
        echo
        warn "检测到输入中断(EOF)，已取消当前操作。"
        return 1
    fi
    return 0
}

answer_yes_default_yes() {
    local ans="${1:-}"
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
}

answer_yes_default_no() {
    local ans="${1:-}"
    [[ "$ans" =~ ^[Yy]$ ]]
}

main_conf_has_include() {
    [[ -f "$MAIN_CONF" ]] || return 1
    grep -Eiq "$INCLUDE_CHECK_REGEX" "$MAIN_CONF" 2>/dev/null
}

nftables_service_uses_main_conf() {
    local exec_start
    command -v systemctl >/dev/null 2>&1 || return 1
    exec_start="$(systemctl show nftables --property=ExecStart --value 2>/dev/null)" || return 1
    [[ -n "$exec_start" ]] || return 1
    grep -Fq -- "-f ${MAIN_CONF}" <<< "$exec_start"
}

show_persistence_hint() {
    if ! main_conf_has_include; then
        warn "持久化未就绪：${MAIN_CONF} 未包含 ${INCLUDE_GLOB}（菜单 4 可修复）"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-enabled --quiet nftables 2>/dev/null; then
            warn_nftables_service_not_enabled "持久化未就绪："
        fi
    else
        warn "无法验证 nftables 开机加载：未发现 systemctl"
    fi
}

# 提示如何启用 nftables 开机加载；prefix 用于区分调用场景文案。
warn_nftables_service_not_enabled() {
    local prefix="${1:-}"
    warn "${prefix}nftables.service 未开机自启；添加规则时可选择启用（默认否）。"
    warn "请先确认本机以 nftables 为唯一防火墙（勿与 firewalld/ufw/iptables 抢接管），再执行："
    warn "  systemctl enable --now nftables"
    warn "可选检查：systemctl status nftables && nft list ruleset"
}

check_root() {
    [[ "${EUID}" -eq 0 ]] || die "请用 root 运行。"
}

check_bash_version() {
    if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 4) )); then
        die "需要 Bash 4.4 或更高版本（当前 ${BASH_VERSION}）。"
    fi
}

check_cmds() {
    local cmd
    local -a required=(nft sysctl flock grep mktemp install cp mv rm chmod cmp ip stat dirname sort tail)
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少必需命令：${cmd}"
    done
}

# ---------- validators ----------
validate_port() {
    local port="${1:-}"
    [[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] || return 1
    (( port >= 1 && port <= 65535 ))
}

# 交互选择协议；通过 nameref 写回协议数组（tcp / udp / tcp+udp）。
# 返回 0 成功，1 用户取消（EOF）。
prompt_proto_choice() {
    local -n __protos_ref="$1"
    local choice

    echo
    echo "  1) tcp"
    echo "  2) udp"
    echo "  3) both (tcp + udp)"
    while true; do
        read_or_cancel choice "请选择协议 [1/2/3，默认 3]: " || return 1
        choice="${choice:-3}"
        case "$choice" in
            1)
                __protos_ref=("tcp")
                return 0
                ;;
            2)
                __protos_ref=("udp")
                return 0
                ;;
            3)
                __protos_ref=("tcp" "udp")
                return 0
                ;;
            *)
                err "请输入 1、2 或 3。"
                ;;
        esac
    done
}

validate_ipv4_basic() {
    local ip="${1:-}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    [[ ! "$ip" =~ (^|[.])0[0-9] ]] || return 1

    local IFS='.'
    read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( o >= 0 && o <= 255 )) || return 1
    done

    return 0
}

validate_ipv4() {
    local ip="${1:-}"
    validate_ipv4_basic "$ip" || return 1

    local IFS='.'
    local o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$ip"
    (( o1 != 0 )) || return 1
    (( o1 != 127 )) || return 1
    ! (( o1 == 169 && o2 == 254 )) || return 1
    (( o1 < 224 )) || return 1
    return 0
}

validate_ipv4_cidr() {
    local cidr="${1:-}"
    local ip prefix canonical
    [[ "$cidr" == */* ]] || return 1
    ip="${cidr%/*}"
    prefix="${cidr##*/}"
    validate_ipv4_basic "$ip" || return 1
    [[ "$prefix" =~ ^([0-9]|[12][0-9]|3[0-2])$ ]] || return 1
    canonical="$(ipv4_cidr_network "$ip" "$prefix")" || return 1
    [[ "$cidr" == "$canonical" ]]
}

ipv4_cidr_network() {
    local ip="$1" prefix="$2" o1 o2 o3 o4 value mask network
    local IFS='.'
    read -r o1 o2 o3 o4 <<< "$ip"
    value=$(( (10#$o1 << 24) | (10#$o2 << 16) | (10#$o3 << 8) | 10#$o4 ))
    if (( prefix == 0 )); then
        mask=0
    else
        mask=$(( (0xffffffff << (32 - prefix)) & 0xffffffff ))
    fi
    network=$(( value & mask ))
    printf '%d.%d.%d.%d/%d' \
        "$(( (network >> 24) & 255 ))" "$(( (network >> 16) & 255 ))" \
        "$(( (network >> 8) & 255 ))" "$(( network & 255 ))" "$prefix"
}

validate_ifname() {
    local ifname="${1:-}"
    [[ "$ifname" == "*" ]] && return 0
    [[ "$ifname" =~ ^[a-zA-Z0-9_.:-]{1,15}$ ]]
}

ifname_exists() {
    local ifname="${1:-}"
    [[ "$ifname" == "*" || -e "/sys/class/net/${ifname}" ]]
}

ipv4_is_local() {
    local ip_addr="$1"
    ip -o -4 addr show 2>/dev/null | grep -Eq "[[:space:]]${ip_addr//./\\.}/[0-9]+[[:space:]]"
}

ipv4_is_rfc1918() {
    local ip="${1:-}" o1 o2
    validate_ipv4_basic "$ip" || return 1
    local IFS='.'
    read -r o1 o2 _ _ <<< "$ip"
    (( o1 == 10 )) && return 0
    (( o1 == 192 && o2 == 168 )) && return 0
    (( o1 == 172 && o2 >= 16 && o2 <= 31 )) && return 0
    return 1
}

# 优先使用默认路由实际选择的源 IPv4；
# 无默认路由时，回退到第一个非 lo 的全局 IPv4。
get_local_ip() {
    local route token want_src=0 ip_addr=""
    local _idx _if _fam cidr _rest

    if IFS= read -r route < <(ip -4 route get 1.1.1.1 2>/dev/null); then
        for token in $route; do
            if (( want_src )); then
                ip_addr="$token"
                break
            fi
            [[ "$token" == "src" ]] && want_src=1
        done
        if validate_ipv4 "$ip_addr"; then
            printf '%s\n' "$ip_addr"
            return 0
        fi
    fi

    while read -r _idx _if _fam cidr _rest; do
        [[ "$_if" == "lo" ]] && continue
        ip_addr="${cidr%/*}"
        if validate_ipv4 "$ip_addr"; then
            printf '%s\n' "$ip_addr"
            return 0
        fi
    done < <(ip -o -4 addr show scope global 2>/dev/null || true)

    return 1
}

refresh_snat_ip() {
    local detected
    detected="$(get_local_ip)" || {
        err "无法获取本机默认路由出口 IPv4，不能生成静态 SNAT 配置。"
        return 1
    }
    validate_ipv4 "$detected" || return 1
    SNAT_IP="$detected"
}

check_snat_ip_current() {
    local detected
    if ! detected="$(get_local_ip)"; then
        err "无法获取当前默认路由出口 IPv4，不能核对配置中的 LOCAL_IP。"
        return 2
    fi
    if [[ "$SNAT_IP" != "$detected" ]]; then
        err "配置 LOCAL_IP=${SNAT_IP}，当前默认路由出口 IPv4=${detected}。"
        err "请使用菜单 4 检查并修复环境，重新提交现有规则。"
        return 1
    fi
    info "SNAT LOCAL_IP 与当前默认路由出口 IPv4 一致：${SNAT_IP}"
}

# ss 监听行是否包含指定端口（避免 :80 误匹配 :8080）。
ss_listen_line_has_port() {
    local port="$1" line="$2"
    [[ "$line" =~ :${port}[[:space:]] ]]
}

# 通过 stdout 返回 TCP / UDP / TCP+UDP；未占用或无法检测时返回空并 exit 1。
describe_local_port_occupancy() {
    local port="${1:-}" line tcp=0 udp=0
    validate_port "$port" || return 1
    command -v ss >/dev/null 2>&1 || return 1

    while IFS= read -r line; do
        ss_listen_line_has_port "$port" "$line" && tcp=1 && break
    done < <(ss -H -ltn 2>/dev/null || true)

    while IFS= read -r line; do
        ss_listen_line_has_port "$port" "$line" && udp=1 && break
    done < <(ss -H -lun 2>/dev/null || true)

    if (( tcp && udp )); then
        printf '%s\n' 'TCP+UDP'
    elif (( tcp )); then
        printf '%s\n' 'TCP'
    elif (( udp )); then
        printf '%s\n' 'UDP'
    else
        return 1
    fi
    return 0
}

# 交互：本机端口已被监听时警告；继续返回 0，取消返回 1。
confirm_continue_despite_local_port_use() {
    local port="$1" occupied="" ans
    occupied="$(describe_local_port_occupancy "$port" 2>/dev/null)" || return 0
    [[ -n "$occupied" ]] || return 0

    warn "本机端口 ${port} 已被占用（${occupied}）。"
    warn "添加转发后，外部访问该端口的流量会被 DNAT；本机原服务可能无法从外部到达。"
    read_or_cancel ans "是否仍要继续添加？[y/N]: " || return 1
    answer_yes_default_no "$ans" || {
        warn "已取消。"
        return 1
    }
    return 0
}

# TCP 连通探测；成功 0，失败 1。依赖 bash /dev/tcp；有 timeout 时限制等待。
can_probe_tcp_connect() {
    command -v timeout >/dev/null 2>&1
}

probe_tcp_connect() {
    local ip="${1:-}" port="${2:-}" wait_sec="${3:-3}"
    validate_ipv4_basic "$ip" || return 1
    validate_port "$port" || return 1
    can_probe_tcp_connect || return 1

    timeout "$wait_sec" bash -c "echo >/dev/tcp/${ip}/${port}" 2>/dev/null
}

# 交互：添加规则前探测目标 TCP；不通时确认。继续返回 0，取消返回 1。
confirm_continue_despite_unreachable_dest() {
    local ip="$1" port="$2" ans

    if ! can_probe_tcp_connect; then
        warn "跳过目标连通性探测：未找到 timeout 命令。"
        return 0
    fi

    info "正在探测目标 TCP ${ip}:${port}（超时 3s）..."
    if probe_tcp_connect "$ip" "$port" 3; then
        info "目标 ${ip}:${port} TCP 可达。"
        return 0
    fi

    warn "目标 ${ip}:${port} TCP 不通或超时（不等于 NAT 会失败；若目标仅 UDP 可忽略）。"
    read_or_cancel ans "是否仍要继续添加？[y/N]: " || return 1
    answer_yes_default_no "$ans" || {
        warn "已取消。"
        return 1
    }
    return 0
}

# 运行 nft 校验/加载；失败时把 nft 原始报错打到 stderr。
run_nft() {
    local -a nft_args=("$@")
    local nft_out rc=0
    nft_out="$(nft "${nft_args[@]}" 2>&1)" || rc=$?
    if (( rc != 0 )) && [[ -n "$nft_out" ]]; then
        printf '%s\n' "$nft_out" >&2
    fi
    return "$rc"
}

ensure_secure_dir() {
    local path="$1" create_mode="$2"
    local uid mode

    [[ ! -L "$path" ]] || die "拒绝使用符号链接目录：${path}"
    if [[ ! -d "$path" ]]; then
        install -d -m "$create_mode" -o root -g root "$path" \
            || die "无法创建安全目录：${path}"
    fi
    uid="$(stat -c '%u' "$path")" || die "无法读取目录所有者：${path}"
    mode="$(stat -c '%a' "$path")" || die "无法读取目录权限：${path}"
    [[ "$uid" == "0" ]] || die "目录必须由 root 拥有：${path}"
    (( (8#$mode & 0022) == 0 )) || die "目录不可由 group/other 写入：${path} (${mode})"
}

secure_root_file() {
    local path="$1" uid mode
    [[ -f "$path" && ! -L "$path" ]] || return 1
    uid="$(stat -c '%u' "$path" 2>/dev/null)" || return 1
    mode="$(stat -c '%a' "$path" 2>/dev/null)" || return 1
    [[ "$uid" == "0" ]] || return 1
    (( (8#$mode & 0022) == 0 ))
}

acquire_lock() {
    local uid mode
    ensure_secure_dir "$RUNTIME_DIR" 0700
    [[ ! -L "$LOCK_FILE" ]] || die "拒绝使用符号链接锁文件：${LOCK_FILE}"
    if [[ ! -e "$LOCK_FILE" ]]; then
        install -m 0600 -o root -g root /dev/null "$LOCK_FILE" \
            || die "无法创建锁文件：${LOCK_FILE}"
    fi
    [[ -f "$LOCK_FILE" ]] || die "锁文件不是普通文件：${LOCK_FILE}"
    uid="$(stat -c '%u' "$LOCK_FILE")" || die "无法读取锁文件所有者。"
    mode="$(stat -c '%a' "$LOCK_FILE")" || die "无法读取锁文件权限。"
    [[ "$uid" == "0" && "$mode" == "600" ]] || die "锁文件 owner/mode 非预期。"
    exec {LOCK_FD}<>"$LOCK_FILE" || die "无法打开锁文件：${LOCK_FILE}"
    flock -x -w 10 "$LOCK_FD" || die "10 秒内无法获取互斥锁：${LOCK_FILE}"
}

release_lock() {
    if [[ -n "${LOCK_FD:-}" ]]; then
        flock -u "$LOCK_FD" >/dev/null 2>&1 || true
        exec {LOCK_FD}>&- || true
        LOCK_FD=""
    fi
}

ensure_dirs() {
    ensure_secure_dir "$CONF_DIR" 0755
    [[ ! -L "$CONF_FILE" ]] || die "拒绝写入符号链接配置：${CONF_FILE}"
    if [[ -e "$CONF_FILE" ]]; then
        secure_root_file "$CONF_FILE" \
            || die "配置必须是 root 拥有且 group/other 不可写的普通文件：${CONF_FILE}"
    fi
}

# ---------- rules load/render/apply ----------
runtime_table_exists() {
    nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1
}

runtime_table_is_owned() {
    nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$OWNER_CHAIN" >/dev/null 2>&1
}

rule_conflicts() {
    local listen_ip="$1" lport="$2" proto="$3" iif="$4"
    local r xlisten xlport xproto xdip xdport xiif xsource
    for r in "${RULES[@]+"${RULES[@]}"}"; do
        IFS='|' read -r xlisten xlport xproto xdip xdport xiif xsource <<< "$r"
        if [[ "$xlisten" == "$listen_ip" && "$xlport" == "$lport" && "$xproto" == "$proto" ]]; then
            if [[ "$xiif" == "*" || "$iif" == "*" || "$xiif" == "$iif" ]]; then
                return 0
            fi
        fi
    done
    return 1
}

load_rules_from_conf() {
    local conf_path="${1:-$CONF_FILE}"
    local line parsed_rule listen_ip lport proto dip dport iif source_cidr
    local tmp_expected="" snat_ip_count=0
    local -a fields=()
    RULES=()
    SNAT_IP=""
    CONFIG_LOAD_ERRORS=0

    [[ ! -L "$conf_path" ]] || {
        err "拒绝读取符号链接配置：${conf_path}"
        CONFIG_LOAD_ERRORS=1
        return 1
    }
    [[ -f "$conf_path" ]] || return 0
    if [[ "$conf_path" == "$CONF_FILE" ]] && ! secure_root_file "$conf_path"; then
        err "配置 owner/mode 不安全：${conf_path}"
        CONFIG_LOAD_ERRORS=1
        return 1
    fi
    grep -Fqx "$CONF_MAGIC" "$conf_path" 2>/dev/null || {
        err "配置缺少当前版本管理标记：${CONF_MAGIC}"
        CONFIG_LOAD_ERRORS=1
        return 1
    }

    while IFS= read -r line || [[ -n "$line" ]]; do
        if [[ "$line" =~ ^[[:space:]]*define[[:space:]]+LOCAL_IP[[:space:]]*=[[:space:]]*([0-9.]+)[[:space:]]*$ ]]; then
            (( ++snat_ip_count ))
            SNAT_IP="${BASH_REMATCH[1]}"
            validate_ipv4 "$SNAT_IP" || {
                err "配置中的 LOCAL_IP 非法：${SNAT_IP}"
                CONFIG_LOAD_ERRORS=1
            }
            continue
        fi
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*RULE:[[:space:]]*(.+)[[:space:]]*$ ]]; then
            parsed_rule="${BASH_REMATCH[1]}"
            fields=()
            IFS='|' read -ra fields <<< "$parsed_rule"

            if (( ${#fields[@]} != 7 )); then
                err "配置规则必须恰好包含 7 个字段：$parsed_rule"
                CONFIG_LOAD_ERRORS=1
                continue
            fi
            listen_ip="${fields[0]}"; lport="${fields[1]}"; proto="${fields[2]}"
            dip="${fields[3]}"; dport="${fields[4]}"; iif="${fields[5]}"
            source_cidr="${fields[6]}"

            [[ "$proto" == "tcp" || "$proto" == "udp" ]] || {
                err "配置规则协议非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue
            }
            validate_ipv4 "$listen_ip" || {
                err "配置规则监听 IPv4 非法/特殊：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue
            }
            validate_port "$lport" || { err "配置规则端口非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            validate_port "$dport" || { err "配置规则目标端口非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            validate_ipv4 "$dip" || { err "配置规则目标 IPv4 非法/特殊：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            validate_ifname "$iif" || { err "配置规则入口网卡非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            validate_ipv4_cidr "$source_cidr" || {
                err "配置规则来源 CIDR 非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue
            }
            if rule_conflicts "$listen_ip" "$lport" "$proto" "$iif"; then
                err "配置存在重叠监听规则：$parsed_rule"
                CONFIG_LOAD_ERRORS=1
                continue
            fi

            RULES+=("${listen_ip}|${lport}|${proto}|${dip}|${dport}|${iif}|${source_cidr}")
        fi
    done < "$conf_path"

    if (( snat_ip_count != 1 )); then
        err "配置必须恰好包含一条 define LOCAL_IP（当前 ${snat_ip_count} 条）。"
        CONFIG_LOAD_ERRORS=1
    fi

    if (( CONFIG_LOAD_ERRORS == 0 )); then
        tmp_expected="$(mktemp)" || {
            err "无法创建配置一致性检查临时文件。"
            CONFIG_LOAD_ERRORS=1
            return 1
        }
        if ! render_conf_file "$tmp_expected" || ! cmp -s "$tmp_expected" "$conf_path"; then
            err "${conf_path} 的规则正文与 # RULE 元数据不一致；拒绝覆盖，请先恢复或人工核对。"
            CONFIG_LOAD_ERRORS=1
        fi
        rm -f "$tmp_expected" || true
    fi

    (( CONFIG_LOAD_ERRORS == 0 ))
}

assert_loaded_config_safe() {
    (( CONFIG_LOAD_ERRORS == 0 )) || {
        err "配置包含错误或漂移，已拒绝修改。"
        return 1
    }
}

render_conf_file() {
    local output_path="$1"
    local r listen_ip lport proto dip dport iif source_cidr
    local iif_expr source_expr original_source_expr

    validate_ipv4 "$SNAT_IP" || {
        err "未设置合法的 SNAT LOCAL_IP，拒绝生成配置。"
        return 1
    }

    if ! {
        printf '%s\n' '#!/usr/sbin/nft -f'
        printf '%s\n\n' "$CONF_MAGIC"
        printf 'define LOCAL_IP = %s\n\n' "$SNAT_IP"
        printf 'add table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf 'delete table %s %s\n\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf 'table %s %s {\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf '    chain %s {\n' "$OWNER_CHAIN"
        printf '    }\n\n'
        printf '    chain %s {\n' "$CHAIN_PREROUTING"
        printf '        type nat hook prerouting priority -100; policy accept;\n'

        for r in "${RULES[@]+"${RULES[@]}"}"; do
            IFS='|' read -r listen_ip lport proto dip dport iif source_cidr <<< "$r"
            iif_expr=""
            source_expr=""
            [[ "$iif" == "*" ]] || iif_expr="iifname \"${iif}\" "
            [[ "$source_cidr" == "0.0.0.0/0" ]] || source_expr="ip saddr ${source_cidr} "
            printf '        # RULE: %s\n' "$r"
            printf '        %sip daddr %s %s%s dport %s dnat to %s:%s\n' \
                "$iif_expr" "$listen_ip" "$source_expr" "$proto" "$lport" "$dip" "$dport"
        done

        printf '    }\n\n'
        printf '    chain %s {\n' "$CHAIN_POSTROUTING"
        printf '        type nat hook postrouting priority 100; policy accept;\n'

        for r in "${RULES[@]+"${RULES[@]}"}"; do
            IFS='|' read -r listen_ip lport proto dip dport iif source_cidr <<< "$r"
            iif_expr=""
            original_source_expr=""
            [[ "$iif" == "*" ]] || iif_expr="iifname \"${iif}\" "
            [[ "$source_cidr" == "0.0.0.0/0" ]] \
                || original_source_expr="ct original ip saddr ${source_cidr} "
            printf '        # RULE-SNAT: %s\n' "$r"
            # proto-dst 需要先有 L4 协议上下文，否则部分 nft 版本会报
            # "Can't parse symbolic invalid expressions"。
            printf '        %sct status dnat ct original ip daddr %s meta l4proto %s ct original proto-dst %s %sip daddr %s %s dport %s snat to $LOCAL_IP\n' \
                "$iif_expr" "$listen_ip" "$proto" "$lport" "$original_source_expr" "$dip" "$proto" "$dport"
        done

        printf '    }\n'
        printf '}\n'
    } > "$output_path"; then
        err "生成 nft 配置失败：${output_path}"
        return 1
    fi

    [[ -s "$output_path" ]] || { err "生成的 nft 配置为空：${output_path}"; return 1; }
    grep -Fqx "$CONF_MAGIC" "$output_path" || return 1
    grep -Fq "table ${TABLE_FAMILY} ${TABLE_NAME} {" "$output_path" || return 1
    return 0
}

runtime_rules_match_loaded_config() {
    local runtime_output="$1" line chain="" key count
    local r listen_ip lport proto dip dport iif source_cidr
    local iif_expr source_expr original_source_expr
    local table_seen=0 owner_seen=0 prerouting_seen=0 postrouting_seen=0
    local prerouting_type_seen=0 postrouting_type_seen=0
    local -A expected=() seen=()

    for r in "${RULES[@]+"${RULES[@]}"}"; do
        IFS='|' read -r listen_ip lport proto dip dport iif source_cidr <<< "$r"
        iif_expr=""
        source_expr=""
        original_source_expr=""
        [[ "$iif" == "*" ]] || iif_expr="iifname \"${iif}\" "
        [[ "$source_cidr" == "0.0.0.0/0" ]] || {
            # nft list 会将 a.b.c.d/32 显示为裸地址；%/32 仅移除该后缀。
            source_expr="ip saddr ${source_cidr%/32} "
            original_source_expr="ct original ip saddr ${source_cidr%/32} "
        }
        expected["${CHAIN_PREROUTING}|${iif_expr}ip daddr ${listen_ip} ${source_expr}${proto} dport ${lport} dnat to ${dip}:${dport}"]=1
        expected["${CHAIN_POSTROUTING}|${iif_expr}ct status dnat ct original ip daddr ${listen_ip} meta l4proto ${proto} ct original proto-dst ${lport} ${original_source_expr}ip daddr ${dip} ${proto} dport ${dport} snat to ${SNAT_IP}"]=1
    done

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        case "$line" in
            "table ${TABLE_FAMILY} ${TABLE_NAME} {") (( ++table_seen )); chain="" ;;
            "chain ${OWNER_CHAIN} {") (( ++owner_seen )); chain="$OWNER_CHAIN" ;;
            "chain ${CHAIN_PREROUTING} {") (( ++prerouting_seen )); chain="$CHAIN_PREROUTING" ;;
            "chain ${CHAIN_POSTROUTING} {") (( ++postrouting_seen )); chain="$CHAIN_POSTROUTING" ;;
            "}") chain="" ;;
            "type nat hook prerouting priority -100; policy accept;"|\
            "type nat hook prerouting priority dstnat; policy accept;")
                [[ "$chain" == "$CHAIN_PREROUTING" ]] || return 1
                (( ++prerouting_type_seen ))
                ;;
            "type nat hook postrouting priority 100; policy accept;"|\
            "type nat hook postrouting priority srcnat; policy accept;")
                [[ "$chain" == "$CHAIN_POSTROUTING" ]] || return 1
                (( ++postrouting_type_seen ))
                ;;
            *)
                [[ "$chain" == "$CHAIN_PREROUTING" || "$chain" == "$CHAIN_POSTROUTING" ]] || return 1
                key="${chain}|${line}"
                [[ -n "${expected[$key]:-}" ]] || return 1
                count="${seen[$key]:-0}"
                (( count += 1 ))
                seen["$key"]="$count"
                (( count == 1 )) || return 1
                ;;
        esac
    done <<< "$runtime_output"

    (( table_seen == 1 && owner_seen == 1 && prerouting_seen == 1 && postrouting_seen == 1 )) || return 1
    (( prerouting_type_seen == 1 && postrouting_type_seen == 1 )) || return 1
    for key in "${!expected[@]}"; do
        [[ "${seen[$key]:-0}" == "1" ]] || return 1
    done
    return 0
}

check_runtime_ownership() {
    runtime_table_exists || return 0
    runtime_table_is_owned && return 0
    err "运行中已有未标记的 table ${TABLE_FAMILY} ${TABLE_NAME}；拒绝接管。"
    return 1
}

# nft list 可能省略 meta l4proto；重新加载时 ct original proto-dst
# 没有 L4 上下文会报 "Can't parse symbolic invalid expressions"。
normalize_runtime_nft_dump() {
    local line proto
    while IFS= read -r line || [[ -n "$line" ]]; do
        # 某些 nft 版本会显式输出 NAT 地址族；在 table ip 中语义相同。
        line="${line// dnat ip to / dnat to }"
        line="${line// snat ip to / snat to }"
        if [[ "$line" == *"ct original proto-dst"* && "$line" != *"meta l4proto"* ]]; then
            if [[ "$line" =~ [[:space:]](tcp|udp)[[:space:]]+dport[[:space:]] ]]; then
                proto="${BASH_REMATCH[1]}"
                line="${line/ct original proto-dst/meta l4proto ${proto} ct original proto-dst}"
            fi
        fi
        printf '%s\n' "$line"
    done
}

build_runtime_rollback() {
    local output_path="$1"
    if ! {
        printf '%s\n\n' '#!/usr/sbin/nft -f'
        printf 'add table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf 'delete table %s %s\n\n' "$TABLE_FAMILY" "$TABLE_NAME"
        if runtime_table_exists; then
            nft list table "$TABLE_FAMILY" "$TABLE_NAME" | normalize_runtime_nft_dump
        fi
    } > "$output_path"; then
        err "生成运行态回滚文件失败。"
        return 1
    fi
    run_nft -c -f "$output_path" || {
        err "运行态回滚文件校验失败。"
        return 1
    }
}

apply_nft_file() {
    local nft_file="$1"
    [[ -f "$nft_file" && ! -L "$nft_file" ]] || return 1
    run_nft -c -f "$nft_file" || return 1
    run_nft -f "$nft_file"
}

cleanup_transaction_files() {
    rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK" || return 1
    rm -f "$TXN_MARKER"
}

recover_incomplete_transaction() {
    ensure_dirs
    if [[ ! -e "$TXN_MARKER" ]]; then
        rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK" || true
        return 0
    fi

    warn "检测到上次未完成的规则事务，正在恢复一致状态。"
    [[ -f "$TXN_MARKER" && ! -L "$TXN_MARKER" ]] \
        || die "事务标记文件异常：${TXN_MARKER}"

    if [[ -f "$TXN_CANDIDATE" ]]; then
        [[ -f "$TXN_ROLLBACK" ]] || die "缺少运行态回滚文件：${TXN_ROLLBACK}"
        apply_nft_file "$TXN_ROLLBACK" \
            || die "无法恢复旧运行态；事务文件已保留，请人工处理。"
        info "已回滚到事务前运行态。"
    else
        [[ -f "$CONF_FILE" ]] || die "事务已提交但正式配置缺失。"
        apply_nft_file "$CONF_FILE" || die "无法按正式配置恢复运行态。"
        info "已按已提交配置恢复运行态。"
    fi

    cleanup_transaction_files || die "无法清理已恢复的事务文件。"
}

commit_rules() {
    assert_loaded_config_safe || return 1
    ensure_dirs
    [[ ! -e "$TXN_MARKER" ]] || {
        err "存在未恢复的规则事务，请重新启动脚本执行恢复。"
        return 1
    }
    check_runtime_ownership || return 1
    refresh_snat_ip || return 1

    rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK" || return 1
    render_conf_file "$TXN_CANDIDATE" || return 1
    chmod 0640 "$TXN_CANDIDATE" || return 1
    if ! run_nft -c -f "$TXN_CANDIDATE"; then
        err "候选 nft 配置语法/语义校验失败。"
        err "候选文件已保留便于排查：${TXN_CANDIDATE}"
        return 1
    fi
    build_runtime_rollback "$TXN_ROLLBACK" || {
        rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK" || true
        return 1
    }
    chmod 0600 "$TXN_ROLLBACK" || return 1
    install -m 0600 -o root -g root /dev/null "$TXN_MARKER" || return 1

    if ! run_nft -f "$TXN_CANDIDATE"; then
        err "加载候选规则失败；nft 原子事务未提交，磁盘配置保持不变。"
        cleanup_transaction_files || true
        return 1
    fi

    if ! mv -f "$TXN_CANDIDATE" "$CONF_FILE"; then
        err "运行态已更新，但提交正式配置失败；正在回滚运行态。"
        if apply_nft_file "$TXN_ROLLBACK"; then
            cleanup_transaction_files || true
            err "已恢复事务前运行态，磁盘配置未改变。"
        else
            err "运行态回滚失败，事务文件已保留，禁止继续操作。"
        fi
        return 1
    fi

    finish_committed_transaction
    return 0
}

finish_committed_transaction() {
    if ! cleanup_transaction_files; then
        warn "规则已提交，但事务清理失败；下次启动会自动核对恢复。"
    fi
    return 0
}

get_ip_forward_value() {
    sysctl -n net.ipv4.ip_forward 2>/dev/null
}

get_ip_forward_display() {
    local value
    if value="$(get_ip_forward_value)"; then
        printf '%s\n' "$value"
    else
        printf '%s\n' 'unknown'
    fi
}

# ---------- ip forward controls ----------
enable_ip_forward_runtime() {
    local cur
    cur="$(get_ip_forward_value)" || {
        err "无法读取 net.ipv4.ip_forward"
        return 1
    }
    if [[ "$cur" != "1" ]]; then
        sysctl -w net.ipv4.ip_forward=1 >/dev/null \
            || { err "无法开启 net.ipv4.ip_forward"; return 1; }
        info "已临时开启 net.ipv4.ip_forward=1"
    else
        info "net.ipv4.ip_forward 已经是 1"
    fi
}

enable_ip_forward_persist() {
    local cur tmp sysctl_dir
    sysctl_dir="$(dirname "$SYSCTL_FILE")"
    ensure_secure_dir "$sysctl_dir" 0755
    [[ ! -L "$SYSCTL_FILE" ]] || { err "拒绝写入符号链接：${SYSCTL_FILE}"; return 1; }
    tmp="$(mktemp "${SYSCTL_FILE}.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' 'net.ipv4.ip_forward=1' > "$tmp"; then
        rm -f "$tmp" || true
        return 1
    fi
    chmod 0644 "$tmp" || { rm -f "$tmp" || true; return 1; }
    if ! sysctl -p "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" || true
        err "应用 IPv4 转发参数失败，未写入持久化文件。"
        return 1
    fi
    cur="$(get_ip_forward_value)" || {
        rm -f "$tmp" || true
        err "无法读取 net.ipv4.ip_forward，未提交持久化文件。"
        return 1
    }
    if [[ "$cur" != "1" ]]; then
        rm -f "$tmp" || true
        err "临时应用后 net.ipv4.ip_forward=${cur}，未提交持久化文件。"
        return 1
    fi
    if ! mv -f "$tmp" "$SYSCTL_FILE"; then
        rm -f "$tmp" || true
        err "提交持久化 sysctl 文件失败。"
        return 1
    fi
    info "已写入并应用持久化参数: $SYSCTL_FILE"
    info "当前 net.ipv4.ip_forward = 1"
}

ip_forward_is_persisted() {
    secure_root_file "$SYSCTL_FILE" || return 1
    grep -Eq '^[[:space:]]*net\.ipv4\.ip_forward[[:space:]]*=[[:space:]]*1[[:space:]]*$' "$SYSCTL_FILE"
}

last_ip_forward_assignment() {
    local path="$1" line value
    line="$(grep -E '^[[:space:]]*-?[[:space:]]*net[./]ipv4[./]ip_forward[[:space:]]*=' "$path" 2>/dev/null | tail -n 1)" \
        || return 1
    [[ -n "$line" ]] || return 1
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%%[[:space:]][#;]*}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

ip_forward_has_competing_persistence() {
    local dir path base value systemd_config systemd_sysctl=""
    local effective_value="" effective_source=""
    local -a names=()
    local -A selected=()

    if command -v systemd-sysctl >/dev/null 2>&1; then
        systemd_sysctl="systemd-sysctl"
    elif [[ -x /usr/lib/systemd/systemd-sysctl ]]; then
        systemd_sysctl="/usr/lib/systemd/systemd-sysctl"
    elif [[ -x /lib/systemd/systemd-sysctl ]]; then
        systemd_sysctl="/lib/systemd/systemd-sysctl"
    fi

    if [[ -n "$systemd_sysctl" ]] \
        && systemd_config="$("$systemd_sysctl" --cat-config 2>/dev/null)" \
        && value="$(last_ip_forward_assignment <(printf '%s\n' "$systemd_config"))"; then
        if [[ "$value" != "1" ]]; then
            warn "systemd-sysctl 合并后的 IPv4 forwarding 持久化值为 ${value}"
            return 0
        fi
        return 1
    fi

    # Higher-priority directories select a basename first; selected basenames
    # are then applied together in C-locale lexical order.
    for dir in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
        for path in "$dir"/*.conf; do
            [[ -e "$path" || -L "$path" ]] || continue
            base="${path##*/}"
            [[ -n "${selected[$base]+present}" ]] || selected["$base"]="$path"
        done
    done

    if (( ${#selected[@]} > 0 )); then
        mapfile -t names < <(printf '%s\n' "${!selected[@]}" | LC_ALL=C sort)
        for base in "${names[@]}"; do
            path="${selected[$base]}"
            [[ -f "$path" ]] || continue
            if value="$(last_ip_forward_assignment "$path")"; then
                effective_value="$value"
                effective_source="$path"
            fi
        done
    fi

    # procps sysctl --system applies this legacy file after sysctl.d.
    if [[ -f /etc/sysctl.conf ]] && value="$(last_ip_forward_assignment /etc/sysctl.conf)"; then
        effective_value="$value"
        effective_source="/etc/sysctl.conf"
    fi

    if [[ -n "$effective_value" && "$effective_value" != "1" ]]; then
        warn "IPv4 forwarding 的最终持久化值为 ${effective_value}（来自 ${effective_source}）"
        return 0
    fi
    return 1
}

plan_ip_forward_for_add() {
    local cur ans
    IPF_WANT_ENABLE=0
    IPF_WANT_PERSIST=0
    cur="$(get_ip_forward_value)" || {
        err "无法读取 net.ipv4.ip_forward，已取消添加规则。"
        return 1
    }
    IPF_ORIGINAL_RUNTIME="$cur"

    if [[ "$cur" != "1" ]]; then
        echo
        warn "检测到 net.ipv4.ip_forward != 1"
        read_or_cancel ans "提交规则后是否开启 IPv4 转发？[Y/n]: " || return 1
        answer_yes_default_yes "$ans" || {
            warn "未开启 IPv4 转发，已取消添加规则。"
            return 1
        }
        IPF_WANT_ENABLE=1
    fi

    if ! ip_forward_is_persisted; then
        read_or_cancel ans "是否持久化到 ${SYSCTL_FILE}？[y/N]: " || return 1
        answer_yes_default_no "$ans" && IPF_WANT_PERSIST=1
    fi
}

plan_nftables_enable_for_add() {
    local ans
    NFT_WANT_ENABLE=0
    command -v systemctl >/dev/null 2>&1 || return 0
    if systemctl is-enabled --quiet nftables 2>/dev/null; then
        return 0
    fi
    read_or_cancel ans "是否启用 nftables.service（systemctl enable --now）？[y/N]: " || return 1
    answer_yes_default_no "$ans" && NFT_WANT_ENABLE=1
    return 0
}

enable_nftables_service() {
    warn "将执行 systemctl enable --now nftables；请确认本机以 nftables 为唯一防火墙。"
    if ! main_conf_has_include; then
        warn "${MAIN_CONF} 尚未 include ${INCLUDE_GLOB}；启动后可能无法加载本脚本规则（可用菜单 4 修复）。"
    fi
    systemctl enable --now nftables || {
        err "启用/启动 nftables.service 失败。"
        return 1
    }
    info "nftables.service 已启用并启动。"
    nftables_service_uses_main_conf \
        || warn "nftables.service 未明确引用 ${MAIN_CONF}；请人工核对开机加载入口。"
    return 0
}

restart_or_enable_nftables_service() {
    command -v systemctl >/dev/null 2>&1 || {
        err "未发现 systemctl，无法启用/重启 nftables.service。"
        return 1
    }
    if systemctl is-enabled --quiet nftables 2>/dev/null; then
        warn "将执行 systemctl restart nftables；请确认本机以 nftables 为唯一防火墙。"
        if ! main_conf_has_include; then
            warn "${MAIN_CONF} 尚未 include ${INCLUDE_GLOB}；重启后可能无法加载本脚本规则（可用菜单 4 修复）。"
        fi
        systemctl restart nftables || {
            err "重启 nftables.service 失败。"
            return 1
        }
        info "nftables.service 已重启。"
        nftables_service_uses_main_conf \
            || warn "nftables.service 未明确引用 ${MAIN_CONF}；请人工核对开机加载入口。"
        return 0
    fi
    enable_nftables_service
}

# 统计运行态 prerouting 中的 DNAT 条数；表/链不存在时输出 0 并返回失败。
count_runtime_dnat_rules() {
    local output line n=0
    if ! output="$(nft -nn list chain "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING" 2>/dev/null)"; then
        printf '%s\n' 0
        return 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" == *" dnat to "* ]] && (( ++n ))
    done <<< "$output"
    printf '%s\n' "$n"
    return 0
}

# 配置有规则，但 nftables 未启用/未运行，或运行态 DNAT 数量与配置不一致时，提示启用或重启（默认 Y）。
maybe_prompt_nftables_enable_or_restart() {
    local ans conf_count runtime_count=0
    local -a reasons=()

    conf_count="${#RULES[@]}"
    (( conf_count > 0 )) || return 0

    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-enabled --quiet nftables 2>/dev/null; then
            reasons+=("nftables.service 未开机自启")
        fi
        if ! systemctl is-active --quiet nftables 2>/dev/null; then
            reasons+=("nftables.service 未运行")
        fi
    fi

    if ! runtime_count="$(count_runtime_dnat_rules)"; then
        runtime_count=0
        reasons+=("运行表缺失或不可读（配置 ${conf_count} 条）")
    elif (( runtime_count != conf_count )); then
        reasons+=("规则数量不一致：配置 ${conf_count} 条，运行态 DNAT ${runtime_count} 条")
    fi

    (( ${#reasons[@]} > 0 )) || return 0

    echo
    warn "检测到配置有规则，但 nftables 状态异常："
    local r
    for r in "${reasons[@]}"; do
        warn "  - ${r}"
    done
    read_or_cancel ans "是否启用/重启 nftables.service？[Y/n]: " || return 0
    answer_yes_default_yes "$ans" || {
        warn "已跳过启用/重启 nftables.service。"
        return 0
    }
    restart_or_enable_nftables_service
}

apply_nftables_enable_plan() {
    (( NFT_WANT_ENABLE )) || return 0
    enable_nftables_service
}

apply_ip_forward_plan() {
    if (( IPF_WANT_ENABLE )); then
        enable_ip_forward_runtime || {
            restore_ip_forward_runtime_after_failure
            return 1
        }
    fi
    if (( IPF_WANT_PERSIST )); then
        enable_ip_forward_persist || {
            restore_ip_forward_runtime_after_failure
            return 1
        }
    fi
    return 0
}

restore_ip_forward_runtime_after_failure() {
    local current
    current="$(get_ip_forward_value)" || {
        err "无法读取 net.ipv4.ip_forward，不能确认是否需要恢复。"
        return 1
    }
    [[ "$current" == "$IPF_ORIGINAL_RUNTIME" ]] && return 0
    sysctl -w "net.ipv4.ip_forward=${IPF_ORIGINAL_RUNTIME}" >/dev/null 2>&1 || {
        err "无法恢复 net.ipv4.ip_forward=${IPF_ORIGINAL_RUNTIME}，请立即人工检查。"
        return 1
    }
    warn "已恢复操作前的 net.ipv4.ip_forward=${IPF_ORIGINAL_RUNTIME}"
}

add_include_to_main_conf() {
    local backup_file="" tmp_main main_dir

    ensure_dirs
    main_dir="$(dirname "$MAIN_CONF")"
    ensure_secure_dir "$main_dir" 0755
    [[ ! -L "$MAIN_CONF" ]] || { err "拒绝修改符号链接主配置：${MAIN_CONF}"; return 1; }
    if [[ -e "$MAIN_CONF" ]] && ! secure_root_file "$MAIN_CONF"; then
        err "主配置必须是 root 拥有且 group/other 不可写的普通文件：${MAIN_CONF}"
        return 1
    fi

    if main_conf_has_include; then
        info "${MAIN_CONF} 已存在 include，无需重复添加。"
        return 0
    fi

    tmp_main="$(mktemp "${MAIN_CONF}.tmp.XXXXXX")" || return 1
    if [[ -f "$MAIN_CONF" ]]; then
        backup_file="$(mktemp "${MAIN_CONF}.bak.XXXXXX")" || {
            rm -f "$tmp_main" || true
            return 1
        }
        cp -p "$MAIN_CONF" "$backup_file" || {
            rm -f "$tmp_main" "$backup_file" || true
            return 1
        }
        cp -p "$MAIN_CONF" "$tmp_main" || {
            rm -f "$tmp_main" "$backup_file" || true
            return 1
        }
        printf '\n%s\n' "$INCLUDE_LINE" >> "$tmp_main" || {
            rm -f "$tmp_main" || true
            return 1
        }
    else
        if ! printf '%s\n\n%s\n' '#!/usr/sbin/nft -f' "$INCLUDE_LINE" > "$tmp_main"; then
            rm -f "$tmp_main" || true
            return 1
        fi
        chmod 0644 "$tmp_main" || { rm -f "$tmp_main" || true; return 1; }
    fi

    if ! run_nft -c -f "$tmp_main"; then
        rm -f "$tmp_main" || true
        [[ -z "$backup_file" ]] || rm -f "$backup_file" || true
        err "加入 include 后语法检查失败；主配置未修改。"
        return 1
    fi

    mv -f "$tmp_main" "$MAIN_CONF" || {
        rm -f "$tmp_main" || true
        return 1
    }
    info "已原子添加 include 到 ${MAIN_CONF}"
    [[ -z "$backup_file" ]] || info "备份文件: $backup_file"
    return 0
}

check_include_hint() {
    local ans

    if [[ -f "$MAIN_CONF" ]]; then
        secure_root_file "$MAIN_CONF" || {
            err "主配置 owner/mode 不安全：${MAIN_CONF}"
            return 1
        }
        if main_conf_has_include; then
            info "${MAIN_CONF} 已包含 ${INCLUDE_GLOB}"
        else
            warn "${MAIN_CONF} 未发现 ${INCLUDE_LINE}"
            warn "将最小化修改系统主配置：仅追加一行 include，并做语法校验（失败会回滚）。"
            read_or_cancel ans "是否现在向 ${MAIN_CONF} 追加 include？[y/N]: " || return 0
            if answer_yes_default_no "$ans"; then
                add_include_to_main_conf || { err "补充 include 失败。"; return 1; }
            else
                warn "已跳过修改 ${MAIN_CONF}。持久化可能不完整，建议稍后执行菜单 4。"
            fi
        fi
    else
        warn "${MAIN_CONF} 不存在。"
        read_or_cancel ans "是否现在创建 ${MAIN_CONF} 并加入 include？[Y/n]: " || return 0
        if answer_yes_default_yes "$ans"; then
            add_include_to_main_conf || { err "创建 ${MAIN_CONF} 失败。"; return 1; }
        else
            warn "已跳过创建 ${MAIN_CONF}，持久化可能不完整。"
            return 0
        fi
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled --quiet nftables 2>/dev/null; then
            info "nftables.service 已设为开机自启。"
            nftables_service_uses_main_conf \
                || warn "nftables.service 未明确引用 ${MAIN_CONF}；当前发行版持久化入口可能不同。"
        else
            warn_nftables_service_not_enabled
        fi
    else
        warn "未发现 systemctl；请按当前 init 系统人工确认 nftables 开机加载入口。"
    fi
}

# ---------- diagnostics & help ----------
check_forward_status() {
    echo
    info "=== 环境快检 ==="

    local ipf
    if ! ipf="$(get_ip_forward_value)"; then
        warn "无法读取 net.ipv4.ip_forward"
    elif [[ "$ipf" == "1" ]]; then
        info "ip_forward = 1"
    else
        warn "ip_forward = ${ipf}（转发可能不通）"
    fi

    if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
        info "表 ${TABLE_FAMILY} ${TABLE_NAME} 已加载"
    else
        warn "表 ${TABLE_FAMILY} ${TABLE_NAME} 未加载"
    fi

    local other_fw=0
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "firewalld 运行中，可能拦截转发或与本脚本规则冲突"
        other_fw=1
    fi
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qiE '^Status:[[:space:]]+active'; then
        warn "ufw 处于 active，可能拦截转发或与本脚本规则冲突"
        other_fw=1
    fi
    if (( other_fw == 0 )); then
        info "未发现活跃的 firewalld / ufw"
    fi

    echo "若仍不通：检查 FORWARD/filter、云安全组。"
    echo
}

show_tips() {
    cat <<EOF

脚本: ${SCRIPT_BASENAME}

使用说明：
1. 模式固定为 DNAT + 静态 SNAT；使用本机默认路由出口 IPv4 作为 LOCAL_IP。
   配置写入 define LOCAL_IP，后端看不到真实客户端 IP；出口地址变化后可用菜单 4 检查并修复。
2. 添加时必须明确监听 IPv4（可按序号选本机地址），并可限制来源 CIDR / 入口网卡。
   云厂商若公网 IP 未挂在网卡上，请选内网 IP（包到达本机时的目的地址）。
   若本机端口已被服务占用，会警告并请你确认。
   输入目标后会做一次 TCP 连通探测；不通可确认后仍继续。
3. 删除时按列表序号；可用空格或逗号多选（如 1 3 5 或 1,3,5）；
   也支持 n+（第 n 与 n+1 条）、n-（第 n 与 n-1 条）；越界邻居会跳过并警告；输入 all 可清空。
4. 菜单 4 可检查/修复 include 与 ip_forward；添加规则时可选择启用 nftables.service（默认否）。
   --check 只做运行态/持久化校验，不对目标做网络探测。

安全边界：
1. 仅管理 table ${TABLE_FAMILY} ${TABLE_NAME}。
2. 不自动改 firewalld / ufw / iptables。
3. 持久化依赖 ${MAIN_CONF} 包含: include "/etc/nftables.d/*.conf"

常用命令：
  # 本脚本
  sudo ./${SCRIPT_BASENAME} --check
  sudo ./${SCRIPT_BASENAME} --check-strict

  # 规则查看 / 校验
  nft list table ${TABLE_FAMILY} ${TABLE_NAME}
  nft -nn list table ${TABLE_FAMILY} ${TABLE_NAME}
  grep -E 'RULE:|RULE-SNAT:' ${CONF_FILE}
  nft -c -f ${CONF_FILE}

  # 转发与持久化
  sysctl net.ipv4.ip_forward
  cat ${SYSCTL_FILE}
  grep -nE 'include.*/etc/nftables\\.d' ${MAIN_CONF}

  # nftables 开机加载（确认无 firewalld/ufw 抢管后再启用）
  systemctl enable --now nftables
  systemctl status nftables
  nft list ruleset

  # 排障
  ip -4 addr show scope global
  ss -lntup
  systemctl is-active firewalld 2>/dev/null; ufw status 2>/dev/null

EOF
}

print_help() {
    cat <<EOF
${SCRIPT_DISPLAY_NAME} v${SCRIPT_VERSION} (static-snat)

用法:
    sudo ./${SCRIPT_BASENAME}
    ./${SCRIPT_BASENAME} --help
    ./${SCRIPT_BASENAME} --version
    ./${SCRIPT_BASENAME} --check
    ./${SCRIPT_BASENAME} --check-strict

参数:
    -h, --help       显示帮助并退出
    -v, --version    显示版本并退出
    -c, --check      检查当前运行态；持久化问题仅警告（不做目标网络探测）
    --check-strict   严格检查；持久化问题也返回失败

说明:
    - 默认进入交互菜单模式
    - 菜单与两种 --check 需要 root 权限；--help/--version 不需要
    - 健康检查不修改系统配置

可能生成或改动的路径（按需，非每次全写）:
    ${CONF_DIR}/
        配置目录（首次需要时创建）
    ${CONF_FILE}
        正式转发规则（每次成功提交覆盖，无历史副本）
    ${MAIN_CONF}
        补 include "${INCLUDE_GLOB}"；若文件不存在则创建最小主配置
    ${MAIN_CONF}.bak.XXXXXX
        修改已有主配置前的一次性备份（成功后保留；已有 include 时不再生成）
    ${SYSCTL_FILE}
        仅在确认持久化时写入 net.ipv4.ip_forward=1
    ${RUNTIME_DIR}/
    ${LOCK_FILE}
        运行时互斥锁（通常位于 /run，重启后消失）
    ${TXN_CANDIDATE}
    ${TXN_ROLLBACK}
    ${TXN_MARKER}
        提交事务中间文件；正常成功后清理，异常时可能残留供恢复/排查
    运行态 table ${TABLE_FAMILY} ${TABLE_NAME}
        以及可选的 net.ipv4.ip_forward=1（内核，非文件）

不会自动改动: firewalld / ufw / iptables、BBR；
添加规则时可选择启用 nftables.service（默认否）。
也不会写操作日志或无限累积 portfwd.conf 备份。
EOF
}

run_health_check() {
    local mode="${1:-check}" status=0 persistence_status=0
    local ipf runtime_output="" config_ok=0

    echo "========================================"
    echo " ${SCRIPT_DISPLAY_NAME} 健康检查"
    echo "========================================"

    [[ ! -e "$TXN_MARKER" ]] || { err "存在未完成事务：${TXN_MARKER}"; status=1; }

    if [[ -f "$MAIN_CONF" ]] && secure_root_file "$MAIN_CONF" \
        && nft -c -f "$MAIN_CONF" >/dev/null 2>&1; then
        info "[持久化] ${MAIN_CONF} 语法校验通过。"
    else
        warn "[持久化] ${MAIN_CONF} 缺失、权限不安全或语法校验失败。"
        persistence_status=1
    fi
    if main_conf_has_include; then
        info "[持久化] ${MAIN_CONF} 已包含 ${INCLUDE_GLOB}"
    else
        warn "[持久化] ${MAIN_CONF} 未包含 ${INCLUDE_GLOB}"
        persistence_status=1
    fi

    if [[ -f "$CONF_FILE" ]] && load_rules_from_conf \
        && nft -c -f "$CONF_FILE" >/dev/null 2>&1; then
        info "${CONF_FILE} 语法及元数据一致性校验通过。"
        config_ok=1
    else
        err "${CONF_FILE} 缺失、漂移或校验失败。"
        status=1
    fi

    if (( config_ok && ${#RULES[@]} > 0 )); then
        check_snat_ip_current || status=1
        if ! ipf="$(get_ip_forward_value)"; then
            err "无法读取 net.ipv4.ip_forward"
            status=1
        elif [[ "$ipf" == "1" ]]; then
            info "net.ipv4.ip_forward = 1"
        else
            err "net.ipv4.ip_forward = ${ipf}"
            status=1
        fi
        if ip_forward_is_persisted; then
            if ip_forward_has_competing_persistence; then
                warn "[持久化] IPv4 forwarding 合并后的最终值不是 1。"
                persistence_status=1
            else
                info "IPv4 转发按加载优先级合并后的最终持久化值为 1。"
            fi
        else
            warn "[持久化] 未发现本脚本 IPv4 转发持久化文件。"
            persistence_status=1
        fi
    elif (( config_ok )); then
        info "配置中没有转发规则，不要求开启 IPv4 forwarding。"
    fi

    if runtime_table_exists; then
        runtime_table_is_owned \
            && info "运行表所有权哨兵存在。" \
            || { err "运行表缺少所有权哨兵。"; status=1; }
        if runtime_output="$(nft -nn list table "$TABLE_FAMILY" "$TABLE_NAME" 2>/dev/null)"; then
            runtime_output="$(normalize_runtime_nft_dump <<< "$runtime_output")"
        else
            status=1
        fi
        if (( config_ok )) && runtime_rules_match_loaded_config "$runtime_output"; then
            info "运行态链结构及每条 DNAT/SNAT 表达式与配置一致。"
        else
            err "运行态链结构或规则表达式与配置不一致。"
            status=1
        fi
    else
        err "运行中缺少 table ${TABLE_FAMILY} ${TABLE_NAME}。"
        status=1
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if systemctl is-enabled --quiet nftables 2>/dev/null; then
            info "[持久化] nftables.service 已设为开机自启。"
            nftables_service_uses_main_conf || {
                warn "[持久化] nftables.service 未明确引用 ${MAIN_CONF}；当前入口不匹配。"
                persistence_status=1
            }
        else
            warn_nftables_service_not_enabled "[持久化] "
            persistence_status=1
        fi
        systemctl is-active --quiet nftables 2>/dev/null \
            || warn "nftables.service 当前未运行；运行表由本脚本直接维护。"
    else
        warn "[持久化] 未发现 systemctl，无法验证 nftables 开机加载入口。"
        persistence_status=1
    fi

    echo
    finish_health_check "$status" "$persistence_status" "$mode"
}

finish_health_check() {
    local status="$1" persistence_status="$2" mode="$3"
    if (( status != 0 )); then
        err "运行态健康检查未通过。"
        return 1
    fi
    if (( persistence_status != 0 )); then
        if [[ "$mode" == "strict" ]]; then
            err "运行态正常，但严格检查因持久化问题未通过。"
            return 1
        fi
        warn "运行态健康；存在不影响当前转发的持久化警告。"
        return 0
    fi
    info "运行态与持久化检查均通过。"
    return 0
}

handle_cli_args() {
    local arg="${1:-}"
    (( $# <= 1 )) || { err "只接受一个参数。"; return 2; }
    case "$arg" in
        "")
            CLI_MODE="menu"
            return 0
            ;;
        -h|--help)
            print_help
            exit 0
            ;;
        -v|--version)
            echo "${SCRIPT_DISPLAY_NAME} v${SCRIPT_VERSION} (static-snat)"
            exit 0
            ;;
        -c|--check)
            CLI_MODE="check"
            return 0
            ;;
        --check-strict)
            CLI_MODE="check-strict"
            return 0
            ;;
        *)
            err "不支持的参数: ${arg}"
            echo
            print_help
            exit 2
            ;;
    esac
}

# ---------- rule CRUD ----------
list_rules() {
    load_rules_from_conf || {
        err "配置无效，拒绝显示不完整的规则列表。"
        return 1
    }

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有规则。"
        return 0
    fi

    printf "\n%-4s %-6s %-21s %-22s %-10s %-18s\n" "No." "Proto" "Listen" "Destination" "IIF" "Source"
    printf "%-4s %-6s %-21s %-22s %-10s %-18s\n" "----" "------" "---------------------" "----------------------" "----------" "------------------"

    local i=1
    local r listen_ip lport proto dip dport iif source_cidr
    for r in "${RULES[@]+"${RULES[@]}"}"; do
        IFS='|' read -r listen_ip lport proto dip dport iif source_cidr <<< "$r"
        iif="${iif:-*}"
        printf "%-4s %-6s %-21s %-22s %-10s %-18s\n" \
            "$i" "$proto" "${listen_ip}:${lport}" "${dip}:${dport}" "$iif" "$source_cidr"
        ((i++))
    done
    echo
}

prompt_listen_ipv4() {
    local __var_name="$1"
    local value ans _idx _if _fam cidr _rest choice default_idx=0 choices_hint=""
    local -a local_ips=()
    local has_private=0

    while read -r _idx _if _fam cidr _rest; do
        value="${cidr%/*}"
        validate_ipv4 "$value" || continue
        local_ips+=("$value")
        ipv4_is_rfc1918 "$value" && has_private=1
    done < <(ip -o -4 addr show scope global 2>/dev/null || true)

    # 默认优先选第一个内网地址（云 1:1 NAT 常见）；否则选列表第一项。
    if [[ ${#local_ips[@]} -gt 0 ]]; then
        default_idx=1
        _idx=1
        for value in "${local_ips[@]}"; do
            if ipv4_is_rfc1918 "$value"; then
                default_idx="$_idx"
                break
            fi
            ((_idx++))
        done
        choices_hint="1"
        for ((_idx = 2; _idx <= ${#local_ips[@]}; _idx++)); do
            choices_hint+="/${_idx}"
        done
    fi

    echo
    if [[ ${#local_ips[@]} -gt 0 ]]; then
        info "检测到本机全局 IPv4（请选包到达本机时的目的地址）："
        _idx=1
        for value in "${local_ips[@]}"; do
            printf "  %d) %s\n" "$_idx" "$value"
            ((_idx++))
        done
    else
        warn "未检测到本机全局 IPv4。"
    fi
    if (( has_private )); then
        warn "若公网 IP 未出现在上方列表，云厂商多为 1:1 NAT：应选内网 IP，不要填公网。"
    fi

    while true; do
        if (( default_idx > 0 )); then
            read_or_cancel choice "请选择前端监听 IPv4 [${choices_hint}，默认 ${default_idx}]: " || return 1
            choice="${choice:-$default_idx}"
        else
            read_or_cancel choice "请输入前端监听 IPv4（必须明确指定）: " || return 1
        fi
        value="$choice"
        if [[ "$choice" =~ ^[0-9]{1,5}$ && ${#local_ips[@]} -gt 0 ]]; then
            _idx=$(( 10#$choice - 1 ))
            if (( _idx >= 0 && _idx < ${#local_ips[@]} )); then
                value="${local_ips[$_idx]}"
            else
                err "请输入 ${choices_hint}，或直接输入 IPv4 地址。"
                continue
            fi
        fi
        validate_ipv4 "$value" || {
            if (( default_idx > 0 )); then
                err "请输入 ${choices_hint}，或直接输入合法 IPv4 地址。"
            else
                err "监听 IPv4 非法或属于特殊地址段。"
            fi
            continue
        }
        if ! ipv4_is_local "$value"; then
            warn "${value} 当前未配置在本机接口上。"
            if (( has_private )); then
                warn "云主机常见情况：公网只做 NAT，进机流量的目的 IP 是内网地址；填公网会导致规则匹配不到。"
            else
                warn "仅适合稍后接管的 VIP；若这是云公网映射地址，通常应改用本机实际接口 IP。"
            fi
            read_or_cancel ans "仍使用该地址？[y/N]: " || return 1
            answer_yes_default_no "$ans" || continue
        fi
        printf -v "$__var_name" '%s' "$value"
        return 0
    done
}

prompt_source_cidr() {
    local __var_name="$1"
    local value
    while true; do
        read_or_cancel value "允许的来源 CIDR [默认 0.0.0.0/0]: " || return 1
        value="${value:-0.0.0.0/0}"
        validate_ipv4_cidr "$value" || { err "来源 CIDR 非法，例如 203.0.113.0/24。"; continue; }
        printf -v "$__var_name" '%s' "$value"
        return 0
    done
}

show_runtime() {
    if nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1; then
        nft list table "$TABLE_FAMILY" "$TABLE_NAME"
    else
        warn "运行中未找到表 ${TABLE_FAMILY} ${TABLE_NAME}"
    fi
}

add_rule_interactive() {
    load_rules_from_conf || return 1
    assert_loaded_config_safe || return 1

    local listen_ip lport dip dport iif source_cidr ans target _path _iface
    local -a old_rules=()
    local -a protos_requested=() protos_to_add=()

    prompt_proto_choice protos_requested || return 0

    while true; do
        read_or_cancel target "请输入目标地址 (IP:端口): " || return 0
        if [[ "$target" =~ ^([0-9.]+):([0-9]+)$ ]]; then
            dip="${BASH_REMATCH[1]}"
            dport="${BASH_REMATCH[2]}"
            validate_ipv4 "$dip" && validate_port "$dport" && break
        fi
        err "格式应为 IPv4:端口，例如 10.0.0.2:8080"
    done

    confirm_continue_despite_unreachable_dest "$dip" "$dport" || return 0

    while true; do
        read_or_cancel lport "本机监听端口 [默认 ${dport}]: " || return 0
        lport="${lport:-$dport}"
        validate_port "$lport" && break
        err "端口无效。"
    done

    confirm_continue_despite_local_port_use "$lport" || return 0

    prompt_listen_ipv4 listen_ip || return 0
    prompt_source_cidr source_cidr || return 0

    iif="*"
    read_or_cancel ans "是否限制入口网卡？[y/N]: " || return 0
    if answer_yes_default_no "$ans"; then
        local -a detected_ifaces=()
        if [[ -d /sys/class/net ]]; then
            for _path in /sys/class/net/*; do
                [[ -e "$_path" ]] || continue
                _iface="${_path##*/}"
                [[ "$_iface" == "lo" ]] && continue
                detected_ifaces+=("$_iface")
            done
        fi

        echo
        if [[ ${#detected_ifaces[@]} -gt 0 ]]; then
            info "检测到以下网卡："
            local _n=1
            for _iface in "${detected_ifaces[@]}"; do
                printf "  %d) %s\n" "$_n" "$_iface"
                ((_n++))
            done
            echo "  *) 不限制（输入 * 或回车）"
        fi

        while true; do
            read_or_cancel iif "入口网卡（序号/名称，回车=*）: " || return 0
            iif="${iif:-*}"

            if [[ "$iif" =~ ^[0-9]{1,5}$ && ${#detected_ifaces[@]} -gt 0 ]]; then
                local idx=$(( 10#$iif - 1 ))
                if (( idx >= 0 && idx < ${#detected_ifaces[@]} )); then
                    iif="${detected_ifaces[$idx]}"
                    info "已选择网卡: ${iif}"
                else
                    err "序号超出范围（1-${#detected_ifaces[@]}）。"
                    continue
                fi
            fi

            if validate_ifname "$iif"; then
                if ! ifname_exists "$iif"; then
                    warn "接口 ${iif} 当前不存在。"
                    read_or_cancel ans "作为未来接口名继续？[y/N]: " || return 0
                    answer_yes_default_no "$ans" || continue
                fi
                break
            fi
            err "入口网卡名无效（允许字母/数字/._:-，或 *）。"
        done
    fi

    local p
    protos_to_add=()
    for p in "${protos_requested[@]}"; do
        if rule_conflicts "$listen_ip" "$lport" "$p" "$iif"; then
            warn "监听范围重叠，跳过：${listen_ip}:${lport}/${p} (iif=${iif})"
        else
            protos_to_add+=("$p")
        fi
    done
    if [[ ${#protos_to_add[@]} -eq 0 ]]; then
        warn "没有可添加的新规则。"
        return 0
    fi

    echo
    info "将添加规则（DNAT + SNAT）:"
    for p in "${protos_to_add[@]}"; do
        echo "  ${p} ${listen_ip}:${lport} -> ${dip}:${dport} (snat=本机出口IP, iif=${iif}, source=${source_cidr})"
    done

    read_or_cancel ans "确认继续? [y/N]: " || return 0
    answer_yes_default_no "$ans" || {
        warn "已取消。"
        return 0
    }

    plan_ip_forward_for_add || return 0
    plan_nftables_enable_for_add || return 0
    old_rules=("${RULES[@]+"${RULES[@]}"}")
    for p in "${protos_to_add[@]}"; do
        RULES+=("${listen_ip}|${lport}|${p}|${dip}|${dport}|${iif}|${source_cidr}")
    done

    if ! commit_rules; then
        RULES=("${old_rules[@]+"${old_rules[@]}"}")
        err "规则提交失败。"
        return 1
    fi
    if ! apply_ip_forward_plan; then
        err "IPv4 转发设置失败，正在撤销刚提交的规则。"
        RULES=("${old_rules[@]+"${old_rules[@]}"}")
        commit_rules || die "撤销规则失败，请立即检查 ${CONF_FILE} 与运行表。"
        return 1
    fi
    if ! apply_nftables_enable_plan; then
        err "规则已提交，但启用 nftables.service 失败；可稍后手动执行 systemctl enable --now nftables。"
    fi

    info "规则添加成功。"
    show_persistence_hint
}

delete_rule_interactive() {
    load_rules_from_conf || return 1
    assert_loaded_config_safe || return 1

    if [[ ${#RULES[@]} -eq 0 ]]; then
        warn "没有规则可删。"
        return 0
    fi

    list_rules

    local choice ans idx i r
    local victim listen_ip lport proto dip dport iif source_cidr
    local -a del_idxs=() new_rules=()
    local -A del_set=()

    while true; do
        read_or_cancel choice "请输入序号删除（多选: 空格/逗号；n+/n-；all=清空；0=取消）: " || return 0
        [[ -n "${choice:-}" ]] || {
            err "输入不能为空。"
            continue
        }

        if [[ "$choice" == "0" ]]; then
            warn "已取消。"
            return 0
        fi

        if [[ "$choice" == "all" || "$choice" == "ALL" ]]; then
            clear_rules_interactive
            return $?
        fi

        if parse_rule_delete_selection "$choice" "${#RULES[@]}" del_idxs; then
            break
        fi
    done

    echo
    info "将删除 ${#del_idxs[@]} 条规则:"
    for idx in "${del_idxs[@]}"; do
        victim="${RULES[$idx]}"
        IFS='|' read -r listen_ip lport proto dip dport iif source_cidr <<< "$victim"
        iif="${iif:-*}"
        echo "  ${proto} ${listen_ip}:${lport} -> ${dip}:${dport} (iif=${iif}, source=${source_cidr})"
    done

    read_or_cancel ans "确认继续? [y/N]: " || return 0
    answer_yes_default_no "$ans" || {
        warn "已取消。"
        return 0
    }

    del_set=()
    for idx in "${del_idxs[@]}"; do
        del_set["$idx"]=1
    done

    new_rules=()
    i=0
    for r in "${RULES[@]+"${RULES[@]}"}"; do
        if [[ -z "${del_set[$i]:-}" ]]; then
            new_rules+=("$r")
        fi
        (( ++i ))
    done

    RULES=("${new_rules[@]+"${new_rules[@]}"}")
    commit_rules || return 1

    info "已删除 ${#del_idxs[@]} 条。"
    [[ ${#RULES[@]} -ne 0 ]] \
        || warn "规则已清空；为避免影响其他路由/VPN/容器，不会自动关闭 IPv4 forwarding。"
}

# 解析删除序号（1-based，空格/逗号分隔，支持中文逗号）。
# 支持 n+（n 与 n+1）、n-（n 与 n-1）；越界邻居跳过并警告。
# 通过 nameref 写回去重后的 0-based 下标（按升序）。成功 0，失败 1。
parse_rule_delete_selection() {
    local input="$1"
    local max="$2"
    local -n _idxs_out="$3"
    local normalized token n idx neighbor zero_based
    local -A seen=()
    local -a tokens=() raw=() sorted=()

    _idxs_out=()
    normalized="${input//，/,}"
    normalized="${normalized//,/ }"
    read -ra tokens <<< "$normalized"
    (( ${#tokens[@]} > 0 )) || {
        err "请输入至少一个序号。"
        return 1
    }

    for token in "${tokens[@]}"; do
        if [[ "$token" =~ ^([1-9][0-9]*)\+$ ]]; then
            n=$((10#${BASH_REMATCH[1]}))
            if (( n < 1 || n > max )); then
                err "序号超出范围：${n}+（1-${max}）。"
                return 1
            fi
            zero_based=$((n - 1))
            if [[ -z "${seen[$zero_based]:-}" ]]; then
                seen["$zero_based"]=1
                raw+=("$zero_based")
            fi
            neighbor=$((n + 1))
            if (( neighbor <= max )); then
                zero_based=$((neighbor - 1))
                if [[ -z "${seen[$zero_based]:-}" ]]; then
                    seen["$zero_based"]=1
                    raw+=("$zero_based")
                fi
            else
                warn "${n}+ 的下一档 ${neighbor} 超出范围（共 ${max} 条），仅保留 ${n}。"
            fi
        elif [[ "$token" =~ ^([1-9][0-9]*)-$ ]]; then
            n=$((10#${BASH_REMATCH[1]}))
            if (( n < 1 || n > max )); then
                err "序号超出范围：${n}-（1-${max}）。"
                return 1
            fi
            zero_based=$((n - 1))
            if [[ -z "${seen[$zero_based]:-}" ]]; then
                seen["$zero_based"]=1
                raw+=("$zero_based")
            fi
            neighbor=$((n - 1))
            if (( neighbor >= 1 )); then
                zero_based=$((neighbor - 1))
                if [[ -z "${seen[$zero_based]:-}" ]]; then
                    seen["$zero_based"]=1
                    raw+=("$zero_based")
                fi
            else
                warn "${n}- 的上一档不存在（已是首条），仅保留 ${n}。"
            fi
        elif [[ "$token" =~ ^[1-9][0-9]*$ ]]; then
            n=$((10#$token))
            if (( n < 1 || n > max )); then
                err "序号超出范围：${n}（1-${max}）。"
                return 1
            fi
            zero_based=$((n - 1))
            if [[ -z "${seen[$zero_based]:-}" ]]; then
                seen["$zero_based"]=1
                raw+=("$zero_based")
            fi
        else
            err "无效序号：${token}（支持正整数、n+、n-；多选用空格或逗号；all/0 请单独输入）。"
            return 1
        fi
    done

    (( ${#raw[@]} > 0 )) || {
        err "请输入至少一个序号。"
        return 1
    }

    mapfile -t sorted < <(printf '%s\n' "${raw[@]}" | sort -n)
    _idxs_out=("${sorted[@]}")
    return 0
}

clear_rules_interactive() {
    load_rules_from_conf || return 1
    assert_loaded_config_safe || return 1

    if [[ ${#RULES[@]} -eq 0 ]]; then
        warn "当前没有规则。"
        return 0
    fi

    local ans
    warn "将清空全部 ${#RULES[@]} 条规则。"
    read_or_cancel ans "确认继续? [y/N]: " || return 0
    answer_yes_default_no "$ans" || {
        warn "已取消。"
        return 0
    }

    RULES=()
    commit_rules || return 1

    info "已清空。"
    warn "为避免影响其他路由/VPN/容器，不会自动关闭 IPv4 forwarding。"
}

init_empty_conf_if_needed() {
    ensure_dirs
    if [[ ! -f "$CONF_FILE" ]]; then
        RULES=()
        CONFIG_LOAD_ERRORS=0
        commit_rules || return 1
        info "已初始化空配置: $CONF_FILE"
    fi
    return 0
}

# 仅覆盖 setup_environment_interactive 实际会处理的项。
# 运行态表达式比对属于健康检查（--check / 菜单 4 快检），不在此反复打扰。
environment_needs_attention() {
    local ipf
    [[ ! -f "$CONF_FILE" ]] && return 0
    main_conf_has_include || return 0
    load_rules_from_conf >/dev/null 2>&1 || return 0
    (( CONFIG_LOAD_ERRORS == 0 )) || return 0
    if (( ${#RULES[@]} > 0 )); then
        check_snat_ip_current >/dev/null 2>&1 || return 0
        ipf="$(get_ip_forward_value)" || return 0
        [[ "$ipf" != "1" ]] && return 0
    fi
    return 1
}

maybe_first_run_setup() {
    local ans

    if environment_needs_attention; then
        echo
        info "检测到环境待处理项（配置 / include / IPv4 转发）。"
        read_or_cancel ans "是否现在检查并修复？[Y/n]: " || return 0
        if answer_yes_default_yes "$ans"; then
            setup_environment_interactive || return 1
        else
            warn "已跳过，可稍后使用菜单 4。"
        fi
    fi
}

setup_environment_interactive() {
    local cur ans snat_check_rc

    info "检查并修复：配置文件、持久化 include、IPv4 转发；不会自动启动通用 nftables.service。"
    init_empty_conf_if_needed || return 1
    check_include_hint || return 1
    load_rules_from_conf || return 1
    if (( ${#RULES[@]} == 0 )); then
        info "当前没有转发规则，不需要开启 IPv4 forwarding。"
        return 0
    fi

    if check_snat_ip_current; then
        :
    else
        snat_check_rc=$?
        (( snat_check_rc == 1 )) || return 1
        read_or_cancel ans "是否以当前出口 IPv4 重新提交现有规则？[Y/n]: " || return 0
        if answer_yes_default_yes "$ans"; then
            commit_rules || return 1
            info "已更新 LOCAL_IP 并重新提交现有规则。"
        else
            warn "已跳过更新 LOCAL_IP；现有静态 SNAT 可能无法正常转发。"
        fi
    fi

    cur="$(get_ip_forward_value)" || {
        err "无法读取 net.ipv4.ip_forward"
        return 1
    }
    if [[ "$cur" == "1" ]]; then
        info "net.ipv4.ip_forward 已经是 1"
        if ! ip_forward_is_persisted; then
            read_or_cancel ans "是否持久化到 ${SYSCTL_FILE}？[y/N]: " || return 0
            if answer_yes_default_no "$ans"; then
                enable_ip_forward_persist || return 1
            fi
        fi
        return 0
    fi

    echo
    read_or_cancel ans "是否现在开启 IPv4 转发？[Y/n]: " || return 0
    if answer_yes_default_yes "$ans"; then
        enable_ip_forward_runtime || return 1
        read_or_cancel ans "是否同时持久化到 ${SYSCTL_FILE}？[y/N]: " || return 0
        if answer_yes_default_no "$ans"; then
            enable_ip_forward_persist || return 1
        fi
    else
        warn "已跳过开启 IPv4 转发。"
    fi
}

check_and_fix_environment_interactive() {
    local ans

    setup_environment_interactive || return 1
    check_forward_status

    read_or_cancel ans "是否查看使用说明？[y/N]: " || return 0
    if answer_yes_default_no "$ans"; then
        show_tips
    fi
}

view_rules_interactive() {
    echo
    list_rules || return 1
    maybe_prompt_nftables_enable_or_restart || warn "启用/重启 nftables.service 未成功。"
    local ans
    read_or_cancel ans "显示原始 nft 规则？[y/N]: " || return 0
    if answer_yes_default_no "$ans"; then
        show_runtime
    fi
}

add_rule_menu_action() {
    init_empty_conf_if_needed || return 1
    add_rule_interactive
}

run_menu_action() {
    local rc
    set +e
    "$@"
    rc=$?
    set -e
    (( rc == 0 )) || warn "操作失败（exit=${rc}），未完成的部分不会报告成功。"
    return 0
}

diagnostic_file_state() {
    local path="$1"
    if [[ -L "$path" ]]; then
        printf '%s' '符号链接（异常）'
    elif [[ -f "$path" ]]; then
        printf '%s' '存在'
    elif [[ -e "$path" ]]; then
        printf '%s' '存在但不是普通文件（异常）'
    else
        printf '%s' '不存在'
    fi
}

show_config_error_guidance() {
    cat <<EOF

托管配置无法通过完整性校验：
  ${CONF_FILE}

为防止覆盖人工变更或损坏的规则，当前仅允许诊断和退出。
请从可信备份恢复该文件；如果确认是全新部署，也可在备份后人工移除，再重新运行脚本初始化。

只读校验命令：
  nft -c -f ${CONF_FILE}
  nft list table ${TABLE_FAMILY} ${TABLE_NAME}

事务文件状态（只读）：
  marker:    ${TXN_MARKER} [$(diagnostic_file_state "$TXN_MARKER")]
  candidate: ${TXN_CANDIDATE} [$(diagnostic_file_state "$TXN_CANDIDATE")]
  rollback:  ${TXN_ROLLBACK} [$(diagnostic_file_state "$TXN_ROLLBACK")]

事务恢复说明：
  - marker 不存在：没有检测到待恢复事务。
  - marker 与 candidate 同时存在：提交可能尚未完成；配置恢复可信后，重新运行脚本会使用 rollback 恢复事务前运行态。
  - marker 存在但 candidate 不存在：运行态提交可能已完成；配置恢复可信后，重新运行脚本会按正式配置恢复运行态。
  - 不要单独删除 marker、candidate 或 rollback，也不要加载未经核对的事务文件。
  - 如果没有可信配置备份，请停止自动操作并人工核对上述文件及当前 nft 运行态。

EOF
}

config_error_menu() {
    local choice
    cat <<EOF

========================================
 ${SCRIPT_DISPLAY_NAME}  |  配置错误（只读诊断模式）
========================================
1) 运行当前运行态健康检查
2) 显示安全恢复指引
0) 退出
========================================
EOF
    read_or_cancel choice "请选择: " || exit 0
    case "${choice:-}" in
        1) run_menu_action run_health_check check ;;
        2) show_config_error_guidance ;;
        0) exit 0 ;;
        *) err "无效选择。" ;;
    esac
}

managed_config_needs_diagnostic() {
    [[ -e "$CONF_FILE" || -L "$CONF_FILE" ]] || return 1
    ! load_rules_from_conf
}

run_config_error_mode() {
    while true; do
        config_error_menu
    done
}

menu() {
    local rule_count choice
    while true; do
        if load_rules_from_conf; then
            rule_count="${#RULES[@]}"
        else
            config_error_menu
            continue
        fi
        cat <<EOF

========================================
 ${SCRIPT_DISPLAY_NAME}  |  ip_forward=$(get_ip_forward_display)  |  规则 ${rule_count} 条
========================================
1) 添加转发
2) 查看规则
3) 删除规则
4) 检查并修复环境
0) 退出
========================================
EOF
        read_or_cancel choice "请选择: " || exit 0

        case "${choice:-}" in
            1) run_menu_action add_rule_menu_action ;;
            2) run_menu_action view_rules_interactive ;;
            3) run_menu_action delete_rule_interactive ;;
            4) run_menu_action check_and_fix_environment_interactive ;;
            0) exit 0 ;;
            *) err "无效选择。" ;;
        esac
    done
}

main() {
    local rc
    check_bash_version
    handle_cli_args "$@"
    check_root
    check_cmds
    acquire_lock
    trap release_lock EXIT
    if [[ "$CLI_MODE" == "check" || "$CLI_MODE" == "check-strict" ]]; then
        set +e
        if [[ "$CLI_MODE" == "check-strict" ]]; then
            run_health_check strict
        else
            run_health_check check
        fi
        rc=$?
        set -e
        return "$rc"
    fi
    if managed_config_needs_diagnostic; then
        run_config_error_mode
        return 0
    fi
    ensure_dirs
    recover_incomplete_transaction
    maybe_first_run_setup
    menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
