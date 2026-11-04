# Security review, November 2026

An external security and reliability review of the initiator, the app, CI
and the release pipeline, and what came of each finding. The IDs are the
review's: S for the shipping code, R for CI and release, D for development
and lab tooling. The fixes are in PR #7.

## Fixed

| ID | Finding | What changed |
|---|---|---|
| S-01 | Any account on a Mac could attach, edit or delete every target and use its saved secret: the daemon checked the caller's code signature, not the user. | Targets and CHAP secrets are per account, chosen from the XPC connection's uid (`UserConfiguration`). They stay daemon-held, because login resolves against them and root must not use a path its caller controls. Fixed after PR #7, not in it. See `docs/open-questions.md`, "Who may use the daemon", for what stays machine-wide. |
| S-03 | A controller's MDTS could overflow `(1 << mdts) * pageBytes` and trap the root daemon, taking every session with it. | The maximum transfer size saturates instead. Tested over all 256 MDTS values; the fuzzer covers it. |
| S-04 | Detach ignored every `diskutil`/`hdiutil`/`umount` result, fell back to forcing, and always dropped the attachment, so uninstall, target removal and updates went ahead over a volume still in use. | Detach is checked at every step and verified: the image device and the FSKit mount must be gone, or it throws and the row stays. Forcing needs the user's yes, in a "Force Eject?" prompt that defaults to Cancel. Uninstall and target removal never force. |
| S-05 | A failed flush when the image was closed was answered with success. | `closeItem` returns EIO. Unmount and the data-cache close cannot return an error, so they log at fault level. |
| S-07 | The updater waited only for fully mounted volumes, not raw attachments or an attach in progress. | It waits on any attachment and on any attach or detach in flight. |
| S-08 | Editing an attached target's address, name or LUN changed its `MountpointTag` and orphaned the live mount. | Those fields are locked while the target is attached. Mounts that no record derives are listed as orphans and can be ejected. |
| S-09 | A CHAP secret save that the keychain refused could be reported as success, and deletes only logged refusals. | Saves require the read-back to equal the new secret. Deletes throw. A target's secrets go before its record. `removeAllData` keeps the target list if any secret is refused. |
| S-10 | iSCSI login and NVMe/TCP bring-up had no deadline once TCP connected, so a target that went quiet hung recovery and every I/O behind it. | `SessionPolicy.loginTimeout` (15 s) bounds login, NVMe bring-up and discovery on both protocols, and the connection is closed on timeout to free a read parked in the transport. |
| R-01 | Sparkle resolved to whatever 2.x was newest at release time; actions were pinned to movable tags; build tools came from `brew`. | Sparkle pinned to exactly 2.10.1, actions to commit SHAs, xcodegen 2.46.0 and create-dmg v1.3.0 installed by `scripts/install-build-tools.sh` and checked against a hash or commit. |
| R-02 | CI's whole package job held a write token while running the tests. | The test job is read-only. The badge push is its own main-only job. |
| R-04 | The always-run credential cleanup missed `appledev.p12`. | It removes it. |

Fixed alongside, not in the review:

- **Logout had the same missing deadline as login.** It now gives up after 5 s and closes the connection.
- **Detach deleted the mount point with `removeItem`, recursively.** It uses `rmdir` instead.
- **`release.sh` signed Sparkle updates with the first `sign_update` it found anywhere,** which could be another app's copy. It now looks only in this project's DerivedData.
- **Setup's macOS 26.x enablement workaround restarted fskitd,** which dropped every account's FSKit volumes (`docs/open-questions.md` item 14). It is refused while anything is mounted through FSKit.
- **The daemon now holds each LUN for one filesystem session at a time,** and the app refuses an attach when that disk is mounted anywhere else.
- **Uninstall's clean-up step now deletes URLSession's disk cache (`Cache.db`, `fsCachedData`).** Before, it only removed empty folders and failed on that cache. It still deletes nothing through a mount.

## Rejected

- **S-06: flush not ordered against writes.** A block-layer flush only covers
  writes completed before it was issued. Writes here are synchronous and
  answered only after the target acknowledges them, Force Unit Access by
  default, so an in-flight write was never acknowledged and nothing was
  promised about it. On the relaxed flush timer, `DaemonCore.flushIfDirty`
  marks flushed only the writes counted before the flush, so one that
  lands during it stays dirty for the next. Holding `ioLock` across the
  flush would add latency and nothing else. This would change only if the
  extension ever answered a write before the target had.
- **S-15: a target-initiated NOP-In should advance StatSN.** RFC 7143
  §11.19.2 says the opposite: with the Initiator Task Tag at 0xffffffff,
  StatSN is not advanced. `Connection.handleNopIn` advances it only for
  echoes of the initiator's own pings, and
  `HappyPathTests.targetInitiatedPingIsEchoed` runs a command after a
  target ping to prove it. The recommended change would reject the next
  status PDU after every idle-session ping, which LIO sends by default.

## Not changed

- **S-02: cleartext storage traffic, target not authenticated.** This is
  by design and documented. The storage network must be trusted or
  tunnelled. Mutual CHAP is switched off for a target-side reason
  (`docs/open-questions.md` item 3a). NVMe/TCP TLS and DH-HMAC-CHAP are
  not implemented.
- **S-11: `lun0.img` is reported 0644 in a root-owned 0755 directory.** It
  is not reachable by other users: the mount points are under
  `~/Library/Caches`, which is 0700.
- **S-12: redirects are followed to any host and port, with the same
  CHAP credentials.** No credential exposure is added, since a malicious
  target can send its own CHAP challenge directly. What remains is up to
  four blind outbound connections. The review also notes that redirect
  handling runs before the ISID, ITT, version and CSG checks.
- **S-13: FSKit boundary checks are incomplete.** Three gaps, all
  defense-in-depth, since the requests come from FSKit and the replies
  from the signed daemon:
  - A negative offset is converted straight to `UInt64` and traps.
  - An unparseable LUN in the mount URL becomes LUN 0.
  - The block size is not bounded before `Int` conversions and buffer
    allocation in `LUNStore` and the extension.
- **S-14: asynchronous reads have no admission bound.** This is the
  opt-in DiskImages2 mode only. Bound it with an in-flight count and a
  byte budget if that mode becomes a default.
- **S-16: the install-location check is a string prefix match.** Abusing
  it needs an already-writable bundle, and the resulting downgrade risk is
  documented in `InstallLocation.swift`.
- **R-03: any pushed `v*` tag publishes a release and commits to `main`.**
  This is repository configuration, not code. As of 2026-11-03 the
  repository has a branch ruleset but no tag ruleset and no deployment
  environment. Protect `v*` tags, or gate the release job on an
  environment with a required reviewer.
- **D-01: the VM daemon installer deploys a DEBUG daemon, which accepts
  every XPC client, as root.** This is development only, and
  `release.sh` refuses to archive a daemon with that bypass.
- **D-02: the simulator listens on all interfaces with no
  authentication.** Bind it to loopback if it is ever run on a shared
  network.
- **D-03: the parked dext.** These block re-enabling Backend B:
  - `allow-any-userclient-access`, with no caller check in the user
    client.
  - The watchdog and the media-change block can run after `free()`, and
    `watchdogRun` is non-atomic.
  - A zombie slot is freed on elapsed time alone and reused while an
    old mapping of the one shared arena can still write into it.
  - A slot in `Parking` escapes abort and teardown.
- **D-04: three VM scripts fall back to a literal sudo and keychain
  password** (`vm-install-daemon.sh`, `vm-deploy-dext.sh`,
  `vm-flush-probe.sh`). It must not be reused anywhere else.
- **D-05 to D-08: development tooling, low:**
  - `fault-inject.sh` puts an unvalidated IP into a `pfctl` rule.
  - The simulator takes `--chap-secret` on the command line.
  - `iscsi-attach.sh` and `iscsi-detach.sh` `eval` a home path built from
    `SUDO_USER`.
  - The simulator's loopback control channel has no limit on connections
    or line length.
