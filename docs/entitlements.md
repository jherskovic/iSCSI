# Entitlements & code signing

The two backends have very different signing stories, and conflating them costs
months. **Backend A (FSKit) needs no Apple approval and can ship today. Backend B
(the DriverKit dext) needs an entitlement grant that takes weeks to months.**

An earlier version of this document claimed both were restricted. That was wrong,
and it is worth knowing how to check rather than taking either claim on faith.

## How to check whether an entitlement is gated

Xcode caches the developer portal's capability table locally:

```sh
/Applications/Xcode*.app/Contents/SharedFrameworks/DVTPortal.framework/\
Versions/A/Resources/DVTPortalCachedPortalCapabilities.json
```

Each capability records `distributionApprovalRequired`, `canRequestFromPortal`,
`editable` and `isPublic`. A freely-addable capability looks like `APP_GROUPS`:
approval not required, editable, public. A gated one is either
`distributionApprovalRequired: true` or `canRequestFromPortal: true` with
`editable: false` — meaning you may only ask, not enable.

Measured on Xcode 26 beta:

| Capability | approvalRequired | canRequestFromPortal | editable | verdict |
|---|---|---|---|---|
| `FSKIT_MODULE` | false | false | **true** | **free — just enable it** |
| `SYSTEM_EXTENSION_INSTALL` | false | false | true | free |
| `DriverKit Family SCSI Controller` | false | **true** | false | must request |
| `DriverKit Family SCSIController (development)` | **true** | false | true | must request |
| `DriverKit (development)` | **true** | false | true | must request |
| `DriverKit Allow Any UserClient (development)` | **true** | false | true | must request |

The JSON is a cached snapshot, so confirm against the live portal when it matters.

## What each target needs

| Target | Entitlement | Gated? |
|--------|-------------|--------|
| iSCSIFSExtension | `com.apple.developer.fskit.fsmodule` | no |
| iSCSIFSExtension | `com.apple.security.app-sandbox` | no |
| iSCSIFSExtension | `com.apple.security.network.client` | no |
| iSCSIFSExtension | `…temporary-exception.mach-lookup.global-name` (the daemon) | no |
| iSCSIApp | `com.apple.developer.system-extension.install` | no (dext only — droppable in v1) |
| iSCSIDext | `com.apple.developer.driverkit` | **yes** |
| iSCSIDext | `com.apple.developer.driverkit.family.scsicontroller` | **yes** |
| iSCSIDext | `com.apple.developer.driverkit.allow-any-userclient-access` | **yes** |
| iSCSIApp | `com.apple.developer.driverkit.userclient-access` (array of dext ids) | **yes** |

Bundle ids are all under `me.herko.iSCSIInitiator` (`.dext`, `.fsext`).

Note `FSKIT_MODULE` carries `profileKey: com.apple.developer.fskit.fsmodule` with
`isRequiredInPlist: true` — the appex needs an **embedded provisioning profile**
carrying the capability. It is not a free-floating entitlement you can simply
write into the plist.

## Shipping Backend A (no Apple approval)

1. developer.apple.com → Identifiers → register explicit macOS App IDs for
   `me.herko.iSCSIInitiator` and `me.herko.iSCSIInitiator.fsext`.
2. On the `.fsext` App ID, enable **FSKit Module** in the capability list.
3. Create two **Developer ID Application** provisioning profiles (not
   Development) — one per App ID — and download them.
4. Build the `iSCSI Initiator` scheme, which contains only the app and the FSKit
   extension. `scripts/release.sh` archives, signs, notarizes and staples it.

**Do not request the DriverKit entitlements while doing this.** They are attached
to your team as an entitlement *group*, and a provisioning profile can select only
one group — asking for both entangles the FSKit App ID in a review queue for no
benefit.

## Requesting the grant for Backend B (the dext), when its time comes

1. <https://developer.apple.com/system-extensions/> → "request an entitlement".
   Describe the product (a software iSCSI initiator presenting a virtual SCSI HBA)
   and that it has no hardware/PCI transport.
2. Request **all** of the dext's entitlements in a single group, for the reason
   above.
3. Apple attaches the group to your team profile; create an App ID +
   provisioning profile for each bundle id.
4. Expect weeks-to-months and be specific. Precedent (forum thread 837879) needed
   DTS escalation to get the SCSI-controller family granted.

## Developing the dext before the grant

On the **test VM** (see vm-setup.md), self-assert the entitlements:

```sh
# Inside the VM, one time:
sudo systemextensionsctl developer on      # ease reload cycles, skip /Applications check
csrutil disable                             # from recoveryOS — required to self-assert
                                            # restricted entitlements
```

Then build the `iSCSIDext-dev` scheme with your Development Team set and automatic
signing. With SIP off + developer mode, the dext loads with self-signed
development entitlements.

**The SIP-off VM is the wrong rig for testing anything about Backend A's
distribution.** SIP-off is precisely what lets unapproved entitlements pass, so it
cannot tell you whether a shipped build works. FSKit enablement, Gatekeeper,
notarization and `SMAppService` must all be tested with SIP **on**.

## Signing

`DEVELOPMENT_TEAM` is set in `apps/project.yml`. Release builds use manual
Developer ID signing; see `scripts/release.sh` for the full archive → export →
notarize → staple pipeline and the per-binary signature assertions it makes.
