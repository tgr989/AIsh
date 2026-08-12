# aish

Utility scripts for Linux server operations.

## Scripts

- `nft-portfwd.sh`: nftables port-forward manager (DNAT + MASQUERADE).
- `nft-neighbor-ban.sh`: nftables same-/24 neighbor ban (INPUT drop, keep self + gateway).
- `ssh_port_fix.sh`: SSH port hardening and config helper.
- `install_realm.sh`: realm proxy installer.

## nft-portfwd Quick Start

```bash
chmod +x ./nft-portfwd.sh
sudo ./nft-portfwd.sh
```

## Prerequisites

- Linux host with Bash 4.4+, `nftables`, `iproute2`, `util-linux` (`flock`) and standard core utilities
- `sysctl` command available
- Root privileges for rule write/apply operations

## CLI Options

```bash
./nft-portfwd.sh --help
./nft-portfwd.sh --version
./nft-portfwd.sh --check
./nft-portfwd.sh --check-strict
```

- Default behavior is interactive menu.
- `--help` and `--version` can run without root.
- `--check` fails only for current runtime/config faults; reboot-persistence gaps are warnings.
- `--check-strict` also treats persistence gaps as failures.
- On hosts without `systemctl`, the script cannot verify the boot-time nftables loader; this is a warning for `--check` and a failure for `--check-strict`.

## Safety Boundaries

- Core NAT rules only manage `table ip portfwd`.
- Every DNAT rule requires an explicit listen IPv4 address; transit traffic to unrelated destination addresses is not matched.
- An empty rule set does not require IPv4 forwarding, and clearing rules never disables the host-wide forwarding setting automatically.
- Does not auto-modify firewalld / ufw / iptables.
- Uses nftables as the sole firewall manager for these forwarding rules; no secondary firewall integration is included.
- This script manages NAT only. Existing filter/FORWARD policies, host firewalls, cloud security groups and upstream ACLs can still block forwarded traffic.
- After adding a rule, optionally offers `systemctl enable --now nftables` (default no). It does not otherwise start/reload/stop the generic `nftables.service`; choose one firewall owner and verify service ordering yourself.
- Persisted loading depends on `/etc/nftables.conf` including `"/etc/nftables.d/*.conf"`.
- Reloads are idempotent and atomically delete/recreate only the owned `table ip portfwd`; an ownership sentinel prevents taking over an unrelated table with the same name.
- Health checks compare the complete runtime chain/rule expressions with the managed configuration and reject unsafe config ownership or permissions.
- Startup only nags about items menu `4` can fix (config / include / `ip_forward`). Runtime expression drift is reported by `--check`, not by a repeated first-run prompt.
- This is a fresh-deployment-only script: it does not migrate or take ownership of an existing unmarked `table ip portfwd` or an older config format.

## Listen IPv4 and Cloud NAT

- Listen IPv4 is the destination address of packets **after they arrive on this host** (`ip daddr`), not necessarily the public address clients dial.
- On many cloud VPS designs the public IPv4 is 1:1 NAT and never appears on a local NIC; only the private address is listed. In that case choose the private listen IP.
- The add-rule prompt lists local global IPv4 addresses by number, defaults to the first RFC1918 address when present, and still accepts a typed address (with confirmation if it is not currently local).

## Source CIDR and Rule Scope

- Source defaults to `0.0.0.0/0`.
- CIDRs must use a canonical network address: `203.0.113.0/24` is valid, while `203.0.113.7/24` is rejected (`203.0.113.7/32` is valid).
- Rules with the same listen IP, port, protocol and overlapping interface scope conflict even when their source CIDRs differ. Source-based dispatch to different backends is intentionally unsupported.

## Typical Workflow

1. First launch offers environment fix only when config / include / `ip_forward` need attention (or use option `4`).
2. Option `1` to add a forward (listen IPv4 by menu/default or typed address, destination `IP:port`, optional source CIDR/interface, protocol default both).
3. Option `2` to list rules (optional raw nft view).
4. Option `3` to delete by list number (or `all` to clear).

If an existing managed configuration fails ownership or integrity validation, startup enters read-only diagnostic mode before attempting environment repair. Add, list and delete actions remain hidden until a trusted configuration is restored or a fresh deployment is manually reinitialized.

The IPv4-forwarding persistence check follows `sysctl.d` directory precedence and filename order. Earlier assignments and repeated assignments whose final effective value is still `1` do not cause a strict-check failure.

## Useful Commands

```bash
# script health
sudo ./nft-portfwd.sh --check
sudo ./nft-portfwd.sh --check-strict

# rules
nft list table ip portfwd
nft -nn list table ip portfwd
grep -E 'RULE:|RULE-MASQ:' /etc/nftables.d/portfwd.conf
nft -c -f /etc/nftables.d/portfwd.conf

# forwarding / persistence
sysctl net.ipv4.ip_forward
cat /etc/sysctl.d/99-portfwd-ip-forward.conf
grep -nE 'include.*/etc/nftables\.d' /etc/nftables.conf

# enable boot load only after confirming nftables is the sole firewall owner
systemctl enable --now nftables
systemctl status nftables
nft list ruleset

# troubleshooting
ip -4 addr show scope global
ss -lntup
systemctl is-active firewalld 2>/dev/null; ufw status 2>/dev/null
```

## Rollback / Recovery

- Runtime and disk updates use a transaction marker plus a pre-generated nft rollback file.
- A failed nft batch leaves the previous runtime and disk configuration untouched.
- If the process is interrupted between runtime and disk commit, the next interactive start automatically rolls back or rolls forward to a consistent state.
- Failed candidate validation keeps `/etc/nftables.d/.portfwd.conf.new` for inspection and prints the raw `nft` error.

Validate configuration before applying manually:

```bash
nft -c -f /etc/nftables.conf
```

## nft-neighbor-ban Quick Start

```bash
chmod +x ./nft-neighbor-ban.sh
sudo ./nft-neighbor-ban.sh              # menu
sudo ./nft-neighbor-ban.sh enable -y    # one-shot ban same /24 neighbors
sudo ./nft-neighbor-ban.sh status
sudo ./nft-neighbor-ban.sh disable -y
```

Optional overrides:

```bash
sudo ./nft-neighbor-ban.sh enable --iface eth0 --ip 203.0.113.10 --gateway 203.0.113.1
sudo ./nft-neighbor-ban.sh enable --allow 203.0.113.50 -y
sudo ./nft-neighbor-ban.sh enable --dry-run
```

Notes:

- Manages only `table inet neighbor_ban` (INPUT filter); does not touch `portfwd` NAT rules.
- Always accepts self; accepts gateway only when it is inside the target /24; then drops the rest of that NIC's /24.
- Warns if the current SSH client sits in the target /24 without `--allow`; with `-y` this is refused until `--allow` is set.
- Persisted conf uses `destroy table` (or `add`+`delete` on older nft) so reloads replace the table instead of appending rules.
- Persists to `/etc/nftables.d/neighbor-ban.conf`; reboot persistence still needs `/etc/nftables.conf` include + `nftables.service`.

Run the offline unit checks with:

```bash
bash ./nft-portfwd.test.sh
bash ./nft-neighbor-ban.test.sh
```
