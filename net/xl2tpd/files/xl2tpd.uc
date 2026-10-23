// SPDX-License-Identifier: GPL-2.0-or-later
// The init service owns this private runtime directory and all generated files.
// LAC interfaces remain netifd-owned; managed LNS credentials never modify the
// system-wide PPP secrets or the separate L2TP tunnel-authentication database.
import { cursor } from 'uci';
import { writefile } from 'fs';

const dir = ARGV[0];
if (!dir || !match(dir, /^\/var\/run\/xl2tpd\/config\.[A-Za-z0-9]+$/))
	die('Invalid private configuration directory\n');
const uci = cursor();
const sections = uci.get_all('xl2tp');
if (!sections)
	die('Unable to load xl2tp configuration\n');

const bools = split('ipsec_saref access_control debug_avp debug_network debug_packet debug_state debug_tunnel exclusive assign_ip hidden_bit length_bit refuse_chap require_chap refuse_pap require_pap refuse_authentication require_authentication unix_authentication ppp_debug flow_bits challenge autodial redial', ' ');
const managed = [ 'enabled', 'ppp_auth', 'ppp_mtu', 'ppp_mru', 'ppp_dns', 'ppp_ipv6' ];

function text(value) {
	if (type(value) != 'string')
		die('Invalid control character or non-string in xl2tp configuration\n');
	// POSIX regex patterns are NUL-terminated, unlike ucode strings.
	for (let i = 0; i < length(value); i++)
		if (ord(value, i) < 32 || ord(value, i) == 127)
			die('Invalid control character or non-string in xl2tp configuration\n');
	return value;
}

function quote(value) {
	text(value);
	let quoted = '"';
	for (let i = 0; i < length(value); i++) {
		let c = substr(value, i, 1);
		if (c == '"' || c == '\\')
			quoted += '\\';
		quoted += c;
	}
	return quoted + '"';
}

function token(value) {
	text(value);
	if (!length(value) || match(value, /\s/))
		die('Invalid L2TP authentication name\n');
	return value;
}

function number(value, fallback, min, max) {
	if (value == null || value == '')
		return fallback;
	if (type(value) != 'string' || !match(value, /^[0-9]+$/) || +value < min || +value > max)
		die('Invalid PPP numeric option\n');
	return +value;
}

function ipv4(value) {
	text(value);
	let parts = split(value, '.');
	if (length(parts) != 4)
		die('Invalid PPP DNS address\n');
	for (let part in parts)
		if (!match(part, /^[0-9]{1,3}$/) || +part > 255)
			die('Invalid PPP DNS address\n');
	return value;
}

function save(name, data) {
	if (writefile(dir + '/' + name, data) != length(data))
		die('Unable to write xl2tp runtime configuration\n');
}

// Compatibility is explicit: never translate or replace an existing legacy file.
for (let name, s in sections)
	if (s['.type'] == 'global' && s.use_legacy_config == '1')
		exit(10);

let config = '';
let secrets = '';
let files = {};
let prefixes = [];
let identities = {};

for (let name, s in sections) {
	let kind = s['.type'];
	if (s.enabled == '0')
		continue;
	if (kind == 'secret') {
		secrets += token(s.local) + ' ' + token(s.remote) + ' ' + text(s.secret) + '\n';
		continue;
	}
	if (kind != 'global' && kind != 'lac' && kind != 'lns')
		continue;
	if (kind != 'global') {
		let identity = kind + ':' + lc(name);
		if (length(name) >= 100 || identities[identity])
			die('L2TP profile names must be distinct ignoring case and shorter than 100 bytes\n');
		identities[identity] = true;
		if (kind == 'lns' && lc(name) != 'default' && !length(s.lac))
			die('A named LNS requires an allowed-client address range; use default for the fallback server\n');
	}
	config += '\n[' + kind + (kind == 'global' ? '' : ' ' + name) + ']\n';
	for (let key, value in s) {
		if (substr(key, 0, 1) == '.' || key == 'use_legacy_config' || index(managed, key) >= 0)
			continue;
		let option = key == 'listen_addr' ? 'listen-addr' : replace(key, /_/g, ' ');
		for (let val in (type(value) == 'array' ? value : [ value ]))
			config += option + ' = ' + (index(bools, key) >= 0 ? (val == '1' ? 'yes' : 'no') : text(val)) + '\n';
	}
	if (kind != 'lns' || !s.ppp_auth)
		continue;
	if (index([ 'pap', 'chap', 'mschap-v2' ], s.ppp_auth) < 0 || s.pppoptfile)
		die('Managed PPP authentication requires a supported method and no pppoptfile\n');
	if (!s.ppp_ifname || !match(s.ppp_ifname, /^[A-Za-z0-9_]{1,7}$/))
		die('A managed LNS requires an interface prefix of 1-7 letters, digits or underscores\n');
	for (let prefix in prefixes)
		if (substr(prefix, 0, length(s.ppp_ifname)) == s.ppp_ifname ||
		    substr(s.ppp_ifname, 0, length(prefix)) == prefix)
			die('LNS interface prefixes must not overlap\n');
	push(prefixes, s.ppp_ifname);

	let base = 'lns-' + name;
	let auth = '';
	let clients = {};
	for (let user_name, user in sections) {
		if (user['.type'] != 'user' || user.lns != name || user.enabled == '0')
			continue;
		let username = text(user.username);
		let password = text(user.password);
		// pppd assigns special meaning to these values even inside quotes.
		if (!length(username) || username == '*' || clients[username] || !length(password) ||
		    password == '@login' || substr(password, 0, 2) == '@/')
			die('Invalid or duplicate managed PPP credential\n');
		clients[username] = true;
		auth += quote(username) + ' ' + quote(base) + ' ' + quote(password) + ' *\n';
	}
	if (!length(auth))
		die('An enabled managed LNS requires at least one enabled PPP user\n');
	files[base + '.secrets'] = auth;
	let opts = 'auth\nrequire-' + s.ppp_auth + '\nname ' + quote(base) + '\n' +
		'pap-secrets ' + quote(dir + '/' + base + '.secrets') + '\n' +
		'chap-secrets ' + quote(dir + '/' + base + '.secrets') + '\n' +
		'nodefaultroute\nnoipdefault\nnoccp\nnovj\nnopcomp\nnoaccomp\n' +
		'lcp-echo-interval 30\nlcp-echo-failure 3\n' +
		'mtu ' + number(s.ppp_mtu, 1400, 128, 65535) + '\n' +
		'mru ' + number(s.ppp_mru, 1400, 128, 65535) + '\n';
	if (s.ppp_ipv6 == '1')
		opts += '+ipv6\n';
	for (let dns in (type(s.ppp_dns) == 'array' ? s.ppp_dns : (s.ppp_dns ? [ s.ppp_dns ] : [])))
		opts += 'ms-dns ' + ipv4(dns) + '\n';
	files[base + '.options'] = opts;
	config += 'pppoptfile = ' + dir + '/' + base + '.options\n';
}

// Validate the complete configuration before publishing any generated input.
for (let name, data in files)
	save(name, data);
save('xl2tp-secrets', secrets);
save('xl2tpd.conf', config);
