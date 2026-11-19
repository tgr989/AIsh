# aish

Operational shell scripts for Linux servers. The nftables tools are deliberately scoped: each manager owns named tables and avoids taking over unrelated firewall state.

## Script inventory

| Script | Purpose |
| --- | --- |
| `nft-portfwd.sh` | IPv4/IPv6 port-forward manager using DNAT + MASQUERADE. |
| `nft-portfwd-snat.sh` | IPv4/IPv6 port-forward manager using DNAT + static SNAT. |
| `nft-portfwd-migrate-to-snat.sh` | In-place migration from the managed MASQUERADE configuration to static SNAT. |
| `nft-neighbor-ban.sh` | Block same-/24 neighbors from reaching the host while keeping self and gateway access. |
| `ssh_port_fix.sh` | Validate and update the OpenSSH listening port. |
| `install_realm.sh` | Install or update the Realm relay binary and service. |
| `deploy_xray.sh` | Interactive Xray deployment for VLESS REALITY and Shadowsocks 2022. |

The `*.test.sh` files are offline regression tests for the corresponding nftables tools.

## Port-forwarding variants

Both port-forward managers share the same managed identity:

```text
table ip portfwd     (IPv4)
table ip6 portfwd    (IPv6)
/etc/nftables.d/portfwd.conf
/run/nft-portfwd/lock
# MANAGED-BY: nft-portfwd v2
```

Choose one active manager for a host. Do not alternate between the MASQUERADE and SNAT scripts against the same configuration.

| Behavior | `nft-portfwd.sh` | `nft-portfwd-snat.sh` |
| --- | --- | --- |
| Source NAT action | `masquerade` | `snat to $LOCAL_IP` (IPv4) or `snat to $LOCAL_IP6` (IPv6) |
| Address selection | Dynamic, based on the actual egress interface | Static, detected from the default route and stored in the config |
| Address changes | Followed automatically by MASQUERADE | Detected by health check; menu `4` can resubmit the existing rules |
| Typical fit | Dynamic addresses or multiple egress paths | Stable, single-egress VPS routing |
| Backend sees real client IP | No | No |

Both variants match the listen address, port, protocol, optional ingress interface and optional source prefix. Select a backend using `IPv4:port`, `[IPv6]:port`, or a hostname such as `nas.example.net:443`. Each rule forwards within one address family (IPv4 NAT or NAT66). Both families can use the same port in the same configuration.

When you add a hostname target, the script queries the system resolver with `getent ahosts`. Choose an address when the resolver returns multiple usable results. The selected IP determines the rule's address family and is saved in the configuration. If the hostname later resolves to a different IP, recreate the rule to select the new address.

## Requirements

- Linux with Bash 4.4+
- Root privileges for menu, health-check and migration operations
- `nftables`, `iproute2`, `procps` (`sysctl`) and `util-linux` (`flock`)
- Standard GNU/Linux tools used by the scripts (`grep`, `stat`, `install`, `mktemp`, `cmp`, and related core utilities)
- Hostname targets require `getent` with the `ahosts` database
- `systemctl` is optional, but without it boot-time nftables loading cannot be verified

The managers do not install these dependencies automatically.

## Fresh deployment

MASQUERADE:

```bash
chmod 0755 ./nft-portfwd.sh
sudo ./nft-portfwd.sh
```

Static SNAT:

```bash
chmod 0755 ./nft-portfwd-snat.sh
sudo ./nft-portfwd-snat.sh
```

CLI options:

```bash
./nft-portfwd.sh --help
./nft-portfwd.sh --version
sudo ./nft-portfwd.sh --check
sudo ./nft-portfwd.sh --check-strict

./nft-portfwd-snat.sh --help
./nft-portfwd-snat.sh --version
sudo ./nft-portfwd-snat.sh --check
sudo ./nft-portfwd-snat.sh --check-strict
```

- No argument opens the interactive menu.
- `--help` and `--version` do not require root.
- `--check` fails for runtime or managed-config faults; persistence gaps are warnings.
- `--check-strict` also treats persistence gaps as failures.
- Health checks are read-only and do not probe every destination.

## Rule model

Managed rule metadata has seven required fields and an optional final name.

```text
listen_ip|listen_port|protocol|destination_ip|destination_port|ingress_interface|source_cidr[|name]
```

Example using documentation-only addresses:

```text
192.0.2.10|8443|tcp|10.0.0.8|443|eth0|203.0.113.0/24
2001:db8:1::10|8443|tcp|fd00:2::8|443|eth0|2001:db8:3::/64|Home NAS
```

This produces a DNAT rule scoped to the original listen address and an associated source-NAT rule scoped to the same original connection tuple. TCP and UDP are stored as separate rules; selecting `both` creates one rule for each protocol.

Names can contain spaces and Unicode. Use a single line and omit `|` and control characters. Existing seven-field rules appear as unnamed. When you add TCP and UDP together, both rules receive the name you enter.

Rules with the same listen address, port and protocol cannot have overlapping ingress-interface scope, even if their source CIDRs differ. Source-based dispatch to different backends is intentionally unsupported.

Source CIDRs must be canonical network addresses. `203.0.113.0/24` and `203.0.113.7/32` are valid; `203.0.113.7/24` is rejected. IPv6 accepts network prefixes such as `2001:db8:3::/64` and individual sources such as `2001:db8::7/128`. The unrestricted defaults are `0.0.0.0/0` and `::/0`. IPv6 input is stored in compressed lowercase form.

## Listen addresses and cloud NAT

Use the destination address as it appears on the VPS ingress interface (`ip daddr` or `ip6 daddr`).

Many cloud providers implement public 1:1 NAT outside the guest. If the public address does not appear in `ip -4 addr`, select the private address that actually exists on the VPS. The add-rule prompt lists local addresses of the backend’s family with global scope and accepts a typed address after confirmation.

## Static SNAT addresses

A dual-stack configuration defines two nftables variables. Each active family needs its own egress address.

```nft
define LOCAL_IP = 192.0.2.10
define LOCAL_IP6 = 2001:db8:1::10
```

Postrouting rules use `snat to $LOCAL_IP` for IPv4 and `snat to $LOCAL_IP6` for IPv6. nftables expands each variable when it loads the file. The kernel listing shows the concrete address.

The script looks up the route-selected source for each address family in use.

```bash
ip -4 route get 1.1.1.1
ip -6 route get 2606:4700:4700::1111
```

If route lookup yields no usable source, the script selects a usable global-scope address on a non-loopback interface of the same family. IPv6-only rules require only an IPv6 egress address.

Static means the stored value does not update by itself. If the address changes, `--check` reports the mismatch. Menu `4` can confirm and atomically resubmit the existing rules with the current address.

## In-place migration: MASQUERADE to static SNAT

Migration is for an existing v2 configuration created by `nft-portfwd.sh`. It preserves:

- the managed `ip portfwd` and/or `ip6 portfwd` tables
- `/etc/nftables.d/portfwd.conf`
- the lock and transaction paths
- all `# RULE:` metadata, including optional names
- listen/destination addresses, ports, protocols, interfaces and source CIDRs

Migration replaces each `masquerade` action with `snat to $LOCAL_IP` or `snat to $LOCAL_IP6` according to the rule’s address family.

### Download a consistent tool set

All three files must come from the same commit or release. Pinning `REV` avoids mixing versions or receiving different branch-cache snapshots:

```bash
REV="<commit-or-tag>"
BASE="https://raw.githubusercontent.com/tgr989/AIsh/${REV}"

for file in \
  nft-portfwd.sh \
  nft-portfwd-snat.sh \
  nft-portfwd-migrate-to-snat.sh
do
  curl -fsSL "${BASE}/${file}" -o "${file}" || exit 1
done

chmod 0755 \
  nft-portfwd.sh \
  nft-portfwd-snat.sh \
  nft-portfwd-migrate-to-snat.sh

bash -n \
  nft-portfwd.sh \
  nft-portfwd-snat.sh \
  nft-portfwd-migrate-to-snat.sh
```

Run the migration:

```bash
sudo bash ./nft-portfwd-migrate-to-snat.sh
```

For pre-approved unattended execution:

```bash
sudo bash ./nft-portfwd-migrate-to-snat.sh --yes
```

### Migration safety model

The migration tool:

1. Acquires the same exclusive lock as both managers.
2. Validates the current file with the MASQUERADE script and refuses drifted or unsafe input.
3. Detects the egress address for each family in use, renders a SNAT candidate and validates it with the SNAT script and `nft -c -f`.
4. Creates a rollback ruleset and a permanent copy of the old MASQUERADE configuration.
5. Loads the candidate with `nft -f`, which applies the file as an atomic nftables transaction.
6. Verifies the managed table, ownership sentinel, prerouting/postrouting chains, and rule counts. Table/chain handles are not counted as rules.
7. Replaces the formal disk configuration only after the runtime checks pass.

If a hard check fails, the old MASQUERADE runtime is restored and the disk configuration is unchanged.

Different nftables releases may print equivalent rules differently. In that case migration can show:

```text
[WARN] SNAT 运行态展示文本与候选配置不完全一致。
[WARN] 检测到 nftables 等价展示格式差异；原子加载及受管表/链校验均已通过，继续提交。
```

This warning alone is not a migration failure. Missing tables/chains, a missing ownership sentinel, a rule-count mismatch, candidate validation failure, or `nft -f` failure remains fatal and triggers rollback.

The formatting exception is limited to the migration transaction immediately after its own candidate was atomically loaded. Normal `nft-portfwd-snat.sh --check` remains strict: a later expression mismatch cannot safely be assumed to be formatting-only merely because the number of rules is unchanged.

### After migration

Verify the stored and runtime rules:

```bash
grep -E 'define LOCAL_IP|RULE:|RULE-SNAT:|snat to' /etc/nftables.d/portfwd.conf
nft -nn list table ip portfwd    # IPv4
nft -nn list table ip6 portfwd   # IPv6
sudo ./nft-portfwd-snat.sh --check
```

The runtime listing shows the address stored in the corresponding `LOCAL_IP` or `LOCAL_IP6` definition. New connections use static SNAT immediately. Connections that already existed may retain their previous conntrack NAT mapping until they close or expire.

If the ordinary SNAT health check reports an expression mismatch, preserve the full `nft -nn list table` output for the affected family for review instead of editing the managed file or transaction artifacts by hand.

After confirming forwarding works, stop using the MASQUERADE manager. The migration tool prints this optional cleanup command but never runs it automatically:

```bash
rm nft-portfwd-migrate-to-snat.sh nft-portfwd.sh
```

Keep `nft-portfwd-snat.sh`. The permanent pre-migration backup is reported in the successful migration output.

## Interactive workflow

1. Menu `1` adds a forward with an optional name. Enter the backend, such as `[2001:db8::8]:443` or `nas.example.net:443`, and select a listen address of the same family, the protocol, and any source or ingress restrictions.
2. Menu `2` lists managed rules and their names. It can also display the raw nftables table.
3. Menu `3` deletes rules by list number and shows their names before confirmation. You can select multiple rules with spaces, commas, or `n+`/`n-`. Enter `all` to clear all rules.
4. Menu `4` checks IP forwarding and offers to restore missing or drifted managed tables from the saved configuration. It can also configure boot loading with confirmation and then runs the strict health check. The SNAT version offers to refresh changed egress addresses.
5. Menu `5` edits a rule's saved name by list number. Submit a blank name to clear it. This saves the configuration metadata without reloading nftables.

An invalid managed configuration places startup in read-only diagnostic mode. Mutation actions remain unavailable until a trusted configuration is restored or the deployment is manually reinitialized.

## Safety boundaries

- IPv4 uses `table ip portfwd` and IPv6 uses `table ip6 portfwd`. Both share one file, lock and transaction. Once a table has been managed, deleting its last rule rebuilds the table with empty NAT chains. Existing IPv4 v2 files load without conversion.
- An ownership sentinel prevents taking over an unrelated table with the same name.
- Configuration, lock and transaction files are checked for safe owner/mode and symbolic-link misuse.
- `flock` serializes managers and migration operations.
- Candidate configurations are validated before loading.
- Runtime and disk commits use a marker plus a pre-generated rollback file for crash recovery.
- Existing firewalld, UFW, iptables, BBR settings and unrelated nftables tables are not modified.
- The scripts manage NAT, not filter/FORWARD policy. Host firewalls, cloud security groups and upstream ACLs can still block traffic.
- Adding a rule offers to enable the corresponding forwarding switch. Clearing rules preserves the operating system’s forwarding settings. IPv4 and IPv6 use separate sysctl drop-ins.
- If the IPv6 default route comes from router advertisements, configure `accept_ra=2` on the uplink to keep learning the route with forwarding enabled. The manager leaves RA settings to the operator. [Linux IP sysctl documentation](https://docs.kernel.org/networking/ip-sysctl.html)
- Boot enablement for `nftables.service` requires confirmation and defaults to no. The manager enables the unit for boot after verifying its configuration path and include.

Boot persistence requires `/etc/nftables.conf` to contain:

```nft
include "/etc/nftables.d/*.conf"
```

## Transactions and recovery

Normal rule updates use these temporary paths:

```text
/etc/nftables.d/.portfwd.conf.new
/etc/nftables.d/.portfwd.rollback.nft
/etc/nftables.d/.portfwd.transaction
```

The candidate is checked before loading, the previous runtime is captured before mutation, and the formal config is replaced only after runtime loading succeeds. If interruption occurs between runtime and disk commit, the next interactive start uses the transaction marker to roll backward or forward to a consistent state.

Do not manually delete only one transaction file. If automatic recovery fails, preserve all three files and inspect them together with the current table.

## Useful commands

```bash
# health
sudo ./nft-portfwd.sh --check
sudo ./nft-portfwd.sh --check-strict
sudo ./nft-portfwd-snat.sh --check
sudo ./nft-portfwd-snat.sh --check-strict

# managed config and runtime
nft -nn list table ip portfwd
nft -nn list table ip6 portfwd
grep -E 'RULE:|RULE-MASQ:|RULE-SNAT:' /etc/nftables.d/portfwd.conf
nft -c -f /etc/nftables.d/portfwd.conf

# forwarding and persistence
sysctl net.ipv4.ip_forward net.ipv6.conf.all.forwarding
cat /etc/sysctl.d/99-portfwd-ip-forward.conf
cat /etc/sysctl.d/99-portfwd-ipv6-forward.conf
grep -nE 'include.*/etc/nftables\.d' /etc/nftables.conf

# enable boot loading only after confirming firewall ownership
systemctl enable nftables
systemctl status nftables
nft list ruleset

# troubleshooting
ip -4 route get 1.1.1.1
ip -4 addr show scope global
ip -6 addr show scope global
ss -lntup
systemctl is-active firewalld 2>/dev/null
ufw status 2>/dev/null
```

## Neighbor-ban quick start

```bash
chmod 0755 ./nft-neighbor-ban.sh
sudo ./nft-neighbor-ban.sh
sudo ./nft-neighbor-ban.sh enable -y
sudo ./nft-neighbor-ban.sh status
sudo ./nft-neighbor-ban.sh disable -y
```

Optional overrides:

```bash
sudo ./nft-neighbor-ban.sh enable --iface eth0 --ip 203.0.113.10 --gateway 203.0.113.1
sudo ./nft-neighbor-ban.sh enable --allow 203.0.113.50 -y
sudo ./nft-neighbor-ban.sh enable --dry-run
```

The tool only manages `table inet neighbor_ban` and does not touch the port-forward NAT table. It accepts the host address, accepts the gateway when the gateway is inside the target /24, applies explicitly allowed addresses, then drops the rest of that interface's /24. It refuses unattended activation when the current SSH client would be blocked unless `--allow` is supplied.

Persistence uses `/etc/nftables.d/neighbor-ban.conf` and has the same `/etc/nftables.conf` include and `nftables.service` requirements.

## SSH port helper

`ssh_port_fix.sh` updates active `Port` directives, validates the resulting OpenSSH configuration and restores its backups if `sshd -t` or the effective-port assertion fails.

```bash
# Preview only
sudo bash ./ssh_port_fix.sh --dry-run --port 34253

# Update /etc/ssh/sshd_config without reloading the service
sudo bash ./ssh_port_fix.sh --port 34253 --no-reload

# Update and reload sshd (falls back to restart when reload fails)
sudo bash ./ssh_port_fix.sh --port 34253 --reload

# Also process /etc/ssh/sshd_config.d/*.conf
sudo bash ./ssh_port_fix.sh --port 34253 --with-sshd-config-d --reload

# Process only the drop-in directory
sudo bash ./ssh_port_fix.sh --port 34253 --only-sshd-config-d --reload
```

Keep the current SSH session open until a second session has connected to the new port. The helper does not open the new port in a host firewall or cloud security group.

## Realm installer

`install_realm.sh` downloads a Realm release for the detected architecture, writes a TOML configuration and manages a systemd service. The latest GitHub release is used unless `--version` pins a tag.

```bash
sudo ./install_realm.sh install \
  --endpoint 0.0.0.0:23456 example.net:23456 \
  --endpoint 0.0.0.0:54321 192.0.2.20:443

sudo ./install_realm.sh install \
  --version vX.Y.Z \
  --udp true \
  --no-tcp false \
  --musl auto

sudo ./install_realm.sh uninstall
```

Relevant overrides are `--config`, `--bin-dir`, `--service`, `--version` and `--musl`. Repeating `--endpoint LISTEN REMOTE` adds mappings. Review the generated service and `/etc/realm/config.toml` before exposing listeners publicly.

## Xray deployment

`deploy_xray.sh` supports these interactive modes:

- `dual`: VLESS-TCP-REALITY plus Shadowsocks 2022
- `vless`: VLESS-TCP-REALITY only
- `ss`: Shadowsocks 2022 only

Supported systems are Debian 12/13 and Ubuntu 24.04/26.04 with systemd. Run:

```bash
sudo bash ./deploy_xray.sh
```

Prompts can be prefilled with `DEPLOY_MODE`, `SERVER_ADDRESS`, `VLESS_PORT`, `SS_PORT`, `REALITY_SERVER_NAME`, `REALITY_TARGET_PORT`, `FALLBACK_PORT` and `SS_METHOD`. Port inputs accept `random` or `r` and are checked for TCP/UDP conflicts.

The script resolves the selected `XTLS/Xray-install` commit through the GitHub API, downloads `install-release.sh`, verifies its Git blob SHA and then invokes the installer. `INSTALLER_REF` can pin a branch, tag or commit. The generated Xray configuration is syntax-tested before commit, previous configuration/service state is backed up for rollback, and credentials/share links are displayed once rather than saved in the summary.

The Xray deployer does not modify host firewall or cloud security-group rules. Manually allow the displayed TCP/UDP ports after reviewing the deployment.

## Offline tests

The tests do not modify the host firewall:

```bash
bash ./nft-portfwd.test.sh
bash ./nft-portfwd-snat.test.sh
bash ./nft-portfwd-ipv6.test.sh
bash ./nft-portfwd-migrate-to-snat.test.sh
bash ./nft-neighbor-ban.test.sh
```
