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
