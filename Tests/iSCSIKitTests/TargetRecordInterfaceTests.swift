import Foundation
import Testing
@testable import iSCSIKit

/// Every installed targets.json predates these keys, and a decode failure
/// there loses the user's whole target list.
@Suite("Target record interface keys")
struct TargetRecordInterfaceTests {

    @Test("a pre-0.7.0 record decodes with no pin")
    func preInterfaceRecordDecodes() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0",
             "flushIntervalSeconds":5}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.networkInterface == nil)
        #expect(record.interfaceFallback == nil)
        #expect(record.interfaceBinding == nil)
    }

    @Test("the interface keys round-trip and become a binding")
    func interfaceKeysRoundTrip() throws {
        let record = TargetRecord(id: "t1", displayName: "NAS", host: "192.168.20.1",
                                  targetIQN: "iqn.2026-08.me.herko:disk0",
                                  networkInterface: "en18", interfaceFallback: true)
        let decoded = try JSONDecoder().decode(TargetRecord.self,
                                               from: JSONEncoder().encode(record))
        #expect(decoded == record)
        #expect(decoded.interfaceBinding == InterfaceBinding(name: "en18", fallback: true))
    }

    @Test("a pin with no fallback key is strict")
    func missingFallbackIsStrict() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0",
             "networkInterface":"en18"}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.interfaceBinding == InterfaceBinding(name: "en18", fallback: false))
    }

    @Test("a blank hand-edited interface name pins nothing")
    func blankInterfaceIsAutomatic() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0",
             "networkInterface":"  ","interfaceFallback":false}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.interfaceBinding == nil)
    }

    @Test("a SessionInfo from an older daemon decodes with no path")
    func olderSessionInfoDecodes() throws {
        let golden = """
            {"handle":"s1","targetIQN":"iqn.x","lun":0,"writeThrough":true,
             "recoveryCount":0,"negotiated":{}}
            """
        let info = try JSONDecoder().decode(SessionInfo.self, from: Data(golden.utf8))
        #expect(info.interfaceName == nil)
        #expect(info.interfaceFallbackFrom == nil)
    }

    @Test("SessionInfo carries the interface and the fallback through a round trip")
    func sessionInfoPathRoundTrips() throws {
        let info = SessionInfo(handle: "s1", targetIQN: "iqn.x", lun: 0, writeThrough: true,
                               recoveryCount: 0, negotiated: [:],
                               interfaceName: "en0", interfaceFallbackFrom: "en18")
        let decoded = try JSONDecoder().decode(SessionInfo.self,
                                               from: JSONEncoder().encode(info))
        #expect(decoded == info)
    }
}
