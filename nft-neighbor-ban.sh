#!/bin/bash
set -euo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
umask 027

#
# nftables 同网段邻居一键封禁（nft-neighbor-ban）
#
# - 管理独立表 table inet neighbor_ban
# - 仅过滤本机 INPUT（不碰 FORWARD / NAT）
# - 默认放行本机 IP + 默认网关，再 drop 同 /24 其它源地址
# - 持久化到 /etc/nftables.d/neighbor-ban.conf
#

TABLE_FAMILY="inet"
TABLE_NAME="neighbor_ban"
CHAIN_INPUT="input"
OWNER_CHAIN="nft_neighbor_ban_owner"
SCRIPT_DISPLAY_NAME="nft-neighbor-ban"
SCRIPT_VERSION="1.0.2"

CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/neighbor-ban.conf"
MAIN_CONF="/etc/nftables.conf"
RUNTIME_DIR="/run/nft-neighbor-ban"
LOCK_FILE="${RUNTIME_DIR}/lock"
TXN_CANDIDATE="${CONF_DIR}/.neighbor-ban.conf.new"
TXN_ROLLBACK="${CONF_DIR}/.neighbor-ban.rollback.nft"
CONF_MAGIC="# MANAGED-BY: nft-neighbor-ban v1"

INCLUDE_GLOB="/etc/nftables.d/*.conf"
INCLUDE_LINE="include \"${INCLUDE_GLOB}\""
INCLUDE_CHECK_REGEX="^[[:space:]]*include[[:space:]]+[\"']?/etc/nftables\\.d/\\*\\.conf[\"']?([[:space:]]*;)?[[:space:]]*$"

readonly TABLE_FAMILY TABLE_NAME CHAIN_INPUT OWNER_CHAIN SCRIPT_DISPLAY_NAME SCRIPT_VERSION
readonly CONF_DIR CONF_FILE MAIN_CONF RUNTIME_DIR LOCK_FILE TXN_CANDIDATE TXN_ROLLBACK CONF_MAGIC
readonly INCLUDE_GLOB INCLUDE_LINE INCLUDE_CHECK_REGEX

IFACE=""
MY_IP=""
GATEWAY=""
SUBNET=""
declare -a EXTRA_ALLOW=()
CLI_ACTION=""
DRY_RUN=0
YES=0
LOCK_FD=""
# enable 已删旧表、尚未成功提交时置 1；EXIT trap 据此恢复 rollback。
APPLY_NEED_ROLLBACK=0
# 1=nft 支持 destroy table（用于 conf 自替换）；探测前为 -1。
NFT_HAS_DESTROY=-1

# ---------- logging ----------
info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }

die() {
    err "$*"
    exit 1
}

print_help() {
    cat <<EOF
${SCRIPT_DISPLAY_NAME} v${SCRIPT_VERSION}

一键封禁同网卡 /24（D 段）邻居对本地主机的访问；放行本机 IP 与默认网关。

Usage:
  sudo ./${SCRIPT_DISPLAY_NAME}.sh                 # 交互菜单
  sudo ./${SCRIPT_DISPLAY_NAME}.sh enable          # 启用/刷新规则
  sudo ./${SCRIPT_DISPLAY_NAME}.sh disable         # 关闭并删除托管表/配置
  sudo ./${SCRIPT_DISPLAY_NAME}.sh status          # 查看状态
  sudo ./${SCRIPT_DISPLAY_NAME}.sh --check         # 健康检查
  ./${SCRIPT_DISPLAY_NAME}.sh --help
  ./${SCRIPT_DISPLAY_NAME}.sh --version

Options:
  --iface <name>          指定网卡（默认取 default route 出口）
  --ip <x.x.x.x>          指定本机 IP（默认取该网卡上的主 IPv4）
  --gateway <x.x.x.x>     指定网关（默认取 default route）
  --allow <x.x.x.x>       额外放行 IP（可重复）
  --dry-run               只打印将写入的 nft 配置，不改动系统
  -y, --yes               非交互确认（若当前 SSH 客户端同 /24 且未 --allow 则拒绝）
  -h, --help
  -v, --version
  -c, --check

Notes:
  - 只管理 table ${TABLE_FAMILY} ${TABLE_NAME}，不影响其它防火墙表。
  - 不会自动 enable/start nftables.service（避免清空其它防火墙）。
  - 重启持久化依赖 ${MAIN_CONF} include ${INCLUDE_GLOB}。
EOF
}

answer_yes_default_yes() {
    local ans="${1:-}"
    [[ -z "$ans" || "$ans" =~ ^[Yy]$ ]]
}

main_conf_has_include() {
    [[ -f "$MAIN_CONF" ]] || return 1
    grep -Eiq "$INCLUDE_CHECK_REGEX" "$MAIN_CONF" 2>/dev/null
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
    local -a required=(nft ip flock grep sed mktemp install mv rm chmod awk sort)
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少必需命令：${cmd}"
    done
}

# ---------- validators / helpers ----------
validate_ipv4_basic() {
    local ip="${1:-}"
    [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
    [[ ! "$ip" =~ (^|[.])0[0-9] ]] || return 1

    local IFS='.'
    local o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$ip"
    for o in "$o1" "$o2" "$o3" "$o4"; do
        (( o >= 0 && o <= 255 )) || return 1
    done
    return 0
}

# 本机 IP / --allow：拒绝 loopback、link-local、组播等。
validate_ipv4() {
    local ip="${1:-}"
    local IFS='.'
    local o1 o2 o3 o4

    validate_ipv4_basic "$ip" || return 1
    read -r o1 o2 o3 o4 <<< "$ip"
    (( o1 != 0 )) || return 1
    (( o1 != 127 )) || return 1
    ! (( o1 == 169 && o2 == 254 )) || return 1
    (( o1 < 224 )) || return 1
    return 0
}

# 网关：允许 link-local（169.254/16），仍拒绝 loopback / 组播 / 0.0.0.0/8。
validate_gateway_ipv4() {
    local ip="${1:-}"
    local IFS='.'
    local o1 o2 o3 o4

    validate_ipv4_basic "$ip" || return 1
    read -r o1 o2 o3 o4 <<< "$ip"
    (( o1 != 0 )) || return 1
    (( o1 != 127 )) || return 1
    (( o1 < 224 )) || return 1
    return 0
}

gateway_needs_accept() {
    same_slash24 "$GATEWAY" "$MY_IP"
}

validate_ifname() {
    local name="${1:-}"
    [[ "$name" =~ ^[A-Za-z0-9_.:-]{1,15}$ ]]
}

ipv4_to_subnet24() {
    local ip="${1:-}"
    validate_ipv4 "$ip" || return 1
    local IFS='.'
    local o1 o2 o3 o4
    read -r o1 o2 o3 o4 <<< "$ip"
    printf '%s.%s.%s.0/24\n' "$o1" "$o2" "$o3"
}

same_slash24() {
    local a b
    a="$(ipv4_to_subnet24 "$1")" || return 1
    b="$(ipv4_to_subnet24 "$2")" || return 1
    [[ "$a" == "$b" ]]
}

# 规范化额外放行列表：去重、排序；剔除本机/网关（它们会单独写规则）。
# 失败返回 1（不直接 exit），便于单测。
normalize_extra_allow() {
    local -a cleaned=()
    local ip seen
    declare -A seen_map=()

    for ip in "${EXTRA_ALLOW[@]+"${EXTRA_ALLOW[@]}"}"; do
        if ! validate_ipv4 "$ip"; then
            err "无效的 --allow IP：${ip}"
            return 1
        fi
        [[ "$ip" == "$MY_IP" || "$ip" == "$GATEWAY" ]] && continue
        if ! same_slash24 "$ip" "$MY_IP"; then
            err "--allow ${ip} 不在目标网段 ${SUBNET} 内"
            return 1
        fi
        seen="${seen_map[$ip]:-}"
        [[ -n "$seen" ]] && continue
        seen_map["$ip"]=1
        cleaned+=("$ip")
    done

    if ((${#cleaned[@]} > 0)); then
        mapfile -t EXTRA_ALLOW < <(printf '%s\n' "${cleaned[@]}" | sort -u)
    else
        EXTRA_ALLOW=()
    fi
}

# 通过 nameref 写回默认路由的 gateway / iface；不直接改全局，便于与 CLI 覆盖合并。
detect_default_route() {
    local -n __gw_ref="$1"
    local -n __iface_ref="$2"
    local line via dev

    line="$(ip -4 route show default 2>/dev/null | head -n1 || true)"
    [[ -n "$line" ]] || return 1

    via=""
    dev=""
    # shellcheck disable=SC2086
    set -- $line
    while (($# > 0)); do
        case "$1" in
            via)
                via="${2:-}"
                shift 2 || true
                ;;
            dev)
                dev="${2:-}"
                shift 2 || true
                ;;
            *)
                shift
                ;;
        esac
    done

    [[ -n "$via" && -n "$dev" ]] || return 1
    validate_gateway_ipv4 "$via" || return 1
    validate_ifname "$dev" || return 1
    __gw_ref="$via"
    __iface_ref="$dev"
}

detect_iface_primary_ipv4() {
    local iface="$1"
    local ip
    ip="$(ip -4 -o addr show dev "$iface" scope global 2>/dev/null \
        | awk '{print $4}' | head -n1 | cut -d/ -f1 || true)"
    [[ -n "$ip" ]] || return 1
    validate_ipv4 "$ip" || return 1
    MY_IP="$ip"
}

resolve_targets() {
    local auto_gw="" auto_iface=""

    if [[ -z "$IFACE" || -z "$GATEWAY" ]]; then
        detect_default_route auto_gw auto_iface \
            || die "无法自动识别默认路由；请用 --iface / --gateway 指定。"
        [[ -n "$IFACE" ]] || IFACE="$auto_iface"
        [[ -n "$GATEWAY" ]] || GATEWAY="$auto_gw"
    fi
    validate_ifname "$IFACE" || die "无效网卡名：${IFACE}"
    validate_gateway_ipv4 "$GATEWAY" || die "无效网关：${GATEWAY}"

    if [[ -z "$MY_IP" ]]; then
        detect_iface_primary_ipv4 "$IFACE" || die "网卡 ${IFACE} 上未找到全局 IPv4。"
    fi
    validate_ipv4 "$MY_IP" || die "无效本机 IP：${MY_IP}"

    if ! ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | grep -Fxq "$MY_IP"; then
        die "本机 IP ${MY_IP} 不在网卡 ${IFACE} 上。"
    fi

    SUBNET="$(ipv4_to_subnet24 "$MY_IP")" || die "无法计算 /24 网段。"
    # 网关不必同 /24：drop 只匹配 SUBNET，段外网关本就不会被丢。

    normalize_extra_allow || die "额外放行列表无效。"
}

# ---------- lock / dirs ----------
ensure_secure_dir() {
    local dir="$1" mode="$2"
    mkdir -p "$dir" || return 1
    [[ ! -L "$dir" ]] || die "拒绝使用符号链接目录：${dir}"
    chmod "$mode" "$dir" || return 1
}

acquire_lock() {
    ensure_secure_dir "$RUNTIME_DIR" 0700
    [[ ! -L "$LOCK_FILE" ]] || die "拒绝使用符号链接锁文件：${LOCK_FILE}"
    if [[ ! -e "$LOCK_FILE" ]]; then
        install -m 0600 -o root -g root /dev/null "$LOCK_FILE" \
            || die "无法创建锁文件：${LOCK_FILE}"
    fi
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

# 中断/异常退出时：若 enable 已删旧表未提交，尽量恢复 rollback。
cleanup_on_exit() {
    if (( APPLY_NEED_ROLLBACK )) && [[ -f "$TXN_ROLLBACK" ]]; then
        warn "检测到未完成的 enable；正在恢复启用前运行态…"
        if runtime_table_exists; then
            nft delete table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 || true
        fi
        if restore_runtime_from_rollback "$TXN_ROLLBACK"; then
            warn "已恢复启用前运行态。"
            rm -f "$TXN_ROLLBACK" "$TXN_CANDIDATE" || true
        else
            err "中断恢复失败；请人工执行: nft -f ${TXN_ROLLBACK}"
        fi
        APPLY_NEED_ROLLBACK=0
    fi
    release_lock
}

ensure_dirs() {
    ensure_secure_dir "$CONF_DIR" 0755
    [[ ! -L "$CONF_FILE" ]] || die "拒绝写入符号链接配置：${CONF_FILE}"
}

# ---------- nft render / apply ----------
runtime_table_exists() {
    nft list table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1
}

runtime_table_is_owned() {
    nft list chain "$TABLE_FAMILY" "$TABLE_NAME" "$OWNER_CHAIN" >/dev/null 2>&1
}

check_runtime_ownership() {
    runtime_table_exists || return 0
    runtime_table_is_owned && return 0
    err "运行中已有未标记的 table ${TABLE_FAMILY} ${TABLE_NAME}；拒绝接管。"
    return 1
}

# nftables >= 1.0.7 支持 destroy（表不存在也不报错），适合 conf 自替换。
nft_supports_destroy() {
    local probe
    if (( NFT_HAS_DESTROY >= 0 )); then
        (( NFT_HAS_DESTROY == 1 ))
        return
    fi
    probe="$(mktemp)" || {
        NFT_HAS_DESTROY=0
        return 1
    }
    printf 'destroy table inet __nft_neighbor_ban_probe\n' > "$probe"
    if nft -c -f "$probe" >/dev/null 2>&1; then
        NFT_HAS_DESTROY=1
    else
        NFT_HAS_DESTROY=0
    fi
    rm -f "$probe"
    (( NFT_HAS_DESTROY == 1 ))
}

write_table_replace_prefix() {
    if nft_supports_destroy; then
        printf 'destroy table %s %s\n\n' "$TABLE_FAMILY" "$TABLE_NAME"
    else
        # 旧 nft：依赖加载前表不存在（脚本 enable 会先删；开机 flush 后也成立）。
        printf 'add table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf 'delete table %s %s\n\n' "$TABLE_FAMILY" "$TABLE_NAME"
    fi
}

render_conf_file() {
    local output_path="$1"
    local ip allow_csv=""

    if ((${#EXTRA_ALLOW[@]} > 0)); then
        allow_csv="$(IFS=','; echo "${EXTRA_ALLOW[*]}")"
    fi

    {
        printf '%s\n' '#!/usr/sbin/nft -f'
        printf '%s\n' "$CONF_MAGIC"
        printf '# META: iface=%s my_ip=%s gateway=%s subnet=%s allow=%s\n\n' \
            "$IFACE" "$MY_IP" "$GATEWAY" "$SUBNET" "$allow_csv"

        write_table_replace_prefix

        printf 'table %s %s {\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf '    chain %s {\n' "$OWNER_CHAIN"
        printf '    }\n\n'
        printf '    chain %s {\n' "$CHAIN_INPUT"
        printf '        type filter hook input priority filter; policy accept;\n'
        printf '        iifname "%s" ip saddr %s accept comment "self"\n' "$IFACE" "$MY_IP"
        if gateway_needs_accept; then
            printf '        iifname "%s" ip saddr %s accept comment "gateway"\n' "$IFACE" "$GATEWAY"
        fi
        for ip in "${EXTRA_ALLOW[@]+"${EXTRA_ALLOW[@]}"}"; do
            printf '        iifname "%s" ip saddr %s accept comment "allow"\n' "$IFACE" "$ip"
        done
        printf '        iifname "%s" ip saddr %s drop comment "neighbor /24"\n' "$IFACE" "$SUBNET"
        printf '    }\n'
        printf '}\n'
    } > "$output_path"
}

# 语法检查：去掉 replace 前缀，避免表已存在时 add table 在 -c 下 EEXIST。
validate_conf_syntax() {
    local conf_path="$1"
    local tmp rc
    tmp="$(mktemp)" || return 1
    grep -Ev '^(add|delete|destroy)[[:space:]]+table[[:space:]]+' "$conf_path" > "$tmp" || true
    set +e
    nft -c -f "$tmp"
    rc=$?
    set -e
    rm -f "$tmp"
    return "$rc"
}

# 生成可重新加载的运行态回滚脚本（表当前不存在时也可安全执行 add+delete 前缀）。
build_runtime_rollback() {
    local output_path="$1"
    {
        printf '%s\n\n' '#!/usr/sbin/nft -f'
        printf 'add table %s %s\n' "$TABLE_FAMILY" "$TABLE_NAME"
        printf 'delete table %s %s\n\n' "$TABLE_FAMILY" "$TABLE_NAME"
        if runtime_table_exists; then
            nft list table "$TABLE_FAMILY" "$TABLE_NAME"
        fi
    } > "$output_path"
}

restore_runtime_from_rollback() {
    local rollback_path="$1"
    [[ -f "$rollback_path" ]] || return 1
    nft -f "$rollback_path"
}

current_ssh_client_ip() {
    local ip=""
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ip="${SSH_CONNECTION%% *}"
    elif [[ -n "${SSH_CLIENT:-}" ]]; then
        ip="${SSH_CLIENT%% *}"
    else
        return 1
    fi
    validate_ipv4 "$ip" || return 1
    printf '%s\n' "$ip"
}

ip_is_allowlisted() {
    local ip="$1" x
    [[ "$ip" == "$MY_IP" ]] && return 0
    if gateway_needs_accept && [[ "$ip" == "$GATEWAY" ]]; then
        return 0
    fi
    for x in "${EXTRA_ALLOW[@]+"${EXTRA_ALLOW[@]}"}"; do
        [[ "$ip" == "$x" ]] && return 0
    done
    return 1
}

# 若当前 SSH 客户端会被封：交互模式警告并继续；-y 模式拒绝（返回 1）。
warn_ssh_client_lockout() {
    local client
    client="$(current_ssh_client_ip)" || return 0
    same_slash24 "$client" "$MY_IP" || return 0
    ip_is_allowlisted "$client" && return 0
    warn "当前 SSH 客户端 ${client} 位于目标网段 ${SUBNET} 且未放行；启用后可能导致无法重连。"
    warn "如需保留管理通道，请加：--allow ${client}"
    if (( YES )); then
        err "已指定 -y/--yes，拒绝在未放行该 SSH 客户端时启用。"
        return 1
    fi
    return 0
}

load_meta_from_conf() {
    local conf_path="${1:-$CONF_FILE}"
    local meta_line iface my_ip gateway subnet allow_csv
    local -a allows=()

    [[ -f "$conf_path" ]] || return 1
    grep -Fqx "$CONF_MAGIC" "$conf_path" || return 1

    meta_line="$(grep -E '^# META:' "$conf_path" | head -n1 || true)"
    [[ -n "$meta_line" ]] || return 1

    iface="$(sed -n 's/.*iface=\([^ ]*\).*/\1/p' <<< "$meta_line")"
    my_ip="$(sed -n 's/.*my_ip=\([^ ]*\).*/\1/p' <<< "$meta_line")"
    gateway="$(sed -n 's/.*gateway=\([^ ]*\).*/\1/p' <<< "$meta_line")"
    subnet="$(sed -n 's/.*subnet=\([^ ]*\).*/\1/p' <<< "$meta_line")"
    allow_csv="$(sed -n 's/.*allow=\([^ ]*\).*/\1/p' <<< "$meta_line")"

    validate_ifname "$iface" || return 1
    validate_ipv4 "$my_ip" || return 1
    validate_gateway_ipv4 "$gateway" || return 1
    [[ "$subnet" == "$(ipv4_to_subnet24 "$my_ip")" ]] || return 1

    IFACE="$iface"
    MY_IP="$my_ip"
    GATEWAY="$gateway"
    SUBNET="$subnet"
    EXTRA_ALLOW=()
    if [[ -n "$allow_csv" ]]; then
        IFS=',' read -r -a allows <<< "$allow_csv"
        EXTRA_ALLOW=("${allows[@]}")
        normalize_extra_allow || return 1
    fi
    return 0
}

show_persistence_hint() {
    if ! main_conf_has_include; then
        warn "持久化未就绪：${MAIN_CONF} 未包含 ${INCLUDE_GLOB}"
        warn "可手动追加一行：${INCLUDE_LINE}"
    fi
    if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl is-enabled --quiet nftables 2>/dev/null; then
            warn "nftables.service 未开机自启；本脚本不会自动启用/启动它。"
            warn "确认本机以 nftables 为唯一防火墙后执行：systemctl enable --now nftables"
        fi
    else
        warn "无法验证 nftables 开机加载：未发现 systemctl"
    fi
}

warn_other_firewalls() {
    if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -qi 'Status: active'; then
        warn "检测到 ufw 处于 active；规则顺序可能与 nft 叠加，请确认效果。"
    fi
    if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet firewalld 2>/dev/null; then
        warn "检测到 firewalld 正在运行；建议只保留一套防火墙。"
    fi
}

print_plan() {
    echo
    echo "计划封禁："
    echo "  网卡     : ${IFACE}"
    echo "  本机 IP  : ${MY_IP}"
    echo "  网关     : ${GATEWAY}"
    echo "  目标网段 : ${SUBNET}"
    if ((${#EXTRA_ALLOW[@]} > 0)); then
        echo "  额外放行 : ${EXTRA_ALLOW[*]}"
    else
        echo "  额外放行 : (无)"
    fi
    if gateway_needs_accept; then
        echo "  网关规则 : accept（网关在 ${SUBNET} 内）"
    else
        echo "  网关规则 : 无需 accept（网关不在 ${SUBNET}，drop 不会命中）"
    fi
    echo "  效果     : 从 ${IFACE} 进入、源地址属于 ${SUBNET} 的流量"
    echo "             除本机/段内网关/额外放行外全部 drop"
    echo
}

confirm_enable() {
    local ans
    if (( YES )); then
        return 0
    fi
    read -rp "确认启用邻居封禁？[Y/n]: " ans || return 1
    answer_yes_default_yes "$ans"
}

cmd_enable() {
    local had_runtime=0
    local allow_note=""

    resolve_targets
    print_plan
    warn_ssh_client_lockout || return 1
    warn_other_firewalls

    if (( DRY_RUN )); then
        echo "----- dry-run nft config -----"
        render_conf_file /dev/stdout
        echo "----- end -----"
        return 0
    fi

    confirm_enable || {
        warn "已取消。"
        return 1
    }

    ensure_dirs
    check_runtime_ownership || return 1

    rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK"
    APPLY_NEED_ROLLBACK=0
    render_conf_file "$TXN_CANDIDATE"
    chmod 0640 "$TXN_CANDIDATE"

    # 先删旧表再 -c/-f：保证 add+delete 前缀可用，且与 destroy 前缀兼容。
    if runtime_table_exists; then
        had_runtime=1
        build_runtime_rollback "$TXN_ROLLBACK" || {
            err "无法生成运行态回滚文件。"
            rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK"
            return 1
        }
        chmod 0600 "$TXN_ROLLBACK"
        if ! nft delete table "$TABLE_FAMILY" "$TABLE_NAME"; then
            err "无法删除旧表以重建规则。"
            rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK"
            return 1
        fi
        APPLY_NEED_ROLLBACK=1
    fi

    if ! validate_conf_syntax "$TXN_CANDIDATE"; then
        err "候选 nft 配置校验失败，已保留：${TXN_CANDIDATE}"
        if (( APPLY_NEED_ROLLBACK )); then
            if restore_runtime_from_rollback "$TXN_ROLLBACK"; then
                err "已恢复启用前运行态；磁盘正式配置未改动。"
            else
                err "运行态回滚失败；请检查 nft 规则。"
            fi
            APPLY_NEED_ROLLBACK=0
            rm -f "$TXN_ROLLBACK"
        fi
        return 1
    fi

    if ! nft -f "$TXN_CANDIDATE"; then
        err "加载规则失败。"
        if (( APPLY_NEED_ROLLBACK )); then
            if restore_runtime_from_rollback "$TXN_ROLLBACK"; then
                err "已恢复启用前运行态；磁盘正式配置未改动。"
            else
                err "运行态回滚失败；请检查 nft 规则。"
            fi
            APPLY_NEED_ROLLBACK=0
        fi
        rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK"
        return 1
    fi

    if ! mv -f "$TXN_CANDIDATE" "$CONF_FILE"; then
        err "运行态已更新，但提交磁盘配置失败；正在回滚运行态。"
        nft delete table "$TABLE_FAMILY" "$TABLE_NAME" >/dev/null 2>&1 || true
        if (( had_runtime )); then
            if restore_runtime_from_rollback "$TXN_ROLLBACK"; then
                err "已恢复启用前运行态；磁盘配置未改变。"
            else
                err "运行态回滚失败，请人工检查 table ${TABLE_FAMILY} ${TABLE_NAME}。"
            fi
        else
            err "已删除新加载的运行表；磁盘配置未改变。"
        fi
        APPLY_NEED_ROLLBACK=0
        rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK"
        return 1
    fi

    APPLY_NEED_ROLLBACK=0
    rm -f "$TXN_ROLLBACK"
    chmod 0640 "$CONF_FILE"

    allow_note="${MY_IP}"
    if gateway_needs_accept; then
        allow_note+=", ${GATEWAY}"
    fi
    if ((${#EXTRA_ALLOW[@]} > 0)); then
        allow_note+=", ${EXTRA_ALLOW[*]}"
    fi
    info "已启用：drop ${SUBNET} neighbors on ${IFACE}（放行 ${allow_note}）"
    info "配置：${CONF_FILE}"
    show_persistence_hint
}

cmd_disable() {
    local ans
    if (( DRY_RUN )); then
        echo "dry-run: 将删除 table ${TABLE_FAMILY} ${TABLE_NAME} 与 ${CONF_FILE}"
        return 0
    fi

    if (( ! YES )); then
        read -rp "确认关闭邻居封禁并删除托管配置？[Y/n]: " ans || return 1
        answer_yes_default_yes "$ans" || {
            warn "已取消。"
            return 1
        }
    fi

    if runtime_table_exists; then
        if runtime_table_is_owned || [[ -f "$CONF_FILE" ]]; then
            nft delete table "$TABLE_FAMILY" "$TABLE_NAME" \
                || die "无法删除运行中的 table ${TABLE_FAMILY} ${TABLE_NAME}"
            info "已删除运行表 ${TABLE_FAMILY} ${TABLE_NAME}"
        else
            die "运行中存在未托管的 table ${TABLE_FAMILY} ${TABLE_NAME}；拒绝删除。"
        fi
    else
        info "运行中无 table ${TABLE_FAMILY} ${TABLE_NAME}"
    fi

    if [[ -f "$CONF_FILE" ]]; then
        rm -f "$CONF_FILE"
        info "已删除配置 ${CONF_FILE}"
    fi
    rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK"
    info "邻居封禁已关闭。"
}

cmd_status() {
    local runtime="absent" disk="absent" meta=""

    if runtime_table_exists; then
        if runtime_table_is_owned; then
            runtime="active (managed)"
        else
            runtime="active (UNMANAGED)"
        fi
    fi
    if [[ -f "$CONF_FILE" ]]; then
        disk="present"
        if load_meta_from_conf "$CONF_FILE"; then
            meta="iface=${IFACE} my_ip=${MY_IP} gateway=${GATEWAY} subnet=${SUBNET}"
            if ((${#EXTRA_ALLOW[@]} > 0)); then
                meta+=" allow=${EXTRA_ALLOW[*]}"
            fi
        else
            meta="(配置无法解析或损坏)"
        fi
    fi

    echo "${SCRIPT_DISPLAY_NAME} status"
    echo "  runtime : ${runtime}"
    echo "  config  : ${disk} (${CONF_FILE})"
    [[ -n "$meta" ]] && echo "  meta    : ${meta}"

    if runtime_table_exists && runtime_table_is_owned; then
        echo
        nft -nn list table "$TABLE_FAMILY" "$TABLE_NAME"
    fi
    show_persistence_hint
}

cmd_check() {
    local rc=0

    if [[ -f "$CONF_FILE" ]]; then
        if ! grep -Fqx "$CONF_MAGIC" "$CONF_FILE"; then
            err "配置缺少托管标记：${CONF_FILE}"
            rc=1
        elif ! load_meta_from_conf "$CONF_FILE"; then
            err "配置 META 无效：${CONF_FILE}"
            rc=1
        elif ! validate_conf_syntax "$CONF_FILE"; then
            err "配置语法校验失败：${CONF_FILE}"
            rc=1
        else
            info "磁盘配置 OK：${CONF_FILE}"
        fi
    else
        info "无磁盘配置（当前未启用持久化规则）"
    fi

    if runtime_table_exists; then
        if runtime_table_is_owned; then
            info "运行表 OK：${TABLE_FAMILY} ${TABLE_NAME}"
        else
            err "运行表存在但无 owner chain，可能不是本脚本创建。"
            rc=1
        fi
    else
        info "运行表不存在"
    fi

    if [[ -f "$CONF_FILE" ]] && ! runtime_table_exists; then
        warn "磁盘有配置但运行表缺失；可执行 enable 重新加载，或检查 nftables 开机加载。"
        rc=1
    fi

    main_conf_has_include || {
        warn "主配置未 include ${INCLUDE_GLOB}（重启可能丢失）"
    }
    return "$rc"
}

# ---------- menu / CLI ----------
menu() {
    local choice
    while true; do
        echo
        echo "======== ${SCRIPT_DISPLAY_NAME} ========"
        echo "  1) enable   启用/刷新邻居封禁"
        echo "  2) disable  关闭邻居封禁"
        echo "  3) status   查看状态"
        echo "  4) check    健康检查"
        echo "  0) quit"
        echo "======================================"
        read -rp "请选择: " choice || exit 1
        case "$choice" in
            1) cmd_enable || true ;;
            2) cmd_disable || true ;;
            3) cmd_status || true ;;
            4) cmd_check || true ;;
            0) exit 0 ;;
            *) err "无效选项" ;;
        esac
    done
}

parse_args() {
    while (($# > 0)); do
        case "$1" in
            -h|--help)
                print_help
                exit 0
                ;;
            -v|--version)
                echo "${SCRIPT_DISPLAY_NAME} v${SCRIPT_VERSION}"
                exit 0
                ;;
            -c|--check)
                CLI_ACTION="check"
                shift
                ;;
            enable|disable|status)
                [[ -z "$CLI_ACTION" ]] || die "只能指定一个动作。"
                CLI_ACTION="$1"
                shift
                ;;
            --iface)
                IFACE="${2:-}"
                [[ -n "$IFACE" ]] || die "--iface 需要参数"
                shift 2
                ;;
            --ip)
                MY_IP="${2:-}"
                [[ -n "$MY_IP" ]] || die "--ip 需要参数"
                shift 2
                ;;
            --gateway)
                GATEWAY="${2:-}"
                [[ -n "$GATEWAY" ]] || die "--gateway 需要参数"
                shift 2
                ;;
            --allow)
                [[ -n "${2:-}" ]] || die "--allow 需要参数"
                EXTRA_ALLOW+=("$2")
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -y|--yes)
                YES=1
                shift
                ;;
            *)
                die "未知参数：$1（见 --help）"
                ;;
        esac
    done
}

main() {
    check_bash_version
    parse_args "$@"

    check_root
    check_cmds
    acquire_lock
    trap cleanup_on_exit EXIT

    case "${CLI_ACTION}" in
        "")
            menu
            ;;
        enable)
            cmd_enable
            ;;
        disable)
            cmd_disable
            ;;
        status)
            cmd_status
            ;;
        check)
            cmd_check
            ;;
        *)
            die "内部错误：未知动作 ${CLI_ACTION}"
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
