import Foundation
import Testing
@testable import iSCSIKit

/// The bounds check both block devices share. It runs in the root daemon on
/// lengths an XPC client chose, so every bad request has to be an error and
/// never a trap.
@Suite("Block request bounds")
struct BlockRequestTests {
    @Test func anAlignedRequestInsideTheDeviceIsAccepted() throws {
        try BlockRequest.validate(offset: 4096, length: 8192, blockSize: 512, capacity: 100)
        try BlockRequest.validate(offset: 0, length: 0, blockSize: 4096, capacity: 1)
        try BlockRequest.validate(offset: 99 * 512, length: 512, blockSize: 512, capacity: 100)
    }

    @Test func misalignmentAndNegativeLengthsAreRefused() {
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 100, length: 512, blockSize: 512, capacity: 100)
        }
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 0, length: 100, blockSize: 512, capacity: 100)
        }
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 0, length: -512, blockSize: 512, capacity: 100)
        }
    }

    /// 2^44 bytes of 512-byte blocks is 2^35 blocks: the old check narrowed
    /// that to 32 bits before comparing it, and trapped.
    @Test func aLengthPastThirtyTwoBitsOfBlocksIsOutOfRangeNotATrap() {
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 0, length: 1 << 44, blockSize: 512, capacity: 1 << 30)
        }
    }

    @Test func anEndPastTheDeviceIsOutOfRange() {
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: 100 * 512, length: 512, blockSize: 512, capacity: 100)
        }
        #expect(throws: BlockDeviceError.self) {
            try BlockRequest.validate(offset: UInt64.max - 511, length: 1024, blockSize: 512,
                                      capacity: 1 << 50)
        }
    }
}

/// Which SCSI statuses the block device retries rather than report.
@Suite("Transient SCSI status")
struct TransientStatusTests {
    private func checkCondition(key: UInt8, asc: UInt8, ascq: UInt8) -> SCSITaskResult {
        var sense = Data(count: 18)
        sense[0] = 0x70
        sense[2] = key
        sense[12] = asc
        sense[13] = ascq
        return SCSITaskResult(status: 0x02, sense: sense)
    }

    @Test func busyAndTaskSetFullAreRetriedLater() {
        #expect(TransientStatus.classify(SCSITaskResult(status: 0x08)) == .retryLater)
        #expect(TransientStatus.classify(SCSITaskResult(status: 0x28)) == .retryLater)
    }

    @Test func unitAttentionIsRetriedAtOnce() {
        #expect(TransientStatus.classify(checkCondition(key: 0x06, asc: 0x29, ascq: 0)) == .unitAttention)
    }

    @Test func aLogicalUnitBecomingReadyIsRetriedLater() {
        #expect(TransientStatus.classify(checkCondition(key: 0x02, asc: 0x04, ascq: 0x01)) == .retryLater)
    }

    @Test func everythingElseIsFinal() {
        #expect(TransientStatus.classify(SCSITaskResult(status: 0x00)) == nil)
        // NOT READY, but not "becoming ready": medium not present.
        #expect(TransientStatus.classify(checkCondition(key: 0x02, asc: 0x3A, ascq: 0)) == nil)
        #expect(TransientStatus.classify(checkCondition(key: 0x03, asc: 0x11, ascq: 0)) == nil)
        #expect(TransientStatus.classify(SCSITaskResult(status: 0x18)) == nil) // reservation conflict
        #expect(TransientStatus.classify(SCSITaskResult(status: 0x02)) == nil) // no sense
    }
}
