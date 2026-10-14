# PPTP server ownership

The `pptpd` UCI service and `login` sections configure the procd-owned daemon.
The default UCI service remains disabled. Generated credentials
are private to this server and selected through pppd's `chap-secrets` option;
starting or reloading the service does not replace `/etc/ppp/chap-secrets`.
Existing global secrets are left untouched. Accounts supplied only through the
former global file must be represented as `pptpd` login sections for this managed
server.
Managed usernames cannot be the PPP wildcard `*`; passwords cannot select
pppd's `@login` or `@/path` indirection. Quotes and backslashes are encoded as
literal bytes, and control bytes are rejected before startup.

Procd tracks the generated daemon, PPP-options and credential files. Applying a
changed server configuration restarts the shared server, so connected clients
must reconnect. Reasserting identical configuration keeps the current instance.
The native manager tracks and retires its control processes and optional
broadcast relay. Each controller retains and reaps its non-detaching PPP child
and adopts any remaining PPP scripts before releasing the call's address slot.
An abnormal controller exit stops admissions and retires the shared server;
procd can then respawn it. The manager adopts and drains children left by a
forced controller exit. Procd's termination deadline allows normal shutdown.
An instance lock remains inherited by the selected pppd and its scripts, so a
forced parent exit cannot admit a replacement while those descendants remain.
If that lock does not become available within ten seconds, startup fails with
an explicit log message. The managed command fixes the PID/lock identity at
`/var/run/pptpd.pid` and `/var/run/pptpd.pid.lock`, independently of the daemon
configuration's `pidfile` setting. The lock file must not be removed during
operation.

PPTPD advertises one call per TCP control connection. An additional call request
on that connection is rejected while retaining the active call. Multiple users
need independent control connections; two PPP processes sharing a client's
legacy call manager do not establish that property. A rejected excess call is
not a successful second user session.
