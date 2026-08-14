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

    public init(session: ISCSISession, lun: UInt64 = 0, maxTransferBytes: Int = 1 << 20,
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
        let lastLBA = result.data.beU64(0)
        cachedBlockSize = Int(result.data.beU32(8))
        cachedBlockCount = lastLBA + 1
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

        var out = Data(capacity: length)
        var lba = offset / UInt64(bs)
        var remaining = length / bs
        while remaining > 0 {
            let blocks = min(remaining, blocksPerChunk)
            let byteLen = blocks * bs
            let result = try await executeAbsorbingUnitAttention(SCSITask(
                lun: lunAddress,
                cdb: CDB.read16(lba: lba, blocks: UInt32(blocks)),
                direction: .read(expectedLength: UInt32(byteLen))
            ))
            guard result.isGood else {
                throw BlockDeviceError.scsiError(status: result.status, sense: result.sense.flatMap(SenseData.init))
            }
            out.append(result.data)
            lba += UInt64(blocks)
            remaining -= blocks
        }
        return out
    }

    public func write(offset: UInt64, data: Data) async throws {
        let (bs, count) = try await readCapacity()
        try validate(offset: offset, length: data.count, blockSize: bs, capacity: count)
        let blocksPerChunk = max(1, maxTransferBytes / bs)

        var lba = offset / UInt64(bs)
        var cursor = data.startIndex
        var remaining = data.count / bs
        while remaining > 0 {
            let blocks = min(remaining, blocksPerChunk)
            let byteLen = blocks * bs
            let chunk = data[cursor ..< cursor + byteLen]
            let result = try await executeAbsorbingUnitAttention(SCSITask(
                lun: lunAddress,
                cdb: CDB.write16(lba: lba, blocks: UInt32(blocks), fua: writeThrough),
                direction: .write(Data(chunk))
            ))
            guard result.isGood else {
                throw BlockDeviceError.scsiError(status: result.status, sense: result.sense.flatMap(SenseData.init))
            }
            lba += UInt64(blocks)
            cursor += byteLen
            remaining -= blocks
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
