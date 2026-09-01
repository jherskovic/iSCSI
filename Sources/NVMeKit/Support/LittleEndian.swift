import Foundation
import iSCSIKit

/// Little-endian, slice-tolerant accessors over `Data`, the NVMe/TCP
/// counterpart of iSCSIKit's big-endian `beU16`/`setBE32` family (which this
/// module reuses for `u8`, `sub`, `setU8`, `setSub`). Every NVMe field is
/// little-endian, including the CRC32C digests on the wire. All offsets are
/// relative to `startIndex`, so these work uniformly on slices handed out by
/// the deframer.
extension Data {
    package func leU16(_ offset: Int) -> UInt16 {
        UInt16(u8(offset)) | UInt16(u8(offset + 1)) << 8
    }

    package func leU32(_ offset: Int) -> UInt32 {
        UInt32(leU16(offset)) | UInt32(leU16(offset + 2)) << 16
    }

    package func leU64(_ offset: Int) -> UInt64 {
        UInt64(leU32(offset)) | UInt64(leU32(offset + 4)) << 32
    }

    package mutating func setLE16(_ v: UInt16, _ offset: Int) {
        setU8(UInt8(v & 0xFF), offset)
        setU8(UInt8(v >> 8), offset + 1)
    }

    package mutating func setLE32(_ v: UInt32, _ offset: Int) {
        setLE16(UInt16(v & 0xFFFF), offset)
        setLE16(UInt16(v >> 16), offset + 2)
    }

    package mutating func setLE64(_ v: UInt64, _ offset: Int) {
        setLE32(UInt32(v & 0xFFFF_FFFF), offset)
        setLE32(UInt32(v >> 32), offset + 4)
    }
}
