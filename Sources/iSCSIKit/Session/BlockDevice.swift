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
    /// Flush the device cache (SCSI SYNCHRONIZE CACHE, NVMe Flush).
    func flush() async throws
    /// Geometry, fetched on first use and cached; `blockSize`/`blockCount`
    /// are the non-throwing view of the same answer.
    func readCapacity() async throws -> (blockSize: Int, blockCount: UInt64)
    /// Whether the device has a volatile write cache (SCSI WCE, NVMe VWC),
    /// so FUA and flushes decide durability. nil when the device did not say.
    func writeCacheEnabled() async throws -> Bool?
}

public enum BlockDeviceError: Error, Equatable, Sendable {
    case notReady
    case misaligned(offset: UInt64, length: Int, blockSize: Int)
    case outOfRange(lba: UInt64, blocks: UInt32, capacity: UInt64)
    case scsiError(status: UInt8, sense: SenseData?)
    /// READ CAPACITY described a device that cannot exist; nothing the
    /// initiator does will make this target usable.
    case invalidGeometry(blockSize: Int, blockCount: UInt64, reason: String)
    /// An NVMe controller completed a command with a non-success status:
    /// Status Code Type, Status Code, and the opcode it answered. Lives in
    /// this enum, not NVMeKit, so `ISCSIError.classify` can see it.
    case nvmeStatus(sct: UInt8, sc: UInt8, opcode: UInt8)
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
    /// bounds memory per request. 256 KiB, not 1 MiB: large commands collapse
    /// under queue depth on real targets, and 256 KiB was never slower
    /// anywhere tested. See docs/queue-depth.md.
    private let maxTransferBytes: Int

    /// When true, every WRITE carries Force Unit Access. Backend A gets no
    /// barrier signal from FSKit, so with a volatile target cache an
    /// acknowledged-but-cached write breaks APFS's ordering guarantees;
    /// write-through keeps each acknowledged write durable, at a throughput
    /// cost.
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

    private var lunAddress: UInt64 { SCSITask.lunField(lun) }

    /// Executes a task, absorbing UNIT ATTENTION (sense key 0x06): targets
    /// report it on the first non-INQUIRY command of a fresh I_T nexus and
    /// after resets. Reporting clears it, so retry here — re-login re-arms it.
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

    /// Parse and sanity-check a READ CAPACITY(16) Data-In. Pure and `static`
    /// so the fuzzer can reach a parser of attacker-controlled bytes without a
    /// session. The power-of-two block-size rule is load-bearing: it is what
    /// keeps `BlockAligner.alignUp`'s wrapping `&+` from rolling over near
    /// 2^64 (regression-tested); relaxing it silently reopens that.
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

        // Several commands, issued concurrently: sequential chunks would make
        // splitting strictly worse than not splitting. Chunks are independent
        // and reassembled by index, so completion order is irrelevant.
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

    /// Chunks of one write pipeline concurrently: they are disjoint by
    /// construction, and disjoint FUA writes are each still durable when
    /// acknowledged, so write-through loses nothing. The gain only applies to
    /// requests larger than `maxTransferBytes` — the extension holds `ioLock`
    /// across each FSKit write.
    public func write(offset: UInt64, data: Data) async throws {
        let (bs, count) = try await readCapacity()
        try validate(offset: offset, length: data.count, blockSize: bs, capacity: count)
        let blocksPerChunk = max(1, maxTransferBytes / bs)

        // Ranges, not payloads: materialising every chunk up front would copy
        // the whole request before the first byte hit the wire. Each task
        // slices (and `Data(...)`-normalises) its chunk when it sends it.
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

        // The common case should not pay for a one-member task group.
        if plan.count == 1 {
            try await writeChunk(lba: plan[0].lba,
                                 payload: Data(data[plan[0].bytes]), blockSize: bs)
            return
        }

        // Bounded: unbounded submission holds a copy of most of the request
        // (the CmdSN window does not cap it — tasks churn while their
        // allocations stay), so a file copy would cost memory proportional to
        // the file.
        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                let chunk = plan[next]
                next += 1
                group.addTask { [self] in
                    try await writeChunk(lba: chunk.lba,
                                         payload: Data(data[chunk.bytes]), blockSize: bs)
                }
            }
            while next < min(Self.maxChunksInFlight, plan.count) { addNext() }
            while try await group.next() != nil {
                if next < plan.count { addNext() }
            }
        }
    }

    /// Commands one request may have outstanding; caps a single request at
    /// this many chunk copies regardless of its size.
    static let maxChunksInFlight = 8

    /// One WRITE(16). On failure the group cancels its siblings, so which
    /// chunks reached the medium is indeterminate; `DaemonStore.write` drops
    /// the whole overlap from its cache on any error for that reason.
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
