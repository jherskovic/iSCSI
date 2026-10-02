import Foundation
import Testing
@testable import iSCSIKit

@Suite("Target record local cache key")
struct TargetRecordCacheTests {

    @Test("a pre-0.7.0 record decodes with the cache off")
    func olderRecordIsOff() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0"}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.localCacheGB == nil)
        #expect(record.localCacheBytes == 0)
    }

    @Test("1 through 16 GB are sizes, in GiB")
    func validSizes() {
        var record = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                                  targetIQN: "iqn.x", localCacheGB: 1)
        #expect(record.localCacheBytes == 1 << 30)
        record.localCacheGB = 16
        #expect(record.localCacheBytes == 16 << 30)
    }

    @Test("anything outside 1…16 is off")
    func invalidSizesAreOff() {
        for gb in [0, -1, 17, 1000] {
            let record = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                                      targetIQN: "iqn.x", localCacheGB: gb)
            #expect(record.localCacheBytes == 0, "\(gb) GB must mean off")
        }
    }

    @Test("the key round-trips")
    func roundTrips() throws {
        let record = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                                  targetIQN: "iqn.x", localCacheGB: 4)
        let decoded = try JSONDecoder().decode(TargetRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }
}
