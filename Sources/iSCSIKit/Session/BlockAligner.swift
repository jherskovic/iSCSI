import Foundation

/// Translates arbitrary byte ranges into the block-aligned requests that
/// `ISCSIBlockDevice` demands.
///
/// `ISCSIBlockDevice` rejects anything that is not block-aligned with a
/// whole-block length (`BlockDeviceError.misaligned`) and truncates on
/// `length / blockSize`. Callers that sit under a filesystem — the FSKit
/// extension in particular — receive arbitrary offsets and lengths, so the
/// arithmetic to widen a request and slice the result back out has to live
/// somewhere. It lives here so it can be tested directly instead of only
/// through a mounted volume against a live target.
///
/// The failure this prevents is genuinely subtle: unaligned access still
/// *appears* to work through ordinary file reads, because the page cache issues
/// page-aligned requests. It only breaks for callers that read the backing
/// store directly at finer granularity — which is how DiskImages reads a raw
/// disk image, and why an APFS probe failed with EIO while `fsck_apfs` on the
/// same container reported it healthy.
public struct BlockAligner: Sendable {
    public let blockSize: UInt64
    public let capacity: UInt64

    public init(blockSize: UInt64, capacity: UInt64) {
        precondition(blockSize > 0, "block size must be positive")
        self.blockSize = blockSize
        self.capacity = capacity
    }

    /// A widened, block-aligned request plus how to slice the caller's bytes
    /// back out of it.
    public struct Plan: Equatable, Sendable {
        /// Block-aligned start of the request to issue.
        public let alignedOffset: UInt64
        /// Whole-block length of the request to issue.
        public let alignedLength: Int
        /// Byte offset of the caller's data within the aligned buffer.
        public let skip: Int
        /// Number of bytes the caller actually gets, after clamping to capacity.
        public let count: Int

        /// True when the caller's range already covers whole blocks, so a
        /// read-modify-write can be skipped on the write path.
        public var isExact: Bool { skip == 0 && count == alignedLength }
    }

    public func alignDown(_ v: UInt64) -> UInt64 { (v / blockSize) * blockSize }
    public func alignUp(_ v: UInt64) -> UInt64 { ((v &+ blockSize &- 1) / blockSize) * blockSize }

    /// Plans access to `length` bytes at `offset`, clamped to capacity.
    /// Returns nil when the range starts at or beyond the end of the device, or
    /// is empty — callers should treat that as a short read of zero bytes.
    public func plan(offset: UInt64, length: Int) -> Plan? {
        guard offset < capacity, length > 0 else { return nil }
        let count = min(UInt64(length), capacity - offset)
        guard count > 0 else { return nil }

        let start = alignDown(offset)
        let end = min(alignUp(offset &+ count), capacity)
        return Plan(alignedOffset: start,
                    alignedLength: Int(end - start),
                    skip: Int(offset - start),
                    count: Int(count))
    }
}
