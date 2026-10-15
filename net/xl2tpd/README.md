# OpenWrt Package for xl2tpd

xl2tpd is a development from the original l2tpd package originally written by
Mark Spencer, subsequently forked by Scott Balmos and David Stipp, inherited
by Jeff McAdams, modified substantially by Jacco de Leeuw and then forked
again by Xelerance (after it was abandoned by l2tpd.org).

## Rationale for inclusion in OpenWrt

l2tpd has some serious alignment problems on RISC platforms. It also runs
purely in userspace.

Some of the features added in this fork include:

1. IPSec SA reference tracking inconjunction with openswan's IPSec transport
   mode, which adds support for multiple clients behind the same NAT router
   and multiple clients on the same internal IP behind different NAT routers.

2. Support for the pppol2tp kernel mode L2TP.

3. Alignment and endian problems resolved.

hcg

## UCI options

When `use_legacy_config` is disabled, `/etc/config/xl2tp` supplies the daemon
configuration. Named `lac` and `lns` sections retain their names, so
`config lns 'default'` defines the default LNS and named LAC profiles can be
selected through the control interface. Anonymous sections use their generated
UCI names. The `global` section remains `[global]` regardless of its UCI name.
Its `listen_addr` option maps to the daemon's `listen-addr` setting.

`xl2tpd-control status-lac NAME` returns the named profile's dialing state and
local tunnel/call IDs (zero when absent). Unknown profiles return an error.

The options below configure netifd L2TP interfaces in `/etc/config/network`.

`server` takes the form `host[:port]` with port defaults to `1701`.  It
specifies the l2tp server's address.

`checkup_interval` tells netifd to check after that many seconds since last
setup attempt to see if the interface is up.  If not it should issue another
teardown/setup round to retry the negotiation.  This option defaults to 0 and
netifd will not do the check and retry.

The following are generic ppp options and should have the same format and
semantics as with other ppp-related protocols.  See
[uci/network#protocol_ppp](https://openwrt.org/docs/guide-user/network/wan/wan_interface_protocols#protocol_ppp_ppp_over_modem)
for details.

	username
	password
	keepalive
	ipv6
	mtu
	pppd_options


## Managed LNS and PPP authentication

`luci-app-xl2tpd` edits the existing `xl2tp` UCI package. The legacy-file switch
remains unchanged by installation. With `use_legacy_config=0`, named `lns` and
`lac` sections and repeated range entries are generated for the native daemon.
Outgoing netifd LACs remain configured under `network`, with their own option
files under `/tmp/l2tp`; this service does not write those files.

An LNS may select `ppp_auth` (`pap`, `chap` or `mschap-v2`), `ppp_mtu`, `ppp_mru`,
`ppp_dns` and `ppp_ipv6`. It then uses generated options and a private credentials
file under the root-only `/var/run/xl2tpd` directory. `user` sections select `lns`,
`username`, `password` and optional `enabled`; wildcard usernames and pppd's
file/login password references are rejected. Global PPP secrets are untouched.
Control bytes are rejected before rendering; quotes and backslashes in managed
credentials are escaped for pppd without changing the credential bytes.
An LNS with managed authentication needs at least one enabled user. Supplying
`pppoptfile` instead retains the existing externally managed PPP workflow.

Managed servers require a distinct `ppp_ifname` prefix (1–7 letters, digits or
underscores). The daemon appends the non-detaching PPP child process ID to create one
interface per PPP call. Prefixes must not overlap. Firewall configuration may
match that specific prefix with `+`; this avoids granting access to unrelated
PPP interfaces. This package does not add WAN firewall admission, forwarding,
NAT or IPsec policies. IPv6 negotiation alone does not assign a routed prefix.

Apply requests a reload of the shared daemon. The reload owner snapshots netifd L2TP
interfaces that are up or pending, pauses them and asks their native owners to
reconstruct them afterward. Manually down clients stay down. LNS clients must
reconnect after the restart. Configuration generation rejects incomplete managed
authentication before starting a daemon; runtime files use mode 0600 under the
private directory. The LuCI application preserves the daemon's startup policy.

Reload stages a complete private generation and checks the native daemon parser
(`xl2tpd -t`) before pausing clients. It starts that exact generation, waits for
the matching native service PID/FIFO and rolls back to the prior generation if
replacement fails. Active LAC intent is restored on every exit. `netifd` status
must expose the actual protocol `state` before a shared reload may pause it.
External legacy PPP-option/authentication files remain administrator-owned.

The native `down` acknowledgement can have an empty reply; its ubus error
status determines request success, and the subsequent status query establishes
completed teardown. Reload checks procd submission and matching generation
readiness separately. A failure to resume a LAC is reported without undoing an
already accepted daemon generation. Failed replacement input is removed only
after its service and PPP readers retire; uncertain ownership retains the files.

UCI Apply/confirm establishes configuration publication, not successful runtime
reload or PPP authentication. The `active` symlink under `/var/run/xl2tpd` records
the generation accepted by the matching native service PID and control FIFO.
On replacement failure the prior generation is restarted when retirement has
completed, and reload still reports failure. New credentials require that new
generation to be accepted and a new PPP authentication exchange.

Plain start reuses the configuration owned by procd, including during respawn, and
does not apply new UCI edits. Reload selects the new checked input. A public stop
removes private generations only after procd and their PPP readers have retired;
internal reload stops retain rollback input. An uncertain retirement leaves the
files in place rather than removing input from a live or respawning owner.
