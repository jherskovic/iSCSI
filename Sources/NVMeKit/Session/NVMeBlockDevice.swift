import Foundation
import iSCSIKit

/// A linear, byte-addressable block device backed by one NVMe namespace —
/// the `ISCSIBlockDevice` twin, with the same chunking, the same in-flight
/// bound, and FUA on every write when `writeThrough` is set.
public actor NVMeBlockDevice: BlockDeviceBackend {
    private let controller: NVMeController
    public let nsid: UInt32
    private var cachedBlockSize: Int = 0
    private var cachedBlockCount: UInt64 = 0
    private var capacityKnown = false

    /// Cap per-command transfer, further clamped to MDTS. 256 KiB for the
    /// same reasons as iSCSI (docs/queue-depth.md). NLB is 16-bit, which
    /// this never approaches at any block size in use.
    private let requestedMaxTransferBytes: Int

    /// When true, every Write carries Force Unit Access. Backend A gets no
    /// barrier signal from FSKit, so with a volatile controller cache an
    /// acknowledged-but-cached write breaks APFS's ordering guarantees.
    private let writeThrough: Bool

    public init(controller: NVMeController, nsid: UInt32, maxTransferBytes: Int = 256 << 10,
                writeThrough: Bool = false) {
        self.controller = controller
        self.nsid = nsid
        self.requestedMaxTransferBytes = maxTransferBytes
        self.writeThrough = writeThrough
    }

    /// VWC from Identify Controller: never nil once the controller is up.
    public func writeCacheEnabled() async throws -> Bool? {
        await controller.volatileWriteCachePresent
    }

    /// Identify Namespace, cached after the first call.
    public func readCapacity() async throws -> (blockSize: Int, blockCount: UInt64) {
        if capacityKnown { return (cachedBlockSize, cachedBlockCount) }
        let (blockSize, blockCount) = try await controller.identifyNamespace(nsid)
        cachedBlockSize = blockSize
        cachedBlockCount = blockCount
        capacityKnown = true
        return (blockSize, blockCount)
    }

    public var blockSize: Int {
        get async { capacityKnown ? cachedBlockSize : ((try? await readCapacity().blockSize) ?? 0) }
    }

    public var blockCount: UInt64 {
        get async { capacityKnown ? cachedBlockCount : ((try? await readCapacity().blockCount) ?? 0) }
    }

    private func maxTransferBytes() async -> Int {
        min(requestedMaxTransferBytes, await controller.maxTransferBytes ?? Int.max)
    }

    public func read(offset: UInt64, length: Int) async throws -> Data {
        let (bs, count) = try await readCapacity()
        try validate(offset: offset, length: length, blockSize: bs, capacity: count)
        let blocksPerChunk = max(1, await maxTransferBytes() / bs)
        let firstLBA = offset / UInt64(bs)
        let totalBlocks = length / bs

        if totalBlocks <= blocksPerChunk {
            return try await readChunk(lba: firstLBA, blocks: totalBlocks, blockSize: bs)
        }

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
                    (chunk.index, try await readChunk(lba: chunk.lba, blocks: chunk.blocks, blockSize: bs))
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
        let completion = try await controller.execute(
            NVMeCommands.read(commandID: 0, nsid: nsid, slba: lba, blocks: UInt32(blocks), blockSize: bs),
            expectedRead: blocks * bs)
        return completion.data
    }

    /// Chunks of one write pipeline concurrently, bounded: they are disjoint
    /// by construction, and disjoint FUA writes are each still durable when
    /// acknowledged, so write-through loses nothing.
    public func write(offset: UInt64, data: Data) async throws {
        let (bs, count) = try await readCapacity()
        try validate(offset: offset, length: data.count, blockSize: bs, capacity: count)
        let blocksPerChunk = max(1, await maxTransferBytes() / bs)

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

        if plan.count == 1 {
            try await writeChunk(lba: plan[0].lba, payload: Data(data[plan[0].bytes]), blockSize: bs)
            return
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            var next = 0
            func addNext() {
                let chunk = plan[next]
                next += 1
                group.addTask { [self] in
                    try await writeChunk(lba: chunk.lba, payload: Data(data[chunk.bytes]), blockSize: bs)
                }
            }
            while next < min(Self.maxChunksInFlight, plan.count) { addNext() }
            while try await group.next() != nil {
                if next < plan.count { addNext() }
            }
        }
    }

    /// Commands one request may have outstanding; the same bound as iSCSI.
    public static let maxChunksInFlight = 8

    private func writeChunk(lba: UInt64, payload: Data, blockSize bs: Int) async throws {
        _ = try await controller.execute(
            NVMeCommands.write(commandID: 0, nsid: nsid, slba: lba, blocks: UInt32(payload.count / bs),
                               blockSize: bs, fua: writeThrough, inCapsule: false),
            data: payload)
    }

    public func flush() async throws {
        _ = try await controller.execute(NVMeCommands.flush(commandID: 0, nsid: nsid))
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
