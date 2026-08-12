#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nft-neighbor-ban.sh"

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

expect_eq() {
    local got="$1" want="$2" msg="${3:-values differ}"
    [[ "$got" == "$want" ]] || fail "${msg}: got='${got}' want='${want}'"
}

expect_ok validate_ipv4_basic 192.0.2.10
expect_ok validate_ipv4_basic 169.254.1.1
expect_ok validate_ipv4 192.0.2.10
expect_ok validate_ipv4 10.0.0.1
expect_fail validate_ipv4 127.0.0.1
expect_fail validate_ipv4 169.254.1.1
expect_fail validate_ipv4 192.0.2.256
expect_fail validate_ipv4 192.0.2
expect_fail validate_ipv4 08.0.0.1

expect_ok validate_gateway_ipv4 203.0.113.1
expect_ok validate_gateway_ipv4 169.254.1.1
expect_fail validate_gateway_ipv4 127.0.0.1
expect_fail validate_gateway_ipv4 224.0.0.1

expect_ok validate_ifname eth0
expect_ok validate_ifname ens18
expect_fail validate_ifname 'bad name'
expect_fail validate_ifname interface-name-too-long

expect_eq "$(ipv4_to_subnet24 203.0.113.77)" "203.0.113.0/24" "subnet24"
expect_eq "$(ipv4_to_subnet24 10.1.2.3)" "10.1.2.0/24" "subnet24"
expect_fail ipv4_to_subnet24 10.1.2.256

expect_ok same_slash24 203.0.113.1 203.0.113.200
expect_fail same_slash24 203.0.113.1 203.0.114.1
expect_fail same_slash24 169.254.1.1 203.0.113.10

MY_IP="203.0.113.10"
GATEWAY="203.0.113.1"
SUBNET="203.0.113.0/24"
expect_ok gateway_needs_accept
GATEWAY="10.0.0.1"
expect_fail gateway_needs_accept
GATEWAY="169.254.1.1"
expect_fail gateway_needs_accept

MY_IP="203.0.113.10"
GATEWAY="203.0.113.1"
SUBNET="203.0.113.0/24"
EXTRA_ALLOW=("203.0.113.1" "203.0.113.10" "203.0.113.50" "203.0.113.50" "203.0.113.8")
normalize_extra_allow
expect_eq "${#EXTRA_ALLOW[@]}" "2" "extra allow dedupe size"
expect_eq "${EXTRA_ALLOW[0]}" "203.0.113.50" "extra allow sort/first"
expect_eq "${EXTRA_ALLOW[1]}" "203.0.113.8" "extra allow sort/second"

EXTRA_ALLOW=("203.0.114.9")
expect_fail normalize_extra_allow

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
IFACE="eth0"
MY_IP="203.0.113.10"
GATEWAY="203.0.113.1"
SUBNET="203.0.113.0/24"
EXTRA_ALLOW=("203.0.113.50")
expect_ok render_conf_file "$tmp"
grep -Fqx "$CONF_MAGIC" "$tmp" || fail 'missing managed marker'
grep -Eq '^(add|destroy) table inet neighbor_ban' "$tmp" || fail 'missing table replace prefix'
grep -Fq 'table inet neighbor_ban {' "$tmp" || fail 'missing table body'
grep -Fq 'chain nft_neighbor_ban_owner' "$tmp" || fail 'missing owner chain'
grep -Fq 'iifname "eth0" ip saddr 203.0.113.10 accept comment "self"' "$tmp" || fail 'missing self accept'
grep -Fq 'iifname "eth0" ip saddr 203.0.113.1 accept comment "gateway"' "$tmp" || fail 'missing gateway accept'
grep -Fq 'iifname "eth0" ip saddr 203.0.113.50 accept comment "allow"' "$tmp" || fail 'missing extra allow'
grep -Fq 'iifname "eth0" ip saddr 203.0.113.0/24 drop comment "neighbor /24"' "$tmp" || fail 'missing subnet drop'
grep -Fq '# META: iface=eth0 my_ip=203.0.113.10 gateway=203.0.113.1 subnet=203.0.113.0/24 allow=203.0.113.50' "$tmp" \
    || fail 'missing meta line'

# validate_conf_syntax 应去掉 replace 前缀后仍含 table 体
syntax_tmp="$(mktemp)"
grep -Ev '^(add|delete|destroy)[[:space:]]+table[[:space:]]+' "$tmp" > "$syntax_tmp"
grep -Fq 'table inet neighbor_ban {' "$syntax_tmp" || fail 'syntax strip lost table body'
grep -Eq '^(add|delete|destroy) table' "$syntax_tmp" && fail 'syntax strip left replace prefix'
rm -f "$syntax_tmp"

# 网关在段外：不应写入 gateway accept
GATEWAY="10.0.0.1"
EXTRA_ALLOW=()
expect_ok render_conf_file "$tmp"
grep -Fq 'comment "gateway"' "$tmp" && fail 'gateway accept should be omitted when outside /24'
grep -Fq 'gateway=10.0.0.1' "$tmp" || fail 'meta should still record outside gateway'
grep -Fq 'iifname "eth0" ip saddr 203.0.113.0/24 drop' "$tmp" || fail 'subnet drop missing'

# link-local 网关可写入 META，且无 gateway accept
GATEWAY="169.254.1.1"
expect_ok render_conf_file "$tmp"
grep -Fq 'gateway=169.254.1.1' "$tmp" || fail 'meta should record link-local gateway'
grep -Fq 'comment "gateway"' "$tmp" && fail 'link-local gateway should not get accept rule'

IFACE="" MY_IP="" GATEWAY="" SUBNET="" EXTRA_ALLOW=()
# restore in-subnet render for load_meta roundtrip
IFACE="eth0"
MY_IP="203.0.113.10"
GATEWAY="203.0.113.1"
SUBNET="203.0.113.0/24"
EXTRA_ALLOW=("203.0.113.50")
expect_ok render_conf_file "$tmp"
IFACE="" MY_IP="" GATEWAY="" SUBNET="" EXTRA_ALLOW=()
expect_ok load_meta_from_conf "$tmp"
expect_eq "$IFACE" "eth0"
expect_eq "$MY_IP" "203.0.113.10"
expect_eq "$GATEWAY" "203.0.113.1"
expect_eq "$SUBNET" "203.0.113.0/24"
expect_eq "${EXTRA_ALLOW[*]}" "203.0.113.50"

# link-local gateway META roundtrip
IFACE="eth0" MY_IP="203.0.113.10" GATEWAY="169.254.1.1" SUBNET="203.0.113.0/24" EXTRA_ALLOW=()
expect_ok render_conf_file "$tmp"
IFACE="" MY_IP="" GATEWAY="" SUBNET="" EXTRA_ALLOW=()
expect_ok load_meta_from_conf "$tmp"
expect_eq "$GATEWAY" "169.254.1.1"

printf '%s\n' '#!/usr/sbin/nft -f' '# not managed' > "$tmp"
expect_fail load_meta_from_conf "$tmp"

# SSH lockout helper
MY_IP="203.0.113.10"
GATEWAY="203.0.113.1"
SUBNET="203.0.113.0/24"
EXTRA_ALLOW=()
SSH_CONNECTION="203.0.113.50 5555 203.0.113.10 22"
expect_eq "$(current_ssh_client_ip)" "203.0.113.50"
expect_fail ip_is_allowlisted 203.0.113.50
YES=0
expect_ok warn_ssh_client_lockout
YES=1
expect_fail warn_ssh_client_lockout
EXTRA_ALLOW=("203.0.113.50")
YES=1
expect_ok warn_ssh_client_lockout
unset SSH_CONNECTION EXTRA_ALLOW
YES=0
EXTRA_ALLOW=()
SSH_CLIENT="198.51.100.9 40000 22"
expect_eq "$(current_ssh_client_ip)" "198.51.100.9"
# different /24 → warn helper should no-op
YES=1
expect_ok warn_ssh_client_lockout
unset SSH_CLIENT
YES=0

printf 'OK: nft-neighbor-ban offline tests passed\n'
