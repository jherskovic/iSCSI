# macOS iSCSI Initiator (DriverKit)

A modern iSCSI initiator for macOS 26/27 on Apple Silicon. macOS ships no
initiator; the old open-source option is a dead kext. This project puts the
iSCSI/TCP protocol engine in a user-space Swift daemon and presents the LUN as
a real block device — first via an FSKit/`hdiutil` backend (works today, full
speed), and ultimately via a DriverKit virtual SCSI HBA once Apple lifts the
software-controller throughput limit (see `docs/architecture.md`).

## Status

| Phase | What | State |
|------|------|-------|
| 0 | SwiftPM scaffolding, fuzz harness | ✅ done |
| 1 | PDU codec (all 17 PDU types), framer, CRC32C | ✅ done |
| 2 | Negotiation engine, login state machine, CHAP | ✅ done |
| 3 | Session/connection engine, scriptable MockTarget, hostile-script suite | ✅ done |
| 4 | `NetworkTransport` (TCP), `iscsictl`, iscsid daemon (BlockDevice + XPC) | ✅ **verified vs real TrueNAS**; daemon built + tested |
| 5 | FSKit + `hdiutil` block-device backend | 🚧 skeleton scaffolded (needs Xcode signing + API reconciliation) |
| 6 | DriverKit dext (virtual SCSI HBA) | 🚧 **builds vs DriverKit 27 SDK**; data-path bridge + VM activation pending |
| 7 | Fault-injection / soak / e2e scripts | ✅ scripts written (run once a LUN is mounted) |

129 tests pass (unit + integration + real-TCP-loopback); the PDU fuzzer runs
clean over millions of inputs. The full protocol stack is **verified end-to-end
against a real TrueNAS target** (login negotiation → INQUIRY → READ CAPACITY →
write + SYNCHRONIZE CACHE → read-back verify → logout). The DriverKit dext
**compiles against the DriverKit 27 SDK**.

## Building the app + extensions (Xcode)

```sh
cd apps
xcodegen generate          # produces iSCSIInitiator.xcodeproj
open iSCSIInitiator.xcodeproj
# Set your signing Team in project.yml or the Signing pane, then build.
```
The DriverKit dext requires a SIP-off test VM to load — see `docs/vm-setup.md`
and `docs/entitlements.md`.

## Layout

```
Sources/
  iSCSIKit/          protocol core — no policy, fully testable
    PDU/             all PDU types, framer with digest verification
    Negotiation/     text-key negotiation, login state machine
    Auth/            CHAP (forward + mutual)
    Digest/          CRC32C
    Session/         ISCSIConnection + ISCSISession (recovery, keepalive)
    Transport/       ConnectionTransport, NetworkTransport (TCP), MemoryPipe
    SCSI/            SCSITask, CDB builders, sense parsing
  MockTarget/        scriptable in-process target + TCP listener (test infra)
  iscsictl/          control CLI (discover, verify)
  iscsid/            daemon (Phase 4, stub)
  pdu-fuzz/          structure-aware fuzzer
Tests/
  iSCSIKitTests/     86 unit tests
  IntegrationTests/  43 tests: happy paths, hostile scripts, recovery, TCP loopback
scripts/fuzz.sh      ASan fuzz driver
docs/                architecture, entitlements, test playbook
```

## Try it

```bash
swift test                          # unit + integration suite
scripts/fuzz.sh 60                  # 60s ASan fuzz of the PDU decoder

# Against a real target (e.g. your NAS):
swift run iscsictl discover 192.168.1.50
swift run iscsictl verify 192.168.1.50 --target iqn.2000-01.com.example:disk0 \
    --lun 0 --write        # DESTRUCTIVE — scratch LUN only
```

See `docs/architecture.md` for the two-backend design and the DriverKit
throughput caveat, and `docs/test-playbook.md` for the full test strategy.
