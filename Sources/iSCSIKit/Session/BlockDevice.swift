import Foundation

/// A linear, byte-addressable block device backed by an iSCSI LUN. Translates
/// byte offsets to LBAs and splits large transfers to respect the negotiated
/// burst/segment limits. This is the surface both backends (FSKit file, dext
/// HBA) consume via the daemon.
public protocol BlockDeviceBackend: Sendable {
    var blockSize: Int { get async }
    var blockCount: UInt64 { get async }
    /// Read `length` bytes at `offset` (both must be block-aligned).
    func read(offset: UInt64, length: Int) async throws -> Data
    /// Write `data` at `offset` (block-aligned, whole blocks).
    func write(offset: UInt64, data: Data) async throws
    /// Flush the device cache (SCSI SYNCHRONIZE CACHE).
    func flush() async throws
}

public enum BlockDeviceError: Error, Equatable, Sendable {
    case notReady
    case misaligned(offset: UInt64, length: Int, blockSize: Int)
    case outOfRange(lba: UInt64, blocks: UInt32, capacity: UInt64)
    case scsiError(status: UInt8, sense: SenseData?)
    /// READ CAPACITY described a device that cannot exist.
    ///
    /// Its own case rather than a `misaligned` or a generic protocol error
    /// because the fix for it is entirely different: nothing the initiator does
    /// will make this target usable, and the geometry is the evidence.
    case invalidGeometry(blockSize: Int, blockCount: UInt64, reason: String)
}

/// Concrete block device over an `ISCSISession`. Reads/writes are chunked so a
/// single request never exceeds the target's MaxBurstLength, and each chunk is
/// its own SCSI task (so the session's recovery/retry applies per chunk).
public actor ISCSIBlockDevice: BlockDeviceBackend {
    private let session: ISCSISession
    private let lun: UInt64
    private var cachedBlockSize: Int = 0
    private var cachedBlockCount: UInt64 = 0
    private var capacityKnown = false

    /// Cap per-SCSI-command transfer. Kept ≤ negotiated MaxBurstLength; also
    /// bounds memory per request.
    ///
    /// The default is 256 KiB rather than the 1 MiB it used to be, because
    /// large commands degrade badly once several are outstanding. Measured
    /// against a TrueNAS target over 10GbE, with the same number of bytes in
    /// flight either way:
    ///
    ///     16 commands x 1 MiB   = 16 MiB outstanding ->  340 MB/s
    ///     64 commands x 256 KiB = 16 MiB outstanding -> 1169 MB/s
    ///
    /// 256 KiB reached the same ceiling as 1 MiB at low depth and kept it out
    /// to 64 outstanding, where 1 MiB fell to under a third of line rate
    /// somewhere between 8 and 16. Smaller commands cost more round trips for
    /// a given transfer, which pipelining already hides; the cliff is not
    /// something depth can compensate for.
    ///
    /// Measured on one target, and 1 MiB happens to be exactly its negotiated
    /// MaxBurstLength, so the boundary may be specific to it. The change is
    /// still the right default: 256 KiB was never slower anywhere tested, and
    /// it removes a failure mode that looks like the network being bad. See
    /// docs/queue-depth.md.
    private let maxTransferBytes: Int

    /// When true, every WRITE carries Force Unit Access, so the target commits
    /// the data to stable media before returning status.
    ///
    /// This exists because Backend A gets no barrier signal: FSKit never calls
    /// `synchronize`, so the layer above cannot tell us when a filesystem
    /// wanted a flush. If the target's write cache is volatile, an
    /// acknowledged-but-cached write can be lost on power failure while APFS
    /// believes its barrier was honoured — which is precisely how ordering
    /// guarantees turn into corruption. Write-through keeps each acknowledged
    /// write durable, at a cost in throughput.
    private let writeThrough: Bool

    public init(session: ISCSISession, lun: UInt64 = 0, maxTransferBytes: Int = 256 << 10,
                writeThrough: Bool = false) {
        self.session = session
        self.lun = lun
        self.maxTransferBytes = maxTransferBytes
        self.writeThrough = writeThrough
    }

    /// Reads the caching mode page (0x08) and reports whether the target's
    /// write cache is enabled (WCE). If it is, cached writes are volatile and
    /// `writeThrough` (or an explicit flush) is required for durability.
    ///
    /// Returns nil when the target does not provide the page.
    public func writeCacheEnabled() async throws -> Bool? {
        let result = try await executeAbsorbingUnitAttention(SCSITask(
            lun: lunAddress,
            cdb: CDB.modeSense10(pageCode: 0x08),
            direction: .read(expectedLength: 192)
        ))
        guard result.isGood else { return nil }
        return ModeSense.writeCacheEnabled(inResponse: result.data)
    }

    private var lunAddress: UInt64 { lun << 48 }

    /// Executes a task, absorbing UNIT ATTENTION.
    ///
    /// A target reports UNIT ATTENTION (sense key 0x06) on the first non-INQUIRY
    /// command of a fresh I_T nexus — "power on, reset, or bus device reset
    /// occurred" — and again after events like a target reset or a capacity
    /// change. Reporting the condition is what clears it, so the correct
    /// initiator behaviour is to retry rather than surface an error. Retrying
    /// the *login* cannot help: each new session re-arms the UA, so it has to be
    /// absorbed inside the session.
    private func executeAbsorbingUnitAttention(
        _ task: SCSITask,
        retries: Int = 2
    ) async throws -> SCSITaskResult {
        var attempt = 0
        while true {
            let result = try await session.execute(task)
            if result.isGood { return result }
            let sense = result.sense.flatMap(SenseData.init)
            guard sense?.key == 0x06, attempt < retries else { return result }
            attempt += 1
        }
    }

    /// Parse and sanity-check a READ CAPACITY(16) Data-In.
    ///
    /// Pure and `static` on purpose, for the same reason `ModeSense` is: it is a
    /// parser of wholly attacker-controlled bytes, so it should be reachable
    /// from a fuzzer without standing up a session. It had no such seam, and
    /// consequently had never been fuzzed.
    ///
    /// Three separate crashes lived in the four lines this replaces, all from
    /// trusting the numbers:
    ///
    /// - `lastLBA + 1` is a *trapping* add. Eight `0xFF` bytes aborted the
    ///   process — and `DaemonCore.login` calls this on every login, so it was
    ///   the first command of every session.
    /// - `blockSize` went unchecked into `maxTransferBytes / blockSize`, so a
    ///   reported size of zero was a division by zero on any path that skipped
    ///   `validate`.
    /// - `blockSize * blockCount` overflowed in the FSKit extension, and further
    ///   out a non-power-of-two size let `BlockAligner.alignUp` wrap.
    ///
    /// Requiring a power of two is doing more work than it looks like. It is
    /// what guarantees the largest multiple of `blockSize` below 2^64 leaves
    /// `blockSize - 1` bytes of headroom, which is what stops `alignUp`'s
    /// wrapping `&+` from rolling over. Relaxing this rule silently reopens
    /// that; there is a regression test pinning it.
    public static func geometry(fromReadCapacity16 data: Data) throws
        -> (blockSize: Int, blockCount: UInt64) {
        guard data.count >= 12 else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: 0, blockCount: 0,
                reason: "READ CAPACITY(16) returned \(data.count) bytes, needs at least 12")
        }
        let lastLBA = data.beU64(0)
        let blockSize = Int(data.beU32(8))

        guard lastLBA != .max else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: blockSize, blockCount: 0,
                reason: "last LBA is 2^64-1, so the block count would overflow")
        }
        let blockCount = lastLBA &+ 1

        guard blockSize >= 512, blockSize <= 1 << 20, blockSize.nonzeroBitCount == 1 else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: blockSize, blockCount: blockCount,
                reason: "block size must be a power of two between 512 and 1048576")
        }
        guard blockCount > 0 else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: blockSize, blockCount: 0, reason: "zero blocks")
        }
        guard !blockSize.multipliedReportingOverflow(by: Int(clamping: blockCount)).overflow,
              !UInt64(blockSize).multipliedReportingOverflow(by: blockCount).overflow else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: blockSize, blockCount: blockCount,
                reason: "block size x block count exceeds 2^64 bytes")
        }
        return (blockSize, blockCount)
    }

    /// READ CAPACITY(16) to learn geometry; cached after first call.
    public func readCapacity() async throws -> (blockSize: Int, blockCount: UInt64) {
        if capacityKnown { return (cachedBlockSize, cachedBlockCount) }
        let result = try await executeAbsorbingUnitAttention(SCSITask(
            lun: lunAddress,
            cdb: CDB.readCapacity16(),
            direction: .read(expectedLength: 32)
        ))
        guard result.isGood, result.data.count >= 12 else {
            throw BlockDeviceError.scsiError(status: result.status, sense: result.sense.flatMap(SenseData.init))
        }
        let (blockSize, blockCount) = try Self.geometry(fromReadCapacity16: result.data)
        cachedBlockSize = blockSize
        cachedBlockCount = blockCount
        capacityKnown = true
        return (cachedBlockSize, cachedBlockCount)
    }

    public var blockSize: Int {
        get async { capacityKnown ? cachedBlockSize : ((try? await readCapacity().blockSize) ?? 0) }
    }

    public var blockCount: UInt64 {
        get async { capacityKnown ? cachedBlockCount : ((try? await readCapacity().blockCount) ?? 0) }
    }

    public func read(offset: UInt64, length: Int) async throws -> Data {
        let (bs, count) = try await readCapacity()
        try validate(offset: offset, length: length, blockSize: bs, capacity: count)
        let blocksPerChunk = max(1, maxTransferBytes / bs)
        let firstLBA = offset / UInt64(bs)
        let totalBlocks = length / bs

        // One command: the overwhelmingly common case, and not worth a task
        // group.
        if totalBlocks <= blocksPerChunk {
            return try await readChunk(lba: firstLBA, blocks: totalBlocks, blockSize: bs)
        }

        // Several commands, issued together rather than one after another.
        //
        // They used to be sequential, which made splitting a request strictly
        // worse than not splitting it: a 1 MiB read became four 256 KiB round
        // trips end to end, ~189 MB/s where a single 1 MiB command managed 349.
        // That would have turned lowering maxTransferBytes — done to avoid the
        // large-command cliff described above — into a regression for anyone
        // asking for more than one chunk at a time.
        //
        // Concurrently, the split is a gain instead: the chunks of one request
        // pipeline against each other, which is the same reason readahead works
        // one layer up. Chunks of a read are independent and the results are
        // reassembled by index, so nothing depends on completion order.
        var plan: [(index: Int, lba: UInt64, blocks: Int)] = []
        var lba = firstLBA
        var remaining = totalBlocks
        while remaining > 0 {
            let blocks = min(remaining, blocksPerChunk)
            plan.append((plan.count, lba, blocks))
            lba += UInt64(blocks)
            remaining -= blocks
        }

        let parts = try await withThrowingTaskGroup(
            of: (Int, Data).self, returning: [Int: Data].self
        ) { group in
            for chunk in plan {
                group.addTask { [self] in
                    (chunk.index, try await readChunk(lba: chunk.lba,
                                                      blocks: chunk.blocks,
                                                      blockSize: bs))
                }
            }
            var collected: [Int: Data] = [:]
            for try await (index, data) in group { collected[index] = data }
            return collected
        }

        var out = Data(capacity: length)
        for chunk in plan {
            guard let part = parts[chunk.index] else { throw BlockDeviceError.notReady }
            out.append(part)
        }
        return out
    }

    private func readChunk(lba: UInt64, blocks: Int, blockSize bs: Int) async throws -> Data {
        let result = try await executeAbsorbingUnitAttention(SCSITask(
            lun: lunAddress,
            cdb: CDB.read16(lba: lba, blocks: UInt32(blocks)),
            direction: .read(expectedLength: UInt32(blocks * bs))
        ))
        guard result.isGood else {
            throw BlockDeviceError.scsiError(
                status: result.status, sense: result.sense.flatMap(SenseData.init))
        }
        return result.data
    }

    /// The chunks of one write pipeline against each other, for the same reason
    /// and by the same argument as `read`: they are contiguous slices of a single
    /// buffer, so they are **disjoint by construction** and nothing depends on
    /// the order they complete in. No ordering gate is needed or wanted here.
    ///
    /// This is deliberately not conditioned on the write-through setting. Four
    /// disjoint FUA writes issued together are each still individually durable
    /// when acknowledged, so there is no durability trade to gate on — this buys
    /// latency back without spending safety.
    ///
    /// What it does *not* do is give a small write any depth. A write is one
    /// FSKit operation and the extension holds `ioLock` across it, so the gain is
    /// confined to requests larger than `maxTransferBytes` — file copies, not the
    /// 7-16 KB writes a running VM makes.
    public func write(offset: UInt64, data: Data) async throws {
        let (bs, count) = try await readCapacity()
        try validate(offset: offset, length: data.count, blockSize: bs, capacity: count)
        let blocksPerChunk = max(1, maxTransferBytes / bs)

        // Ranges, not payloads. Materialising every chunk here would copy the
        // whole request before the first byte reached the wire — worse on peak
        // memory and worse on first-byte latency, which is the very thing
        // pipelining is for, and worse the larger the write. Each task slices
        // its own chunk when it is about to send it.
        //
        // The copy itself stays: `data[range]` is a slice carrying a non-zero
        // `startIndex`, and normalising it is what the original code's
        // `Data(chunk)` was doing.
        var plan: [(lba: UInt64, bytes: Range<Data.Index>)] = []
        var lba = offset / UInt64(bs)
        var cursor = data.startIndex
        var remaining = data.count / bs
        while remaining > 0 {
            let blocks = min(remaining, blocksPerChunk)
            let byteLen = blocks * bs
            plan.append((lba, cursor ..< cursor + byteLen))
            lba += UInt64(blocks)
            cursor += byteLen
            remaining -= blocks
        }

        // The overwhelmingly common case, and it should not pay for a task group
        // to discover it has one member.
        if plan.count == 1 {
            try await writeChunk(lba: plan[0].lba,
                                 payload: Data(data[plan[0].bytes]), blockSize: bs)
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for chunk in plan {
                group.addTask { [self] in
                    try await writeChunk(lba: chunk.lba,
                                         payload: Data(data[chunk.bytes]), blockSize: bs)
                }
            }
            try await group.waitForAll()
        }
    }

    /// One WRITE(16). On failure the group cancels its siblings, so which chunks
    /// reached the medium is indeterminate — as it already was, since a partial
    /// write is a partial write whether the survivors form a prefix or a subset.
    /// `DaemonStore.write` drops the whole overlap from its cache on any error
    /// for exactly that reason.
    private func writeChunk(lba: UInt64, payload: Data, blockSize bs: Int) async throws {
        let result = try await executeAbsorbingUnitAttention(SCSITask(
            lun: lunAddress,
            cdb: CDB.write16(lba: lba, blocks: UInt32(payload.count / bs), fua: writeThrough),
            direction: .write(payload)
        ))
        guard result.isGood else {
            throw BlockDeviceError.scsiError(
                status: result.status, sense: result.sense.flatMap(SenseData.init))
        }
    }

    public func flush() async throws {
        let result = try await executeAbsorbingUnitAttention(SCSITask(lun: lunAddress, cdb: CDB.synchronizeCache16()))
        guard result.isGood else {
            throw BlockDeviceError.scsiError(status: result.status, sense: result.sense.flatMap(SenseData.init))
        }
    }

    private func validate(offset: UInt64, length: Int, blockSize: Int, capacity: UInt64) throws {
        guard blockSize > 0,
              offset % UInt64(blockSize) == 0,
              length % blockSize == 0,
              length >= 0
        else {
            throw BlockDeviceError.misaligned(offset: offset, length: length, blockSize: blockSize)
        }
        let lba = offset / UInt64(blockSize)
        let blocks = UInt32(length / blockSize)
        guard UInt64(lba) + UInt64(blocks) <= capacity else {
            throw BlockDeviceError.outOfRange(lba: lba, blocks: blocks, capacity: capacity)
        }
    }
}
