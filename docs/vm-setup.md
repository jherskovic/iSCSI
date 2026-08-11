# DriverKit test VM setup

The dext (Backend B) requires SIP disabled to self-assert its restricted
entitlements during development. **Do this in a throwaway macOS VM**, not on
your host — a buggy storage dext can wedge the storage stack, and SIP-off is a
security downgrade you don't want on your daily machine.

## Why a VM

- SIP-off + `systemextensionsctl developer on` lets the dext load without an
  Apple entitlement grant.
- VM snapshots make dext iteration cheap: snapshot before activating, roll back
  if the storage stack hangs.
- The host stays fully protected (SIP on).

## Creating the VM (Apple Silicon)

Use Apple's Virtualization.framework (fastest, native). Options:

- **UTM** (GUI): New → Virtualize → macOS. Install macOS 26/27 from an IPSW.
- **Tart** (CLI, scriptable):
  ```sh
  brew install cirruslabs/cli/tart
  tart create --from-ipsw=latest iscsi-dev-vm
  tart set iscsi-dev-vm --cpu 4 --memory 8192 --disk-size 60
  tart run iscsi-dev-vm
  ```
- Give it **bridged networking** so it can reach the NAS
  (`planet-express.herko.me`) directly.

## Inside the VM, one time

1. Boot into recoveryOS (hold power on Apple Silicon), open Terminal:
   ```sh
   csrutil disable
   ```
   Reboot back to macOS.
2. Enable developer mode for system extensions:
   ```sh
   sudo systemextensionsctl developer on
   ```
3. Install Xcode (or copy the built `.app` over).
4. Sign in to your Apple developer account in Xcode; set the team in
   `apps/project.yml`.

## Build, install, activate (in the VM)

```sh
cd apps
xcodegen generate
# Open in Xcode, set signing team, Product → Run the app.
# The app calls OSSystemExtensionRequest.activationRequest; approve in
# System Settings → General → Login Items & Extensions → Driver Extensions.
open iSCSIInitiator.xcodeproj
```

Verify the dext loaded:
```sh
systemextensionsctl list
log stream --predicate 'sender == "iSCSIDext"'   # our os_log output
ioreg -c IOUserSCSIParallelInterfaceController    # the virtual HBA
```

## Iteration tips

- Snapshot the VM before each activate; roll back if the storage stack hangs.
- The nub-teardown user-client selector (kISCSIUserClientTeardownNub) is the
  reboot-free upgrade path — without it, replacing an always-matched virtual
  dext needs a reboot (forum thread 836344).
- `sudo dmesg` and `log show --last 5m --predicate 'sender == "iSCSIDext"'` for
  post-mortems after a hang.
