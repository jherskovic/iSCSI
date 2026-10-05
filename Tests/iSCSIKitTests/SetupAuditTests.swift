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

    @Test("the running copy is recognised through /private and a firmlinked path")
    func privateAndFirmlink() throws {
        let dir = "/tmp/" + UUID().uuidString + ".app"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        let others = RegisteredCopies.others(registered: ["/private" + dir], running: dir,
                                             exists: { _ in true })
        #expect(others.isEmpty)
        #expect(RegisteredCopies.canonical("/System/Volumes/Data/Applications")
                == RegisteredCopies.canonical("/Applications"))
    }

    // MARK: - Reading the lsregister dump

    @Test("the dump yields each containing app once, and ignores other records")
    func dumpParsing() {
        let dump = """
            path:                       /Applications/iSCSI Initiator.app/Contents/Extensions/iSCSIFSExtension.appex (0x1a2b)
            path:                       /Volumes/iSCSI Initiator/iSCSI Initiator.app/Contents/Extensions/iSCSIFSExtension.appex (0x3c4d)
            path:                       /Volumes/iSCSI Initiator/iSCSI Initiator.app/Contents/Extensions/iSCSIFSExtension.appex (0x5e6f)
            path:                       /Applications/Other.app/Contents/Extensions/Other.appex (0x7a8b)
            bundle id:                  me.herko.iSCSIInitiator.fsext (0x1a2b)
            """
        #expect(RegisteredCopies.appBundles(inDump: dump)
                == ["/Applications/iSCSI Initiator.app",
                    "/Volumes/iSCSI Initiator/iSCSI Initiator.app"])
        #expect(RegisteredCopies.appBundles(inDump: "").isEmpty)
    }

    // MARK: - What the step says

    @Test("one existing copy: named, home abbreviated, says what it can break")
    func summaryOfOne() {
        let text = RegisteredCopies.summary([RegisteredCopy(path: Self.downloads, exists: true)],
                                            home: "/Users/herko")
        #expect(text.hasPrefix("Another copy is registered at ~/Downloads/iSCSI Initiator.app."))
        #expect(text.contains("background service"))
        #expect(!text.contains("/Users/herko/"))
    }

    @Test("several existing copies: counted and each named")
    func summaryOfSeveral() {
        let text = RegisteredCopies.summary(
            [RegisteredCopy(path: Self.downloads, exists: true),
             RegisteredCopy(path: Self.dmg, exists: true)],
            home: "/Users/herko")
        #expect(text.hasPrefix("2 other copies are registered: "))
        #expect(text.contains("~/Downloads/iSCSI Initiator.app; /Volumes/iSCSI Initiator/iSCSI Initiator.app"))
    }

    @Test("a gone copy is a note that says nothing uses it")
    func goneNoteOfOne() {
        let text = RegisteredCopies.goneNote([RegisteredCopy(path: Self.dmg, exists: false)],
                                             home: "/Users/herko")
        #expect(text == "macOS still has a record of /Volumes/iSCSI Initiator/iSCSI Initiator.app, "
                + "which no longer exists — usually an ejected disk image. Nothing uses it.")
    }

    @Test("several gone copies are counted")
    func goneNoteOfSeveral() {
        let text = RegisteredCopies.goneNote(
            [RegisteredCopy(path: Self.downloads, exists: false),
             RegisteredCopy(path: Self.dmg, exists: false)],
            home: "/Users/herko")
        #expect(text.hasPrefix("macOS still has records of 2 copies that no longer exist"))
        #expect(text.hasSuffix("Nothing uses them."))
    }

    @Test("a look-alike home directory is not abbreviated")
    func summaryLookalikeHome() {
        let text = RegisteredCopies.summary(
            [RegisteredCopy(path: "/Users/herko2/iSCSI Initiator.app", exists: true)],
            home: "/Users/herko")
        #expect(text.contains("/Users/herko2/iSCSI Initiator.app"))
        #expect(!text.contains("~"))
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
