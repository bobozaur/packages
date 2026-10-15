// SPDX-License-Identifier: GPL-2.0-or-later
// Reloading the shared daemon also removes dynamic netifd LAC entries. Capture
// only active/pending owners before restart; never enable a manually down LAC.
import { connect, error as ubus_error } from 'ubus';
import { glob, stat, readfile } from 'fs';

let bus = connect();
if (!bus)
	die('Unable to connect to the service owner\n');

function instances() {
	let service = bus.call('service', 'list', { name: 'xl2tpd' });
	if (type(service) != 'object')
		die('Unable to query the L2TP service owner\n');
	return service.xl2tpd?.instances ?? {};
}

function generation(instance) {
	let command = instance.command;
	if (type(command) != 'array' || length(command) != 9 ||
	    command[0] != 'xl2tpd' || command[1] != '-D' || command[2] != '-l' ||
	    command[3] != '-p' || command[4] != '/var/run/xl2tpd.pid' ||
	    command[5] != '-c' || command[7] != '-s')
		die('Unrecognized L2TP service definition; stop it before starting this version\n');
	let path = match(command[6], /^(\/var\/run\/xl2tpd(\/config\.[A-Za-z0-9]+)?|\/etc\/xl2tpd)\/xl2tpd\.conf$/)?.[1];
	if (!path || command[8] != path + '/xl2tp-secrets')
		die('The L2TP service does not own a recognized configuration directory\n');
	return path;
}

// A failed start may still be registered for respawn. The accepted-generation
// symlink cannot establish which files procd currently owns.
if (ARGV[0] == 'owner') {
	let owners = instances();
	if (length(owners) > 1)
		die('Multiple L2TP service instances cannot share the control FIFO\n');
	for (let name, instance in owners)
		print(generation(instance));
	exit(0);
}

function readers() {
	// PPP authentication can read its private secrets after the daemon exits.
	// Include those children before removing a generation, even after SIGKILL.
	const prefix = '/var/run/xl2tpd/';
	let paths = glob('/proc/[0-9]*/cmdline');
	if (paths == null)
		die('Unable to query L2TP configuration readers\n');
	for (let path in paths) {
		let content = readfile(path);
		if (content == null) {
			if (stat(replace(path, /\/cmdline$/, '')))
				die('Unable to inspect an L2TP configuration reader\n');
			continue;
		}
		let command = split(content, '\x00');
		if (!match(command[0], /(^|\/)(xl2tpd|pppd)$/))
			continue;
		for (let argument in command)
			if (substr(argument, 0, length(prefix)) == prefix)
				return true;
	}
	return false;
}

if (ARGV[0] == 'stopped') {
	for (let attempt = 0; attempt < 100; attempt++) {
		if (!length(instances()) && !readers())
			exit(0);
		sleep(100);
	}
	die('L2TP configuration still has an owner; retaining its files\n');
}

// Bounded native owner queries: do not treat an asynchronous down/restart reply
// as completed teardown or a ready FIFO, and do not race the LAC auto-start path.
if (ARGV[0] == 'down') {
	for (let iface in slice(ARGV, 1)) {
		// Successful void methods have no payload. Only the native status
		// distinguishes their acknowledgement from a failed request.
		bus.call('network.interface.' + iface, 'down', {});
		let error = ubus_error();
		if (error)
			die('Unable to pause L2TP interface ' + iface + ': ' + error + '\n');
	}
	for (let attempt = 0; attempt < 200; attempt++) {
		let down = true;
		for (let iface in slice(ARGV, 1)) {
			let state = bus.call('network.interface.' + iface, 'status', {});
			if (!state || state.state != 'down')
				down = false;
		}
		if (down)
			exit(0);
		sleep(100);
	}
	die('Timed out waiting for L2TP interface teardown\n');
}

if (ARGV[0] == 'ready') {
	for (let attempt = 0; attempt < 100; attempt++) {
		let owners = instances();
		let pid = +(readfile('/var/run/xl2tpd.pid') ?? '0');
		for (let name, instance in owners)
			if (instance.running && instance.pid == pid && pid > 0 &&
			    generation(instance) == ARGV[1] &&
			    stat('/var/run/xl2tpd/l2tp-control')?.type == 'fifo')
				exit(0);
		sleep(100);
	}
	die('Timed out waiting for the L2TP service\n');
}

let status = bus.call('network.interface', 'dump', {});
if (!status || type(status.interface) != 'array')
	die('Unable to query active L2TP interfaces\n');
for (let iface in status.interface) {
	if (iface.proto != 'l2tp' || (!iface.up && !iface.pending))
		continue;
	if (iface.state != 'up' && iface.state != 'setup')
		die('The network owner does not expose L2TP lifecycle state\n');
	if (!match(iface.interface, /^[A-Za-z0-9_]+$/))
		die('Invalid L2TP interface name\n');
	printf('%s\n', iface.interface);
}
