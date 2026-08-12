#!/bin/bash
set -euo pipefail

PATH="/usr/sbin:/usr/bin:/sbin:/bin"
export PATH
umask 027

# 将 nft-portfwd v2 的托管配置从 MASQUERADE 原位迁移为静态 SNAT。
# 迁移后继续使用同一 table/config/lock/transaction 身份。

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_SCRIPT="${SCRIPT_DIR}/nft-portfwd.sh"
TARGET_SCRIPT="${SCRIPT_DIR}/nft-portfwd-snat.sh"

CONF_DIR="/etc/nftables.d"
CONF_FILE="${CONF_DIR}/portfwd.conf"
RUNTIME_DIR="/run/nft-portfwd"
LOCK_FILE="${RUNTIME_DIR}/lock"
TXN_CANDIDATE="${CONF_DIR}/.portfwd.conf.new"
TXN_ROLLBACK="${CONF_DIR}/.portfwd.rollback.nft"
TXN_MARKER="${CONF_DIR}/.portfwd.transaction"

ASSUME_YES=0
LOCK_FD=""
BACKUP_FILE=""
OWNED_ARTIFACTS=0

info() { printf '\033[32m[INFO]\033[0m %s\n' "$*"; }
warn() { printf '\033[33m[WARN]\033[0m %s\n' "$*"; }
err()  { printf '\033[31m[ERR ]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

print_help() {
    cat <<EOF
用法:
  sudo bash ./nft-portfwd-migrate-to-snat.sh
  sudo bash ./nft-portfwd-migrate-to-snat.sh --yes

作用:
  将 ${CONF_FILE} 从 DNAT + MASQUERADE 原位迁移为 DNAT + 静态 SNAT。
  每条规则使用其监听 IPv4 作为 SNAT 地址，表名、配置路径及规则元数据保持不变。

要求:
  ${SOURCE_SCRIPT}
  ${TARGET_SCRIPT}
  必须与本迁移脚本位于同一目录。

说明:
  --yes  跳过最终确认，适合无人值守执行。
EOF
}

handle_args() {
    case "${1:-}" in
        "") ;;
        -y|--yes) ASSUME_YES=1 ;;
        -h|--help) print_help; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
    (( $# <= 1 )) || die "参数过多。"
}

check_root() {
    [[ "$EUID" -eq 0 ]] || die "请用 root 运行。"
}

check_requirements() {
    local cmd
    local -a required=(bash nft flock install stat grep mktemp chmod cp mv rm)
    for cmd in "${required[@]}"; do
        command -v "$cmd" >/dev/null 2>&1 || die "缺少必需命令：${cmd}"
    done
    [[ -f "$SOURCE_SCRIPT" && ! -L "$SOURCE_SCRIPT" ]] \
        || die "缺少原版脚本或文件是符号链接：${SOURCE_SCRIPT}"
    [[ -f "$TARGET_SCRIPT" && ! -L "$TARGET_SCRIPT" ]] \
        || die "缺少 SNAT 脚本或文件是符号链接：${TARGET_SCRIPT}"
    bash -n "$SOURCE_SCRIPT" "$TARGET_SCRIPT" \
        || die "主脚本 Bash 语法检查失败。"
}

ensure_secure_dir() {
    local path="$1" mode uid
    [[ ! -L "$path" ]] || die "拒绝使用符号链接目录：${path}"
    if [[ ! -d "$path" ]]; then
        install -d -m 0700 -o root -g root "$path" \
            || die "无法创建目录：${path}"
    fi
    uid="$(stat -c '%u' "$path")" || die "无法读取目录所有者：${path}"
    mode="$(stat -c '%a' "$path")" || die "无法读取目录权限：${path}"
    [[ "$uid" == "0" ]] || die "目录必须由 root 拥有：${path}"
    (( (8#$mode & 0022) == 0 )) || die "目录不可由 group/other 写入：${path} (${mode})"
}

check_secure_dir() {
    local path="$1" mode uid
    [[ -d "$path" && ! -L "$path" ]] || die "目录不存在或是符号链接：${path}"
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
    ensure_secure_dir "$RUNTIME_DIR"
    [[ ! -L "$LOCK_FILE" ]] || die "拒绝使用符号链接锁文件：${LOCK_FILE}"
    if [[ ! -e "$LOCK_FILE" ]]; then
        install -m 0600 -o root -g root /dev/null "$LOCK_FILE" \
            || die "无法创建锁文件：${LOCK_FILE}"
    fi
    secure_root_file "$LOCK_FILE" || die "锁文件 owner/mode 不安全：${LOCK_FILE}"
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

cleanup_on_exit() {
    if (( OWNED_ARTIFACTS == 1 )) && [[ ! -e "$TXN_MARKER" ]]; then
        rm -f "$TXN_CANDIDATE" "$TXN_ROLLBACK" >/dev/null 2>&1 || true
    fi
    release_lock
}

run_nft_file() {
    local path="$1"
    [[ -f "$path" && ! -L "$path" ]] || return 1
    nft -c -f "$path" && nft -f "$path"
}

recover_transaction_if_needed() {
    [[ -e "$TXN_MARKER" ]] || {
        [[ ! -e "$TXN_CANDIDATE" && ! -e "$TXN_ROLLBACK" ]] \
            || die "发现无事务标记的残留文件，请人工核对：${TXN_CANDIDATE} ${TXN_ROLLBACK}"
        return 0
    }

    [[ -f "$TXN_MARKER" && ! -L "$TXN_MARKER" ]] \
        || die "事务标记异常：${TXN_MARKER}"
    warn "检测到未完成事务，先恢复一致状态。"
    if [[ -f "$TXN_CANDIDATE" ]]; then
        run_nft_file "$TXN_ROLLBACK" || die "无法恢复事务前运行态；事务文件已保留。"
        info "已恢复事务前运行态。"
    else
        run_nft_file "$CONF_FILE" || die "无法按已提交配置恢复运行态；事务文件已保留。"
        info "已按已提交配置恢复运行态。"
    fi
    rm -f "$TXN_MARKER" "$TXN_CANDIDATE" "$TXN_ROLLBACK" \
        || die "无法清理已恢复的事务文件。"
}

validate_config_with() {
    local script_path="$1" conf_path="$2"
    bash -s -- "$script_path" "$conf_path" <<'BASH'
set -euo pipefail
source "$1"
load_rules_from_conf "$2"
BASH
}

render_snat_candidate() {
    local old_conf="$1" output_path="$2"
    bash -s -- "$TARGET_SCRIPT" "$old_conf" "$output_path" <<'BASH'
set -euo pipefail
source "$1"
RULES=()
while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*#[[:space:]]*RULE:[[:space:]]*(.+)[[:space:]]*$ ]]; then
        RULES+=("${BASH_REMATCH[1]}")
    fi
done < "$2"
CONFIG_LOAD_ERRORS=0
render_conf_file "$3"
BASH
}

build_runtime_rollback() {
    local output_path="$1"
    bash -s -- "$SOURCE_SCRIPT" "$output_path" <<'BASH'
set -euo pipefail
source "$1"
check_runtime_ownership
build_runtime_rollback "$2"
BASH
}

verify_snat_runtime() {
    local candidate="$1"
    bash -s -- "$TARGET_SCRIPT" "$candidate" <<'BASH'
set -euo pipefail
source "$1"
load_rules_from_conf "$2"
runtime_output="$(nft -nn list table "$TABLE_FAMILY" "$TABLE_NAME")"
runtime_output="$(normalize_runtime_nft_dump <<< "$runtime_output")"
runtime_rules_match_loaded_config "$runtime_output"
BASH
}

rollback_failed_migration() {
    err "迁移未完成，正在恢复原运行态。"
    if run_nft_file "$TXN_ROLLBACK"; then
        rm -f "$TXN_MARKER" "$TXN_CANDIDATE" "$TXN_ROLLBACK" || true
        info "已恢复原 MASQUERADE 运行态；磁盘配置未改变。"
    else
        err "自动回滚失败；已保留事务文件，请勿继续修改 nftables。"
        err "回滚文件：${TXN_ROLLBACK}"
    fi
}

confirm_migration() {
    local answer
    (( ASSUME_YES == 1 )) && return 0
    printf '\n将原位更新 %s 及运行中的 table ip portfwd。\n' "$CONF_FILE"
    printf '旧配置备份会永久保留；迁移后请使用 nft-portfwd-snat.sh。\n'
    read -rp "确认从 MASQUERADE 迁移到静态 SNAT？[y/N]: " answer || return 1
    [[ "$answer" =~ ^[Yy]$ ]]
}

main() {
    local rule_count
    handle_args "$@"
    check_root
    check_requirements
    acquire_lock
    trap cleanup_on_exit EXIT

    check_secure_dir "$CONF_DIR"
    secure_root_file "$CONF_FILE" \
        || die "配置必须是 root 拥有且 group/other 不可写的普通文件：${CONF_FILE}"
    recover_transaction_if_needed

    if validate_config_with "$TARGET_SCRIPT" "$CONF_FILE" >/dev/null 2>&1; then
        info "配置已经是 SNAT 版（空配置也无需迁移）。"
        exit 0
    fi
    validate_config_with "$SOURCE_SCRIPT" "$CONF_FILE" \
        || die "旧配置未通过原 MASQUERADE 版的完整性校验，拒绝迁移。"

    rule_count="$(grep -Ec '^[[:space:]]*#[[:space:]]*RULE:' "$CONF_FILE" || true)"
    (( rule_count > 0 )) || die "旧配置没有可迁移规则。"
    confirm_migration || { warn "已取消。"; exit 0; }

    OWNED_ARTIFACTS=1
    render_snat_candidate "$CONF_FILE" "$TXN_CANDIDATE" \
        || die "无法生成 SNAT 候选配置。"
    chmod 0640 "$TXN_CANDIDATE" || die "无法设置候选配置权限。"
    validate_config_with "$TARGET_SCRIPT" "$TXN_CANDIDATE" \
        || die "SNAT 候选配置未通过完整性校验。"
    nft -c -f "$TXN_CANDIDATE" || die "SNAT 候选配置未通过 nft 语法/语义校验。"

    build_runtime_rollback "$TXN_ROLLBACK" || die "无法生成原运行态回滚文件。"
    chmod 0600 "$TXN_ROLLBACK" || die "无法设置回滚文件权限。"
    BACKUP_FILE="$(mktemp "${CONF_FILE}.masquerade-backup.XXXXXX")" \
        || die "无法创建旧配置备份。"
    cp -p "$CONF_FILE" "$BACKUP_FILE" || die "无法备份旧配置。"
    install -m 0600 -o root -g root /dev/null "$TXN_MARKER" \
        || die "无法创建事务标记。"

    if ! nft -f "$TXN_CANDIDATE" || ! verify_snat_runtime "$TXN_CANDIDATE"; then
        rollback_failed_migration
        exit 1
    fi
    if ! mv -f "$TXN_CANDIDATE" "$CONF_FILE"; then
        rollback_failed_migration
        exit 1
    fi

    rm -f "$TXN_MARKER" "$TXN_ROLLBACK" \
        || warn "迁移已提交，但事务文件清理失败；下次运行会自动恢复一致状态。"
    OWNED_ARTIFACTS=0

    info "迁移成功：${rule_count} 条规则已改为静态 SNAT。"
    info "旧配置备份：${BACKUP_FILE}"
    info "后续请使用：sudo ./nft-portfwd-snat.sh"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
