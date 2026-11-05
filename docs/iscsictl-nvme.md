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
