import Foundation
import Testing
@testable import iSCSIKit

@Suite("Block alignment")
struct BlockAlignerTests {
    // A 4Kn LUN, which is the configuration that exposed the bug: unaligned
    // access works through the page cache and fails only for callers that read
    // the backing store directly, such as DiskImages at 512-byte granularity.
    let lun = BlockAligner(blockSize: 4096, capacity: 42_949_672_960) // 40 GiB

    @Test func alreadyAlignedRequestIsUnchanged() {
        let p = lun.plan(offset: 8192, length: 4096)!
        #expect(p.alignedOffset == 8192)
        #expect(p.alignedLength == 4096)
        #expect(p.skip == 0)
        #expect(p.count == 4096)
        #expect(p.isExact)
    }

    @Test func unalignedOffsetWidensDownAndRecordsSkip() {
        // The 512-byte-granularity access that DiskImages actually issues.
        let p = lun.plan(offset: 512, length: 512)!
        #expect(p.alignedOffset == 0)
        #expect(p.alignedLength == 4096)
        #expect(p.skip == 512)
        #expect(p.count == 512)
        #expect(!p.isExact)
    }

    @Test func rangeSpanningTwoBlocksWidensBothEnds() {
        let p = lun.plan(offset: 4095, length: 2)!
        #expect(p.alignedOffset == 0)
        #expect(p.alignedLength == 8192)
        #expect(p.skip == 4095)
        #expect(p.count == 2)
    }

    @Test func alignedOffsetWithPartialLengthWidensUp() {
        let p = lun.plan(offset: 4096, length: 100)!
        #expect(p.alignedOffset == 4096)
        #expect(p.alignedLength == 4096)
        #expect(p.skip == 0)
        #expect(p.count == 100)
        // Not exact: writing this range needs read-modify-write for the tail.
        #expect(!p.isExact)
    }

    @Test func largeMultiBlockRequestStaysWhole() {
        let p = lun.plan(offset: 0, length: 1 << 20)!
        #expect(p.alignedOffset == 0)
        #expect(p.alignedLength == 1 << 20)
        #expect(p.count == 1 << 20)
        #expect(p.isExact)
    }

    @Test func requestIsClampedToCapacity() {
        // Last block of the device, asking for more than remains.
        let p = lun.plan(offset: lun.capacity - 512, length: 4096)!
        #expect(p.count == 512)
        #expect(p.alignedOffset == lun.capacity - 4096)
        // Must never plan a read past the end of the LUN.
        #expect(UInt64(p.alignedLength) + p.alignedOffset == lun.capacity)
    }

    @Test func offsetAtOrBeyondCapacityYieldsNoPlan() {
        #expect(lun.plan(offset: lun.capacity, length: 4096) == nil)
        #expect(lun.plan(offset: lun.capacity + 4096, length: 4096) == nil)
    }

    @Test func zeroLengthYieldsNoPlan() {
        #expect(lun.plan(offset: 0, length: 0) == nil)
    }

    @Test func fiveTwelveByteLunLeavesEverythingExact() {
        // With 512-byte blocks the same accesses need no widening at all, which
        // is why the bug was invisible until a 4Kn target was used.
        let lun512 = BlockAligner(blockSize: 512, capacity: 1 << 30)
        let p = lun512.plan(offset: 512, length: 512)!
        #expect(p.isExact)
        #expect(p.alignedOffset == 512)
        #expect(p.alignedLength == 512)
    }

    @Test func planNeverExceedsCapacityForAnyOffset() {
        // Property check across the last block, where clamping and rounding up
        // pull in opposite directions.
        for delta in stride(from: UInt64(1), through: 4096, by: 97) {
            guard let p = lun.plan(offset: lun.capacity - delta, length: 8192) else { continue }
            #expect(p.alignedOffset % lun.blockSize == 0)
            #expect(p.alignedOffset + UInt64(p.alignedLength) <= lun.capacity)
            #expect(p.skip + p.count <= p.alignedLength)
        }
    }
}
