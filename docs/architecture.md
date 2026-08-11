# Architecture

## Why two processes

DriverKit extensions (dexts) **cannot open TCP sockets** — no BSD sockets, no
Network.framework, in any DriverKit SDK through 25.x. So the iSCSI/TCP protocol
engine must live in user space, and the dext only presents the block device.
This is the same wall that stalled the old `iscsi-osx` kext port.

```
┌──────────────────────── user space ─────────────────────────┐
│  iscsictl ─XPC─► iscsid (LaunchDaemon)                       │
│                    │  Network.framework ──TCP──► target/NAS  │
│                    │                                          │
│                    ├─ iSCSIKit: PDU codec, negotiation,      │
│                    │  CHAP, CRC32C, session engine           │
│                    │                                          │
│      Backend A ──► FSKit file ──hdiutil CRawDiskImage──► /dev/diskN
│      Backend B ──► shared-memory ring + IOUserClient ─┐      │
└───────────────────────────────────────────────────────┼──────┘
                                          ┌──────────────▼─────────────┐
                                          │ iSCSIDext (C++): virtual   │
                                          │ SCSI HBA on IOUserResources│
                                          └──────────► kernel SCSI stack → /dev/diskN
```

## iSCSIKit (done)

Transport-free protocol core, so every path is unit-testable and fuzzable:

- **PDU layer** — all 17 iSCSI PDU types (RFC 7143 §11), a serializer and an
  incremental deframer that verifies header/data CRC32C digests and bounds
  DataSegmentLength (DoS guard against a hostile peer).
- **Negotiation** — RFC 7143 result functions (bool-and/or, numeric min/max,
  declarative, list-select) with strict validation of the target's answers;
  login state machine covering security + operational stages, CHAP and None
  auth, redirect, and C-bit continuation in both directions.
- **Auth** — CHAP (MD5), forward and mutual, vectors cross-checked against an
  independent implementation.
- **Session** — `ISCSIConnection` (an actor) runs the full-feature phase:
  CmdSN window flow control, StatSN validation, Data-In reassembly, R2T-driven
  Data-Out (immediate + unsolicited + solicited bursts), NOP keepalive/echo,
  task management, text exchange, logout. `ISCSISession` adds ERL0 recovery
  (drop → backoff → re-login with a fresh ISID), bounded transparent retry of
  interrupted (idempotent) block I/O, and NOP-based dead-peer detection.
- **Transport** — `ConnectionTransport` protocol with two implementations:
  `NetworkTransport` (Network.framework TCP, Nagle off) and `MemoryPipe` (used
  by tests and the in-process MockTarget).

Scope is a "daily-driver" initiator: single connection per session, ERL0, no
MC/S, no iSNS. Those are deliberate future work.

## The DriverKit throughput caveat (the load-bearing risk)

`SCSIControllerDriverKit` / `IOUserSCSIParallelInterfaceController` can host a
virtual (no-hardware) SCSI HBA by matching on `IOUserResources` — this is
proven (Apple forum thread 837879, with DTS involvement). **But** the
framework's data path assumes DMA hardware: for a software controller the
kernel rejects tasks whose buffer spans more than one physical segment
*before* the dext sees them, forcing ~4 KB per task and measured throughput of
2.5–8 MB/s even with a shared-memory ring and bundled tasks — far below a
1 GbE NAS. Apple DTS has confirmed this and signaled a "software backend"
opt-in fix (Feedback FB23814092) that **has not shipped** as of Aug 2026.

**Consequence for this project:** we ship **Backend A** (FSKit exposing the
LUN as a file + `hdiutil attach -imagekey diskimage-class=CRawDiskImage`) as a
usable, full-speed product now, and build **Backend B** (the dext) behind the
same `BlockDeviceBackend` protocol so it's ready the day the fix lands. Both
sit on the identical iSCSIKit session engine.

## Backend B implementation notes (when built)

- Two-personality matching: an `IOUserResources` bootstrap personality
  publishes a nub via `RegisterService()`; the
  `IOUserSCSIParallelInterfaceController` personality matches that nub.
- Daemon↔dext: `IOUserClient` + `IOBufferMemoryDescriptor` shared ring
  (request/completion slots, out-of-order completion) + `IODataQueueDispatchSource`.
- **Nub-teardown user-client command from day one** — an always-matched
  virtual dext never gets a termination signal, so in-place upgrades otherwise
  require a reboot.
- Known pitfalls to code around: report the real max target ID in
  `UserReportHighestSupportedDeviceID`; set `version =
  kScsiUserParallelTaskResponseCurrentVersion1` on every task response;
  the zero-filled-reused-WRITE-buffer bug.

Entitlements (all restricted, requested from Apple): `com.apple.developer.driverkit`,
`.driverkit.family.scsicontroller`, `.driverkit.userclient-access` (daemon),
`com.apple.developer.system-extension.install` (host app). For development
before Apple grants them: `systemextensionsctl developer on` + SIP disabled,
done inside a throwaway macOS VM so the host stays protected.
