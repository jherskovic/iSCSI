import Foundation

/// CRC-32C (Castagnoli) as used by iSCSI header/data digests (RFC 7143 §13.1).
///
/// Standard reflected CRC: polynomial 0x1EDC6F41 (reversed 0x82F63B78),
/// init 0xFFFFFFFF, final XOR 0xFFFFFFFF. The 32-bit result is transmitted
/// on the wire in little-endian byte order (so the RFC's "32 bytes of zeros →
/// aa 36 91 8a" wire bytes correspond to the value 0x8a9136aa).
public enum CRC32C {
    @usableFromInline
    static let table: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0 ..< 256 {
            var crc = UInt32(i)
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x82F6_3B78 : crc >> 1
            }
            table[i] = crc
        }
        return table
    }()

    @inlinable
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for b in bytes {
            crc = table[Int((crc ^ UInt32(b)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }

    /// The 4 digest bytes as they appear on the wire (little-endian value).
    @inlinable
    public static func wireDigest(_ bytes: some Sequence<UInt8>) -> Data {
        let v = checksum(bytes)
        return Data([
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ])
    }
}
