#!/bin/sh

OPENVPN_PKG="/etc/config/openvpn"
NETWORK_PKG="/etc/config/network"

[ -f "$OPENVPN_PKG" ] || exit 0

awk '
function section_exists(name) {
	cmd = "uci -q get network." name " >/dev/null 2>&1"
	return (system(cmd) == 0)
}

function option_enabled(name, option, cmd, value, extra, result) {
	cmd = "uci -q get openvpn." name "." option
	result = (cmd | getline value)
	if (result != 1 || (cmd | getline extra) > 0)
		value = ""
	close(cmd)
	return value ~ /^(1|on|true|yes|enabled)$/ ? 1 : 0
}

BEGIN {
	in_section=0
	secname = ""
}

/^config[ \t]+openvpn[ \t]+/ {
	# get section name
	secname = $3
	gsub(/'\''/, "", secname)

	if (section_exists(secname)) {
		in_section=0
		next
	}

	in_section=1

	sub(/^config[ \t]+openvpn/, "config interface")
	print
	print "\toption proto '\''openvpn'\''"
	print "\toption auto '\''" (option_enabled(secname, "enable") || option_enabled(secname, "enabled")) "'\''"
	next
}

# Start of another section
/^config[ \t]+/ {
	in_section=0
}

# Inside openvpn section, rename proto
in_section && /^[ \t]*option[ \t]+proto[ \t]/ {
	sub(/option[ \t]+proto/, "option ovpnproto")
	print
	next
}

# The legacy enable flags have been translated to netifd auto.
in_section && /^[ \t]*option[ \t]+enable(d)?[ \t]/ {
	next
}

# Inside openvpn section; copy as-is
in_section {
	print
}
' "$OPENVPN_PKG" >> "$NETWORK_PKG"

exit 0
