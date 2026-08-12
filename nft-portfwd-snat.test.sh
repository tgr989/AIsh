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
trap 'rm -f "$tmp"' EXIT

RULES=("192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.0/24")
expect_ok render_conf_file "$tmp"

grep -Fqx "$CONF_MAGIC" "$tmp" || fail 'missing SNAT managed marker'
grep -Fq 'delete table ip portfwd' "$tmp" \
    || fail 'SNAT table is not rebuilt completely'
grep -Fq 'ip daddr 192.0.2.10 ip saddr 203.0.113.0/24 tcp dport 8443 dnat to 10.0.0.2:443' "$tmp" \
    || fail 'DNAT is not scoped to listen IP/source'
grep -Fq 'ct original ip daddr 192.0.2.10 meta l4proto tcp ct original proto-dst 8443 ct original ip saddr 203.0.113.0/24 ip daddr 10.0.0.2 tcp dport 443 snat to 192.0.2.10' "$tmp" \
    || fail 'SNAT is not scoped to the original tuple or listen IP'
expect_fail grep -Fq 'masquerade' "$tmp"

expect_ok load_rules_from_conf "$tmp"
[[ ${#RULES[@]} -eq 1 && "$CONFIG_LOAD_ERRORS" -eq 0 ]] \
    || fail 'managed SNAT config reload failed'

runtime_output="$(sed -E '/^(#!|add table|delete table|[[:space:]]*#)/d' "$tmp")"
expect_ok runtime_rules_match_loaded_config "$runtime_output"

tampered_snat="${runtime_output/snat to 192.0.2.10/snat to 192.0.2.11}"
expect_fail runtime_rules_match_loaded_config "$tampered_snat"
masquerade_runtime="${runtime_output/snat to 192.0.2.10/masquerade}"
expect_fail runtime_rules_match_loaded_config "$masquerade_runtime"

[[ "$TABLE_NAME" == "portfwd" ]] || fail 'unexpected table name'
[[ "$CONF_FILE" == "/etc/nftables.d/portfwd.conf" ]] || fail 'unexpected config path'
[[ "$SCRIPT_VERSION" == "2.2.4" ]] || fail 'unexpected script version'

printf 'PASS: nft-portfwd-snat offline tests\n'
