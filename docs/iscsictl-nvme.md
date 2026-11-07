# NVMe namespace commands

The CLI can save a namespace target, expose it as a disk, detach it, and remove its saved configuration.
The iSCSI Initiator app, enabled FSKit extension, and daemon must be installed.

## Usage

The tool is installed at
`/Applications/iSCSI Initiator.app/Contents/MacOS/iscsictl`.
Setup can add a link in `/usr/local/bin` so it can be invoked as `iscsictl`.

Run these commands as the logged-in user. Replace the placeholder values first:

```bash
iscsictl nvme add '<target-host>' --port '<target-port>' --subsystem '<subsystem-nqn>' --nsid '<namespace-id>'
iscsictl nvme attach '<target-host>' --port '<target-port>' --subsystem '<subsystem-nqn>' --nsid '<namespace-id>'
iscsictl nvme detach '<target-host>' --port '<target-port>' --subsystem '<subsystem-nqn>' --nsid '<namespace-id>'
iscsictl nvme remove '<target-host>' --port '<target-port>' --subsystem '<subsystem-nqn>' --nsid '<namespace-id>'
```

Add uses the daemon's XPC interface and preserves an existing matching record.
An existing target reports its saved ID. The --name option applies to new targets.
Configuration belongs to the logged-in account. Run without sudo.
The next FSKit login reads the saved configuration without a daemon restart.

Remove uses the same host, port, subsystem NQN, and namespace ID to find and
delete the saved target through the daemon's XPC interface. It prints the removed
ID; an absent target is a successful no-op. Like add, it belongs to the logged-in
account and must run without sudo. Remove refuses with a device-in-use error
and preserves the configuration if the namespace is still mounted or its disk
is still attached. Run `nvme detach` successfully before removing it. A busy
disk that cannot be detached cannot be removed either.
The daemon also refuses deletion while a login, session, or logout is in progress,
and prevents new logins during deletion. The CLI and daemon must both be updated:
remove uses a checked deletion interface and never falls back to unchecked deletion.

The exact saved record is checked again before deletion. Concurrent configuration
changes cause an error before deletion. Duplicate namespace records with distinct
IDs can be removed one at a time. Duplicate IDs are refused before credentials or
records are deleted; remove that target in the app to repair them. An orphaned `lun0.img` under another valid mount tag in this
account's namespace cache also blocks removal. Its error reports the actual disk
and image path for inspection and detachment. Ordinary files named `lun0.img`
outside those managed paths do not block removal; arbitrary old mount paths
cannot be attributed to a namespace from the filename alone.

If XPC disconnects or times out, the command reports that the result could not be
confirmed; deletion may already have completed. Refresh the saved target list or
retry `nvme remove` (an absent target remains a successful no-op).

Attach uses FSKit and hdiutil with -nomount. Both a new attachment and an
existing attachment print only the whole-disk path to stdout. The backing
mount directory is reported on stderr. Detach finds the whole disk by its image path, detaches
it, unmounts the backing FSKit volume, and removes the mount directory.
A busy disk causes detach to fail while preserving the backing mount.

If the target has stopped answering, detach takes about a minute. The disk goes
first, then the backing volume refuses to unmount for some seconds, so detach
keeps trying for 30 seconds. If it still fails, run it again once the target is
back: nothing is lost.

A stalled target is bounded by the daemon's timeouts. A wedged FSKit extension
is not: these commands can block in the kernel until the extension is released
or killed, like anything else that touches the volume.

## Tracing

`discover`, `verify` and the benches take `--log-level`, which writes timestamped
lines to stderr. Level 1 summarizes connection setup and each command with its
outcome. Level 2 adds the fields of every PDU. `add`, `remove`, `attach` and `detach` have
no trace, because the daemon does that work.
