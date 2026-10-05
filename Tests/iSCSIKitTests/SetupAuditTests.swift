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
