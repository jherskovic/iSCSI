import Foundation
import Testing
@testable import iSCSIKit

/// The one rule that tells the two protocols apart: iSCSI names start with
/// iqn./eui./naa., NVMe subsystem names with nqn. Nothing is stored — the
/// name is the discriminator, so this must never get clever.
@Suite("Protocol from the target name")
struct NQNPrefixTests {
    @Test func nqnPrefixDecidesTheProtocol() {
        #expect(IQN.isNQN("nqn.2011-06.com.truenas:uuid:1234:disk0"))
        #expect(IQN.isNQN("nqn.2014-08.org.nvmexpress.discovery"))
        #expect(!IQN.isNQN("iqn.2026-08.me.herko:disk0"))
        #expect(!IQN.isNQN("eui.0123456789abcdef"))
        #expect(!IQN.isNQN("naa.5000000000000001"))
        #expect(!IQN.isNQN("NQN.2011-06.com.truenas:x"))   // NQNs are lowercase by spec
        #expect(!IQN.isNQN(""))
    }

    @Test func recordsAndSessionsKnowTheirProtocol() {
        let nvme = TargetRecord(id: "a", displayName: "n", host: "h", port: 4420,
                                targetIQN: "nqn.2011-06.com.truenas:disk0", lun: 1)
        let iscsi = TargetRecord(id: "b", displayName: "i", host: "h",
                                 targetIQN: "iqn.2026-08.me.herko:disk0")
        #expect(nvme.isNVMe && !iscsi.isNVMe)
        let session = SessionInfo(handle: "s1", targetIQN: nvme.targetIQN, lun: 1,
                                  writeThrough: true, recoveryCount: 0, negotiated: [:])
        #expect(session.isNVMe)
    }

    /// An old daemon's reply has no hostNQN; a new app must still decode it,
    /// and a new daemon's reply must carry it.
    @Test func daemonInfoRoundTripsWithAndWithoutAHostNQN() throws {
        let legacy = Data(#"{"version":"0.5.1","build":"7","pid":3,"authorizationRelaxed":false}"#.utf8)
        let old = try JSONDecoder().decode(DaemonInfo.self, from: legacy)
        #expect(old.hostNQN == nil)

        let new = DaemonInfo(version: "1", build: "2", pid: 3, authorizationRelaxed: false,
                             hostNQN: "nqn.2014-08.org.nvmexpress:uuid:abc")
        let back = try JSONDecoder().decode(DaemonInfo.self, from: try JSONEncoder().encode(new))
        #expect(back == new)
    }
}
