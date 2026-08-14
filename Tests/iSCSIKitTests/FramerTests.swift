import Foundation
import Testing
@testable import iSCSIKit

@Suite("PDU framing and deframing")
struct FramerTests {
    func makeNopOut(dataSize: Int) -> NopOutPDU {
        var pdu = NopOutPDU()
        pdu.initiatorTaskTag = 1
        pdu.dataSegment = Data((0 ..< dataSize).map { UInt8($0 & 0xFF) })
        return pdu
    }

    @Test func byteAtATimeFeed() throws {
        let wire = PDUSerializer().serialize(makeNopOut(dataSize: 100))
        var deframer = PDUDeframer()
        var got: RawPDU?
        for byte in wire {
            deframer.append(Data([byte]))
            if let raw = try deframer.next() {
                #expect(got == nil)
                got = raw
            }
        }
        let raw = try #require(got)
        #expect(raw.data.count == 100)
        #expect(deframer.buffered == 0)
    }

    @Test func multiplePDUsInOneChunk() throws {
        let serializer = PDUSerializer()
        var stream = Data()
        for i in 0 ..< 5 {
            stream.append(serializer.serialize(makeNopOut(dataSize: i * 7)))
        }
        var deframer = PDUDeframer()
        deframer.append(stream)
        var count = 0
        while let raw = try deframer.next() {
            #expect(raw.data.count == count * 7)
            count += 1
        }
        #expect(count == 5)
        #expect(deframer.buffered == 0)
    }

    @Test func headerDigestRoundTrip() throws {
        let digests = DigestConfig(headerDigest: true, dataDigest: true)
        let wire = PDUSerializer(digests: digests).serialize(makeNopOut(dataSize: 33))
        // 48 BHS + 4 HD + 36 padded data + 4 DD
        #expect(wire.count == 48 + 4 + 36 + 4)
        var deframer = PDUDeframer(digests: digests)
        deframer.append(wire)
        let raw = try #require(try deframer.next())
        #expect(raw.data.count == 33)
    }

    @Test func headerDigestMismatchDetected() throws {
        let digests = DigestConfig(headerDigest: true)
        var wire = PDUSerializer(digests: digests).serialize(makeNopOut(dataSize: 0))
        wire.setU8(wire.u8(16) ^ 0xFF, 16) // corrupt ITT inside the covered header
        var deframer = PDUDeframer(digests: digests)
        deframer.append(wire)
        #expect(throws: PDUError.headerDigestMismatch) { try deframer.next() }
    }

    @Test func dataDigestMismatchDetected() throws {
        let digests = DigestConfig(dataDigest: true)
        var wire = PDUSerializer(digests: digests).serialize(makeNopOut(dataSize: 64))
        wire.setU8(wire.u8(48 + 10) ^ 0x01, 48 + 10) // flip one data byte
        var deframer = PDUDeframer(digests: digests)
        deframer.append(wire)
        #expect(throws: PDUError.dataDigestMismatch) { try deframer.next() }
    }

    @Test func corruptedDigestItselfDetected() throws {
        let digests = DigestConfig(headerDigest: true)
        var wire = PDUSerializer(digests: digests).serialize(makeNopOut(dataSize: 0))
        wire.setU8(wire.u8(48) ^ 0xFF, 48) // corrupt the digest bytes
        var deframer = PDUDeframer(digests: digests)
        deframer.append(wire)
        #expect(throws: PDUError.headerDigestMismatch) { try deframer.next() }
    }

    @Test func oversizedDataSegmentRejected() throws {
        var bhs = Data(count: 48)
        bhs.setU8(Opcode.nopIn.rawValue, 0)
        bhs.setBE24(1 << 20, 5) // claims 1 MiB
        var deframer = PDUDeframer(maxDataSegmentLength: 65536)
        deframer.append(bhs)
        #expect(throws: PDUError.dataSegmentTooLarge(length: 1 << 20, limit: 65536)) {
            try deframer.next()
        }
    }

    @Test func truncatedStreamYieldsNothing() throws {
        let wire = PDUSerializer().serialize(makeNopOut(dataSize: 512))
        var deframer = PDUDeframer()
        deframer.append(wire.prefix(wire.count - 1))
        #expect(try deframer.next() == nil)
        #expect(deframer.buffered == wire.count - 1)
    }

    @Test func ahsPassthrough() throws {
        // Hand-build a PDU with an 8-byte AHS; the framer must carry it.
        var bhs = Data(count: 48)
        bhs.setU8(Opcode.scsiCommand.rawValue, 0)
        bhs.setU8(0x80, 1)
        let ahs = Data([0, 4, 0x01, 0, 0xDE, 0xAD, 0xBE, 0xEF])
        let wire = PDUSerializer().serialize(RawPDU(bhs: bhs, ahs: ahs, data: Data()))
        var deframer = PDUDeframer()
        deframer.append(wire)
        let raw = try #require(try deframer.next())
        #expect(raw.ahs == ahs)
        #expect(raw.bhs.u8(4) == 2) // TotalAHSLength stamped in words
    }

    @Test func paddingIsNotPartOfData() throws {
        let wire = PDUSerializer().serialize(makeNopOut(dataSize: 5))
        #expect(wire.count == 48 + 8) // 5 → padded to 8
        var deframer = PDUDeframer()
        deframer.append(wire)
        let raw = try #require(try deframer.next())
        #expect(raw.data == Data([0, 1, 2, 3, 4]))
    }
}

@Suite("Serial number arithmetic")
struct SerialTests {
    @Test func basicOrdering() {
        #expect(Serial.lt(1, 2))
        #expect(!Serial.lt(2, 1))
        #expect(!Serial.lt(5, 5))
        #expect(Serial.lte(5, 5))
    }

    @Test func wraparound() {
        #expect(Serial.lt(0xFFFF_FFFF, 0))
        #expect(Serial.lt(0xFFFF_FFF0, 0x10))
        #expect(!Serial.lt(0x10, 0xFFFF_FFF0))
    }

    @Test func window() {
        // Window that spans the wrap point.
        #expect(Serial.inWindow(0xFFFF_FFFF, lo: 0xFFFF_FFF0, hi: 0x10))
        #expect(Serial.inWindow(0x5, lo: 0xFFFF_FFF0, hi: 0x10))
        #expect(!Serial.inWindow(0x11, lo: 0xFFFF_FFF0, hi: 0x10))
        // MaxCmdSN < ExpCmdSN means a closed window: nothing fits.
        #expect(!Serial.inWindow(5, lo: 6, hi: 5))
    }
}

/// Covers the deframer's consumed-index bookkeeping, added to avoid the
/// quadratic `removeFirst` per PDU. Off-by-one errors there would corrupt
/// every PDU after the first, so the invariants are checked explicitly.
@Suite("Deframer buffer management")
struct DeframerBufferTests {
    private func nop(_ tag: UInt32, dataSize: Int) -> NopOutPDU {
        var pdu = NopOutPDU()
        pdu.initiatorTaskTag = tag
        pdu.dataSegment = Data((0 ..< dataSize).map { UInt8(truncatingIfNeeded: $0 &+ Int(tag)) })
        return pdu
    }

    /// Many PDUs delivered in a single append must come back in order, intact.
    @Test func manyPDUsInOneAppend() throws {
        let ser = PDUSerializer()
        var wire = Data()
        let sizes = [0, 1, 3, 4, 100, 4096, 7]
        for (i, size) in sizes.enumerated() {
            wire.append(ser.serialize(nop(UInt32(i + 1), dataSize: size)))
        }
        var deframer = PDUDeframer()
        deframer.append(wire)

        for (i, size) in sizes.enumerated() {
            let raw = try #require(try deframer.next())
            let pdu = try #require(try AnyPDU.decode(raw))
            #expect(raw.data.count == size, "pdu \(i)")
            _ = pdu
        }
        #expect(try deframer.next() == nil)
        #expect(deframer.buffered == 0)
    }

    /// Enough traffic to cross the compaction threshold several times; the
    /// stream must stay correct across every compaction.
    @Test func staysCorrectAcrossCompactions() throws {
        let ser = PDUSerializer()
        var deframer = PDUDeframer()
        var expected = 0
        var seen = 0
        // ~8 MiB total, well past the 64 KiB compaction threshold.
        for round in 0 ..< 64 {
            var chunk = Data()
            for i in 0 ..< 32 {
                chunk.append(ser.serialize(nop(UInt32(i + 1), dataSize: 4096)))
                expected += 1
            }
            deframer.append(chunk)
            _ = round
            while let raw = try deframer.next() {
                #expect(raw.data.count == 4096)
                seen += 1
            }
            #expect(deframer.buffered == 0)
        }
        #expect(seen == expected)
    }

    /// A PDU split across appends, with a partial tail left buffered, must
    /// report the right `buffered` count and resume correctly.
    @Test func partialTailIsReportedAndResumes() throws {
        let ser = PDUSerializer()
        let a = ser.serialize(nop(1, dataSize: 512))
        let b = ser.serialize(nop(2, dataSize: 512))
        var deframer = PDUDeframer()

        // First PDU plus 10 bytes of the second.
        deframer.append(a + b.prefix(10))
        let first = try #require(try deframer.next())
        #expect(first.data.count == 512)
        #expect(try deframer.next() == nil)
        #expect(deframer.buffered == 10)

        deframer.append(b.dropFirst(10))
        let second = try #require(try deframer.next())
        #expect(second.data.count == 512)
        #expect(deframer.buffered == 0)
    }

    /// Digest verification reads at an offset into the buffer, so it must also
    /// respect the consumed index rather than assuming the PDU starts at 0.
    @Test func digestsVerifyForLaterPDUs() throws {
        let cfg = DigestConfig(headerDigest: true, dataDigest: true)
        let ser = PDUSerializer(digests: cfg)
        var wire = Data()
        for i in 0 ..< 5 { wire.append(ser.serialize(nop(UInt32(i + 1), dataSize: 333))) }

        var deframer = PDUDeframer(digests: cfg)
        deframer.append(wire)
        for _ in 0 ..< 5 {
            let raw = try #require(try deframer.next())
            #expect(raw.data.count == 333)
        }
        #expect(deframer.buffered == 0)
    }
}
