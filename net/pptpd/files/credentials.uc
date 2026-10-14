// SPDX-License-Identifier: GPL-2.0-or-later
import { cursor } from 'uci';
import { writefile } from 'fs';

const dir = ARGV[0];
if (!dir || !match(dir, /^\/var\/etc\/pptpd\/config\.[A-Za-z0-9]+$/))
	die('Invalid PPTP credentials output path\n');

function quote(value) {
	if (type(value) != 'string')
		die('PPTP login fields must be strings\n');
	let result = '"';
	for (let i = 0; i < length(value); i++) {
		let byte = ord(value, i);
		if (byte < 32 || byte == 127)
			die('PPTP login fields must not contain control bytes\n');
		if (byte == 34 || byte == 92)
			result += '\\';
		result += substr(value, i, 1);
	}
	return result + '"';
}

const config = cursor().get_all('pptpd');
if (!config)
	die('Unable to load PPTP configuration\n');

let data = '';
for (let name, section in config) {
	if (section['.type'] != 'login' || !section.username || !section.password)
		continue;
	if (section.username == '*' || section.password == '@login' ||
	    substr(section.password, 0, 2) == '@/')
		die('PPTP logins require literal usernames and passwords\n');
	data += quote(section.username) + ' "pptp-server" ' + quote(section.password) +
		' ' + quote(section.remoteip || '*') + '\n';
}

if (writefile(dir + '/chap-secrets', data) != length(data))
	die('Unable to write private PPTP credentials\n');
