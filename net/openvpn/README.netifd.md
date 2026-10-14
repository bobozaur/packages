# Native interface ownership

The package installs the shell netifd protocol handler. With the default
`script_security=3` integration it invokes OpenVPN with `--ifconfig-noexec` and
`--route-noexec`; the OpenVPN hotplug hook publishes addresses and routes through
netifd.

OpenVPN's `tun_mtu` option controls the tunnel MTU. The hook applies the daemon's
effective value to the created device before reporting the link up, including
with DCO. A failed MTU update fails the hook instead of publishing an interface
with a different value. Removing the option restores OpenVPN's chosen default
on the next configuration setup. Explicit device configuration remains a
separate administrator-owned constraint.
