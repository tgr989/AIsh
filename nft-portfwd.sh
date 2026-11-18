#!/bin/bash
set -euo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
umask 027

#
# nftables 端口转发管理脚本（nft-portfwd）
#
# - 按地址族管理 table ip portfwd / table ip6 portfwd
# - DNAT + MASQUERADE
# - 协议 tcp/udp（可同时添加，默认 both）
# - 检查/持久化 ip_forward 与 nftables include
#

TABLE_FAMILY="ip"
TABLE_NAME="portfwd"
CHAIN_PREROUTING="prerouting"
CHAIN_POSTROUTING="postrouting"
SCRIPT_DISPLAY_NAME="nft-portfwd"
SCRIPT_VERSION="2.3.1"

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
INCLUDE_CHECK_REGEX="^[[:space:]]*include[[:space:]]+[\"']?/etc/nftables\\.d/(\\*|portfwd)\\.conf[\"']?[[:space:]]*;?[[:space:]]*(#.*)?$"

readonly TABLE_FAMILY TABLE_NAME CHAIN_PREROUTING CHAIN_POSTROUTING SCRIPT_DISPLAY_NAME SCRIPT_VERSION
readonly CONF_DIR CONF_FILE MAIN_CONF SYSCTL_FILE
readonly RUNTIME_DIR LOCK_FILE OWNER_CHAIN
readonly TXN_CANDIDATE TXN_ROLLBACK TXN_MARKER
readonly CONF_MAGIC
readonly INCLUDE_GLOB INCLUDE_LINE INCLUDE_CHECK_REGEX

# 规则存储格式:
# listen_ip|lport|proto|dest_ip|dest_port|iif|source_cidr[|rule_name]
# proto 仅存 tcp / udp；如果用户选 both，会展开成两条
# iif 为入口网卡名（如 eth0）或 *（不限制）
# source_cidr 默认为 IPv4 的 0.0.0.0/0 或 IPv6 的 ::/0
declare -a RULES=()
# 清空最后一条规则时仍重建已托管的表，避免旧 NAT 规则残留。
declare -A CONFIG_TABLES=()
declare -Ar FORWARD_KEYS=([ip]=net.ipv4.ip_forward [ip6]=net.ipv6.conf.all.forwarding)
declare -Ar FORWARD_FILES=([ip]="$SYSCTL_FILE" [ip6]=/etc/sysctl.d/99-portfwd-ipv6-forward.conf)
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
    local conf_path="${1:-$MAIN_CONF}"
    [[ -f "$conf_path" ]] || return 1
    grep -Eq "$INCLUDE_CHECK_REGEX" "$conf_path" 2>/dev/null
}

nftables_service_uses_main_conf() {
    local exec_start file_arg
    command -v systemctl >/dev/null 2>&1 || return 1
    exec_start="$(systemctl show nftables --property=ExecStart --value 2>/dev/null)" || return 1
    file_arg="[[:space:]](-f[[:space:]]+|--file([[:space:]]+|=))${MAIN_CONF//./[.]}([[:space:];]|$)"
    [[ "$exec_start" =~ $file_arg ]]
}

nftables_is_enabled_at_boot() {
    local state
    state="$(systemctl is-enabled nftables 2>/dev/null)" || return 1
    [[ "$state" == enabled ]]
}

show_persistence_hint() {
    if ! main_conf_has_include; then
        warn "持久化未就绪：${MAIN_CONF} 未包含 ${INCLUDE_GLOB}（菜单 4 可修复）"
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if ! nftables_is_enabled_at_boot; then
            warn_nftables_service_not_enabled "持久化未就绪："
        elif ! nftables_service_uses_main_conf; then
            warn "持久化未就绪：nftables.service 的启动命令未确认使用 ${MAIN_CONF}。"
        fi
    else
        warn "无法验证 nftables 开机加载：未发现 systemctl"
    fi
}

# 提示如何启用 nftables 开机加载；prefix 用于区分调用场景文案。
warn_nftables_service_not_enabled() {
    local prefix="${1:-}"
    warn "${prefix}nftables.service 未永久启用；可用菜单 4 检查并配置开机加载。"
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

validate_rule_name() {
    [[ "$1" != *'|'* && "$1" != *[[:cntrl:]]* ]]
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
    local ip="${1:-}" o1 o2 o3 o4 o
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

address_family() {
    if [[ "$1" == *:* ]]; then
        printf 'ip6\n'
    else
        printf 'ip\n'
    fi
}

format_ipv6_address() {
    local -n groups="$1"
    local prefix="$2" i zero_count=0 best_count=1 best_start=-1
    local formatted="" separator="" hex ipv4_prefix="::"

    # 连续零组的长度相同，优先压缩左侧。
    for (( i=0; i<8; i++ )); do
        if (( groups[i] == 0 )); then
            (( ++zero_count ))
            if (( zero_count > best_count )); then
                best_count="$zero_count"
                best_start=$((i - zero_count + 1))
            fi
        else
            zero_count=0
        fi
    done

    # 保留旧版及 Linux nft 对 IPv4 兼容/映射地址的点分形式。
    if (( best_start == 0 && (best_count == 6 || (best_count == 5 && groups[5] == 0xffff)) )); then
        if (( best_count == 5 )); then
            ipv4_prefix+="ffff:"
        fi
        printf '%s%d.%d.%d.%d%s\n' "$ipv4_prefix" \
            "$((groups[6] >> 8))" "$((groups[6] & 255))" \
            "$((groups[7] >> 8))" "$((groups[7] & 255))" "${prefix:+/$prefix}"
        return
    fi

    for (( i=0; i<8; i++ )); do
        if (( i == best_start )); then
            formatted+="::"
            separator=""
            (( i += best_count - 1 ))
        else
            printf -v hex '%x' "${groups[i]}"
            formatted+="$separator$hex"
            separator=":"
        fi
    done
    printf '%s%s\n' "$formatted" "${prefix:+/$prefix}"
}

normalize_ipv6() {
    local LC_ALL=C
    local address="$1" kind="$2" prefix="" dotted i host_mask
    local hex_group='[[:xdigit:]]{1,4}' group_list
    local -a words=() tail=()

    if [[ "$kind" == cidr ]]; then
        [[ "$address" == */* ]] || return 1
        prefix="${address##*/}"
        address="${address%/*}"
        [[ "$prefix" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( prefix <= 128 )) || return 1
    fi

    if [[ "$address" == *.* ]]; then
        [[ "$address" == *:* ]] || return 1
        dotted="${address##*:}"
        validate_ipv4_basic "$dotted" || return 1
        local o1 o2 o3 o4
        IFS='.' read -r o1 o2 o3 o4 <<< "$dotted"
        printf -v address '%s:%x:%x' "${address%:*}" "$((o1 << 8 | o2))" "$((o3 << 8 | o4))"
    fi

    if [[ "$address" == *::* ]]; then
        group_list="$hex_group(:$hex_group)*"
        [[ "$address" =~ ^($group_list)?::($group_list)?$ ]] || return 1
        IFS=':' read -ra words <<< "${address%%::*}"
        IFS=':' read -ra tail <<< "${address#*::}"
        (( ${#words[@]} + ${#tail[@]} < 8 )) || return 1
        while (( ${#words[@]} + ${#tail[@]} < 8 )); do
            words+=(0)
        done
        words+=("${tail[@]}")
    else
        [[ "$address" =~ ^($hex_group:){7}$hex_group$ ]] || return 1
        IFS=':' read -ra words <<< "$address"
    fi

    for i in "${!words[@]}"; do
        words[i]=$((16#${words[i]}))
    done

    if [[ "$kind" == cidr ]]; then
        host_mask=$((0xffff >> (prefix % 16)))
        for (( i=prefix / 16; i<8; i++ )); do
            (( (words[i] & host_mask) == 0 )) || return 1
            host_mask=0xffff
        done
    else
        # 监听和目标排除特殊地址，来源前缀仍可匹配这些地址。
        (( (words[0] & 0xffc0) != 0xfe80 && (words[0] & 0xff00) != 0xff00 )) || return 1
        if (( (words[0] | words[1] | words[2] | words[3] | words[4]) == 0 )); then
            (( words[5] != 0xffff && (words[5] != 0 || words[6] != 0 || words[7] > 1) )) || return 1
        fi
    fi
    format_ipv6_address words "$prefix"
}

# 地址在进入 RULES 前统一规范化，确保不同 IPv6 写法使用同一个监听键。
normalize_ip() {
    local family="$1" value="$2" kind="${3:-address}"
    if [[ "$family" == ip ]]; then
        if [[ "$kind" == cidr ]]; then
            validate_ipv4_cidr "$value" || return 1
        else
            validate_ipv4 "$value" || return 1
        fi
        printf '%s\n' "$value"
        return 0
    fi
    normalize_ipv6 "$value" "$kind"
}

format_endpoint() {
    if [[ "$1" == *:* ]]; then
        printf '[%s]:%s' "$1" "$2"
    else
        printf '%s:%s' "$1" "$2"
    fi
}

parse_target() {
    local target="$1" parsed_addr parsed_port family
    local -n out_addr="$2" out_port="$3"
    if [[ "$target" =~ ^\[([[:xdigit:]:.]+)\]:([0-9]+)$ ]]; then
        parsed_addr="${BASH_REMATCH[1]}" parsed_port="${BASH_REMATCH[2]}" family=ip6
    elif [[ "$target" =~ ^([0-9.]+):([0-9]+)$ ]]; then
        parsed_addr="${BASH_REMATCH[1]}" parsed_port="${BASH_REMATCH[2]}" family=ip
    else
        return 1
    fi
    validate_port "$parsed_port" || return 1
    parsed_addr="$(normalize_ip "$family" "$parsed_addr")" || return 1
    out_addr="$parsed_addr"
    out_port="$parsed_port"
}

family_rules() {
    local family="$1" rule
    local -n result="$2"
    result=()
    for rule in "${RULES[@]}"; do
        if [[ "${rule%%|*}" == *:* ]]; then
            [[ "$family" == ip6 ]] || continue
        else
            [[ "$family" == ip ]] || continue
        fi
        result+=("$rule")
    done
}

table_families() {
    local family
    local -a selected
    if (( ${#RULES[@]} == 0 && ${#CONFIG_TABLES[@]} == 0 )); then
        printf 'ip\n'
        return
    fi
    for family in ip ip6; do
        family_rules "$family" selected
        if (( ${#selected[@]} )) || [[ -n "${CONFIG_TABLES[$family]:-}" ]]; then
            printf '%s\n' "$family"
        fi
    done
}

record_table_header() {
    case "$1" in
        "table ip $TABLE_NAME {") CONFIG_TABLES[ip]=1 ;;
        "table ip6 $TABLE_NAME {") CONFIG_TABLES[ip6]=1 ;;
        *) return 1 ;;
    esac
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

ip_is_local() {
    local family="$1" addr="$2" flag=-4 addresses idx iface type cidr rest
    [[ "$family" == ip6 ]] && flag=-6
    addresses="$(ip -o "$flag" addr show 2>/dev/null)" || return 1
    while read -r idx iface type cidr rest; do
        [[ "${cidr%/*}" == "$addr" ]] && return 0
    done <<< "$addresses"
    return 1
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

# ss 监听行是否包含指定端口（避免 :80 误匹配 :8080）。
ss_listen_line_has_port() {
    local port="$1" line="$2"
    [[ "$line" =~ :${port}[[:space:]] ]]
}

# 通过 stdout 返回 TCP / UDP / TCP+UDP；未占用或无法检测时返回空并 exit 1。
describe_local_port_occupancy() {
    local port="${1:-}" line tcp=0 udp=0
    local -a flags=()
    [[ "${2:-ip}" == ip6 ]] && flags=(-6)
    validate_port "$port" || return 1
    command -v ss >/dev/null 2>&1 || return 1

    while IFS= read -r line; do
        ss_listen_line_has_port "$port" "$line" && tcp=1 && break
    done < <(ss "${flags[@]}" -H -ltn 2>/dev/null || true)

    while IFS= read -r line; do
        ss_listen_line_has_port "$port" "$line" && udp=1 && break
    done < <(ss "${flags[@]}" -H -lun 2>/dev/null || true)

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
    occupied="$(describe_local_port_occupancy "$port" "${2:-ip}" 2>/dev/null)" || return 0
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
    normalize_ip "$(address_family "$ip")" "$ip" >/dev/null || return 1
    validate_port "$port" || return 1
    can_probe_tcp_connect || return 1

    timeout "$wait_sec" bash -c 'exec 3<>"/dev/tcp/$1/$2"' bash "$ip" "$port" 2>/dev/null
}

# 交互：添加规则前探测目标 TCP；不通时确认。继续返回 0，取消返回 1。
confirm_continue_despite_unreachable_dest() {
    local ip="$1" port="$2" ans endpoint
    endpoint="$(format_endpoint "$ip" "$port")"

    if ! can_probe_tcp_connect; then
        warn "跳过目标连通性探测：未找到 timeout 命令。"
        return 0
    fi

    info "正在探测目标 TCP ${endpoint}（超时 3s）..."
    if probe_tcp_connect "$ip" "$port" 3; then
        info "目标 ${endpoint} TCP 可达。"
        return 0
    fi

    warn "目标 ${endpoint} TCP 不通或超时（不等于 NAT 会失败；若目标仅 UDP 可忽略）。"
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
    nft list table "$1" "$TABLE_NAME" >/dev/null 2>&1
}

runtime_table_is_owned() {
    nft list chain "$1" "$TABLE_NAME" "$OWNER_CHAIN" >/dev/null 2>&1
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
    local line parsed_rule family listen_ip lport proto dip dport iif source_cidr rule_name
    local tmp_expected=""
    local -a fields=()
    RULES=()
    CONFIG_TABLES=()
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
        record_table_header "$line" && continue
        if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*RULE:[[:space:]]*(.+)[[:space:]]*$ ]]; then
            parsed_rule="${BASH_REMATCH[1]}"
            fields=()
            IFS='|' read -ra fields <<< "$parsed_rule"

            if (( ${#fields[@]} != 7 && ${#fields[@]} != 8 )); then
                err "配置规则应包含 7 个必填字段和一个可选名称。"
                CONFIG_LOAD_ERRORS=1
                continue
            fi
            listen_ip="${fields[0]}"; lport="${fields[1]}"; proto="${fields[2]}"
            dip="${fields[3]}"; dport="${fields[4]}"; iif="${fields[5]}"
            source_cidr="${fields[6]}"
            rule_name="${fields[7]:-}"
            validate_rule_name "$rule_name" || {
                err "配置中的规则名称包含竖线或控制字符。"
                CONFIG_LOAD_ERRORS=1
                continue
            }

            [[ "$proto" == "tcp" || "$proto" == "udp" ]] || {
                err "配置规则协议非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue
            }
            family="$(address_family "$listen_ip")"
            listen_ip="$(normalize_ip "$family" "$listen_ip")" || {
                err "配置规则监听 IP 非法/特殊：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue
            }
            validate_port "$lport" || { err "配置规则端口非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            validate_port "$dport" || { err "配置规则目标端口非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            dip="$(normalize_ip "$family" "$dip")" || { err "配置规则目标 IP 非法/特殊或地址族不同：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            validate_ifname "$iif" || { err "配置规则入口网卡非法：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue; }
            source_cidr="$(normalize_ip "$family" "$source_cidr" cidr)" || {
                err "配置规则来源 CIDR 非法或地址族不同：$parsed_rule"; CONFIG_LOAD_ERRORS=1; continue
            }
            if rule_conflicts "$listen_ip" "$lport" "$proto" "$iif"; then
                err "配置存在重叠监听规则：$parsed_rule"
                CONFIG_LOAD_ERRORS=1
                continue
            fi

            RULES+=("${listen_ip}|${lport}|${proto}|${dip}|${dport}|${iif}|${source_cidr}${rule_name:+|$rule_name}")
        fi
    done < "$conf_path"

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

rule_expressions() {
    local family="$1" rule="$2" view="$3"
    local -n pre_expr="$4" post_expr="$5"
    local listen lport proto dest dport iif cidr endpoint _rule_name
    local ingress="" source="" original_source=""
    local nat_action=masquerade
    IFS='|' read -r listen lport proto dest dport iif cidr _rule_name <<< "$rule"
    [[ "$iif" == "*" ]] || ingress="iifname \"${iif}\" "
    if [[ "$cidr" != "0.0.0.0/0" && "$cidr" != "::/0" ]]; then
        if [[ "$view" == runtime ]]; then
            if [[ "$family" == ip6 ]]; then cidr="${cidr%/128}"; else cidr="${cidr%/32}"; fi
        fi
        source="$family saddr $cidr "
        original_source="ct original $source"
    fi
    endpoint="$(format_endpoint "$dest" "$dport")"
    pre_expr="${ingress}$family daddr $listen ${source}$proto dport $lport dnat to $endpoint"
    # ct original proto-dst 需要先指定 L4 协议上下文。
    post_expr="${ingress}ct status dnat ct original $family daddr $listen meta l4proto $proto ct original proto-dst $lport ${original_source}$family daddr $dest $proto dport $dport $nat_action"
}

render_table() {
    local family="$1" rule dnat postnat
    local -a selected post_lines=()
    family_rules "$family" selected
    printf 'add table %s %s\n' "$family" "$TABLE_NAME"
    printf 'delete table %s %s\n\n' "$family" "$TABLE_NAME"
    printf 'table %s %s {\n' "$family" "$TABLE_NAME"
    printf '    chain %s {\n    }\n\n' "$OWNER_CHAIN"
    printf '    chain %s {\n' "$CHAIN_PREROUTING"
    printf '        type nat hook prerouting priority -100; policy accept;\n'
    for rule in "${selected[@]}"; do
        rule_expressions "$family" "$rule" config dnat postnat
        printf '        # RULE: %s\n        %s\n' "$rule" "$dnat"
        post_lines+=("        # RULE-MASQ: $rule" "        $postnat")
    done
    printf '    }\n\n    chain %s {\n' "$CHAIN_POSTROUTING"
    printf '        type nat hook postrouting priority 100; policy accept;\n'
    if (( ${#post_lines[@]} )); then printf '%s\n' "${post_lines[@]}"; fi
    printf '    }\n}\n'
}

render_conf_file() {
    local output_path="$1" family
    local -a families
    mapfile -t families < <(table_families)

    if ! {
        printf '%s\n' '#!/usr/sbin/nft -f'
        printf '%s\n\n' "$CONF_MAGIC"
        for family in "${families[@]}"; do
            render_table "$family" || return 1
        done
    } > "$output_path"; then
        err "生成 nft 配置失败：${output_path}"
        return 1
    fi
    grep -Fqx "$CONF_MAGIC" "$output_path" || return 1
    for family in "${families[@]}"; do
        grep -Fqx "table $family $TABLE_NAME {" "$output_path" || return 1
    done
}

runtime_rules_match_loaded_config() {
    local runtime_output="$1" family="${2:-ip}" line chain="" key count rule dnat postnat
    local table_seen=0 owner_seen=0 prerouting_seen=0 postrouting_seen=0
    local prerouting_type_seen=0 postrouting_type_seen=0
    local -A expected=() seen=()
    local -a selected

    family_rules "$family" selected
    for rule in "${selected[@]}"; do
        rule_expressions "$family" "$rule" runtime dnat postnat
        expected["${CHAIN_PREROUTING}|$dnat"]=1
        expected["${CHAIN_POSTROUTING}|$postnat"]=1
    done

    while IFS= read -r line || [[ -n "$line" ]]; do
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        case "$line" in
            "table ${family} ${TABLE_NAME} {") (( ++table_seen )); chain="" ;;
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

runtime_table_matches_loaded_config() {
    local family="$1" output
    output="$(nft -nn list table "$family" "$TABLE_NAME" 2>/dev/null | normalize_runtime_nft_dump "$family")" \
        || return 1
    runtime_rules_match_loaded_config "$output" "$family"
}

check_runtime_ownership() {
    local family tables
    tables="$(nft list tables)" || { err "无法读取运行表列表。"; return 1; }
    while read -r family; do
        grep -Fxq "table $family $TABLE_NAME" <<< "$tables" || continue
        runtime_table_is_owned "$family" || {
            err "运行中已有未标记的 table $family $TABLE_NAME；拒绝接管。"
            return 1
        }
    done < <(table_families)
}

# nft list 可能省略 meta l4proto；重新加载时 ct original proto-dst
# 没有 L4 上下文会报 "Can't parse symbolic invalid expressions"。
normalize_runtime_nft_dump() {
    local family="${1:-ip}" line proto bits=32 host_pattern
    [[ "$family" == ip6 ]] && bits=128
    host_pattern="($family saddr [[:xdigit:].:]+)/$bits([[:space:]]|$)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        # nft -nn 可将 conntrack 的 DNAT 状态位显示为十六进制。
        line="${line//ct status 0x20 /ct status dnat }"
        line="${line// dnat $family to / dnat to }"
        line="${line// snat $family to / snat to }"
        if [[ "$line" =~ $host_pattern ]]; then
            line="${line/"${BASH_REMATCH[1]}/$bits"/"${BASH_REMATCH[1]}"}"
        fi
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
    local output_path="$1" family tables
    tables="$(nft list tables)" || return 1
    {
        printf '%s\n\n' '#!/usr/sbin/nft -f'
        while read -r family; do
            printf 'add table %s %s\n' "$family" "$TABLE_NAME"
            printf 'delete table %s %s\n\n' "$family" "$TABLE_NAME"
            if grep -Fxq "table $family $TABLE_NAME" <<< "$tables"; then
                runtime_table_is_owned "$family" || return 1
                nft -nn list table "$family" "$TABLE_NAME" | normalize_runtime_nft_dump "$family" || return 1
            fi
        done < <(table_families)
    } > "$output_path" || { err "生成运行态回滚文件失败。"; return 1; }
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

repair_runtime_interactive() {
    local family ans
    local -a mismatched=()
    while read -r family; do
        if ! runtime_table_matches_loaded_config "$family"; then
            mismatched+=("$family $TABLE_NAME")
        fi
    done < <(table_families)
    (( ${#mismatched[@]} )) || return 0

    warn "以下运行表缺失或与配置不一致。"
    for family in "${mismatched[@]}"; do
        warn "  table $family"
    done
    read_or_cancel ans "是否按正式配置恢复托管运行表？[Y/n]: " || return 1
    answer_yes_default_yes "$ans" || return 1

    if [[ -e "$TXN_MARKER" || -L "$TXN_MARKER" ]]; then
        err "存在未恢复的规则事务，请重新启动脚本执行恢复。"
        return 1
    fi
    secure_root_file "$CONF_FILE" && load_rules_from_conf || return 1
    check_runtime_ownership || return 1
    apply_nft_file "$CONF_FILE" || {
        err "加载托管配置失败。"
        return 1
    }

    while read -r family; do
        if ! runtime_table_matches_loaded_config "$family"; then
            err "重新加载后，table $family $TABLE_NAME 仍未通过规则比对。"
            return 1
        fi
    done < <(table_families)
    info "托管运行表已恢复，并通过规则比对。"
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

    rm -f "$TXN_MARKER" "$TXN_CANDIDATE" "$TXN_ROLLBACK" \
        || die "无法清理已恢复的事务文件。"
}

commit_rules() {
    assert_loaded_config_safe || return 1
    ensure_dirs
    [[ ! -e "$TXN_MARKER" ]] || {
        err "存在未恢复的规则事务，请重新启动脚本执行恢复。"
        return 1
    }
    check_runtime_ownership || return 1

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
        rm -f "$TXN_MARKER" "$TXN_CANDIDATE" "$TXN_ROLLBACK" || true
        return 1
    fi

    if ! mv -f "$TXN_CANDIDATE" "$CONF_FILE"; then
        err "运行态已更新，但提交正式配置失败；正在回滚运行态。"
        if apply_nft_file "$TXN_ROLLBACK"; then
            rm -f "$TXN_MARKER" "$TXN_CANDIDATE" "$TXN_ROLLBACK" || true
            err "已恢复事务前运行态，磁盘配置未改变。"
        else
            err "运行态回滚失败，事务文件已保留，禁止继续操作。"
        fi
        return 1
    fi

    local family
    while read -r family; do CONFIG_TABLES[$family]=1; done < <(table_families)
    finish_committed_transaction
    return 0
}

finish_committed_transaction() {
    if ! rm -f "$TXN_MARKER" "$TXN_ROLLBACK"; then
        warn "规则已提交，但事务清理失败；下次启动会自动核对恢复。"
    fi
    return 0
}

get_ip_forward_value() {
    sysctl -n "${FORWARD_KEYS[${1:-ip}]}" 2>/dev/null
}

get_ip_forward_display() {
    local value
    if value="$(get_ip_forward_value "${1:-ip}")"; then
        printf '%s\n' "$value"
    else
        printf '%s\n' 'unknown'
    fi
}

# ---------- ip forward controls ----------
enable_ip_forward_runtime() {
    local family="${1:-ip}" cur key
    key="${FORWARD_KEYS[$family]}"
    cur="$(get_ip_forward_value "$family")" || { err "无法读取 $key"; return 1; }
    if [[ "$cur" != 1 ]]; then
        sysctl -w "$key=1" >/dev/null || { err "无法开启 $key"; return 1; }
        info "已临时开启 $key=1"
    else
        info "$key 已经是 1"
    fi
}

enable_ip_forward_persist() {
    local family="${1:-ip}" cur tmp sysctl_dir key path
    key="${FORWARD_KEYS[$family]}"
    path="${FORWARD_FILES[$family]}"
    sysctl_dir="$(dirname "$path")"
    ensure_secure_dir "$sysctl_dir" 0755
    [[ ! -L "$path" ]] || { err "拒绝写入符号链接：${path}"; return 1; }
    tmp="$(mktemp "${path}.tmp.XXXXXX")" || return 1
    if ! printf '%s\n' "$key=1" > "$tmp"; then
        rm -f "$tmp" || true
        return 1
    fi
    chmod 0644 "$tmp" || { rm -f "$tmp" || true; return 1; }
    if ! sysctl -p "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp" || true
        err "应用 ${key} 失败，未写入持久化文件。"
        return 1
    fi
    cur="$(get_ip_forward_value "$family")" || {
        rm -f "$tmp" || true
        err "无法读取 ${key}，未提交持久化文件。"
        return 1
    }
    if [[ "$cur" != "1" ]]; then
        rm -f "$tmp" || true
        err "临时应用后 ${key}=${cur}，未提交持久化文件。"
        return 1
    fi
    if ! mv -f "$tmp" "$path"; then
        rm -f "$tmp" || true
        err "提交持久化 sysctl 文件失败。"
        return 1
    fi
    info "已写入并应用持久化参数: $path"
    info "当前 ${key} = 1"
}

ip_forward_is_persisted() {
    local family="${1:-ip}" path
    path="${FORWARD_FILES[$family]}"
    secure_root_file "$path" && [[ "$(last_ip_forward_assignment "$path" "$family")" == 1 ]]
}

last_ip_forward_assignment() {
    local path="$1" family="${2:-ip}" line value key
    key="${FORWARD_KEYS[$family]}"
    line="$(grep -E "^[[:space:]]*-?[[:space:]]*${key//./[./]}[[:space:]]*=" "$path" 2>/dev/null | tail -n 1)" \
        || return 1
    [[ -n "$line" ]] || return 1
    value="${line#*=}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%%[[:space:]][#;]*}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

ip_forward_has_competing_persistence() {
    local family="${1:-ip}" dir path base value systemd_config systemd_sysctl=""
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
        && value="$(last_ip_forward_assignment <(printf '%s\n' "$systemd_config") "$family")"; then
        if [[ "$value" != "1" ]]; then
            warn "systemd-sysctl 合并后的 ${FORWARD_KEYS[$family]} 持久化值为 ${value}"
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
            if value="$(last_ip_forward_assignment "$path" "$family")"; then
                effective_value="$value"
                effective_source="$path"
            fi
        done
    fi

    # procps sysctl --system applies this legacy file after sysctl.d.
    if [[ -f /etc/sysctl.conf ]] && value="$(last_ip_forward_assignment /etc/sysctl.conf "$family")"; then
        effective_value="$value"
        effective_source="/etc/sysctl.conf"
    fi

    if [[ -n "$effective_value" && "$effective_value" != "1" ]]; then
        warn "${FORWARD_KEYS[$family]} 的最终持久化值为 ${effective_value}（来自 ${effective_source}）"
        return 0
    fi
    return 1
}

warn_ipv6_ra_forwarding() {
    if [[ "$1" == ip6 && -n "$(ip -6 route show default proto ra 2>/dev/null)" ]]; then
        warn "当前 IPv6 默认路由来自 RA。开启转发后，上联网卡需要 accept_ra=2 才能继续接收该路由。"
    fi
}

plan_ip_forward_for_add() {
    local family="${1:-ip}" cur ans key
    key="${FORWARD_KEYS[$family]}"
    IPF_WANT_ENABLE=0
    IPF_WANT_PERSIST=0
    cur="$(get_ip_forward_value "$family")" || { err "无法读取 $key，已取消添加规则。"; return 1; }
    IPF_ORIGINAL_RUNTIME="$cur"
    if [[ "$cur" != "1" ]]; then
        warn "检测到 $key != 1"
        warn_ipv6_ra_forwarding "$family"
        read_or_cancel ans "提交规则后是否开启 $key？[Y/n]: " || return 1
        answer_yes_default_yes "$ans" || { warn "已取消添加规则。"; return 1; }
        IPF_WANT_ENABLE=1
    fi
    if ! ip_forward_is_persisted "$family"; then
        read_or_cancel ans "是否持久化到 ${FORWARD_FILES[$family]}？[y/N]: " || return 1
        answer_yes_default_no "$ans" && IPF_WANT_PERSIST=1
    fi
    return 0
}

plan_nftables_enable() {
    local ans
    NFT_WANT_ENABLE=0
    if nftables_is_enabled_at_boot || ! nftables_service_uses_main_conf || ! main_conf_has_include; then
        return 0
    fi
    read_or_cancel ans "是否将 nftables.service 设为开机自启？[y/N]: " || return 1
    if answer_yes_default_no "$ans"; then NFT_WANT_ENABLE=1; fi
}

enable_nftables_at_boot() {
    if ! nftables_service_uses_main_conf || ! main_conf_has_include || ! secure_root_file "$MAIN_CONF"; then
        err "请先确认 nftables.service 从 ${MAIN_CONF} 加载托管配置。"
        return 1
    fi
    run_nft -c -f "$MAIN_CONF" || return 1
    systemctl enable nftables || return 1
    if ! nftables_is_enabled_at_boot; then
        err "未能验证 nftables.service 已永久启用。"
        return 1
    fi
    info "nftables.service 已设为开机自启。"
}

apply_nftables_enable_plan() {
    (( NFT_WANT_ENABLE )) || return 0
    enable_nftables_at_boot
}

apply_ip_forward_plan() {
    local family="${1:-ip}"
    if (( IPF_WANT_ENABLE )); then
        enable_ip_forward_runtime "$family" || {
            restore_ip_forward_runtime_after_failure "$family"
            return 1
        }
    fi
    if (( IPF_WANT_PERSIST )); then
        enable_ip_forward_persist "$family" || {
            restore_ip_forward_runtime_after_failure "$family"
            return 1
        }
    fi
    return 0
}

restore_ip_forward_runtime_after_failure() {
    local family="${1:-ip}" current key
    key="${FORWARD_KEYS[$family]}"
    current="$(get_ip_forward_value "$family")" || {
        err "无法读取 ${key}，不能确认是否需要恢复。"
        return 1
    }
    [[ "$current" == "$IPF_ORIGINAL_RUNTIME" ]] && return 0
    sysctl -w "${key}=${IPF_ORIGINAL_RUNTIME}" >/dev/null 2>&1 || {
        err "无法恢复 ${key}=${IPF_ORIGINAL_RUNTIME}，请立即人工检查。"
        return 1
    }
    warn "已恢复操作前的 ${key}=${IPF_ORIGINAL_RUNTIME}"
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
        info "${MAIN_CONF} 已包含托管配置。"
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
            info "${MAIN_CONF} 已包含托管配置。"
            return 0
        fi
        warn "${MAIN_CONF} 缺少托管 include。"
        read_or_cancel ans "是否追加 include？[y/N]: " || return 0
        answer_yes_default_no "$ans" || return 0
    else
        warn "${MAIN_CONF} 不存在。"
        read_or_cancel ans "是否创建 ${MAIN_CONF} 并加入 include？[Y/n]: " || return 0
        answer_yes_default_yes "$ans" || return 0
    fi
    add_include_to_main_conf
}

# ---------- diagnostics & help ----------
show_forward_filter_hints() {
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

脚本: ${SCRIPT_DISPLAY_NAME}.sh

使用说明：
1. 模式固定为 DNAT + MASQUERADE（后端看不到真实客户端 IP）。
2. 目标可填 IPv4:端口 或 [IPv6]:端口。监听地址和来源 CIDR 使用目标的地址族，可限制入口网卡。
   云厂商若公网 IP 未挂在网卡上，请选内网 IP（包到达本机时的目的地址）。
   若本机端口已被服务占用，会警告并请你确认。
   输入目标后会做一次 TCP 连通探测；不通可确认后仍继续。
3. 删除时按列表序号；可用空格或逗号多选（如 1 3 5 或 1,3,5）；
   也支持 n+（第 n 与 n+1 条）、n-（第 n 与 n-1 条）；越界邻居会跳过并警告；输入 all 可清空。
4. 菜单 4 可恢复托管运行表并复查内核转发和开机加载；开机自启需单独确认（默认否）。
   --check 只做运行态/持久化校验，不对目标做网络探测。
5. 添加规则时可填写名称，菜单 2 和 3 会显示名称。菜单 5 可按序号补填、修改或清除名称。

安全边界：
1. 按地址族管理 table ip ${TABLE_NAME} 和 table ip6 ${TABLE_NAME}。
2. 不自动改 firewalld / ufw / iptables。
3. 持久化依赖 ${MAIN_CONF} 包含: include "/etc/nftables.d/*.conf"

常用命令：
  # 本脚本
  sudo ./${SCRIPT_DISPLAY_NAME}.sh --check
  sudo ./${SCRIPT_DISPLAY_NAME}.sh --check-strict

  # 规则查看 / 校验
  nft list table ${TABLE_FAMILY} ${TABLE_NAME}
  nft -nn list table ip6 ${TABLE_NAME}
  grep -E 'RULE:|RULE-MASQ:' ${CONF_FILE}
  nft -c -f ${CONF_FILE}

  # 转发与持久化
  sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
  cat ${SYSCTL_FILE} ${FORWARD_FILES[ip6]}
  grep -nE 'include.*/etc/nftables\\.d' ${MAIN_CONF}

  # nftables 开机加载（确认无 firewalld/ufw 抢管后再启用）
  systemctl enable nftables
  systemctl status nftables
  nft list ruleset

  # 排障
  ip -4 addr show scope global
  ip -6 addr show scope global
  ss -lntup
  systemctl is-active firewalld 2>/dev/null; ufw status 2>/dev/null

EOF
}

print_help() {
    cat <<EOF
${SCRIPT_DISPLAY_NAME} v${SCRIPT_VERSION}

用法:
    sudo ./${SCRIPT_DISPLAY_NAME}.sh
    ./${SCRIPT_DISPLAY_NAME}.sh --help
    ./${SCRIPT_DISPLAY_NAME}.sh --version
    ./${SCRIPT_DISPLAY_NAME}.sh --check
    ./${SCRIPT_DISPLAY_NAME}.sh --check-strict

参数:
    -h, --help       显示帮助并退出
    -v, --version    显示版本并退出
    -c, --check      检查当前运行态；持久化问题仅警告（不做目标网络探测）
    --check-strict   严格检查；持久化问题也返回失败

说明:
    - 目标支持 IPv4:端口 或 [IPv6]:端口，例如 [2001:db8::2]:443
    - 默认进入交互菜单模式
    - 模式固定为 DNAT + MASQUERADE；静态 SNAT 请使用 nft-portfwd-snat.sh
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
    ${FORWARD_FILES[ip6]}
        按地址族在确认持久化时写入对应的转发开关
    ${RUNTIME_DIR}/
    ${LOCK_FILE}
        运行时互斥锁（通常位于 /run，重启后消失）
    ${TXN_CANDIDATE}
    ${TXN_ROLLBACK}
    ${TXN_MARKER}
        提交事务中间文件；正常成功后清理，异常时可能残留供恢复/排查
    运行态 table ip ${TABLE_NAME} / table ip6 ${TABLE_NAME}
        以及对应的 IPv4 / IPv6 内核转发设置

不会自动改动: firewalld / ufw / iptables、BBR；
添加规则时可选择启用 nftables.service（默认否）。
也不会写操作日志或无限累积 portfwd.conf 备份。
EOF
}

run_health_check() {
    local mode="${1:-check}" status=0 persistence_status=0
    local ipf config_ok=0
    local -A checked_tables=()

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
        info "[持久化] ${MAIN_CONF} 已包含托管配置。"
    else
        warn "[持久化] ${MAIN_CONF} 缺少托管 include。"
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

    local family key
    local -a selected
    while read -r family; do
        checked_tables[$family]=1
        key="${FORWARD_KEYS[$family]}"
        family_rules "$family" selected
        if (( config_ok && ${#selected[@]} )); then
            if ipf="$(get_ip_forward_value "$family")" && [[ "$ipf" == 1 ]]; then
                info "$key = 1"
            else
                err "$key = ${ipf:-unknown}"
                status=1
            fi
            if ! ip_forward_is_persisted "$family" || ip_forward_has_competing_persistence "$family"; then
                warn "[持久化] $key 缺少持久化配置或最终值不是 1。"
                persistence_status=1
            else
                info "[持久化] $key = 1"
            fi
        fi

        if ! runtime_table_is_owned "$family"; then
            err "运行中缺少 table $family $TABLE_NAME 或其所有权哨兵。"
            status=1
        elif (( config_ok )) && runtime_table_matches_loaded_config "$family"; then
            info "table $family $TABLE_NAME 的运行态链和规则表达式与配置一致。"
        else
            err "table $family $TABLE_NAME 的运行态链或规则表达式与配置不一致。"
            status=1
        fi
    done < <(table_families)
    if (( config_ok )); then
        for family in ip ip6; do
            if [[ -z "${checked_tables[$family]:-}" ]] && runtime_table_is_owned "$family"; then
                err "运行中存在配置未声明的托管表 $family $TABLE_NAME。"
                status=1
            fi
        done
    fi

    if command -v systemctl >/dev/null 2>&1; then
        if nftables_is_enabled_at_boot; then
            info "[持久化] nftables.service 已设为开机自启。"
        else
            warn_nftables_service_not_enabled "[持久化] "
            persistence_status=1
        fi
        if ! nftables_service_uses_main_conf; then
            warn "[持久化] nftables.service 的启动命令未确认使用 ${MAIN_CONF}。请查看 systemctl cat nftables。"
            persistence_status=1
        fi
        systemctl is-active --quiet nftables 2>/dev/null \
            || info "nftables.service 当前未运行，运行表由本脚本直接维护。"
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
            echo "${SCRIPT_DISPLAY_NAME} v${SCRIPT_VERSION}"
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
print_rule_summary() {
    local number="$1" rule="$2"
    local listen_ip lport proto dip dport iif source_cidr rule_name
    IFS='|' read -r listen_ip lport proto dip dport iif source_cidr rule_name <<< "$rule"
    printf '  %d. 「%s」 %s %s -> %s (iif=%s, source=%s)\n' \
        "$number" "${rule_name:-未命名}" "$proto" \
        "$(format_endpoint "$listen_ip" "$lport")" "$(format_endpoint "$dip" "$dport")" "${iif:-*}" "$source_cidr"
}

list_rules() {
    load_rules_from_conf || {
        err "配置无效，拒绝显示不完整的规则列表。"
        return 1
    }

    if [[ ${#RULES[@]} -eq 0 ]]; then
        info "当前没有规则。"
        return 0
    fi

    local i=1 r
    echo
    for r in "${RULES[@]+"${RULES[@]}"}"; do
        print_rule_summary "$i" "$r"
        ((i++))
    done
    echo
}

prompt_listen_ip() {
    local __var_name="$1" family="$2" label=IPv4 flag=-4
    if [[ "$family" == ip6 ]]; then label=IPv6; flag=-6; fi
    local value ans _idx _if _fam cidr _rest choice default_idx=0 choices_hint=""
    local -a local_ips=()
    local has_private=0

    while read -r _idx _if _fam cidr _rest; do
        value="${cidr%/*}"
        [[ ! "$_rest" =~ (tentative|dadfailed) ]] || continue
        value="$(normalize_ip "$family" "$value")" || continue
        local_ips+=("$value")
        [[ "$family" == ip ]] && ipv4_is_rfc1918 "$value" && has_private=1
    done < <(ip -o "$flag" addr show scope global 2>/dev/null || true)

    # 默认优先选第一个内网地址（云 1:1 NAT 常见）；否则选列表第一项。
    if [[ ${#local_ips[@]} -gt 0 ]]; then
        default_idx=1
        _idx=1
        for value in "${local_ips[@]}"; do
            if (( has_private )) && ipv4_is_rfc1918 "$value"; then
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
        info "检测到本机全局 ${label}（请选包到达本机时的目的地址）："
        _idx=1
        for value in "${local_ips[@]}"; do
            printf "  %d) %s\n" "$_idx" "$value"
            ((_idx++))
        done
    else
        warn "未检测到本机全局 ${label}。"
    fi
    if (( has_private )); then
        warn "若公网 IP 未出现在上方列表，云厂商多为 1:1 NAT：应选内网 IP，不要填公网。"
    fi

    while true; do
        if (( default_idx > 0 )); then
            read_or_cancel choice "请选择前端监听 ${label} [${choices_hint}，默认 ${default_idx}]: " || return 1
            choice="${choice:-$default_idx}"
        else
            read_or_cancel choice "请输入前端监听 ${label}（必须明确指定）: " || return 1
        fi
        value="$choice"
        if [[ "$choice" =~ ^[0-9]{1,5}$ && ${#local_ips[@]} -gt 0 ]]; then
            _idx=$(( 10#$choice - 1 ))
            if (( _idx >= 0 && _idx < ${#local_ips[@]} )); then
                value="${local_ips[$_idx]}"
            else
                err "请输入 ${choices_hint}，或直接输入 ${label} 地址。"
                continue
            fi
        fi
        value="$(normalize_ip "$family" "$value")" || {
            if (( default_idx > 0 )); then
                err "请输入 ${choices_hint}，或直接输入合法 ${label} 地址。"
            else
                err "监听 ${label} 非法或属于特殊地址段。"
            fi
            continue
        }
        if ! ip_is_local "$family" "$value"; then
            warn "${value} 当前未配置在本机接口上。"
            if [[ "$family" == ip6 ]]; then
                warn "请确认此 IPv6 地址会被路由到本机。"
            elif (( has_private )); then
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
    local __var_name="$1" family="$2" value default=0.0.0.0/0
    [[ "$family" == ip6 ]] && default=::/0
    while true; do
        read_or_cancel value "允许的来源 CIDR [默认 $default]: " || return 1
        value="$(normalize_ip "$family" "${value:-$default}" cidr)" || {
            err "请输入同一地址族的网络前缀，主机位必须为零。"
            continue
        }
        printf -v "$__var_name" '%s' "$value"
        return 0
    done
}

prompt_rule_name() {
    local __var_name="$1" prompt="$2" input
    while true; do
        read_or_cancel input "$prompt" || return 1
        if validate_rule_name "$input"; then
            printf -v "$__var_name" '%s' "$input"
            return 0
        fi
        err "名称不能包含竖线 | 或控制字符。"
    done
}

rename_rule_interactive() {
    local choice count index old_rule old_name new_name candidate
    local listen_ip lport proto dip dport iif source_cidr

    list_rules || return 1
    count="${#RULES[@]}"
    (( count > 0 )) || return 0

    while true; do
        read_or_cancel choice "请输入规则序号（0=返回）: " || return 0
        [[ "$choice" == "0" ]] && return 0
        if [[ "$choice" =~ ^[1-9][0-9]*$ && ${#choice} -le ${#count} ]] && (( choice <= count )); then
            break
        fi
        err "请输入 1 至 ${count} 的规则序号。"
    done

    index=$((choice - 1))
    old_rule="${RULES[index]}"
    IFS='|' read -r listen_ip lport proto dip dport iif source_cidr old_name <<< "$old_rule"
    info "第 ${choice} 条规则当前名称为「${old_name:-未命名}」。"
    prompt_rule_name new_name "输入新名称（回车清除）: " || return 0
    [[ "$new_name" != "$old_name" ]] || return 0

    ensure_dirs
    if [[ -e "$TXN_MARKER" || -L "$TXN_MARKER" ]]; then
        err "存在未恢复的规则事务，请重新启动脚本执行恢复。"
        return 1
    fi
    candidate="$(mktemp "${CONF_DIR}/.portfwd-name.XXXXXX")" || return 1

    # 名称仅用于托管注释，修改时只需原子替换磁盘配置。
    RULES[index]="${listen_ip}|${lport}|${proto}|${dip}|${dport}|${iif}|${source_cidr}${new_name:+|$new_name}"
    if ! cp -p "$CONF_FILE" "$candidate" || ! render_conf_file "$candidate" \
        || ! mv -f "$candidate" "$CONF_FILE"; then
        RULES[index]="$old_rule"
        rm -f "$candidate" || true
        err "保存规则名称失败。"
        return 1
    fi
    info "第 ${choice} 条规则已保存为「${new_name:-未命名}」。"
}

show_runtime() {
    local family
    while read -r family; do
        nft list table "$family" "$TABLE_NAME" || warn "无法读取 table $family $TABLE_NAME"
    done < <(table_families)
}

add_rule_interactive() {
    load_rules_from_conf || return 1
    assert_loaded_config_safe || return 1

    local listen_ip lport dip dport iif source_cidr rule_name ans target family _path _iface
    local -a old_rules=()
    local -a protos_requested=() protos_to_add=()

    prompt_proto_choice protos_requested || return 0

    while true; do
        read_or_cancel target "请输入目标地址 (IPv4:端口 或 [IPv6]:端口): " || return 0
        parse_target "$target" dip dport && break
        err "目标格式错误，例如 10.0.0.2:8080 或 [2001:db8::2]:8080。"
    done
    family="$(address_family "$dip")"

    confirm_continue_despite_unreachable_dest "$dip" "$dport" || return 0

    while true; do
        read_or_cancel lport "本机监听端口 [默认 ${dport}]: " || return 0
        lport="${lport:-$dport}"
        validate_port "$lport" && break
        err "端口无效。"
    done

    confirm_continue_despite_local_port_use "$lport" "$family" || return 0

    prompt_listen_ip listen_ip "$family" || return 0
    prompt_source_cidr source_cidr "$family" || return 0

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
            warn "监听范围重叠，跳过：$(format_endpoint "$listen_ip" "$lport")/${p} (iif=${iif})"
        else
            protos_to_add+=("$p")
        fi
    done
    if [[ ${#protos_to_add[@]} -eq 0 ]]; then
        warn "没有可添加的新规则。"
        return 0
    fi

    prompt_rule_name rule_name "规则名称（可选，例如 家里 NAS）: " || return 0
    echo
    info "将添加规则（DNAT + MASQUERADE）:"
    info "名称为「${rule_name:-未命名}」。"
    for p in "${protos_to_add[@]}"; do
        echo "  ${p} $(format_endpoint "$listen_ip" "$lport") -> $(format_endpoint "$dip" "$dport") (iif=${iif}, source=${source_cidr})"
    done

    read_or_cancel ans "确认继续? [y/N]: " || return 0
    answer_yes_default_no "$ans" || {
        warn "已取消。"
        return 0
    }

    plan_ip_forward_for_add "$family" || return 0
    plan_nftables_enable || return 0
    old_rules=("${RULES[@]+"${RULES[@]}"}")
    for p in "${protos_to_add[@]}"; do
        RULES+=("${listen_ip}|${lport}|${p}|${dip}|${dport}|${iif}|${source_cidr}${rule_name:+|$rule_name}")
    done

    if ! commit_rules; then
        RULES=("${old_rules[@]+"${old_rules[@]}"}")
        err "规则提交失败。"
        return 1
    fi
    if ! apply_ip_forward_plan "$family"; then
        err "${FORWARD_KEYS[$family]} 设置失败，正在撤销刚提交的规则。"
        RULES=("${old_rules[@]+"${old_rules[@]}"}")
        commit_rules || die "撤销规则失败，请立即检查 ${CONF_FILE} 与运行表。"
        return 1
    fi
    if ! apply_nftables_enable_plan; then
        err "规则已提交，但设置开机加载失败；请用菜单 4 检查。"
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
        print_rule_summary "$((idx + 1))" "${RULES[$idx]}"
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
        || warn "规则已清空；为避免影响其他路由/VPN/容器，保留系统当前的 IP 转发设置。"
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
    warn "为避免影响其他路由/VPN/容器，保留系统当前的 IP 转发设置。"
}

init_empty_conf_if_needed() {
    local ipv4_addrs ipv6_addrs
    ensure_dirs
    if [[ ! -f "$CONF_FILE" ]]; then
        RULES=()
        CONFIG_TABLES=()
        if ipv4_addrs="$(ip -o -4 addr show scope global)" && [[ -z "$ipv4_addrs" ]] \
            && ipv6_addrs="$(ip -o -6 addr show scope global)" && [[ -n "$ipv6_addrs" ]]; then
            CONFIG_TABLES[ip6]=1
        fi
        CONFIG_LOAD_ERRORS=0
        commit_rules || return 1
        info "已初始化空配置: $CONF_FILE"
    fi
    return 0
}

# 启动时用较轻的检查发现基础环境和缺失的运行表。
# 逐条规则比对由菜单 4 和健康检查执行。
environment_needs_attention() {
    local family
    local -a selected
    [[ -f "$CONF_FILE" ]] && main_conf_has_include || return 0
    load_rules_from_conf >/dev/null 2>&1 || return 0
    for family in ip ip6; do
        family_rules "$family" selected
        (( ${#selected[@]} )) || continue
        [[ "$(get_ip_forward_value "$family")" == 1 ]] || return 0
        runtime_table_exists "$family" || return 0
    done
    return 1
}

maybe_first_run_setup() {
    local ans

    if environment_needs_attention; then
        echo
        info "检测到配置、运行表或转发环境有待检查。"
        read_or_cancel ans "是否现在检查并修复？[Y/n]: " || return 0
        if answer_yes_default_yes "$ans"; then
            repair_environment_and_check || warn "仍有未解决的项目，可稍后使用菜单 4。"
        else
            warn "已跳过，可稍后使用菜单 4。"
        fi
    fi
}

setup_environment_interactive() {
    local family key cur ans status=0
    local -a selected

    if [[ -e "$TXN_MARKER" || -L "$TXN_MARKER" ]]; then
        err "存在未恢复的规则事务，请重新启动脚本执行恢复。"
        return 1
    fi
    info "检查托管配置、内核转发、运行表和开机加载。"
    init_empty_conf_if_needed || return 1
    load_rules_from_conf || return 1
    check_include_hint || status=1

    for family in ip ip6; do
        family_rules "$family" selected
        (( ${#selected[@]} )) || continue
        key="${FORWARD_KEYS[$family]}"
        if ! cur="$(get_ip_forward_value "$family")"; then
            err "无法读取 $key。"
            status=1
            continue
        fi
        if [[ "$cur" != 1 ]]; then
            warn_ipv6_ra_forwarding "$family"
            read_or_cancel ans "是否现在开启 $key？[Y/n]: " || return "$status"
            answer_yes_default_yes "$ans" || continue
            if ! enable_ip_forward_runtime "$family"; then
                status=1
                continue
            fi
        fi
        if ! ip_forward_is_persisted "$family"; then
            read_or_cancel ans "是否持久化到 ${FORWARD_FILES[$family]}？[y/N]: " || return "$status"
            if answer_yes_default_no "$ans"; then
                enable_ip_forward_persist "$family" || status=1
            fi
        fi
    done

    repair_runtime_interactive || return 1
    if plan_nftables_enable; then
        apply_nftables_enable_plan || status=1
    fi
    return "$status"
}

repair_environment_and_check() {
    local status=0
    setup_environment_interactive || status=1
    run_health_check strict || status=1
    return "$status"
}

check_and_fix_environment_interactive() {
    local ans status=0
    repair_environment_and_check || status=1
    show_forward_filter_hints

    read_or_cancel ans "是否查看使用说明？[y/N]: " || return "$status"
    if answer_yes_default_no "$ans"; then
        show_tips
    fi
    return "$status"
}

view_rules_interactive() {
    echo
    list_rules || return 1
    if (( ${#RULES[@]} > 0 )); then
        if ! repair_runtime_interactive; then
            warn "运行态问题仍待处理，可用菜单 4 核对。"
        elif plan_nftables_enable; then
            apply_nftables_enable_plan || warn "设置开机加载失败，可用菜单 4 核对。"
        fi
    fi
    local ans
    read_or_cancel ans "显示原始 nft 规则？[y/N]: " || return 0
    if answer_yes_default_no "$ans"; then
        show_runtime
    fi
}

add_rule_menu_action() {
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
  nft list table ip ${TABLE_NAME}
  nft list table ip6 ${TABLE_NAME}

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
 ${SCRIPT_DISPLAY_NAME}  |  IPv4=$(get_ip_forward_display ip)  IPv6=$(get_ip_forward_display ip6)  |  规则 ${rule_count} 条
========================================
1) 添加转发
2) 查看规则
3) 删除规则
4) 检查并修复环境
5) 修改规则名称
0) 退出
========================================
EOF
        read_or_cancel choice "请选择: " || exit 0

        case "${choice:-}" in
            1) run_menu_action add_rule_menu_action ;;
            2) run_menu_action view_rules_interactive ;;
            3) run_menu_action delete_rule_interactive ;;
            4) run_menu_action check_and_fix_environment_interactive ;;
            5) run_menu_action rename_rule_interactive ;;
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
