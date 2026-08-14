import Foundation
import Testing
@testable import iSCSIKit

@Suite("CRC32C digest")
struct CRC32CTests {
    // RFC 7143 §13.1 / RFC 3720 B.4 test patterns. The RFC gives the wire
    // byte sequences; values here are those bytes read little-endian.
    @Test func rfcZeroVector() {
        let bytes = [UInt8](repeating: 0x00, count: 32)
        #expect(CRC32C.checksum(bytes) == 0x8A91_36AA)
        #expect(CRC32C.wireDigest(bytes) == Data([0xAA, 0x36, 0x91, 0x8A]))
    }

    @Test func rfcOnesVector() {
        let bytes = [UInt8](repeating: 0xFF, count: 32)
        #expect(CRC32C.checksum(bytes) == 0x62A8_AB43)
        #expect(CRC32C.wireDigest(bytes) == Data([0x43, 0xAB, 0xA8, 0x62]))
    }

    @Test func rfcIncrementingVector() {
        let bytes = (UInt8(0) ..< 32).map { $0 }
        #expect(CRC32C.checksum(bytes) == 0x46DD_794E)
        #expect(CRC32C.wireDigest(bytes) == Data([0x4E, 0x79, 0xDD, 0x46]))
    }

    @Test func rfcDecrementingVector() {
        let bytes = (UInt8(0) ..< 32).map { 31 - $0 }
        #expect(CRC32C.checksum(bytes) == 0x113F_DB5C)
        #expect(CRC32C.wireDigest(bytes) == Data([0x5C, 0xDB, 0x3F, 0x11]))
    }

    /// Standard CRC-32C check value for "123456789".
    @Test func checkValue() {
        #expect(CRC32C.checksum(Array("123456789".utf8)) == 0xE306_9283)
    }

    @Test func emptyInput() {
        #expect(CRC32C.checksum([]) == 0)
    }
}

// MARK: - Accelerated implementation

@Suite("CRC32C acceleration")
struct CRC32CAccelTests {
    /// The streaming API must agree with the one-shot for every split point,
    /// including splits that land mid-8-byte-word — the hardware path consumes
    /// 8 bytes at a time and handles the tail separately, which is exactly
    /// where a chained digest goes wrong.
    @Test func chunkedMatchesOneShot() {
        let data = Data((0 ..< 1000).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) })
        let expected = CRC32C.checksum(data)
        for split in [0, 1, 7, 8, 9, 15, 16, 63, 64, 65, 511, 999, 1000] {
            var crc: UInt32 = 0xFFFF_FFFF
            crc = data.prefix(split).withUnsafeBytes { CRC32C.update(crc, $0) }
            crc = data.dropFirst(split).withUnsafeBytes { CRC32C.update(crc, $0) }
            #expect(CRC32C.finalize(crc) == expected, "split at \(split)")
        }
    }

    /// Data, [UInt8] and the generic Sequence overload must not diverge; the
    /// fast paths are separate code.
    @Test func overloadsAgree() {
        let bytes = (0 ..< 257).map { UInt8($0 & 0xFF) }
        let viaArray = CRC32C.checksum(bytes)
        let viaData = CRC32C.checksum(Data(bytes))
        let viaSequence = CRC32C.checksum(AnySequence(bytes))
        #expect(viaArray == viaData)
        #expect(viaArray == viaSequence)
    }

    /// Lengths around the 8-byte block boundary, where the tail loop runs.
    @Test func allTailLengthsAreCorrect() {
        // Reference: the original byte-at-a-time definition.
        func reference(_ b: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in b {
                crc ^= UInt32(byte)
                for _ in 0 ..< 8 {
                    crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
                }
            }
            return crc ^ 0xFFFF_FFFF
        }
        for len in 0 ... 40 {
            let b = (0 ..< len).map { UInt8(truncatingIfNeeded: $0 &* 17 &+ 3) }
            #expect(CRC32C.checksum(b) == reference(b), "length \(len)")
        }
    }
}
