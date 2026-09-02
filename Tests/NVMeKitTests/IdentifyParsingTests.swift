import Foundation
import Testing
import iSCSIKit
@testable import NVMeKit

@Suite("Identify, namespace list and discovery log parsing")
struct IdentifyParsingTests {
    func controllerBuffer() -> Data {
        var d = Data(count: 4096)
        d.setSub(Data("SERIAL123           ".utf8), 4)
        d.setSub(Data("Linux".utf8) + Data(repeating: 0x20, count: 35), 24)
        d.setSub(Data("6.12.0  ".utf8), 64)
        d.setU8(5, 77)                     // MDTS: 2^5 pages
        d.setLE16(7, 78)                   // CNTLID
        d.setLE16(100, 320)                // KAS (100 ms units)
        d.setLE16(4, 514)                  // MAXCMD
        d.setLE32(3, 516)                  // NN
        d.setU8(1, 525)                    // VWC present
        d.setLE32(0x0010_0005, 536)        // SGLS
        d.setSub(Data("nqn.2026-08.test:disk".utf8), 768)
        d.setLE32(1028, 1792)              // IOCCSZ: (16384 + 64) / 16
        d.setLE32(1, 1796)                 // IORCSZ
        d.setLE16(0, 1800)                 // ICDOFF
        return d
    }

    @Test func identifyControllerFields() throws {
        let id = try IdentifyController(data: controllerBuffer())
        #expect(id.serial == "SERIAL123")
        #expect(id.model == "Linux")
        #expect(id.firmware == "6.12.0")
        #expect(id.mdts == 5)
        #expect(id.controllerID == 7)
        #expect(id.keepAliveGranularityMS == 10_000)
        #expect(id.maxOutstandingCommands == 4)
        #expect(id.namespaceCount == 3)
        #expect(id.volatileWriteCachePresent)
        #expect(id.subsystemNQN == "nqn.2026-08.test:disk")
        #expect(id.inCapsuleDataBytes == 16384)
        #expect(id.inCapsuleDataOffsetBytes == 0)
        #expect(id.maxTransferBytes(pageBytes: 4096) == 131_072)
        #expect(throws: NVMeTCPError.self) { try IdentifyController(data: Data(count: 2048)) }
    }

    @Test func mdtsZeroMeansUnlimited() throws {
        var buf = controllerBuffer()
        buf.setU8(0, 77)
        #expect(try IdentifyController(data: buf).maxTransferBytes(pageBytes: 4096) == nil)
    }

    func namespaceBuffer(nsze: UInt64 = 1000, formats: [(ms: UInt16, ds: UInt8)] = [(0, 9), (0, 12)],
                         flbas: UInt8 = 1) -> Data {
        var d = Data(count: 4096)
        d.setLE64(nsze, 0)
        d.setLE64(nsze, 8)
        d.setU8(UInt8(formats.count - 1), 25)   // NLBAF is 0's based
        d.setU8(flbas, 26)
        for (i, f) in formats.enumerated() {
            d.setLE16(f.ms, 128 + 4 * i)
            d.setU8(f.ds, 128 + 4 * i + 2)
        }
        return d
    }

    @Test func namespaceGeometryFollowsFLBAS() throws {
        let g = try IdentifyNamespace.geometry(from: namespaceBuffer())
        #expect(g.blockSize == 4096 && g.blockCount == 1000)
        let g0 = try IdentifyNamespace.geometry(from: namespaceBuffer(flbas: 0))
        #expect(g0.blockSize == 512)
    }

    @Test func namespaceGeometryRejectsWhatCannotBeServed() {
        #expect(throws: BlockDeviceError.self) {
            try IdentifyNamespace.geometry(from: namespaceBuffer(nsze: 0))
        }
        #expect(throws: BlockDeviceError.self) {   // metadata per block: unsupported
            try IdentifyNamespace.geometry(from: namespaceBuffer(formats: [(8, 12)], flbas: 0))
        }
        #expect(throws: BlockDeviceError.self) {   // 256-byte blocks
            try IdentifyNamespace.geometry(from: namespaceBuffer(formats: [(0, 8)], flbas: 0))
        }
        #expect(throws: BlockDeviceError.self) {   // FLBAS names a format past NLBAF
            try IdentifyNamespace.geometry(from: namespaceBuffer(flbas: 5))
        }
        #expect(throws: BlockDeviceError.self) {   // block size x count overflows
            try IdentifyNamespace.geometry(from: namespaceBuffer(nsze: .max, formats: [(0, 12)], flbas: 0))
        }
        #expect(throws: NVMeTCPError.self) {
            try IdentifyNamespace.geometry(from: Data(count: 100))
        }
    }

    @Test func activeNamespaceListStopsAtZero() {
        var d = Data(count: 4096)
        d.setLE32(1, 0)
        d.setLE32(5, 4)
        d.setLE32(9, 8)
        #expect(ActiveNamespaceList.parse(d) == [1, 5, 9])
        #expect(ActiveNamespaceList.parse(Data(count: 4096)) == [])
        #expect(ActiveNamespaceList.parse(Data([1, 0, 0, 0, 2, 0])) == [1])   // trailing partial entry ignored
    }

    func discoveryEntry(subnqn: String, traddr: String, trsvcid: String) -> Data {
        var e = Data(count: 1024)
        e.setU8(3, 0)                                   // TRTYPE TCP
        e.setU8(1, 1)                                   // ADRFAM IPv4
        e.setU8(2, 2)                                   // SUBTYPE NVM subsystem
        e.setLE16(1, 4)                                 // PORTID
        e.setLE16(0xFFFF, 6)                            // CNTLID dynamic
        e.setLE16(32, 8)                                // ASQSZ
        e.setSub(Data(trsvcid.utf8), 32)
        e.setSub(Data(subnqn.utf8), 256)
        e.setSub(Data(traddr.utf8), 512)
        return e
    }

    @Test func discoveryLogPageParsesEntries() throws {
        var page = Data(count: 1024)
        page.setLE64(42, 0)                              // GENCTR
        page.setLE64(2, 8)                               // NUMREC
        page.setLE16(0, 16)                              // RECFMT
        page.append(discoveryEntry(subnqn: "nqn.2011-06.com.truenas:disk0", traddr: "192.168.20.1", trsvcid: "4420"))
        page.append(discoveryEntry(subnqn: "nqn.2014-08.org.nvmexpress.discovery", traddr: "192.168.20.1  ", trsvcid: "4420"))
        let parsed = try DiscoveryLogPage.parse(page)
        #expect(parsed.genctr == 42 && parsed.numrec == 2)
        #expect(parsed.entries.count == 2)
        #expect(parsed.entries[0].subnqn == "nqn.2011-06.com.truenas:disk0")
        #expect(parsed.entries[0].traddr == "192.168.20.1")
        #expect(parsed.entries[0].trsvcid == "4420")
        #expect(parsed.entries[0].trtype == 3 && parsed.entries[0].subtype == 2)
        #expect(parsed.entries[1].traddr == "192.168.20.1")   // space padding trimmed
    }

    @Test func discoveryLogPageToleratesTruncationAndLies() throws {
        var page = Data(count: 1024)
        page.setLE64(5, 8)                               // NUMREC claims five
        page.append(discoveryEntry(subnqn: "nqn.a", traddr: "h", trsvcid: "1"))
        page.append(Data(count: 100))                    // a torn second entry
        let parsed = try DiscoveryLogPage.parse(page)
        #expect(parsed.numrec == 5)
        #expect(parsed.entries.count == 1)               // only what is actually there
        #expect(throws: NVMeTCPError.self) { try DiscoveryLogPage.parse(Data(count: 16)) }
    }
}
