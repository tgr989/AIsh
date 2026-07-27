#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/nft-portfwd.sh"

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

expect_ok validate_port 1
expect_ok validate_port 65535
expect_fail validate_port 0
expect_fail validate_port 65536
expect_ok validate_ipv4 192.0.2.10
expect_fail validate_ipv4 127.0.0.1
expect_fail validate_ipv4 169.254.169.254
expect_fail validate_ipv4 224.0.0.1
expect_ok validate_ipv4_cidr 0.0.0.0/0
expect_ok validate_ipv4_cidr 203.0.113.0/24
expect_ok validate_ipv4_cidr 203.0.113.7/32
expect_fail validate_ipv4_cidr 203.0.113.7/24
expect_fail validate_ipv4_cidr 203.0.113.0/33
expect_ok validate_ifname eth0
expect_fail validate_ifname interface-name-too-long

expect_ok ss_listen_line_has_port 8080 'LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*'
expect_ok ss_listen_line_has_port 8080 'LISTEN 0 128 *:8080 *:*'
expect_fail ss_listen_line_has_port 80 'LISTEN 0 128 0.0.0.0:8080 0.0.0.0:*'
expect_fail ss_listen_line_has_port 8080 'LISTEN 0 128 0.0.0.0:8081 0.0.0.0:*'

can_probe_tcp_connect() { return 0; }
probe_tcp_connect() { return 0; }
confirm_out="$(confirm_continue_despite_unreachable_dest 10.0.0.2 443)"
grep -Fq 'TCP 可达' <<< "$confirm_out" || fail 'reachable dest did not report success'
probe_tcp_connect() { return 1; }
read_or_cancel() { printf -v "$1" '%s' 'n'; }
expect_fail confirm_continue_despite_unreachable_dest 10.0.0.2 443 >/dev/null
read_or_cancel() { printf -v "$1" '%s' 'y'; }
expect_ok confirm_continue_despite_unreachable_dest 10.0.0.2 443 >/dev/null
unset -f can_probe_tcp_connect probe_tcp_connect read_or_cancel

RULES=("192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.0/24")
expect_ok rule_conflicts 192.0.2.10 8443 tcp eth0
expect_fail rule_conflicts 192.0.2.10 8443 tcp eth1
expect_fail rule_conflicts 192.0.2.11 8443 tcp eth0

tmp="$(mktemp)"
invalid_tmp="$(mktemp)"
sysctl_tmp="$(mktemp)"
trap 'rm -f "$tmp" "$invalid_tmp" "$sysctl_tmp"' EXIT
expect_ok render_conf_file "$tmp"
grep -Fqx "$CONF_MAGIC" "$tmp" || fail 'missing managed marker'
grep -Fq 'delete table ip portfwd' "$tmp" || fail 'managed table is not rebuilt completely'
expect_fail grep -Fq 'flush table ip portfwd' "$tmp"
grep -Fq 'ip daddr 192.0.2.10 ip saddr 203.0.113.0/24 tcp dport 8443 dnat to 10.0.0.2:443' "$tmp" \
    || fail 'DNAT is not scoped to listen IP/source'
grep -Fq 'ct original ip daddr 192.0.2.10 meta l4proto tcp ct original proto-dst 8443' "$tmp" \
    || fail 'MASQUERADE is not scoped to original tuple'

expect_ok load_rules_from_conf "$tmp"
[[ ${#RULES[@]} -eq 1 && "$CONFIG_LOAD_ERRORS" -eq 0 ]] || fail 'managed config reload failed'
printf '%s\n' '# unexpected manual drift' >> "$tmp"
expect_fail load_rules_from_conf "$tmp" 2>/dev/null
[[ "$CONFIG_LOAD_ERRORS" -eq 1 ]] || fail 'managed config drift was not recorded'

printf '%s\n' '#!/usr/sbin/nft -f' "$CONF_MAGIC" \
    '# RULE: 8443|tcp|10.0.0.2|443|eth0' > "$invalid_tmp"
expect_fail load_rules_from_conf "$invalid_tmp" 2>/dev/null
[[ "$CONFIG_LOAD_ERRORS" -eq 1 ]] || fail 'non-current rule format was not rejected'

printf '%s\n' '#!/usr/sbin/nft -f' > "$invalid_tmp"
expect_fail load_rules_from_conf "$invalid_tmp" 2>/dev/null
[[ "$CONFIG_LOAD_ERRORS" -eq 1 ]] || fail 'missing managed marker was not rejected'

runtime_output="$(printf '%s\n' \
    'table ip portfwd {' \
    '    chain nft_portfwd_owner {' \
    '    }' \
    '    chain prerouting {' \
    '        type nat hook prerouting priority dstnat; policy accept;' \
    '        iifname "eth0" ip daddr 192.0.2.10 ip saddr 203.0.113.0/24 tcp dport 8443 dnat to 10.0.0.2:443' \
    '    }' \
    '    chain postrouting {' \
    '        type nat hook postrouting priority srcnat; policy accept;' \
        '        iifname "eth0" ct status dnat ct original ip daddr 192.0.2.10 meta l4proto tcp ct original proto-dst 8443 ct original ip saddr 203.0.113.0/24 ip daddr 10.0.0.2 tcp dport 443 masquerade' \
    '    }' \
    '}')"
RULES=("192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.0/24")
expect_ok runtime_rules_match_loaded_config "$runtime_output"
tampered_output="${runtime_output/10.0.0.2:443/10.0.0.3:443}"
expect_fail runtime_rules_match_loaded_config "$tampered_output"
extra_output="${runtime_output/        iifname/        counter\n        iifname}"
expect_fail runtime_rules_match_loaded_config "$extra_output"
priority_output="${runtime_output/priority dstnat/priority -90}"
expect_fail runtime_rules_match_loaded_config "$priority_output"
missing_prerouting_type="$(grep -Fv 'type nat hook prerouting' <<< "$runtime_output")"
expect_fail runtime_rules_match_loaded_config "$missing_prerouting_type"
missing_postrouting_type="$(grep -Fv 'type nat hook postrouting' <<< "$runtime_output")"
expect_fail runtime_rules_match_loaded_config "$missing_postrouting_type"

RULES=()
empty_runtime_output="$(printf '%s\n' \
    'table ip portfwd {' \
    '    chain nft_portfwd_owner {' '    }' \
    '    chain prerouting {' \
    '        type nat hook prerouting priority -100; policy accept;' '    }' \
    '    chain postrouting {' \
    '        type nat hook postrouting priority 100; policy accept;' '    }' \
    '}')"
expect_ok runtime_rules_match_loaded_config "$empty_runtime_output"

printf '%s\n' 'net.ipv4.ip_forward=0' 'net.ipv4.ip_forward = 1' > "$sysctl_tmp"
[[ "$(last_ip_forward_assignment "$sysctl_tmp")" == "1" ]] \
    || fail 'last sysctl assignment was not selected'
printf '%s\n' '-net.ipv4.ip_forward = 0' > "$sysctl_tmp"
[[ "$(last_ip_forward_assignment "$sysctl_tmp")" == "0" ]] \
    || fail 'optional sysctl failure prefix was not parsed'
printf '%s\n' 'net/ipv4/ip_forward = 1 # keep forwarding' > "$sysctl_tmp"
[[ "$(last_ip_forward_assignment "$sysctl_tmp")" == "1" ]] \
    || fail 'slash-form sysctl key or trailing comment was not parsed'

systemd-sysctl() {
    printf '%s\n' 'net.ipv4.ip_forward=0' 'net.ipv4.ip_forward=1'
}
expect_fail ip_forward_has_competing_persistence >/dev/null
systemd-sysctl() {
    printf '%s\n' 'net.ipv4.ip_forward=1' 'net.ipv4.ip_forward=0'
}
expect_ok ip_forward_has_competing_persistence >/dev/null
unset -f systemd-sysctl

systemctl() {
    [[ "$1" == "show" ]] || return 1
    printf '%s\n' '{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft -f /etc/nftables.conf ; }'
}
expect_ok nftables_service_uses_main_conf
systemctl() {
    [[ "$1" == "show" ]] || return 1
    printf '%s\n' '{ path=/usr/sbin/nft ; argv[]=/usr/sbin/nft -f /etc/other.conf ; }'
}
expect_fail nftables_service_uses_main_conf
unset -f systemctl

rm() { return 1; }
expect_ok finish_committed_transaction >/dev/null 2>&1
unset -f rm

runtime_ipf=0
get_ip_forward_value() { printf '%s\n' "$runtime_ipf"; }
enable_ip_forward_runtime() { runtime_ipf=1; }
enable_ip_forward_persist() { return 1; }
sysctl() {
    runtime_ipf="${2##*=}"
    return 0
}
IPF_ORIGINAL_RUNTIME=0
IPF_WANT_ENABLE=1
IPF_WANT_PERSIST=1
expect_fail apply_ip_forward_plan >/dev/null 2>&1
[[ "$runtime_ipf" == "0" ]] || fail 'runtime ip_forward was not restored after partial failure'
unset -f get_ip_forward_value enable_ip_forward_runtime enable_ip_forward_persist sysctl

load_rules_from_conf() { return 1; }
expect_fail list_rules >/dev/null 2>&1
unset -f load_rules_from_conf

setup_environment_interactive() { return 1; }
check_forward_status() { fail 'environment check continued after setup failure'; }
expect_fail check_and_fix_environment_interactive
unset -f setup_environment_interactive check_forward_status

load_rules_from_conf() {
    RULES=("192.0.2.10|8443|tcp|10.0.0.2|443|eth0|203.0.113.0/24")
    return 0
}
assert_loaded_config_safe() { return 0; }
list_rules() { return 0; }
read_or_cancel() { printf -v "$1" '%s' 'all'; }
clear_rules_interactive() { return 1; }
expect_fail delete_rule_interactive
unset -f load_rules_from_conf assert_loaded_config_safe list_rules read_or_cancel clear_rules_interactive

expect_ok finish_health_check 0 1 check >/dev/null 2>&1
expect_fail finish_health_check 0 1 strict >/dev/null 2>&1
expect_fail finish_health_check 1 0 check >/dev/null 2>&1
expect_ok finish_health_check 0 0 strict >/dev/null 2>&1

CLI_MODE="menu"
expect_ok handle_cli_args --check-strict
[[ "$CLI_MODE" == "check-strict" ]] || fail '--check-strict did not select strict mode'
[[ "$SCRIPT_VERSION" == "2.2.3" ]] || fail 'unexpected script version'
help_out="$(print_help)"
grep -Fq "$CONF_FILE" <<< "$help_out" || fail 'help omitted managed conf path'
grep -Fq "$SYSCTL_FILE" <<< "$help_out" || fail 'help omitted sysctl path'
grep -Fq "$TXN_MARKER" <<< "$help_out" || fail 'help omitted transaction marker path'
grep -Fq '不会自动改动' <<< "$help_out" || fail 'help omitted non-touch summary'
grep -Fq '添加规则时可选择启用 nftables.service' <<< "$help_out" \
    || fail 'help omitted optional nftables enable note'

systemctl() {
    [[ "$1" == "is-enabled" ]] && return 1
    return 0
}
read_or_cancel() { printf -v "$1" '%s' ''; }
NFT_WANT_ENABLE=1
expect_ok plan_nftables_enable_for_add
[[ "$NFT_WANT_ENABLE" == "0" ]] || fail 'empty answer should leave nftables enable off'
read_or_cancel() { printf -v "$1" '%s' 'y'; }
expect_ok plan_nftables_enable_for_add
[[ "$NFT_WANT_ENABLE" == "1" ]] || fail 'y should request nftables enable'
systemctl() {
    [[ "$1" == "is-enabled" ]] && return 0
    return 0
}
NFT_WANT_ENABLE=1
expect_ok plan_nftables_enable_for_add
[[ "$NFT_WANT_ENABLE" == "0" ]] || fail 'already-enabled nftables should skip prompt'
unset -f systemctl read_or_cancel
NFT_WANT_ENABLE=0

del_idxs=()
expect_ok parse_rule_delete_selection '1,3 5' 5 del_idxs
[[ "${del_idxs[*]}" == "0 2 4" ]] || fail 'comma/space multi-select parse failed'
expect_ok parse_rule_delete_selection '3 1 3' 5 del_idxs
[[ "${del_idxs[*]}" == "0 2" ]] || fail 'delete selection did not dedupe/sort'
expect_ok parse_rule_delete_selection '1，2' 5 del_idxs
[[ "${del_idxs[*]}" == "0 1" ]] || fail 'fullwidth comma parse failed'
# 空格 + 英文逗号 + 中文逗号任意混用；3+ 展开为 3、4
expect_ok parse_rule_delete_selection $'1, 2\xef\xbc\x8c3+ 5' 5 del_idxs
[[ "${del_idxs[*]}" == "0 1 2 3 4" ]] || fail 'mixed space/comma/fullwidth-comma parse failed'
expect_ok parse_rule_delete_selection '3+' 5 del_idxs
[[ "${del_idxs[*]}" == "2 3" ]] || fail 'n+ parse failed'
expect_ok parse_rule_delete_selection '3-' 5 del_idxs
[[ "${del_idxs[*]}" == "1 2" ]] || fail 'n- parse failed'
expect_ok parse_rule_delete_selection '2+ 5-' 5 del_idxs
[[ "${del_idxs[*]}" == "1 2 3 4" ]] || fail 'mixed n+/n- parse failed'
boundary_err="$(mktemp)"
expect_ok parse_rule_delete_selection '1-' 5 del_idxs >"$boundary_err"
[[ "${del_idxs[*]}" == "0" ]] || fail '1- boundary should keep only first'
grep -Fq '仅保留 1' "$boundary_err" || fail '1- boundary warning missing'
expect_ok parse_rule_delete_selection '5+' 5 del_idxs >"$boundary_err"
[[ "${del_idxs[*]}" == "4" ]] || fail '5+ boundary should keep only last'
grep -Fq '仅保留 5' "$boundary_err" || fail '5+ boundary warning missing'
expect_ok parse_rule_delete_selection '1+' 1 del_idxs >"$boundary_err"
[[ "${del_idxs[*]}" == "0" ]] || fail 'single-rule 1+ should keep only item 1'
rm -f "$boundary_err"
expect_fail parse_rule_delete_selection '1,all' 5 del_idxs >/dev/null
expect_fail parse_rule_delete_selection '9' 5 del_idxs >/dev/null
expect_fail parse_rule_delete_selection '0' 5 del_idxs >/dev/null
expect_fail parse_rule_delete_selection '9+' 5 del_idxs >/dev/null


attn_src="$(declare -f environment_needs_attention)"
grep -Fq 'runtime_rules_match_loaded_config' <<< "$attn_src" \
    && fail 'environment_needs_attention still depends on runtime rule matching'
grep -Fq 'main_conf_has_include' <<< "$attn_src" \
    || fail 'environment_needs_attention should check include'

expect_ok ipv4_is_rfc1918 10.0.0.1
expect_ok ipv4_is_rfc1918 192.168.1.1
expect_ok ipv4_is_rfc1918 172.16.0.1
expect_fail ipv4_is_rfc1918 203.0.113.10
expect_fail ipv4_is_rfc1918 127.0.0.1

legacy_masq='        ct status dnat ct original ip daddr 10.42.0.16 ct original proto-dst 3146 ip daddr 21.11.17.16 tcp dport 31046 masquerade'
normalized_masq="$(normalize_runtime_nft_dump <<< "$legacy_masq")"
[[ "$normalized_masq" == *'meta l4proto tcp ct original proto-dst 3146'* ]] \
    || fail 'normalize_runtime_nft_dump did not inject meta l4proto for tcp'
legacy_udp='        ct status dnat ct original ip daddr 10.42.0.16 ct original proto-dst 3146 ip daddr 21.11.17.16 udp dport 31046 masquerade'
normalized_udp="$(normalize_runtime_nft_dump <<< "$legacy_udp")"
[[ "$normalized_udp" == *'meta l4proto udp ct original proto-dst 3146'* ]] \
    || fail 'normalize_runtime_nft_dump did not inject meta l4proto for udp'
already_ok='        ct status dnat ct original ip daddr 10.42.0.16 meta l4proto tcp ct original proto-dst 3146 ip daddr 21.11.17.16 tcp dport 31046 masquerade'
[[ "$(normalize_runtime_nft_dump <<< "$already_ok")" == "$already_ok" ]] \
    || fail 'normalize_runtime_nft_dump altered a complete rule'

nft() {
    printf '%s\n' 'Error: syntax error' >&2
    return 1
}
run_out="$(run_nft -c -f /dev/null 2>&1)" || true
grep -Fq 'Error: syntax error' <<< "$run_out" || fail 'run_nft did not surface nft stderr'
unset -f nft

guidance="$(show_config_error_guidance)"
grep -Fq "$TXN_MARKER" <<< "$guidance" || fail 'diagnostic guidance omitted transaction marker'
grep -Fq "$TXN_CANDIDATE" <<< "$guidance" || fail 'diagnostic guidance omitted candidate file'
grep -Fq "$TXN_ROLLBACK" <<< "$guidance" || fail 'diagnostic guidance omitted rollback file'
grep -Fq '不要单独删除' <<< "$guidance" || fail 'diagnostic guidance omitted transaction safety warning'

read_or_cancel() { printf -v "$1" '%s' '2'; }
expect_ok config_error_menu >/dev/null
unset -f read_or_cancel

startup_diagnostic_entered=0
check_bash_version() { return 0; }
handle_cli_args() { CLI_MODE=menu; }
check_root() { return 0; }
check_cmds() { return 0; }
acquire_lock() { return 0; }
release_lock() { return 0; }
managed_config_needs_diagnostic() { return 0; }
run_config_error_mode() { startup_diagnostic_entered=1; }
ensure_dirs() { fail 'startup touched managed directories before diagnostic mode'; }
maybe_first_run_setup() { fail 'startup attempted repair before diagnostic mode'; }
menu() { fail 'normal menu opened for invalid managed config'; }
expect_ok main
[[ "$startup_diagnostic_entered" == "1" ]] || fail 'startup did not enter diagnostic mode'
trap - EXIT
rm -f "$tmp" "$invalid_tmp" "$sysctl_tmp"

printf 'PASS: nft-portfwd offline unit tests\n'
