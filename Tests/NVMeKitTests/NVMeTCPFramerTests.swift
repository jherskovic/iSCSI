import Foundation
import Testing
import iSCSIKit
@testable import NVMeKit

@Suite("NVMe/TCP common header")
struct NVMeTCPHeaderTests {
    @Test func decodesTheEightByteCommonHeader() throws {
        // type 7 (C2HData), flags LAST|SUCCESS, HLEN 24, PDO 28, PLEN 0x0000_0084
        let bytes = Data([0x07, 0x0C, 24, 28, 0x84, 0x00, 0x00, 0x00])
        let header = try NVMeTCPHeader(bytes: bytes)
        #expect(header.type == 7)
        #expect(header.pduType == .c2hData)
        #expect(header.flags == [.lastPDU, .success])
        #expect(header.hlen == 24)
        #expect(header.pdo == 28)
        #expect(header.plen == 132)
        #expect(header.encoded == bytes)
    }

    @Test func rejectsFewerThanEightBytes() {
        #expect(throws: NVMeTCPError.headerTooShort) {
            try NVMeTCPHeader(bytes: Data([0x00, 0x00, 0x08]))
        }
    }

    @Test func unknownTypeIsRepresentedButNotClassified() throws {
        let header = try NVMeTCPHeader(bytes: Data([0x08, 0, 8, 0, 8, 0, 0, 0]))
        #expect(header.type == 8)
        #expect(header.pduType == nil)
    }
}

@Suite("NVMe/TCP framing and deframing")
struct NVMeTCPFramerTests {
    /// A 24-byte-header PDU (C2HData shape) with `dataSize` payload bytes.
    func makeDataPDU(dataSize: Int, flags: NVMeTCPFlags = []) -> RawNVMeTCPPDU {
        RawNVMeTCPPDU(type: .c2hData, flags: flags,
                      psh: Data(repeating: 0xAB, count: 16),
                      data: Data((0 ..< dataSize).map { UInt8($0 & 0xFF) }))
    }

    @Test func serializesHeaderPSHAndDataWithoutDigests() {
        let wire = NVMeTCPSerializer().serialize(makeDataPDU(dataSize: 100, flags: [.lastPDU]))
        #expect(wire.count == 24 + 100)
        #expect(wire.u8(0) == 7)
        #expect(wire.u8(1) == 0x04)          // LAST_PDU only; no digest flags
        #expect(wire.u8(2) == 24)            // HLEN
        #expect(wire.u8(3) == 24)            // PDO: data starts right after the header
        #expect(wire.leU32(4) == 124)        // PLEN
        #expect(wire.sub(8, 16) == Data(repeating: 0xAB, count: 16))
        #expect(wire.u8(24) == 0 && wire.u8(123) == 99)
    }

    @Test func pduWithoutDataHasZeroPDOAndPLENEqualsHLEN() {
        let raw = RawNVMeTCPPDU(type: .icReq, psh: Data(count: 120))
        let wire = NVMeTCPSerializer().serialize(raw)
        #expect(wire.count == 128)
        #expect(wire.u8(2) == 128)
        #expect(wire.u8(3) == 0)
        #expect(wire.leU32(4) == 128)
    }

    @Test func digestsAreAppendedAndFlagged() {
        let digests = NVMeTCPDigests(header: true, data: true)
        let wire = NVMeTCPSerializer(digests: digests).serialize(makeDataPDU(dataSize: 100))
        // CH+PSH (24) + HDGST (4) + data (100) + DDGST (4)
        #expect(wire.count == 132)
        #expect(wire.u8(1) == 0x03)          // HDGSTF | DDGSTF
        #expect(wire.u8(3) == 28)            // PDO skips the header digest
        #expect(wire.leU32(4) == 132)
        #expect(wire.sub(24, 4) == CRC32C.wireDigest(wire.sub(0, 24)))
        #expect(wire.sub(128, 4) == CRC32C.wireDigest(wire.sub(28, 100)))
    }

    @Test func headerDigestOnlyOnDatalessPDU() {
        let digests = NVMeTCPDigests(header: true, data: true)
        let wire = NVMeTCPSerializer(digests: digests)
            .serialize(RawNVMeTCPPDU(type: .icReq, psh: Data(count: 120)))
        #expect(wire.count == 132)
        #expect(wire.u8(1) == 0x01)          // DDGSTF is only set when there is data
        #expect(wire.u8(3) == 0)
        #expect(wire.leU32(4) == 132)
    }

    @Test func byteAtATimeFeed() throws {
        let wire = NVMeTCPSerializer().serialize(makeDataPDU(dataSize: 100))
        var deframer = NVMeTCPDeframer()
        var got: RawNVMeTCPPDU?
        for byte in wire {
            deframer.append(Data([byte]))
            if let raw = try deframer.next() {
                #expect(got == nil)
                got = raw
            }
        }
        let raw = try #require(got)
        #expect(raw.type == 7)
        #expect(raw.psh.count == 16)
        #expect(raw.data.count == 100)
        #expect(deframer.buffered == 0)
    }

    @Test func multiplePDUsInOneChunk() throws {
        let serializer = NVMeTCPSerializer()
        var stream = Data()
        for i in 0 ..< 5 { stream.append(serializer.serialize(makeDataPDU(dataSize: i * 7))) }
        var deframer = NVMeTCPDeframer()
        deframer.append(stream)
        var count = 0
        while let raw = try deframer.next() {
            #expect(raw.data.count == count * 7)
            count += 1
        }
        #expect(count == 5)
        #expect(deframer.buffered == 0)
    }

    @Test func digestRoundTrip() throws {
        let digests = NVMeTCPDigests(header: true, data: true)
        let wire = NVMeTCPSerializer(digests: digests).serialize(makeDataPDU(dataSize: 33, flags: [.lastPDU]))
        var deframer = NVMeTCPDeframer(digests: digests)
        deframer.append(wire)
        let raw = try #require(try deframer.next())
        #expect(raw.data == Data((0 ..< 33).map { UInt8($0) }))
        #expect(raw.flags.contains(.lastPDU))
        #expect(raw.flags.contains(.headerDigest))
    }

    @Test func headerDigestMismatchDetected() throws {
        let digests = NVMeTCPDigests(header: true)
        var wire = NVMeTCPSerializer(digests: digests).serialize(makeDataPDU(dataSize: 0))
        wire.setU8(wire.u8(10) ^ 0xFF, 10)   // inside the PSH, covered by HDGST
        var deframer = NVMeTCPDeframer(digests: digests)
        deframer.append(wire)
        #expect(throws: NVMeTCPError.headerDigestMismatch) { try deframer.next() }
    }

    @Test func dataDigestMismatchDetected() throws {
        let digests = NVMeTCPDigests(data: true)
        var wire = NVMeTCPSerializer(digests: digests).serialize(makeDataPDU(dataSize: 64))
        wire.setU8(wire.u8(24 + 10) ^ 0x01, 24 + 10)
        var deframer = NVMeTCPDeframer(digests: digests)
        deframer.append(wire)
        #expect(throws: NVMeTCPError.dataDigestMismatch) { try deframer.next() }
    }

    /// The controller may align data (CPDA) so PDO exceeds HLEN+HDGST. The
    /// bytes in between are padding: not data, not covered by DDGST. Locating
    /// data by HLEN instead of PDO is the classic initiator bug.
    @Test func dataIsLocatedAtPDONotAtHLEN() throws {
        let digests = NVMeTCPDigests(data: true)
        let payload = Data([1, 2, 3, 4, 5, 6, 7, 8])
        var wire = Data([0x07, 0x02, 24, 32, 0, 0, 0, 0])   // PDO 32: 8 pad bytes
        wire.setLE32(UInt32(32 + 8 + 4), 4)
        wire.append(Data(repeating: 0xAB, count: 16))        // PSH
        wire.append(Data(repeating: 0xFF, count: 8))         // pad
        wire.append(payload)
        wire.append(CRC32C.wireDigest(payload))              // DDGST over data only
        var deframer = NVMeTCPDeframer(digests: digests)
        deframer.append(wire)
        let raw = try #require(try deframer.next())
        #expect(raw.data == payload)
        #expect(deframer.buffered == 0)
    }

    @Test func oversizedPLENIsRefusedBeforeBuffering() {
        var wire = Data([0x07, 0x00, 24, 24, 0, 0, 0, 0])
        wire.setLE32(1_000_000, 4)
        var deframer = NVMeTCPDeframer(maxPDUBytes: 64 * 1024)
        deframer.append(wire)
        #expect(throws: NVMeTCPError.pduTooLarge(length: 1_000_000, limit: 64 * 1024)) {
            try deframer.next()
        }
    }

    @Test func inconsistentLengthsAreRefused() {
        // HLEN 4 is shorter than the common header itself.
        var deframer = NVMeTCPDeframer()
        deframer.append(Data([0x07, 0x00, 4, 0, 8, 0, 0, 0]))
        #expect(throws: NVMeTCPError.self) { try deframer.next() }

        // PLEN 20 is shorter than HLEN 24.
        var second = NVMeTCPDeframer()
        second.append(Data([0x07, 0x00, 24, 0, 20, 0, 0, 0]))
        #expect(throws: NVMeTCPError.self) { try second.next() }

        // PDO 40 lies past PLEN 32.
        var third = NVMeTCPDeframer()
        third.append(Data([0x07, 0x00, 24, 40, 32, 0, 0, 0]) + Data(count: 24))
        #expect(throws: NVMeTCPError.self) { try third.next() }
    }
}
