import Foundation
import Testing
@testable import NVMeKit

@Suite("Little-endian Data accessors")
struct LittleEndianTests {
    @Test func readsLittleEndianIntegers() {
        let d = Data([0x78, 0x56, 0x34, 0x12, 0xEF, 0xCD, 0xAB, 0x89])
        #expect(d.leU16(0) == 0x5678)
        #expect(d.leU32(0) == 0x1234_5678)
        #expect(d.leU64(0) == 0x89AB_CDEF_1234_5678)
    }

    /// The deframer hands out slices; every offset must be relative to the
    /// slice's own start, exactly as iSCSIKit's big-endian accessors are.
    @Test func offsetsAreRelativeToSliceStart() {
        let d = Data([0xAA, 0xBB, 0x01, 0x02, 0x03, 0x04])
        let slice = d.dropFirst(2)
        #expect(slice.leU32(0) == 0x0403_0201)
        #expect(slice.leU16(2) == 0x0403)
    }

    @Test func writesRoundTripAndLandLowByteFirst() {
        var d = Data(count: 16)
        d.setLE16(0xBEEF, 0)
        d.setLE32(0xDEAD_BEEF, 4)
        d.setLE64(0x0123_4567_89AB_CDEF, 8)
        #expect(Array(d[0 ..< 2]) == [0xEF, 0xBE])
        #expect(d.leU32(4) == 0xDEAD_BEEF)
        #expect(Array(d[8 ..< 16]) == [0xEF, 0xCD, 0xAB, 0x89, 0x67, 0x45, 0x23, 0x01])
        #expect(d.leU64(8) == 0x0123_4567_89AB_CDEF)
    }
}
