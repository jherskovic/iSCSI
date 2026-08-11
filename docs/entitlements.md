# Entitlements & code signing

The dext and FSKit extension use **restricted** entitlements that Apple must
grant. You can develop and test locally before the grant (SIP-off VM, below),
but distribution requires the real entitlements on your provisioning profile.

## What each target needs

| Target | Entitlement | Notes |
|--------|-------------|-------|
| iSCSIDext | `com.apple.developer.driverkit` | base "run as a driver" |
| iSCSIDext | `com.apple.developer.driverkit.family.scsicontroller` | SCSI HBA family |
| iSCSIDext | `com.apple.developer.driverkit.allow-any-userclient-access` | let the daemon open the user client |
| iSCSIApp | `com.apple.developer.system-extension.install` | activate extensions |
| iSCSIApp | `com.apple.developer.driverkit.userclient-access` | array with the dext bundle id |
| iSCSIFSExtension | `com.apple.developer.fskit.fsmodule` | FSKit module |

Bundle ids are all under `me.herko.iSCSIInitiator` (`.dext`, `.fsext`).

## Requesting the grant from Apple

1. Go to <https://developer.apple.com/system-extensions/> and "request an
   entitlement". Describe the product (a software iSCSI initiator presenting a
   virtual SCSI HBA) and that it has no hardware/PCI transport.
2. Request **all** entitlements for the product in a single group — a
   provisioning profile can select only one entitlement group.
3. Apple attaches the group to your team profile; create an App ID +
   provisioning profile for each bundle id in Certificates, Identifiers &
   Profiles.
4. Expect weeks-to-months and be specific. Precedent (forum thread 837879)
   needed DTS escalation to get the SCSI-controller family granted.

## Developing before the grant (no Apple approval needed)

On the **test VM** (see vm-setup.md), self-assert the entitlements:

```sh
# Inside the VM, one time:
sudo systemextensionsctl developer on      # ease reload cycles, skip /Applications check
csrutil disable                             # from recoveryOS — required to self-assert
                                            # restricted entitlements
```

Then in Xcode: set your **Development Team**, keep automatic signing, and the
`.entitlements` files as-is. With SIP off + developer mode, the dext loads with
self-signed development entitlements.

## Signing note

Set `DEVELOPMENT_TEAM` in `apps/project.yml` (or the Xcode Signing pane) before
building the app/extensions. The dext build shown working in CI used
`CODE_SIGNING_ALLOWED=NO`; a real load needs development signing with your team.
