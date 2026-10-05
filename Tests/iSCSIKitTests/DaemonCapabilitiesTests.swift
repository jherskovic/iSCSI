import Testing
@testable import iSCSIKit

/// What an extension may ask a daemon that shipped in another build. Asking a
/// method the daemon's interface lacks does not just go unanswered: NSXPC drops
/// the connection, and the daemon logs out every session it carried (measured
/// against 0.6.1, 2026-10-05: every read on the volume then failed with EIO).
@Suite("Daemon capabilities")
struct DaemonCapabilitiesTests {

    private func info(_ version: String, _ build: String) -> DaemonInfo {
        DaemonInfo(version: version, build: build, pid: 1, authorizationRelaxed: false)
    }

    @Test("0.6.1, the last release before the local cache, is not asked")
    func before() {
        #expect(!DaemonCapabilities.answersLocalCache(info("0.6.1", "39")))
    }

    @Test("every build from 0.7.0's first RC on is asked")
    func from() {
        #expect(DaemonCapabilities.answersLocalCache(info("0.7.0", "40")))
        #expect(DaemonCapabilities.answersLocalCache(info("0.7.1", "46")))
    }

    @Test("a loose daemon from swift run is current code")
    func dev() {
        #expect(DaemonCapabilities.answersLocalCache(info("dev", "dev")))
    }

    @Test("an unreadable build or no answer at all is not asked")
    func unknown() {
        #expect(!DaemonCapabilities.answersLocalCache(info("0.7.1", "")))
        #expect(!DaemonCapabilities.answersLocalCache(info("0.7.1", "forty")))
        #expect(!DaemonCapabilities.answersLocalCache(nil))
    }
}
