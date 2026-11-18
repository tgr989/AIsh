#!/bin/bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
conf="$(mktemp)"
bad_conf="$(mktemp)"
trap 'rm -f "$conf" "$bad_conf"' EXIT
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail "unexpected success: $*"; fi; }

v4='192.0.2.10|8443|tcp|10.0.0.2|443|eth0|0.0.0.0/0'
v6='2001:db8::10|8443|tcp|fd00:2::2|443|eth0|2001:db8:3::/64'
udp6='2001:db8::10|8443|udp|fd00:2::2|443|*|::/0'
rule_name='家庭 NAS # HTTPS'
named_v6="$v6|$rule_name"

for script in nft-portfwd.sh nft-portfwd-snat.sh; do (
    source "$script_dir/$script"
    (
        # 地址和前缀解析在找不到外部程序时也应工作。
        PATH=/dev/null
        parse_target '[2001:0DB8:0:0::ABCD]:65535' dip dport
        [[ "$dip" == 2001:db8::abcd && "$dport" == 65535 ]] || fail 'IPv6 endpoint normalization'
        [[ "$(normalize_ip ip6 '2001:0:0:1:0:0:2:3')" == 2001::1:0:0:2:3 ]] || fail 'equal zero runs'
        [[ "$(normalize_ip ip6 '2001:db8::1:2:3:4:5')" == 2001:db8:0:1:2:3:4:5 ]] || fail 'single zero group'
        [[ "$(normalize_ip ip6 '64:ff9b::192.0.2.1')" == 64:ff9b::c000:201 ]] || fail 'dotted IPv4 tail'
        [[ "$(normalize_ip ip6 '::c000:0201')" == ::192.0.2.1 ]] || fail 'legacy IPv4-compatible spelling'
        for target in '2001:db8::a:443' '[192.0.2.1]:443' '[::1]:443' '[::]:443' '[fe80::1%eth0]:443' \
                      '[febf::1]:443' '[ff02::1]:80' '[::ffff:192.0.2.1]:80' '[2001:db8::1]:65536' \
                      '[1::2::3]:80' '[1:::2]:80' '[1:2:3:4:5:6:7::8]:80' '[64:ff9b::192.0.02.1]:80'; do
            expect_fail parse_target "$target" dip dport
        done
        [[ "$(normalize_ip ip6 '0:0:0:0:0:0:0:0/0' cidr)" == '::/0' ]] || fail 'default IPv6 prefix'
        [[ "$(normalize_ip ip6 '2001:0DB8::/64' cidr)" == '2001:db8::/64' ]] || fail 'IPv6 prefix'
        [[ "$(normalize_ip ip6 '2001:db8:0:0:8000::/65' cidr)" == '2001:db8:0:0:8000::/65' ]] || fail 'partial group prefix'
        [[ "$(normalize_ip ip6 'fd00::a/128' cidr)" == 'fd00::a/128' ]] || fail 'host prefix'
        [[ "$(normalize_ip ip6 '::ffff:c000:0201/128' cidr)" == '::ffff:192.0.2.1/128' ]] \
            || fail 'legacy mapped prefix spelling'
        for cidr in '2001:db8::a/64' '2001:db8:0:0:8001::/65' '2001:db8::/064' \
                    'fd00::/129' 'fd00::' '0.0.0.0/0' 'fe80::%eth0/64'; do
            expect_fail normalize_ip ip6 "$cidr" cidr
        done
    )

    RULES=("$v4" "$named_v6" "$udp6")
    SNAT_IP=192.0.2.10 SNAT_IP6=2001:db8::10
    render_conf_file "$conf"
    grep -Fq 'iifname "eth0" ip6 daddr 2001:db8::10 ip6 saddr 2001:db8:3::/64 tcp dport 8443 dnat to [fd00:2::2]:443' "$conf"
    grep -Fq 'ct original ip6 daddr 2001:db8::10 meta l4proto tcp ct original proto-dst 8443 ct original ip6 saddr 2001:db8:3::/64 ip6 daddr fd00:2::2 tcp dport 443' "$conf"
    grep -Fq 'ip6 daddr 2001:db8::10 udp dport 8443 dnat to [fd00:2::2]:443' "$conf"
    load_rules_from_conf "$conf"
    [[ "${RULES[*]}" == "$v4 $named_v6 $udp6" ]] || fail 'mixed named and legacy configuration round trip'
    listing="$(sed -n '/^table ip6 portfwd {$/,$p' "$conf" | sed '/^[[:space:]]*#/d')"
    listing="${listing//\$LOCAL_IP6/$SNAT_IP6}"
    listing="${listing//ct status dnat/ct status 0x20}"
    listing="${listing//dnat to/dnat ip6 to}"
    listing="$(normalize_runtime_nft_dump ip6 <<< "$listing")"
    runtime_rules_match_loaded_config "$listing" ip6 || fail 'IPv6 runtime formatting'
    expect_fail runtime_rules_match_loaded_config "${listing/2001:db8:3::\/64/2001:db8:4::\/64}" ip6
    expect_fail runtime_rules_match_loaded_config "${listing/\[fd00:2::2\]:443/[fd00:2::3]:443}" ip6
    host_match="$(normalize_runtime_nft_dump ip6 <<< 'ct original ip6 saddr fd00::5/128 ip6 daddr fd00::2')"
    [[ "$host_match" == 'ct original ip6 saddr fd00::5 ip6 daddr fd00::2' ]] || fail 'IPv6 host prefix normalization'
    rule_conflicts "$(normalize_ip ip6 '2001:0DB8:0:0::10')" 8443 tcp eth0 || fail 'equivalent listen address'
    expect_fail rule_conflicts 2001:db8::10 8443 tcp eth1

    sed 's/fd00:2::2/192.0.2.2/g' "$conf" > "$bad_conf"
    expect_fail load_rules_from_conf "$bad_conf"
    sed 's/2001:db8:3::\/64/192.0.2.0\/24/g' "$conf" > "$bad_conf"
    expect_fail load_rules_from_conf "$bad_conf"
    config_text="$(<"$conf")"
    printf '%s\n' "${config_text//"$rule_name"/bad|name}" > "$bad_conf"
    expect_fail load_rules_from_conf "$bad_conf"
    printf '%s\n' "${config_text//"$rule_name"/$'bad\tname'}" > "$bad_conf"
    expect_fail load_rules_from_conf "$bad_conf"

    load_rules_from_conf "$conf"
    RULES=("$v4")
    render_conf_file "$bad_conf"
    grep -Fqx 'delete table ip6 portfwd' "$bad_conf" || fail 'last IPv6 rule left behind'
    expect_fail grep -Fq 'ip6 daddr' "$bad_conf"
    load_rules_from_conf "$bad_conf"
    CONFIG_TABLES=()
    nft() { [[ "$*" == 'list tables' ]] && printf 'table ip6 portfwd\n'; }
    check_runtime_ownership || fail 'IPv4 configuration claimed an unrelated IPv6 table'
    RULES=("$v6")
    expect_fail check_runtime_ownership
    nft() { return 1; }
    expect_fail check_runtime_ownership

    if [[ "$script" == nft-portfwd-snat.sh ]]; then
        ip() {
            [[ "$*" == '-6 route get 2606:4700:4700::1111' ]] || return 1
            printf '%s\n' '2606:4700:4700::1111 dev eth0 src 2001:0DB8::9 metric 10'
        }
        refresh_snat_ip
        [[ -z "$SNAT_IP" && "$SNAT_IP6" == 2001:db8::9 ]] || fail 'IPv6-only SNAT detection'
        check_snat_ip_current ip6 >/dev/null
        render_conf_file "$conf"
        grep -Fqx 'define LOCAL_IP6 = 2001:db8::9' "$conf"
        grep -Fq 'snat to $LOCAL_IP6' "$conf"
        expect_fail grep -Fq 'define LOCAL_IP =' "$conf"
        sed '/^define LOCAL_IP6/d' "$conf" > "$bad_conf"
        expect_fail load_rules_from_conf "$bad_conf"
        SNAT_IP6=2001:db8::8
        expect_fail check_snat_ip_current ip6
        ip() {
            [[ "$*" == '-o -6 addr show scope global' ]] || return 1
            printf '%s\n' '2: eth0 inet6 fd00::1/64 scope global tentative' '2: eth0 inet6 fd00::2/64 scope global'
        }
        [[ "$(get_local_ip ip6)" == fd00::2 ]] || fail 'IPv6 egress fallback'
    fi

    # Exercise the add menu's family selection, normalization and CIDR default.
    RULES=()
    load_rules_from_conf() { CONFIG_LOAD_ERRORS=0; }
    ip() { printf '%s\n' '2: eth0 inet6 2001:db8::10/64 scope global'; }
    can_probe_tcp_connect() { return 1; }
    describe_local_port_occupancy() { return 1; }
    plan_ip_forward_for_add() { [[ "$1" == ip6 ]] || fail 'wrong forward plan'; }
    apply_ip_forward_plan() { [[ "$1" == ip6 ]] || fail 'wrong forward switch'; }
    plan_nftables_enable() { return 0; }
    commit_rules() { render_conf_file "$conf"; }
    show_persistence_hint() { return 0; }
    add_rule_interactive <<< $'3\n[fd00:2::2]:443\n8443\n2001:0DB8::10\n\nn\nbad|name\n家庭 NAS # HTTPS\ny' \
        > "$bad_conf" 2>&1
    grep -Fq "名称为「$rule_name」" "$bad_conf"
    [[ "${RULES[0]}" == "${udp6/|udp|/|tcp|}|$rule_name" && "${RULES[1]}" == "$udp6|$rule_name" ]] \
        || fail 'dual-protocol IPv6 naming'
    grep -Fqx 'table ip6 portfwd {' "$conf"
    expect_fail grep -Fqx 'table ip portfwd {' "$conf"
    list_rules > "$bad_conf"
    grep -Fq "$rule_name" "$bad_conf"
    delete_rule_interactive <<< $'1\nn' > "$bad_conf"
    grep -Fq "1. 「$rule_name」 tcp" "$bad_conf"
    [[ "${#RULES[@]}" == 2 ]] || fail 'cancelled named rule deletion changed the rule list'

    printf '%s\n' 'net.ipv4.ip_forward=0' 'net/ipv6/conf/all/forwarding = 1 # router' > "$bad_conf"
    [[ "$(last_ip_forward_assignment "$bad_conf" ip6)" == 1 ]] || fail 'IPv6 sysctl precedence'
    [[ "$(last_ip_forward_assignment "$bad_conf" ip)" == 0 ]] || fail 'IPv4 sysctl precedence'
    echo "PASS: $script IPv6 and mixed-family regression tests"
); done
