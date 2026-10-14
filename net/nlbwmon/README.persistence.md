Database commits write and flush a private file in the database directory,
then atomically rename it over the previous period. Write, encoder-close and
file-sync failures preserve the previous published file. A successful rename
ends the pristine state even if a subsequent directory sync reports an error.
No failed save unlinks the previous snapshot.

The compression option selects the encoding of newly created periods. Existing
periods retain their encoding on later commits, so a power interruption cannot
leave a newer plain file hidden by an older gzip alias. If both legacy aliases
exist, gzip retains the same precedence as loading; a successful replacement
then removes the plain alias.

Loading validates a temporary database and reserves merge capacity before
changing live counters. Corrupt or incomplete files and allocation failures do
not partially merge data that a later retry would add again. Orderly shutdown
runs through the event loop, after an active save has returned.

Backup consumers may hardlink published files to obtain immutable snapshots.
The database directory must support same-filesystem rename and file/directory
sync; backups additionally require hardlinks. File publication and successful
sync are separate outcomes: sync errors are reported even after publication.

The control socket is published after startup has loaded and validated the
selected database. An empty database is a valid framed response; `ENODATA` from
the client denotes an incomplete control stream, not proof of lost records.
Clients assemble complete headers, records and replies across short reads.
Control responses use native ustream output and retain their client until the
queued bytes drain; a slow client cannot busy-spin and block shutdown signals.
Conntrack event batches yield to the existing event loop so continuous events
cannot indefinitely exclude queued shutdown signals or control requests.

An init restart request does not prove the replacement daemon is ready. Observe
the managed process incarnation and its control socket before reading restored
state; a forced termination remains a lifecycle failure. Counters accumulated
while traffic continues can mask missing earlier data, so retention qualification
must include a quiescent record or an equivalent immutable snapshot boundary.
