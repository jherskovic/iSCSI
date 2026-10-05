# Setup Repair Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Setup detects other registered copies of the app (ghost or stale, e.g. from a DMG) and a daemon registered from another copy, and repairs both with a consented click.

**Architecture:** A new `OtherCopies` setup step queries LaunchServices by bundle ID (~4 ms), classifies the other copies with pure logic in iSCSIKit, and unregisters them with `lsregister -u` off the main actor. The daemon reports its own bundle path in `DaemonInfo`; `DaemonController` turns a mismatch into a new `.otherCopy` state and makes `.registeredNotResponding` repairable, both through the existing `reregister()`.

**Tech Stack:** Swift 6, AppKit (`NSWorkspace`), ServiceManagement, LaunchServices `lsregister`, swift-testing, xcodegen; JXA (`osascript -l JavaScript`) for probing on a VM without Xcode.

**Spec:** `docs/superpowers/specs/2026-10-05-setup-repair-design.md`

## Global Constraints

- Swift 6 language mode; swift-testing (`@Test` / `#expect`). CI runs `swift test --no-parallel`.
- Every repair removes **registrations only** — no file is ever deleted — and runs behind a consent prompt. Nothing is repaired silently.
- Every subprocess the app waits on runs **off the main actor** (`Task.detached`).
- New `DaemonInfo` fields are **optional**, so an app and an older daemon still decode each other.
- The app builds against the **macOS 26 SDK**; CI (Xcode 26.6) is the authority. Use no API newer than macOS 26.
- New app source files need `cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate`, and the regenerated `.pbxproj` is committed. `xcodebuild` rewrites `Package.resolved`'s `originHash`; restore it with `git checkout -- Package.resolved`.
- Probes and hardware checks run on the **SIP-on VM `herko@192.168.64.16`** (FSKit/LaunchServices behaviour is not trustworthy on the SIP-off VM). Its `targets.json` also holds "ssd-vms (soak)" — live VM storage: never attach or modify it. `name-testing` is the only scratch namespace.
- Nothing is installed or registered on the dev host.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
  ```
- Work on branch `setup-repair`.

## Review Focus

1. A translocated or DMG-launched app must never offer Clean up — it would count the real install as "another copy" and unregister it. The location step gates the button; checked by hand in Task 7.
2. An older daemon that sends no `bundlePath` must never be reported as "another copy" — unit test in Task 2.
3. Paths with spaces and under the home directory (`~/Downloads/iSCSI Initiator.app`) must be shown readably and passed to `lsregister -u` intact — unit test in Task 2; `Process` arguments in Task 4.
4. If `lsregister -u` fails for a path, the step must stay actionable and keep listing it, not turn green — the step re-queries LaunchServices after acting rather than assuming success; checked in Task 7.
5. The DMG copy must be caught both while the image is still mounted and after it is ejected — Task 1 establishes what LaunchServices reports; Task 7 checks the step end to end.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/iSCSIKit/SetupAudit.swift` (create) | Pure: `RegisteredCopy`, `RegisteredCopies` (canonical paths, classification, summary text), `DaemonPlacement` (other-copy comparison, bundle path of a daemon) |
| `Sources/iSCSIKit/XPCModels.swift` (modify) | `DaemonInfo.bundlePath` |
| `Sources/iSCSIDaemon/XPCService.swift` (modify) | Fill `bundlePath` |
| `apps/iSCSIApp/Setup/OtherCopies.swift` (create) | The setup step: LaunchServices query, `lsregister -u` |
| `apps/iSCSIApp/Setup/SetupCoordinator.swift` (modify) | Insert the step; `DaemonStep` renders `.otherCopy` and a repairable `.registeredNotResponding` |
| `apps/iSCSIApp/Setup/DaemonController.swift` (modify) | `.otherCopy(path:)`; probe compares bundle paths |
| `docs/backend-a-fskit-notes.md`, `docs/daemon-registration.md` (modify) | Probe result; the new daemon state |
| Tests (create) `Tests/iSCSIKitTests/SetupAuditTests.swift`; (modify) `Tests/IntegrationTests/XPCServiceTests.swift` | |

---

### Task 1: Probe the DMG scenario on the SIP-on VM

**Files:**
- Modify: `docs/backend-a-fskit-notes.md` (new subsection after "Registered *twice* looks exactly like not registered")

**Interfaces:**
- Produces: the branch decision for Task 4 — **A** (the bundle-ID query lists a registration whose bundle is gone) or **B** (it does not). Recorded in the ledger as `Task 1: Ruling: branch A|B — <evidence>`.

No code. Everything here is read-only except mounting/ejecting a DMG and launching an app from it, which is the scenario under test, and bringing `en2` back up (left down by an earlier test).

- [ ] **Step 1: Restore the storage link and stage the DMG**

```bash
V=herko@192.168.64.16
ssh $V 'sudo -n ifconfig en2 up; sleep 3; ifconfig en2 | grep "inet "; nc -z -G 4 192.168.20.1 4420 && echo "NAS reachable"'
scp "<scratchpad>/rc2/iSCSI-Initiator-0.7.0.dmg" $V:/tmp/rc.dmg
```
Expected: `en2` has 192.168.20.77 and the NAS answers on 4420. (`<scratchpad>` is this session's scratchpad; the RC2 DMG was downloaded there. If it is gone: `gh run download 37261495975 -n dmg -D <dir>`.)

- [ ] **Step 2: Put the two queries on the VM**

The fast query is the app's own call, run through JXA (the VM has no Xcode); the dump is the module-level view:
```bash
ssh $V 'cat > /tmp/fast.js' <<'EOF'
ObjC.import("AppKit");
var a = $.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier("me.herko.iSCSIInitiator");
var o = [];
for (var i = 0; i < a.count; i++) o.push(a.objectAtIndex(i).path.js);
o.join("\n");
EOF
ssh $V 'cat > /tmp/dump.sh' <<'EOF'
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -dump \
  | grep -o "/[^\"]*\.app/Contents/Extensions/iSCSIFSExtension.appex" | sort | uniq -c
EOF
ssh $V 'echo "== baseline"; osascript -l JavaScript /tmp/fast.js; sh /tmp/dump.sh'
```
Expected baseline: `/Applications/iSCSI Initiator.app` only, from both.

- [ ] **Step 3: Mount the DMG, launch from it, quit it**

```bash
ssh $V 'hdiutil attach /tmp/rc.dmg | tail -1'
ssh $V 'echo "== mounted"; osascript -l JavaScript /tmp/fast.js; sh /tmp/dump.sh'
ssh $V 'open -n "/Volumes/iSCSI Initiator/iSCSI Initiator.app"; sleep 8; pkill -f "/Volumes/iSCSI Initiator/iSCSI Initiator.app/Contents/MacOS/iSCSI Initiator"; sleep 2'
ssh $V 'echo "== after launching from the DMG"; osascript -l JavaScript /tmp/fast.js; sh /tmp/dump.sh'
```
Record which paths each query lists at each stage.

- [ ] **Step 4: Eject, query, and try an attach**

```bash
ssh $V 'hdiutil detach "/Volumes/iSCSI Initiator"'
ssh $V 'echo "== after eject"; osascript -l JavaScript /tmp/fast.js; sh /tmp/dump.sh'
ssh $V 'mkdir -p /tmp/probe-mnt; mount -F -t iSCSI "nvme://192.168.20.1:4420/nqn.2011-06.com.truenas:uuid:75ca6aa3-69fd-44e5-8269-8722b52845d0:name-testing/1" /tmp/probe-mnt; echo "mount exit=$?"; mount | grep probe-mnt; umount /tmp/probe-mnt 2>/dev/null; rm -f /tmp/rc.dmg'
```
Expected: record the post-eject lists and whether `mount -F` succeeds (`name-testing` only — never `ssd-vms`).

- [ ] **Step 5: Decide and record**

Rule: if the post-eject fast query lists `/Volumes/iSCSI Initiator/iSCSI Initiator.app` → **branch A**; otherwise → **branch B**. Add to `docs/backend-a-fskit-notes.md`, directly after the "Registered *twice*" section's last paragraph, a subsection:

```markdown
### What LaunchServices keeps after a DMG (measured 2026-10-05, SIP-on VM)

<a four-row table: baseline / mounted / launched from DMG / ejected — for each,
what `NSWorkspace.urlsForApplications(withBundleIdentifier:)` listed, what the
`lsregister -dump` appex records listed, and (ejected row) whether `mount -F`
worked>

<one paragraph: which branch the setup-repair step takes and why.>
```

Fill the table from the recorded output — no blanks.

- [ ] **Step 6: Commit**

```bash
git add docs/backend-a-fskit-notes.md
git commit -F - <<'EOF'
Record what LaunchServices keeps after a DMG is mounted and ejected

Measured on the SIP-on VM for the setup-repair step: <one line: what the
fast query and the dump each showed after eject, and the branch taken>.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 2: The pure audit logic

**Files:**
- Create: `Sources/iSCSIKit/SetupAudit.swift`
- Test: `Tests/iSCSIKitTests/SetupAuditTests.swift`

**Interfaces:**
- Produces:
  - `public struct RegisteredCopy: Sendable, Equatable { var path: String; var exists: Bool }`
  - `public enum RegisteredCopies { static func canonical(_ path: String) -> String; static func others(registered: [String], running: String, exists: (String) -> Bool) -> [RegisteredCopy]; static func summary(_ copies: [RegisteredCopy], home: String) -> String }`
  - `public enum DaemonPlacement { static func isOtherCopy(daemonBundlePath: String?, appBundlePath: String) -> Bool; static func bundlePath(ofBundleAt url: URL) -> String? }`

- [ ] **Step 1: Write the failing tests**

Create `Tests/iSCSIKitTests/SetupAuditTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIKit

/// The rules behind the "No other copies registered" step and the daemon's
/// other-copy check, without LaunchServices.
@Suite("Setup audit")
struct SetupAuditTests {

    private static let app = "/Applications/iSCSI Initiator.app"
    private static let dmg = "/Volumes/iSCSI Initiator/iSCSI Initiator.app"
    private static let downloads = "/Users/herko/Downloads/iSCSI Initiator.app"

    /// A real directory and a symlink to it, for the symlink cases.
    private func symlinkPair() throws -> (real: String, link: String) {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let real = base.appendingPathComponent("Real.app", isDirectory: true)
        let link = base.appendingPathComponent("Link.app")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        return (real.path, link.path)
    }

    // MARK: - Other copies

    @Test("the running copy is not another copy")
    func runningCopyExcluded() {
        let others = RegisteredCopies.others(registered: [Self.app, Self.dmg], running: Self.app,
                                             exists: { _ in true })
        #expect(others == [RegisteredCopy(path: Self.dmg, exists: true)])
    }

    @Test("the running copy is recognised through a trailing slash")
    func trailingSlash() {
        let others = RegisteredCopies.others(registered: [Self.app + "/"], running: Self.app,
                                             exists: { _ in true })
        #expect(others.isEmpty)
    }

    @Test("the running copy is recognised through a symlink")
    func symlinkedRunningCopy() throws {
        let (real, link) = try symlinkPair()
        let others = RegisteredCopies.others(registered: [link], running: real,
                                             exists: { _ in true })
        #expect(others.isEmpty)
    }

    @Test("copies are classified present or gone, in a stable order")
    func classifiesPresentAndGone() {
        let others = RegisteredCopies.others(
            registered: [Self.dmg, Self.app, Self.downloads], running: Self.app,
            exists: { $0 == Self.downloads })
        #expect(others == [RegisteredCopy(path: Self.downloads, exists: true),
                           RegisteredCopy(path: Self.dmg, exists: false)])
    }

    @Test("a copy registered twice is listed once")
    func duplicatesCollapse() {
        let others = RegisteredCopies.others(registered: [Self.dmg, Self.dmg + "/"],
                                             running: Self.app, exists: { _ in false })
        #expect(others.count == 1)
    }

    // MARK: - What the step says

    @Test("one copy: named, marked gone, home abbreviated where it applies")
    func summaryOfOne() {
        let text = RegisteredCopies.summary([RegisteredCopy(path: Self.dmg, exists: false)],
                                            home: "/Users/herko")
        #expect(text.hasPrefix("Another copy of iSCSI Initiator is registered with macOS: "))
        #expect(text.contains("/Volumes/iSCSI Initiator/iSCSI Initiator.app (no longer exists)"))
        #expect(text.contains("not found"))
    }

    @Test("several copies: counted, each named, the home directory shown as ~")
    func summaryOfSeveral() {
        let text = RegisteredCopies.summary(
            [RegisteredCopy(path: Self.downloads, exists: true),
             RegisteredCopy(path: Self.dmg, exists: true)],
            home: "/Users/herko")
        #expect(text.hasPrefix("2 other copies of iSCSI Initiator are registered with macOS: "))
        #expect(text.contains("~/Downloads/iSCSI Initiator.app"))
        #expect(!text.contains("/Users/herko/"))
        #expect(!text.contains("(no longer exists)"))
    }

    // MARK: - Which copy the daemon runs from

    @Test("an older daemon that sends no bundle path is never another copy")
    func nilDaemonPathIsNotOther() {
        #expect(!DaemonPlacement.isOtherCopy(daemonBundlePath: nil, appBundlePath: Self.app))
    }

    @Test("the same bundle, however written, is not another copy")
    func samePathIsNotOther() throws {
        #expect(!DaemonPlacement.isOtherCopy(daemonBundlePath: Self.app, appBundlePath: Self.app))
        #expect(!DaemonPlacement.isOtherCopy(daemonBundlePath: Self.app + "/", appBundlePath: Self.app))
        let (real, link) = try symlinkPair()
        #expect(!DaemonPlacement.isOtherCopy(daemonBundlePath: link, appBundlePath: real))
    }

    @Test("a different bundle is another copy")
    func differentPathIsOther() {
        #expect(DaemonPlacement.isOtherCopy(daemonBundlePath: Self.dmg, appBundlePath: Self.app))
    }

    @Test("only a daemon inside an .app reports a bundle path")
    func bundlePathOnlyForApps() {
        #expect(DaemonPlacement.bundlePath(ofBundleAt: URL(fileURLWithPath: Self.app))
                == Self.app)
        #expect(DaemonPlacement.bundlePath(ofBundleAt: URL(fileURLWithPath: "/usr/local/bin"))
                == nil)
    }

    // MARK: - DaemonInfo across versions

    @Test("a DaemonInfo from an older daemon decodes with no bundle path")
    func olderDaemonInfoDecodes() throws {
        let golden = """
            {"authorizationRelaxed":false,"build":"40","pid":1234,"version":"0.7.0"}
            """
        let info = try JSONDecoder().decode(DaemonInfo.self, from: Data(golden.utf8))
        #expect(info.bundlePath == nil)
    }

    @Test("DaemonInfo carries its bundle path through a round trip")
    func daemonInfoRoundTrips() throws {
        let info = DaemonInfo(version: "0.7.0", build: "42", pid: 1, authorizationRelaxed: false,
                              bundlePath: Self.app)
        let decoded = try JSONDecoder().decode(DaemonInfo.self, from: JSONEncoder().encode(info))
        #expect(decoded == info)
        #expect(decoded.bundlePath == Self.app)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SetupAuditTests 2>&1 | grep -E "error:" | head -5`
Expected: build failure — `cannot find 'RegisteredCopies' in scope`, `value of type 'DaemonInfo' has no member 'bundlePath'`.

- [ ] **Step 3: Add `DaemonInfo.bundlePath`**

In `Sources/iSCSIKit/XPCModels.swift`, in `DaemonInfo`, after `public var initiatorName: String?` add:

```swift
    /// The app bundle this daemon runs from — which copy launchd actually
    /// starts. Optional so an app and an older daemon still decode each
    /// other; nil for a daemon not inside an .app (a loose `swift run`).
    public var bundlePath: String?
```

and replace its init with:

```swift
    public init(version: String, build: String, pid: Int32, authorizationRelaxed: Bool,
                hostNQN: String? = nil, initiatorName: String? = nil,
                bundlePath: String? = nil) {
        self.version = version
        self.build = build
        self.pid = pid
        self.authorizationRelaxed = authorizationRelaxed
        self.hostNQN = hostNQN
        self.initiatorName = initiatorName
        self.bundlePath = bundlePath
    }
```

- [ ] **Step 4: Write the audit logic**

Create `Sources/iSCSIKit/SetupAudit.swift`:

```swift
import Foundation

/// Another copy of the app that LaunchServices has registered.
public struct RegisteredCopy: Sendable, Equatable {
    public var path: String
    /// false: LaunchServices still holds a record, but the bundle is gone —
    /// an ejected disk image, a deleted build folder.
    public var exists: Bool

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

/// The rules behind Setup's "No other copies registered" step. Pure: the
/// caller supplies what LaunchServices reported and how to test existence,
/// so none of this needs LaunchServices to test. See
/// docs/superpowers/specs/2026-10-05-setup-repair-design.md.
public enum RegisteredCopies {
    /// The form two paths are compared in: symlinks resolved, standardized,
    /// no trailing slash.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Every registered copy except the running one, once each, sorted.
    public static func others(registered: [String], running: String,
                              exists: (String) -> Bool) -> [RegisteredCopy] {
        let mine = canonical(running)
        var seen = Set<String>()
        var copies: [RegisteredCopy] = []
        for path in registered {
            let normal = canonical(path)
            guard normal != mine, seen.insert(normal).inserted else { continue }
            copies.append(RegisteredCopy(path: normal, exists: exists(normal)))
        }
        return copies.sorted { $0.path < $1.path }
    }

    /// What the step says when other copies exist: each one named, gone ones
    /// marked, the home directory shown as `~`, and why it matters.
    public static func summary(_ copies: [RegisteredCopy], home: String) -> String {
        let listed = copies.map { copy -> String in
            let shown = copy.path.hasPrefix(home + "/")
                ? "~" + copy.path.dropFirst(home.count)
                : copy.path
            return copy.exists ? shown : "\(shown) (no longer exists)"
        }.joined(separator: "; ")
        let lead = copies.count == 1
            ? "Another copy of iSCSI Initiator is registered with macOS: "
            : "\(copies.count) other copies of iSCSI Initiator are registered with macOS: "
        return lead + listed + ". With more than one, macOS cannot tell which filesystem "
            + "extension to load, so attaching fails with \"not found\" even while this "
            + "screen is green."
    }
}

/// Which copy of the app the daemon runs from.
public enum DaemonPlacement {
    /// Whether the daemon belongs to a copy other than this one. nil — an
    /// older daemon, or one run loose — says nothing, so it is not "other".
    public static func isOtherCopy(daemonBundlePath: String?, appBundlePath: String) -> Bool {
        guard let daemonBundlePath else { return false }
        return RegisteredCopies.canonical(daemonBundlePath)
            != RegisteredCopies.canonical(appBundlePath)
    }

    /// The path a daemon reports for itself: its bundle's, but only when that
    /// bundle is an app — `iscsid` inside `<app>/Contents/MacOS` resolves to
    /// the containing app; anything else is a loose build.
    public static func bundlePath(ofBundleAt url: URL) -> String? {
        url.pathExtension == "app" ? url.path : nil
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter SetupAuditTests 2>&1 | grep -E "Test run with|✘"`
Expected: 13 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/iSCSIKit/SetupAudit.swift Sources/iSCSIKit/XPCModels.swift Tests/iSCSIKitTests/SetupAuditTests.swift
git commit -F - <<'EOF'
Add the pure logic for finding other registered copies of the app

Classifies LaunchServices' copies against the running one (symlinks and
trailing slashes normalised, present vs gone), words the Setup message,
and compares the daemon's own bundle path with the app's. DaemonInfo
gains an optional bundlePath so older daemons still decode.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 3: The daemon reports its bundle path

**Files:**
- Modify: `Sources/iSCSIDaemon/XPCService.swift` (`daemonInfo`, ~line 245)
- Test: `Tests/IntegrationTests/XPCServiceTests.swift` (`daemonInfoDecodes`, ~line 381)

**Interfaces:**
- Consumes: `DaemonInfo(…, bundlePath:)`, `DaemonPlacement.bundlePath(ofBundleAt:)` (Task 2).
- Produces: every `daemonInfo` reply carries `bundlePath`.

- [ ] **Step 1: Extend the existing test**

In `Tests/IntegrationTests/XPCServiceTests.swift`, in `daemonInfoDecodes`, after `#expect(info.initiatorName == "iqn.test:initiator")` add:

```swift
        // Wiring only: the rule (an .app reports its path, anything else nil)
        // is unit-tested in SetupAuditTests.
        #expect(info.bundlePath == DaemonPlacement.bundlePath(ofBundleAt: Bundle.main.bundleURL))
```

- [ ] **Step 2: Run it, and note why it cannot go red here**

Run: `swift test --filter XPCServiceTests 2>&1 | grep -E "error:|Test run with|✘" | head -5`
Expected: it passes even before Step 3. Under `swift test` the runner is not an `.app`, so the expected value is nil and an unwired field is nil too. The rule itself is pinned by `SetupAuditTests.bundlePathOnlyForApps`, and the wiring's real test is Task 7, where the installed daemon must report `/Applications/…`. Ledger it: `Task 3: Ruling: the daemonInfo wiring test cannot fail under swift test (runner is not an .app) — covered by bundlePathOnlyForApps and Task 7 — cost if wrong: a broken wiring reaches the RC and Task 7 catches it`.

- [ ] **Step 3: Fill the field**

In `Sources/iSCSIDaemon/XPCService.swift`, in `daemonInfo`, add the argument to the `DaemonInfo(` call after `initiatorName: core.initiatorName`:

```swift
            initiatorName: core.initiatorName,
            // Which copy launchd runs, so the app can tell a daemon registered
            // from another copy of itself (docs/daemon-registration.md).
            bundlePath: DaemonPlacement.bundlePath(ofBundleAt: Bundle.main.bundleURL)
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter "XPCServiceTests|SetupAuditTests" 2>&1 | grep -E "Test run with|✘"`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iSCSIDaemon/XPCService.swift Tests/IntegrationTests/XPCServiceTests.swift
git commit -F - <<'EOF'
Have the daemon report which copy of the app it runs from

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 4: The "No other copies registered" step

**Files:**
- Create: `apps/iSCSIApp/Setup/OtherCopies.swift`
- Modify: `apps/iSCSIApp/Setup/SetupCoordinator.swift` (header comment, `init`)
- Modify (generated): `apps/iSCSIInitiator.xcodeproj/project.pbxproj`

**Interfaces:**
- Consumes: `RegisteredCopies`, `RegisteredCopy` (Task 2); Task 1's branch decision; `FSKitRegistrationAudit.registeredAppBundles()` (existing, branch B only).
- Produces: `final class OtherCopies: SetupStep` with `id = "other-copies"`.

No unit test: the logic is Task 2's; this file is the `NSWorkspace` query, the `lsregister` call and the step's wiring. The build is the check here; Task 7 is the behavioural one.

- [ ] **Step 1: Write the step**

Create `apps/iSCSIApp/Setup/OtherCopies.swift`:

```swift
//
//  OtherCopies.swift
//  Setup step: no other copy of the app is registered with macOS.
//
//  LaunchServices registers the app inside a mounted disk image and keeps that
//  registration after the image is ejected; build products register too. With
//  two registered copies, `mount -F` cannot choose a filesystem module and
//  fails with "not found" while every other step is green — they all check
//  presence, and presence is not the problem. This step checks plurality.
//  See docs/superpowers/specs/2026-10-05-setup-repair-design.md.
//

import AppKit
import Foundation
import iSCSIKit

private let lsregisterPath = "/System/Library/Frameworks/CoreServices.framework"
    + "/Frameworks/LaunchServices.framework/Support/lsregister"

@MainActor
final class OtherCopies: SetupStep {
    let id = "other-copies"
    let title = "No other copies registered"
    private(set) var state: StepState = .checking
    private var others: [RegisteredCopy] = []

    func check() async {
        let bundleID = Bundle.main.bundleIdentifier ?? "me.herko.iSCSIInitiator"
        // ~4 ms; LaunchServices' own answer, by bundle identifier.
        let registered = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: bundleID)
            .map(\.path)
        // BRANCH B ONLY (Task 1 found the fast query omits registrations whose
        // bundle is gone) — insert here:
        //   let dumped = await Task.detached { FSKitRegistrationAudit.registeredAppBundles() }.value
        //   and pass `registered + dumped` below.
        others = RegisteredCopies.others(registered: registered,
                                         running: Bundle.main.bundleURL.path,
                                         exists: { FileManager.default.fileExists(atPath: $0) })
        state = others.isEmpty
            ? .satisfied("only this copy is registered")
            : .actionable(RegisteredCopies.summary(others, home: NSHomeDirectory()))
    }

    var actionLabel: String? { state.isSatisfied ? nil : "Clean up" }

    var consentPrompt: String? {
        guard !state.isSatisfied else { return nil }
        return "This removes macOS's registration of the copies listed above so only "
            + "this one is used. It does not delete any files."
    }

    /// Unregister every other copy, then ask LaunchServices again rather than
    /// assume it worked — a copy that would not unregister stays listed.
    func perform() async {
        let paths = others.map(\.path)
        state = .checking
        // Off the main actor, like every subprocess the app waits on.
        await Task.detached {
            for path in paths { Self.unregister(path) }
        }.value
        await check()
    }

    nonisolated private static func unregister(_ path: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsregisterPath)
        process.arguments = ["-u", path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            // Nothing to do here: the re-check after this reports the copy as
            // still registered, which is the honest answer.
        }
    }
}
```

**If Task 1 chose branch B**, replace the four `// BRANCH B ONLY` comment lines and the `others = RegisteredCopies.others(registered: registered,` line with:

```swift
        // The fast query omits registrations whose bundle is gone (measured
        // 2026-10-05, docs/backend-a-fskit-notes.md); the dump sees them.
        // ~2.3 s, so off the main actor.
        let dumped = await Task.detached { FSKitRegistrationAudit.registeredAppBundles() }.value
        others = RegisteredCopies.others(registered: registered + dumped,
```

**If branch A**, delete the four `// BRANCH B ONLY` comment lines and replace them with:

```swift
        // It also lists registrations whose bundle is gone (measured
        // 2026-10-05, docs/backend-a-fskit-notes.md), so no dump is needed.
```

- [ ] **Step 2: Insert the step**

In `apps/iSCSIApp/Setup/SetupCoordinator.swift`:

1. In the header comment, replace
   ```
   //    location -> daemon -> registered -> enabled
   //
   //  Location first because SMAppService registration from a translocated bundle
   //  points at a path that will not exist.
   ```
   with
   ```
   //    location -> other copies -> daemon -> registered -> enabled
   //
   //  Location first because SMAppService registration from a translocated bundle
   //  points at a path that will not exist. Other copies next: a second
   //  registered copy (a once-mounted DMG, a build product) is what lets the
   //  later steps report green over a broken install, and cleaning it up does
   //  not depend on the daemon.
   ```
2. In `init`, change
   ```swift
            InstallLocation(),
            DaemonStep(controller: daemon),
   ```
   to
   ```swift
            InstallLocation(),
            OtherCopies(),
            DaemonStep(controller: daemon),
   ```

- [ ] **Step 3: Regenerate the project and build**

```bash
cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd ..
git diff --stat apps/iSCSIInitiator.xcodeproj
cd apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|warning:.*(OtherCopies|SetupCoordinator)|BUILD (SUCCEEDED|FAILED)"; cd ..
git checkout -- Package.resolved
```
Expected: the `.pbxproj` gains exactly `OtherCopies.swift`; `** BUILD SUCCEEDED **`; no warnings in the touched files.

- [ ] **Step 4: Commit**

```bash
git add apps/iSCSIApp/Setup/OtherCopies.swift apps/iSCSIApp/Setup/SetupCoordinator.swift \
        apps/iSCSIInitiator.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
Add the "No other copies registered" setup step

Lists every other copy of the app LaunchServices has registered — a
once-mounted DMG, a build product — present or gone, and unregisters
them with one consented click. Two registered copies make attaching
fail with "not found" while every presence check is green.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 5: A daemon from another copy, and a repairable "not answering"

**Files:**
- Modify: `apps/iSCSIApp/Setup/DaemonController.swift` (`DaemonState`, `probe()`)
- Modify: `apps/iSCSIApp/Setup/SetupCoordinator.swift` (`DaemonStep`)

**Interfaces:**
- Consumes: `DaemonPlacement.isOtherCopy` (Task 2), `DaemonInfo.bundlePath` (Tasks 2–3), existing `DaemonController.reregister()`.
- Produces: `DaemonState.otherCopy(path: String)`.

No unit test: the comparison is Task 2's; this is state wiring in the app target. Build here; Task 7 exercises it.

- [ ] **Step 1: The state**

In `apps/iSCSIApp/Setup/DaemonController.swift`, in `enum DaemonState`, after the `versionMismatch` case add:

```swift
    /// Answering, but launchd runs it out of a different copy of the app —
    /// a once-mounted DMG, a second install. Wrong even at the same version.
    case otherCopy(path: String)
```

In `summary`, after the `.versionMismatch` case add:

```swift
        case .otherCopy(let path):
            return "running from another copy of the app at \(path) — needs reinstalling from this one"
```

In `color`, change `case .requiresApproval, .versionMismatch: return .orange` to `case .requiresApproval, .versionMismatch, .otherCopy: return .orange`.

- [ ] **Step 2: The probe**

In `probe()`, replace

```swift
            let info = try await DaemonConnection.info()
            let matches = info.version == appVersion && info.build == appBuild
```

with

```swift
            let info = try await DaemonConnection.info()
            // Placement before version: a daemon from another copy is the wrong
            // daemon even when the versions agree.
            let appPath = Bundle.main.bundleURL.path
            if DaemonPlacement.isOtherCopy(daemonBundlePath: info.bundlePath,
                                           appBundlePath: appPath) {
                transition(to: .otherCopy(path: info.bundlePath ?? "?"),
                           "daemonInfo: bundlePath=\(info.bundlePath ?? "nil") app=\(appPath)")
                return
            }
            let matches = info.version == appVersion && info.build == appBuild
```

- [ ] **Step 3: The step**

In `apps/iSCSIApp/Setup/SetupCoordinator.swift`, in `DaemonStep`:

1. In `state`, replace
   ```swift
        case .registeredNotResponding:
            return .blocked("the background service is approved but not running. "
                            + "Reinstalling from the disk image usually fixes this.")
   ```
   with
   ```swift
        case .registeredNotResponding:
            return .actionable("the background service is approved but not running — "
                               + "most often because it belongs to a copy of the app that "
                               + "no longer exists. Reinstall it from this copy.")
        case .otherCopy(let path):
            return .actionable("the background service belongs to another copy of the app "
                               + "at \(path); it needs reinstalling from this one.")
   ```
2. In `actionLabel`, change `case .versionMismatch:  return "Reinstall"` to
   ```swift
        case .versionMismatch, .otherCopy, .registeredNotResponding:
            return "Reinstall"
   ```
3. In `perform()`, change `case .versionMismatch:  await controller.reregister()` to
   ```swift
        case .versionMismatch, .otherCopy, .registeredNotResponding:
            await controller.reregister()
   ```

- [ ] **Step 4: Build**

```bash
cd apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 \
  | grep -E "error:|warning:.*(DaemonController|SetupCoordinator)|BUILD (SUCCEEDED|FAILED)"; cd ..
git checkout -- Package.resolved
```
Expected: `** BUILD SUCCEEDED **`, no warnings in the touched files. (An exhaustive `switch` over `DaemonState` elsewhere that misses `.otherCopy` fails here — add the case where the compiler points.)

- [ ] **Step 5: Commit**

```bash
git add apps/iSCSIApp/Setup/DaemonController.swift apps/iSCSIApp/Setup/SetupCoordinator.swift
git commit -F - <<'EOF'
Offer Reinstall for a daemon from another copy, or one not answering

The daemon now says which copy of the app it runs from; one belonging to
another copy is reported as such and reinstalled from this one, ahead of
the version check. "Approved but not answering" — most often a daemon
whose copy is gone — stops being a dead end and gets the same button.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 6: Docs and full verification

**Files:**
- Modify: `docs/daemon-registration.md` (new section before `## Development cleanup`)

- [ ] **Step 1: Document the daemon state**

In `docs/daemon-registration.md`, before `## Development cleanup`, add:

```markdown
## Which copy the daemon runs from (0.7.0)

launchd will not tell an unprivileged app which bundle a registered daemon runs
from: `launchctl print system/me.herko.iSCSIInitiator.daemon` shows only
`program identifier = Contents/MacOS/iscsid` and the parent bundle identifier.
So the daemon reports it — `DaemonInfo.bundlePath`, its own containing `.app` —
and the app compares that with itself before comparing versions. A daemon from
another copy (a once-mounted DMG, a second install) is `.otherCopy`, and
"approved but not answering" — most often a daemon whose copy is gone — is no
longer a dead end: both offer **Reinstall**, which unregisters and registers
from the running copy.
```

- [ ] **Step 2: Full verification**

```bash
swift build -Xswiftc -DISCSI_BACKEND_B 2>&1 | grep -E "error:"; echo "backend-b build done"
swift test --no-parallel > "${TMPDIR:-/tmp}/setup-repair-test.log" 2>&1; echo "exit=$?"
grep -E "Test run with|✘" "${TMPDIR:-/tmp}/setup-repair-test.log"
cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && xcodebuild -project iSCSIInitiator.xcodeproj \
  -scheme 'iSCSI Initiator' -configuration Release -destination 'generic/platform=macOS' \
  CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; cd ..
git checkout -- Package.resolved
git diff --exit-code apps/iSCSIInitiator.xcodeproj && echo "pbxproj in sync"
```
Expected: no Backend B errors; `exit=0`, no `✘`; `** BUILD SUCCEEDED **`; `pbxproj in sync`.

- [ ] **Step 3: Commit**

```bash
git add docs/daemon-registration.md
git commit -F - <<'EOF'
Document how the app learns which copy the daemon runs from

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 7: RC3 and the hardware check on the SIP-on VM

**Files:**
- Modify: `apps/project.yml` (`CURRENT_PROJECT_VERSION` 41 → 42), regenerated `.pbxproj`
- Modify: `docs/backend-a-fskit-notes.md` (one paragraph appended to Task 1's subsection)

Needs the user for two steps: the Safari download/install, and pressing buttons in Setup. Pushing the branch is part of the plan's approval.

- [ ] **Step 1: Bump and cut RC3 from the branch**

```bash
sed -i '' 's/CURRENT_PROJECT_VERSION: "41"/CURRENT_PROJECT_VERSION: "42"/' apps/project.yml
cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd ..
git add apps/project.yml apps/iSCSIInitiator.xcodeproj/project.pbxproj
git commit -F - <<'EOF'
Bump to build 42 for RC3 (setup repair)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
git push -u origin setup-repair
gh workflow run release.yml --ref setup-repair -f publish=false
```
Then watch the run (pass its numeric ID to `gh run watch` directly), download the `dmg` artifact, and verify: `xcrun stapler validate` passes (retry once on a TLS error), `spctl -a -t open --context context:primary-signature -vv` says "Notarized Developer ID", no `v0.7.0` release exists, the appcast steps were skipped. Record the SHA-256.

- [ ] **Step 2: The user installs RC3 on .37** (Safari download of the artifact, drag over the existing copy), and Setup completes.

- [ ] **Step 3: The DMG scenario, end to end**

With the RC3 DMG still mounted after the install:
1. Setup's new step names `/Volumes/iSCSI Initiator/iSCSI Initiator.app` and offers **Clean up**. (Ask the user what it shows, and confirm with `ssh $V 'osascript -l JavaScript /tmp/fast.js'` — Task 1's script; recreate it if /tmp was cleared.)
2. Launch the copy inside the DMG (`open -n "/Volumes/iSCSI Initiator/iSCSI Initiator.app"`): its location step fails, and its other-copies step shows state **without a button** (Review Focus 1). Quit it.
3. Eject the DMG; relaunch the installed app: the step lists the DMG copy as "(no longer exists)" — or, under branch B, after the dump scan.
4. The user presses **Clean up** and confirms: the step turns green; `fast.js` and `dump.sh` list only `/Applications/iSCSI Initiator.app`.
5. Attach `name-testing` (only that target): it mounts.

- [ ] **Step 4: A daemon from another copy, then a copy that is gone**

Only the first unsatisfied step offers a button, so the order matters: each copy has to clear the other copy's registration before its daemon step can offer Reinstall.

```bash
ssh $V 'sudo -n mkdir -p /Applications/Test && sudo -n ditto "/Applications/iSCSI Initiator.app" "/Applications/Test/iSCSI Initiator.app"'
```
1. The user quits the app and opens `/Applications/Test/iSCSI Initiator.app`. Its other-copies step lists `/Applications/iSCSI Initiator.app` → **Clean up** (harmless: launching that copy again re-registers it). Its daemon step then says the service belongs to `/Applications/iSCSI Initiator.app` → **Reinstall** → green. Confirm in the app log (`/usr/bin/log show --last 5m --info --debug --predicate 'subsystem == "me.herko.iSCSIInitiator.app"'`): before Reinstall a transition to `otherCopy` with `bundlePath=/Applications/iSCSI Initiator.app`; after it, `running`.
2. The user quits the Test copy. Then: `ssh $V 'sudo -n rm -rf /Applications/Test'`.
3. The user opens `/Applications/iSCSI Initiator.app` (launching re-registers it). Its other-copies step lists `/Applications/Test/iSCSI Initiator.app (no longer exists)` → **Clean up** → green (Review Focus 4: a copy that would not unregister stays listed). Its daemon step now shows either "belongs to another copy at /Applications/Test/…" (the old daemon process still answering from its deleted bundle) or "approved but not running" — either way **Reinstall** → green, and the log shows `bundlePath=/Applications/iSCSI Initiator.app`.
4. Attach `name-testing` once more: it mounts.

- [ ] **Step 5: Record and commit**

Append one paragraph to Task 1's subsection in `docs/backend-a-fskit-notes.md`: what the step showed at each stage of Step 3, and the daemon scenario's outcome.

```bash
git add docs/backend-a-fskit-notes.md
git commit -F - <<'EOF'
Record the setup-repair hardware check on the SIP-on VM

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
git push
```
