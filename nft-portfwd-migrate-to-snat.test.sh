#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nft-portfwd-migrate-to-snat.sh"

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

expect_ok() {
    "$@" || fail "expected success: $*"
}

expect_fail() {
    if "$@"; then
        fail "expected failure: $*"
    fi
}

old_conf="$(mktemp)"
new_conf="$(mktemp)"
old_empty_conf="$(mktemp)"
new_empty_conf="$(mktemp)"
trap 'rm -f "$old_conf" "$new_conf" "$old_empty_conf" "$new_empty_conf"' EXIT

(
    source "${SCRIPT_DIR}/nft-portfwd.sh"
    RULES=("192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.0/24")
    render_conf_file "$old_conf"
)

expect_ok validate_config_with "${SCRIPT_DIR}/nft-portfwd.sh" "$old_conf"
expect_fail validate_config_with "${SCRIPT_DIR}/nft-portfwd-snat.sh" "$old_conf" >/dev/null 2>&1
expect_ok render_snat_candidate "$old_conf" "$new_conf" "198.51.100.10"
expect_ok validate_config_with "${SCRIPT_DIR}/nft-portfwd-snat.sh" "$new_conf"
expect_fail validate_config_with "${SCRIPT_DIR}/nft-portfwd.sh" "$new_conf" >/dev/null 2>&1

grep -Fq 'table ip portfwd {' "$new_conf" || fail 'table identity changed'
grep -Fqx '# MANAGED-BY: nft-portfwd v2' "$new_conf" || fail 'managed marker changed'
grep -Fq '# RULE: 192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.0/24' "$new_conf" \
    || fail 'seven-field rule metadata changed'
grep -Fq '# RULE-SNAT:' "$new_conf" || fail 'SNAT metadata marker missing'
grep -Fqx 'define LOCAL_IP = 198.51.100.10' "$new_conf" || fail 'LOCAL_IP definition missing'
grep -Fq 'snat to $LOCAL_IP' "$new_conf" || fail 'LOCAL_IP variable was not used for SNAT'
expect_fail grep -Fq 'masquerade' "$new_conf"

(
    source "${SCRIPT_DIR}/nft-portfwd.sh"
    RULES=()
    render_conf_file "$old_empty_conf"
)
expect_ok validate_config_with "${SCRIPT_DIR}/nft-portfwd.sh" "$old_empty_conf"
expect_ok render_snat_candidate "$old_empty_conf" "$new_empty_conf" "198.51.100.10"
expect_ok validate_config_with "${SCRIPT_DIR}/nft-portfwd-snat.sh" "$new_empty_conf"
grep -Fqx 'define LOCAL_IP = 198.51.100.10' "$new_empty_conf" \
    || fail 'empty config migration lost LOCAL_IP'
expect_fail grep -Eq '^[[:space:]]*#[[:space:]]*RULE:' "$new_empty_conf"

source_identity="$(bash -s -- "${SCRIPT_DIR}/nft-portfwd.sh" <<'BASH'
source "$1"
printf '%s|' "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING" "$CHAIN_POSTROUTING" \
    "$SCRIPT_DISPLAY_NAME" "$SCRIPT_VERSION" "$CONF_DIR" "$CONF_FILE" "$MAIN_CONF" \
    "$SYSCTL_FILE" "$RUNTIME_DIR" "$LOCK_FILE" "$OWNER_CHAIN" "$TXN_CANDIDATE" \
    "$TXN_ROLLBACK" "$TXN_MARKER" "$CONF_MAGIC"
BASH
)"
target_identity="$(bash -s -- "${SCRIPT_DIR}/nft-portfwd-snat.sh" <<'BASH'
source "$1"
printf '%s|' "$TABLE_FAMILY" "$TABLE_NAME" "$CHAIN_PREROUTING" "$CHAIN_POSTROUTING" \
    "$SCRIPT_DISPLAY_NAME" "$SCRIPT_VERSION" "$CONF_DIR" "$CONF_FILE" "$MAIN_CONF" \
    "$SYSCTL_FILE" "$RUNTIME_DIR" "$LOCK_FILE" "$OWNER_CHAIN" "$TXN_CANDIDATE" \
    "$TXN_ROLLBACK" "$TXN_MARKER" "$CONF_MAGIC"
BASH
)"
[[ "$source_identity" == "$target_identity" ]] || fail 'main script identity constants differ'

printf 'PASS: nft-portfwd MASQUERADE-to-SNAT migration tests\n'
