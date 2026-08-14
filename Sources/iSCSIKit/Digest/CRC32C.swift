import CCRC32C
import Foundation

/// CRC-32C (Castagnoli) as used by iSCSI header/data digests (RFC 7143 §13.1).
///
/// Standard reflected CRC: polynomial 0x1EDC6F41 (reversed 0x82F63B78),
/// init 0xFFFFFFFF, final XOR 0xFFFFFFFF. The 32-bit result is transmitted
/// on the wire in little-endian byte order (so the RFC's "32 bytes of zeros →
/// aa 36 91 8a" wire bytes correspond to the value 0x8a9136aa).
///
/// The digest covers every byte in both directions, so it sits in the
/// throughput path. `iscsi_crc32c` uses the CRC32C instruction where the CPU
/// has one; the previous byte-at-a-time table loop also ran through a generic
/// `Sequence`, which prevented any contiguous fast path.
public enum CRC32C {
    /// Fast path: contiguous bytes go straight to the accelerated routine.
    @inlinable
    public static func checksum(_ bytes: Data) -> UInt32 {
        bytes.withUnsafeBytes { raw in
            checksum(raw)
        }
    }

    @inlinable
    public static func checksum(_ raw: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = raw.baseAddress, !raw.isEmpty else { return 0 }
        return iscsi_crc32c(0xFFFF_FFFF, base, raw.count) ^ 0xFFFF_FFFF
    }

    @inlinable
    public static func checksum(_ bytes: [UInt8]) -> UInt32 {
        bytes.withUnsafeBytes { checksum($0) }
    }

    /// General case. Anything without contiguous storage is copied once — the
    /// accelerated routine needs a buffer, and the copy is still far cheaper
    /// than iterating a Sequence byte by byte.
    @inlinable
    public static func checksum(_ bytes: some Sequence<UInt8>) -> UInt32 {
        if let contiguous = bytes as? [UInt8] { return checksum(contiguous) }
        if let data = bytes as? Data { return checksum(data) }
        return checksum(Array(bytes))
    }

    /// Continues a running digest across several buffers without joining them.
    /// `crc` starts at 0xFFFFFFFF; call `finalize` on the result.
    @inlinable
    public static func update(_ crc: UInt32, _ raw: UnsafeRawBufferPointer) -> UInt32 {
        guard let base = raw.baseAddress, !raw.isEmpty else { return crc }
        return iscsi_crc32c(crc, base, raw.count)
    }

    @inlinable
    public static func finalize(_ crc: UInt32) -> UInt32 { crc ^ 0xFFFF_FFFF }

    /// The 4 digest bytes as they appear on the wire (little-endian value).
    @inlinable
    public static func wireDigest(_ bytes: some Sequence<UInt8>) -> Data {
        wireBytes(checksum(bytes))
    }

    @inlinable
    public static func wireDigest(_ bytes: Data) -> Data {
        wireBytes(checksum(bytes))
    }

    @inlinable
    public static func wireBytes(_ v: UInt32) -> Data {
        Data([
            UInt8(v & 0xFF),
            UInt8((v >> 8) & 0xFF),
            UInt8((v >> 16) & 0xFF),
            UInt8((v >> 24) & 0xFF),
        ])
    }
}
