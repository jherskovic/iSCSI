import Foundation

/// Big-endian, slice-tolerant accessors over `Data`. All offsets are relative
/// to `startIndex`, so these work uniformly on slices returned by the framer.
extension Data {

    package func u8(_ offset: Int) -> UInt8 {
        self[startIndex + offset]
    }


    package func beU16(_ offset: Int) -> UInt16 {
        UInt16(u8(offset)) << 8 | UInt16(u8(offset + 1))
    }

    /// 24-bit big-endian field (used by DataSegmentLength).

    package func beU24(_ offset: Int) -> UInt32 {
        UInt32(u8(offset)) << 16 | UInt32(u8(offset + 1)) << 8 | UInt32(u8(offset + 2))
    }


    package func beU32(_ offset: Int) -> UInt32 {
        UInt32(beU16(offset)) << 16 | UInt32(beU16(offset + 2))
    }


    package func beU64(_ offset: Int) -> UInt64 {
        UInt64(beU32(offset)) << 32 | UInt64(beU32(offset + 4))
    }


    package func sub(_ offset: Int, _ count: Int) -> Data {
        self[startIndex + offset ..< startIndex + offset + count]
    }


    package mutating func setU8(_ v: UInt8, _ offset: Int) {
        self[startIndex + offset] = v
    }


    package mutating func setBE16(_ v: UInt16, _ offset: Int) {
        setU8(UInt8(v >> 8), offset)
        setU8(UInt8(v & 0xFF), offset + 1)
    }


    package mutating func setBE24(_ v: UInt32, _ offset: Int) {
        precondition(v <= 0xFF_FFFF)
        setU8(UInt8((v >> 16) & 0xFF), offset)
        setU8(UInt8((v >> 8) & 0xFF), offset + 1)
        setU8(UInt8(v & 0xFF), offset + 2)
    }


    package mutating func setBE32(_ v: UInt32, _ offset: Int) {
        setBE16(UInt16(v >> 16), offset)
        setBE16(UInt16(v & 0xFFFF), offset + 2)
    }


    package mutating func setBE64(_ v: UInt64, _ offset: Int) {
        setBE32(UInt32(v >> 32), offset)
        setBE32(UInt32(v & 0xFFFF_FFFF), offset + 4)
    }


    package mutating func setSub(_ bytes: Data, _ offset: Int) {
        replaceSubrange(startIndex + offset ..< startIndex + offset + bytes.count, with: bytes)
    }
}

/// Round `n` up to the next multiple of 4 (iSCSI PDU segments are 4-byte padded).

package func padded4(_ n: Int) -> Int {
    (n + 3) & ~3
}
