# NVMe namespace commands

The CLI can save a namespace target, expose it as a disk, and detach it.
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
```

Add uses the daemon's XPC interface and preserves an existing matching record.
An existing target reports its saved ID. The --name option applies to new targets.
Configuration belongs to the logged-in account. Run without sudo.
The next FSKit login reads the saved configuration without a daemon restart.

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
outcome. Level 2 adds the fields of every PDU. `add`, `attach` and `detach` have
no trace, because the daemon does that work.
