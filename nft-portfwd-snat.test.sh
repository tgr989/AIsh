#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nft-portfwd-snat.sh"

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

tmp="$(mktemp)"
invalid_tmp="$(mktemp)"
trap 'rm -f "$tmp" "$invalid_tmp"' EXIT

SNAT_IP="198.51.100.10"
RULES=("192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.0/24")
expect_ok render_conf_file "$tmp"

grep -Fqx "$CONF_MAGIC" "$tmp" || fail 'missing SNAT managed marker'
grep -Fqx 'define LOCAL_IP = 198.51.100.10' "$tmp" || fail 'missing LOCAL_IP definition'
grep -Fq 'delete table ip portfwd' "$tmp" \
    || fail 'SNAT table is not rebuilt completely'
grep -Fq 'ip daddr 192.0.2.10 ip saddr 203.0.113.0/24 tcp dport 8443 dnat to 10.0.0.2:443' "$tmp" \
    || fail 'DNAT is not scoped to listen IP/source'
grep -Fq 'ct original ip daddr 192.0.2.10 meta l4proto tcp ct original proto-dst 8443 ct original ip saddr 203.0.113.0/24 ip daddr 10.0.0.2 tcp dport 443 snat to $LOCAL_IP' "$tmp" \
    || fail 'SNAT is not scoped to the original tuple or LOCAL_IP'
expect_fail grep -Fq 'masquerade' "$tmp"

expect_ok load_rules_from_conf "$tmp"
[[ ${#RULES[@]} -eq 1 && "$CONFIG_LOAD_ERRORS" -eq 0 ]] \
    || fail 'managed SNAT config reload failed'
grep -Fv 'define LOCAL_IP' "$tmp" > "$invalid_tmp"
expect_fail load_rules_from_conf "$invalid_tmp" >/dev/null 2>&1
[[ "$CONFIG_LOAD_ERRORS" -eq 1 ]] || fail 'missing LOCAL_IP was not rejected'
expect_ok load_rules_from_conf "$tmp"

runtime_output="$(sed -E '/^(#!|define LOCAL_IP|add table|delete table|[[:space:]]*#)/d' "$tmp")"
runtime_output="${runtime_output//\$LOCAL_IP/$SNAT_IP}"
expect_ok runtime_rules_match_loaded_config "$runtime_output"

tampered_snat="${runtime_output/snat to 198.51.100.10/snat to 198.51.100.11}"
expect_fail runtime_rules_match_loaded_config "$tampered_snat"
masquerade_runtime="${runtime_output/snat to 198.51.100.10/masquerade}"
expect_fail runtime_rules_match_loaded_config "$masquerade_runtime"

# nft 的跨版本规范化差异：显式 NAT 地址族和 /32 主机前缀。
RULES=("192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.7/32")
expect_ok render_conf_file "$tmp"
runtime_output="$(sed -E '/^(#!|define LOCAL_IP|add table|delete table|[[:space:]]*#)/d' "$tmp")"
runtime_output="${runtime_output//\$LOCAL_IP/$SNAT_IP}"
runtime_output="${runtime_output//203.0.113.7\/32/203.0.113.7}"
runtime_output="${runtime_output//dnat to/dnat ip to}"
runtime_output="${runtime_output//snat to/snat ip to}"
runtime_output="$(normalize_runtime_nft_dump <<< "$runtime_output")"
expect_ok runtime_rules_match_loaded_config "$runtime_output"

ip() {
    if [[ "$1 $2 $3 $4" == "-4 route get 1.1.1.1" ]]; then
        printf '%s\n' '1.1.1.1 via 192.0.2.1 dev eth0 src 198.51.100.20'
        return 0
    fi
    return 1
}
[[ "$(get_local_ip)" == "198.51.100.20" ]] || fail 'default-route LOCAL_IP detection failed'
SNAT_IP="198.51.100.20"
expect_ok check_snat_ip_current >/dev/null
SNAT_IP="198.51.100.10"
expect_fail check_snat_ip_current >/dev/null 2>&1
unset -f ip

cli_docs="$(print_help; show_tips)"
[[ "$cli_docs" == *'./nft-portfwd-snat.sh --check'* ]] \
    || fail 'SNAT CLI docs do not use the actual script basename'
[[ "$cli_docs" != *'./nft-portfwd.sh --check'* ]] \
    || fail 'SNAT CLI docs still point to the MASQUERADE script'
version_output="$(handle_cli_args --version)"
[[ "$version_output" == 'nft-portfwd v2.2.4 (static-snat)' ]] \
    || fail 'SNAT version output does not identify its mode'

[[ "$TABLE_NAME" == "portfwd" ]] || fail 'unexpected table name'
[[ "$CONF_FILE" == "/etc/nftables.d/portfwd.conf" ]] || fail 'unexpected config path'
[[ "$SCRIPT_VERSION" == "2.2.4" ]] || fail 'unexpected script version'

printf 'PASS: nft-portfwd-snat offline tests\n'
