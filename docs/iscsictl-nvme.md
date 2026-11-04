# NVMe namespace commands

The CLI can save a namespace target, expose it as a disk, and detach it.
The iSCSI Initiator app, enabled FSKit extension, and daemon must be installed.

## Release signing

The release daemon accepts the CLI only when it carries the Developer ID
Application signature for team 4A27X5PJP3 and the identifier
me.herko.iSCSIInitiator.iscsictl. Ad-hoc signatures and sudo do not satisfy
this requirement.

A maintainer with the team's certificate and private key can build, sign,
and verify the CLI with:

```bash
bash scripts/sign-iscsictl.sh 'Developer ID Application: ... (4A27X5PJP3)'
```

Distribute the resulting signed CLI with a daemon built from this change.
Rebuilding the CLI requires signing it again. The script is a manual signing
entry point. Integration into the release artifacts remains a maintainer task.

## Usage

Run these commands as the logged-in user. Replace the placeholder values first:

```bash
iscsictl nvme add '<target-host>' --port '<target-port>' --subsystem '<subsystem-nqn>' --nsid '<namespace-id>'
iscsictl nvme attach '<target-host>' --port '<target-port>' --subsystem '<subsystem-nqn>' --nsid '<namespace-id>'
iscsictl nvme detach '<target-host>' --port '<target-port>' --subsystem '<subsystem-nqn>' --nsid '<namespace-id>'
```

Add uses the daemon's XPC interface and preserves an existing matching record.
All client connections share the daemon's target store, so a new record is
immediately available to a subsequent FSKit login. Adding requires no daemon
restart or interruption of existing sessions.

Attach uses FSKit and hdiutil with -nomount, printing the resulting disk and
backing mount directory. Detach finds the whole disk by its image path, detaches
it, unmounts the backing FSKit volume, and removes the mount directory.
A busy disk causes detach to fail while preserving the backing mount.

## Validation

Release CLI build and six client authorization tests passed locally.
Signed CLI-to-release-daemon communication and end-to-end add/attach/detach
still require verification on a machine with the signing credentials and
updated installed components.
