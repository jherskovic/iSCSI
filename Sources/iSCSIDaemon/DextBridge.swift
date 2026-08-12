#if canImport(IOKit)
import Foundation
import IOKit
import iSCSIKit

// MARK: - Wire contract
//
// Everything in this section mirrors apps/Shared/iSCSIUserClientShared.h,
// which is the SOURCE OF TRUTH for the daemon<->dext contract. That header
// lives in the Xcode app project and is not reachable from this SwiftPM
// target (no bridging header here), so the values are restated. If the header
// changes, change these to match.

/// External method selectors on the dext's IOUserClient.
private enum DextSelector {
    static let publishLUN: UInt32 = 0     // in: blockSize, blockCount
    static let unpublishLUN: UInt32 = 1   // no args
    static let setRingBuffer: UInt32 = 2  // memory type for CopyClientMemoryForType
    static let fetchTask: UInt32 = 3      // out: 9 scalars, see FetchScalar
    static let completeTask: UInt32 = 4   // in: 4 scalars, see CompleteScalar
    static let teardownNub: UInt32 = 5    // reboot-free upgrade: drop the nub
}

/// Scalar output order for `kISCSIUserClientFetchTask`.
private enum FetchScalar {
    static let taskTag = 0        // 0 => no task pending
    static let slotIndex = 1      // payload at slotIndex * slotPayloadBytes
    static let targetID = 2
    static let lun = 3
    static let direction = 4      // 0 none, 1 device->initiator (read), 2 write
    static let transferLength = 5
    static let cdbLow = 6         // CDB bytes 0-7, little-endian packed
    static let cdbHigh = 7        // CDB bytes 8-15
    static let cdbLength = 8
    static let count = 9
}

/// Scalar input order for `kISCSIUserClientCompleteTask`.
private enum CompleteScalar {
    static let taskTag = 0
    static let scsiStatus = 1
    static let dataLength = 2
    static let senseLength = 3
    static let count = 4
}

/// Transfer directions used in the fetch scalars.
private enum DextDirection {
    static let none: UInt64 = 0
    static let read: UInt64 = 1
    static let write: UInt64 = 2
}

/// Per-slot data window inside the shared arena (`kISCSISlotPayloadBytes`).
private let slotPayloadBytes = 65_536
/// Total payload arena (`kISCSIDataRegionBytes`), 256 slots of 64 KiB.
private let dataRegionBytes = 16 * 1024 * 1024

/// SAM status bytes we hand back to the dext.
private enum SAMStatus {
    static let good: UInt8 = 0x00
    static let checkCondition: UInt8 = 0x02
}

/// The SCSI opcodes the dext can hand us for a disk LUN.
private enum SCSIOpcode {
    static let testUnitReady: UInt8 = 0x00
    static let read10: UInt8 = 0x28
    static let write10: UInt8 = 0x2A
    static let synchronizeCache10: UInt8 = 0x35
    static let read16: UInt8 = 0x88
    static let write16: UInt8 = 0x8A
    static let synchronizeCache16: UInt8 = 0x91
}

/// Sense keys / ASC-ASCQ pairs used when we have to fail a task.
private enum SenseCode {
    static let mediumError: UInt8 = 0x04
    static let illegalRequest: UInt8 = 0x05
    static let ascInvalidOpcode: UInt8 = 0x20      // INVALID COMMAND OPERATION CODE
    static let ascUnrecoveredRead: UInt8 = 0x11    // UNRECOVERED READ ERROR
    static let ascLBAOutOfRange: UInt8 = 0x21      // LOGICAL BLOCK ADDRESS OUT OF RANGE
    static let ascNotReady: UInt8 = 0x04           // LUN NOT READY
}

// MARK: - Errors

public enum DextBridgeError: Error, Sendable, CustomStringConvertible {
    /// No IOService matched; the dext isn't loaded/activated.
    case serviceNotFound(String)
    case openFailed(kern_return_t)
    case mapFailed(kern_return_t)
    /// `open()` hasn't been called (or `close()` already was).
    case notConnected
    case methodFailed(selector: UInt32, code: kern_return_t)

    public var description: String {
        switch self {
        case .serviceNotFound(let name):
            return "no IOService matching \"\(name)\" (is the dext activated?)"
        case .openFailed(let kr):
            return "IOServiceOpen failed: \(Self.hex(kr))"
        case .mapFailed(let kr):
            return "IOConnectMapMemory64 failed: \(Self.hex(kr))"
        case .notConnected:
            return "dext user client is not open"
        case .methodFailed(let selector, let kr):
            return "IOConnectCallScalarMethod(selector: \(selector)) failed: \(Self.hex(kr))"
        }
    }

    private static func hex(_ kr: kern_return_t) -> String {
        "0x" + String(UInt32(bitPattern: kr), radix: 16)
    }
}

// MARK: - Logging

/// File-scope so the concurrent servicing path (which is deliberately outside
/// the actor) can log without touching `DextBridge` at all.
private func dextLog(_ message: String) {
    FileHandle.standardError.write(Data("iscsid[dext]: \(message)\n".utf8))
}

/// Set ISCSI_TRACE_TASKS=1 to log every serviced READ/WRITE with its LBA —
/// forensics for content-level bugs that per-PDU tracing can't see.
private let traceTasks = ProcessInfo.processInfo.environment["ISCSI_TRACE_TASKS"] != nil

// MARK: - Decoding helpers
//
// Pure functions at file scope: the per-task path must not reach into the
// actor for anything, not even a static member lookup.

/// CDB bytes 0-7 arrive packed little-endian in `low`, 8-15 in `high`.
private func unpackCDB(low: UInt64, high: UInt64) -> [UInt8] {
    var cdb = [UInt8](repeating: 0, count: 16)
    for i in 0 ..< 8 {
        cdb[i] = UInt8(truncatingIfNeeded: low >> (8 * UInt64(i)))
        cdb[8 + i] = UInt8(truncatingIfNeeded: high >> (8 * UInt64(i)))
    }
    return cdb
}

/// LBA + block count for READ/WRITE (10) and (16). All big-endian:
/// 10-byte: LBA = bytes 2-5, blocks = bytes 7-8.
/// 16-byte: LBA = bytes 2-9, blocks = bytes 10-13.
private func cdbRange(cdb: [UInt8], sixteenByte: Bool) -> (lba: UInt64, blocks: UInt32) {
    if sixteenByte {
        var lba: UInt64 = 0
        for i in 2 ... 9 { lba = (lba << 8) | UInt64(cdb[i]) }
        var blocks: UInt32 = 0
        for i in 10 ... 13 { blocks = (blocks << 8) | UInt32(cdb[i]) }
        return (lba, blocks)
    }
    var lba: UInt64 = 0
    for i in 2 ... 5 { lba = (lba << 8) | UInt64(cdb[i]) }
    let blocks = (UInt32(cdb[7]) << 8) | UInt32(cdb[8])
    return (lba, blocks)
}

/// 18-byte fixed-format sense (response code 0x70, additional length 10).
private func fixedSense(key: UInt8, asc: UInt8, ascq: UInt8) -> [UInt8] {
    var sense = [UInt8](repeating: 0, count: 18)
    sense[0] = 0x70          // current error, fixed format
    sense[2] = key & 0x0F
    sense[7] = 10            // additional sense length: 18 - 8
    sense[12] = asc
    sense[13] = ascq
    return sense
}

/// Bytes to move for a task: what the CDB asks for, never more than the
/// dext's own transfer length or one slot window.
private func transferBytes(blocks: UInt32, requested: Int, blockSize: Int) -> Int {
    let byCDB = Int(blocks) * blockSize
    let bounded = requested > 0 ? min(byCDB, requested) : byCDB
    return min(bounded, slotPayloadBytes)
}

// MARK: - Connection ownership

/// Owns the IOKit connection and the mapped arena. A reference type so the
/// resources can be released from `deinit` without actor-isolation gymnastics,
/// and `@unchecked Sendable` because it carries a raw pointer: the pointer is
/// immutable after init and IOKit connections are safe to call from any thread.
///
/// All of the dext plumbing (fetch/complete/payload) lives here rather than on
/// the actor so that many tasks can be serviced at once: an actor-isolated
/// `complete()` would funnel every in-flight task back through one executor and
/// re-serialise the pump.
private final class DextLink: @unchecked Sendable {
    let connection: io_connect_t
    let arena: UnsafeMutableRawPointer
    let arenaSize: Int
    /// Byte offset of the payload arena inside the mapped region.
    let dataRegionOffset: Int
    private let arenaAddress: mach_vm_address_t
    private let gate = NSCondition()
    private var isOpen = true
    private var activeCalls = 0

    init(connection: io_connect_t,
         arena: UnsafeMutableRawPointer,
         arenaAddress: mach_vm_address_t,
         arenaSize: Int,
         dataRegionOffset: Int) {
        self.connection = connection
        self.arena = arena
        self.arenaAddress = arenaAddress
        self.arenaSize = arenaSize
        self.dataRegionOffset = dataRegionOffset
    }

    /// Idempotent: safe to call explicitly and again from `deinit`.
    ///
    /// Waits for in-flight IOKit calls to return first. `close()` and the pump
    /// used to be mutually exclusive because both were actor-isolated; now that
    /// servicing runs off-actor, this is what keeps the mach port from being
    /// torn down underneath a call that is already in the kernel.
    func close() {
        gate.lock()
        guard isOpen else { gate.unlock(); return }
        isOpen = false
        while activeCalls > 0 { gate.wait() }
        gate.unlock()
        IOConnectUnmapMemory64(connection, DextSelector.setRingBuffer, mach_task_self_, arenaAddress)
        IOServiceClose(connection)
    }

    deinit { close() }

    // MARK: IOKit plumbing

    /// Runs `body` on the connection unless we're closed. Concurrent callers go
    /// through together — the lock is only held to admit and retire them, never
    /// across the mach trap — so this costs nothing in parallelism.
    private func withConnection<T>(_ body: (io_connect_t) -> T) -> T? {
        gate.lock()
        guard isOpen else { gate.unlock(); return nil }
        activeCalls += 1
        gate.unlock()
        defer {
            gate.lock()
            activeCalls -= 1
            if activeCalls == 0 { gate.broadcast() }
            gate.unlock()
        }
        return body(connection)
    }

    func callScalar(_ selector: UInt32, input: [UInt64]) throws {
        let kr = withConnection { connection in
            input.withUnsafeBufferPointer { buffer in
                IOConnectCallScalarMethod(
                    connection,
                    selector,
                    buffer.baseAddress,
                    UInt32(input.count),
                    nil, nil
                )
            }
        }
        guard let kr else { throw DextBridgeError.notConnected }
        guard kr == KERN_SUCCESS else {
            throw DextBridgeError.methodFailed(selector: selector, code: kr)
        }
    }

    /// Pull the next parked task, or nil when the dext has nothing pending.
    func fetch() throws -> FetchedTask? {
        var out = [UInt64](repeating: 0, count: FetchScalar.count)
        var outCount = UInt32(FetchScalar.count)
        let result = withConnection { connection in
            out.withUnsafeMutableBufferPointer { buffer in
                IOConnectCallScalarMethod(
                    connection,
                    DextSelector.fetchTask,
                    nil, 0,
                    buffer.baseAddress,
                    &outCount
                )
            }
        }
        guard let kr = result else { throw DextBridgeError.notConnected }
        guard kr == KERN_SUCCESS else {
            throw DextBridgeError.methodFailed(selector: DextSelector.fetchTask, code: kr)
        }
        guard outCount >= UInt32(FetchScalar.count) else {
            throw DextBridgeError.methodFailed(selector: DextSelector.fetchTask, code: kIOReturnUnderrun)
        }
        let taskTag = out[FetchScalar.taskTag]
        guard taskTag != 0 else { return nil }  // idle

        return FetchedTask(
            taskTag: taskTag,
            slotIndex: out[FetchScalar.slotIndex],
            targetID: out[FetchScalar.targetID],
            lun: out[FetchScalar.lun],
            direction: out[FetchScalar.direction],
            transferLength: Int(min(out[FetchScalar.transferLength], UInt64(slotPayloadBytes))),
            cdb: unpackCDB(low: out[FetchScalar.cdbLow], high: out[FetchScalar.cdbHigh]),
            cdbLength: Int(min(out[FetchScalar.cdbLength], 16))
        )
    }

    func complete(taskTag: UInt64,
                  status: UInt8,
                  dataLength: Int,
                  senseLength: Int = 0) {
        var input = [UInt64](repeating: 0, count: CompleteScalar.count)
        input[CompleteScalar.taskTag] = taskTag
        input[CompleteScalar.scsiStatus] = UInt64(status)
        input[CompleteScalar.dataLength] = UInt64(max(0, dataLength))
        input[CompleteScalar.senseLength] = UInt64(max(0, senseLength))
        let kr = withConnection { connection in
            input.withUnsafeBufferPointer { buffer in
                IOConnectCallScalarMethod(
                    connection,
                    DextSelector.completeTask,
                    buffer.baseAddress,
                    UInt32(CompleteScalar.count),
                    nil, nil
                )
            }
        }
        guard let kr else { return }   // closed; nothing left to answer to
        if kr != KERN_SUCCESS {
            dextLog("CompleteTask(\(taskTag)) failed: 0x\(String(UInt32(bitPattern: kr), radix: 16))")
        }
    }

    /// Base of a task's payload window inside the mapped arena, bounds-checked.
    /// Nil once closed: the arena is unmapped and the pointer would dangle.
    func payload(slot: UInt64) -> UnsafeMutableRawPointer? {
        gate.lock()
        let open = isOpen
        gate.unlock()
        guard open else { return nil }
        guard slot < UInt64(Int.max / slotPayloadBytes) else { return nil }
        let offset = dataRegionOffset + Int(slot) * slotPayloadBytes
        guard offset >= 0, offset + slotPayloadBytes <= arenaSize else { return nil }
        return arena.advanced(by: offset)
    }

    /// Stage fixed-format sense in a task's slot; returns the sense length to
    /// report (0 when the slot is out of bounds).
    func stageSense(slot: UInt64, key: UInt8, asc: UInt8, ascq: UInt8) -> Int {
        guard let payload = payload(slot: slot) else { return 0 }
        let sense = fixedSense(key: key, asc: asc, ascq: ascq)
        sense.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                payload.copyMemory(from: src, byteCount: sense.count)
            }
        }
        return sense.count
    }
}

/// One task fetched from the dext, decoded out of the fetch scalars.
private struct FetchedTask: Sendable {
    let taskTag: UInt64
    let slotIndex: UInt64
    let targetID: UInt64
    let lun: UInt64
    let direction: UInt64
    let transferLength: Int
    let cdb: [UInt8]
    let cdbLength: Int

    var opcode: UInt8 { cdb[0] }
}

// MARK: - In-flight bookkeeping

/// Tags handed to a servicer but not yet answered.
///
/// Two jobs, both required now that tasks are serviced concurrently:
/// 1. `claim` makes completion one-shot. The servicing path and the timeout
///    path race for every task and the dext must see exactly one CompleteTask
///    per tag, or it would complete a slot that has already been recycled.
/// 2. `drain` lets the pump answer everything still parked when it exits, so
///    the kernel never waits on a task nobody is going to finish.
private final class InFlightTable: @unchecked Sendable {
    private let lock = NSLock()
    private var tasks: [UInt64: UInt64] = [:]   // taskTag -> slotIndex

    func add(tag: UInt64, slot: UInt64) {
        lock.lock()
        tasks[tag] = slot
        lock.unlock()
    }

    /// True exactly once per tag: the winner owns posting the completion.
    func claim(tag: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return tasks.removeValue(forKey: tag) != nil
    }

    /// Take ownership of everything outstanding, leaving the table empty.
    func drain() -> [(tag: UInt64, slot: UInt64)] {
        lock.lock()
        defer { lock.unlock() }
        let parked = tasks.map { (tag: $0.key, slot: $0.value) }
        tasks.removeAll()
        return parked
    }
}

// MARK: - Overlap ordering

/// Admission control that preserves submission order for OVERLAPPING block
/// ranges while letting disjoint I/O run fully concurrent.
///
/// The kernel rewrites the same LBA back-to-back (superblocks, GPT headers,
/// journal heads) trusting the device to apply them in submission order. With
/// N concurrent servicers and no gate, the second write can reach the target
/// first and the FINAL on-disk content is the older data — nondeterministic
/// corruption that per-op CRC tracing can never see. Tickets are issued in
/// fetch order (the pump loop is serial); a task waits until every in-flight
/// or earlier-queued task whose range overlaps its own has released.
///
/// Lock-based rather than an actor so `release` is synchronous — it must run
/// in a `defer` inside servicers that the timeout path may abandon, and an
/// abandoned-but-stuck task legitimately HOLDS its range: its write may still
/// be live on the wire, and admitting an overlapper would reorder it.
private final class OrderingGate: @unchecked Sendable {
    private struct Entry {
        let id: UInt64
        let range: Range<UInt64>
        var continuation: CheckedContinuation<Void, Never>?
        var admitted: Bool
    }

    private let lock = NSLock()
    private var entries: [Entry] = []   // ticket order; small (≤ maxInFlight)
    private var nextID: UInt64 = 0

    /// Issue a ticket in submission order. Call from the (serial) pump loop.
    func enqueue(_ range: Range<UInt64>) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        let id = nextID
        nextID += 1
        entries.append(Entry(id: id, range: range, continuation: nil, admitted: false))
        return id
    }

    /// Suspend until every overlapping predecessor has released.
    func admitted(_ id: UInt64) async {
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            lock.lock()
            guard let idx = entries.firstIndex(where: { $0.id == id }) else {
                lock.unlock()
                cont.resume()   // released before it ever waited (wind-down)
                return
            }
            if clearAt(idx) {
                entries[idx].admitted = true
                lock.unlock()
                cont.resume()
            } else {
                entries[idx].continuation = cont
                lock.unlock()
            }
        }
    }

    /// Drop the ticket and admit any newly-eligible waiters. Synchronous and
    /// idempotent; safe from `defer`.
    func release(_ id: UInt64) {
        lock.lock()
        entries.removeAll { $0.id == id }
        var resumable: [CheckedContinuation<Void, Never>] = []
        for idx in entries.indices where entries[idx].continuation != nil && clearAt(idx) {
            entries[idx].admitted = true
            resumable.append(entries[idx].continuation!)
            entries[idx].continuation = nil
        }
        lock.unlock()
        for cont in resumable { cont.resume() }
    }

    /// True when nothing earlier in ticket order overlaps entries[idx].
    /// Caller holds the lock.
    private func clearAt(_ idx: Int) -> Bool {
        let range = entries[idx].range
        for j in 0 ..< idx where entries[j].range.overlaps(range) {
            return false
        }
        return true
    }
}

/// The block range a task touches, for overlap ordering. Flushes are a
/// full-device barrier; non-I/O tasks need no ordering.
private func taskRange(_ task: FetchedTask, blockSize: Int) -> Range<UInt64>? {
    switch task.opcode {
    case SCSIOpcode.read10, SCSIOpcode.read16, SCSIOpcode.write10, SCSIOpcode.write16:
        guard blockSize > 0 else { return nil }
        let sixteen = task.opcode == SCSIOpcode.read16 || task.opcode == SCSIOpcode.write16
        let (lba, blocks) = cdbRange(cdb: task.cdb, sixteenByte: sixteen)
        return lba ..< lba + UInt64(max(1, blocks))
    case SCSIOpcode.synchronizeCache10, SCSIOpcode.synchronizeCache16:
        return 0 ..< UInt64.max
    default:
        return nil
    }
}

// MARK: - Bounded-time execution

/// One-shot resolver shared by a unit of work and its watchdog.
///
/// Both sides are unstructured `Task`s so the loser can simply be abandoned:
/// a structured child would have to be awaited, which is exactly what we must
/// avoid when an iSCSI round trip wedges and ignores cancellation.
private final class TimeoutRace: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?
    private var work: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var finished = false

    /// Kick off the work and the watchdog. If the race was already lost (the
    /// surrounding task was cancelled before we got here) neither is started.
    func begin(_ continuation: CheckedContinuation<Bool, Never>,
               timeout: Duration,
               operation: @escaping @Sendable () async -> Void) {
        lock.lock()
        if finished {
            lock.unlock()
            continuation.resume(returning: false)
            return
        }
        self.continuation = continuation
        lock.unlock()

        let timer = Task {
            do { try await Task.sleep(for: timeout) } catch { return }
            self.finish(false)
        }
        let work = Task {
            await operation()
            self.finish(true)
        }

        lock.lock()
        if finished {
            // Someone resolved us while we were spawning; clean both up.
            lock.unlock()
            work.cancel()
            timer.cancel()
            return
        }
        self.work = work
        self.timer = timer
        lock.unlock()
    }

    /// `true` when the work completed, `false` when we gave up on it.
    func finish(_ completed: Bool) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let continuation = self.continuation
        let work = self.work
        let timer = self.timer
        self.continuation = nil
        self.work = nil
        self.timer = nil
        lock.unlock()

        if !completed { work?.cancel() }   // ask nicely; we do not wait for it
        timer?.cancel()
        continuation?.resume(returning: completed)
    }
}

/// Run `operation`, giving up after `timeout` or as soon as the surrounding
/// task is cancelled. Returns false when we gave up.
///
/// The abandoned operation is cancelled but never awaited, so a hung iSCSI
/// call can delay nothing: the caller's in-flight slot is released immediately
/// and the task is failed back to the kernel.
private func withTimeout(_ timeout: Duration,
                         operation: @escaping @Sendable () async -> Void) async -> Bool {
    let race = TimeoutRace()
    return await withTaskCancellationHandler {
        await withCheckedContinuation { continuation in
            race.begin(continuation, timeout: timeout, operation: operation)
        }
    } onCancel: {
        race.finish(false)
    }
}

// MARK: - Task servicing (deliberately outside the actor)
//
// Nothing below this line touches `DextBridge`. Everything the hot path needs
// — the link, the task (tag, slot, CDB, direction, lengths), the block size,
// the session handle and the core — arrives by value, so N tasks really do run
// at once instead of queueing on the bridge's executor.

/// Post a completion, but only if nobody else already has.
private func postCompletion(_ link: DextLink,
                            _ table: InFlightTable,
                            tag: UInt64,
                            status: UInt8,
                            dataLength: Int,
                            senseLength: Int = 0) {
    guard table.claim(tag: tag) else { return }
    link.complete(taskTag: tag, status: status, dataLength: dataLength, senseLength: senseLength)
}

/// Answer a task with CHECK CONDITION plus fixed-format sense written into
/// the task's slot.
private func postFailure(_ link: DextLink,
                         _ table: InFlightTable,
                         task: FetchedTask,
                         key: UInt8,
                         asc: UInt8,
                         ascq: UInt8) {
    guard table.claim(tag: task.taskTag) else { return }
    let senseLength = link.stageSense(slot: task.slotIndex, key: key, asc: asc, ascq: ascq)
    link.complete(taskTag: task.taskTag,
                  status: SAMStatus.checkCondition,
                  dataLength: 0,
                  senseLength: senseLength)
}

private func service(_ task: FetchedTask,
                     link: DextLink,
                     table: InFlightTable,
                     handle: String,
                     core: DaemonCore,
                     blockSize: Int) async {
    do {
        switch task.opcode {
        case SCSIOpcode.testUnitReady:
            postCompletion(link, table, tag: task.taskTag, status: SAMStatus.good, dataLength: 0)

        case SCSIOpcode.synchronizeCache10, SCSIOpcode.synchronizeCache16:
            try await core.flush(handle)
            postCompletion(link, table, tag: task.taskTag, status: SAMStatus.good, dataLength: 0)

        case SCSIOpcode.read10, SCSIOpcode.read16:
            try await serviceRead(task, link: link, table: table,
                                  handle: handle, core: core, blockSize: blockSize)

        case SCSIOpcode.write10, SCSIOpcode.write16:
            try await serviceWrite(task, link: link, table: table,
                                   handle: handle, core: core, blockSize: blockSize)

        default:
            dextLog("unsupported opcode 0x\(String(task.opcode, radix: 16)) (cdbLength \(task.cdbLength), direction \(task.direction))")
            postFailure(link, table, task: task, key: SenseCode.illegalRequest,
                        asc: SenseCode.ascInvalidOpcode, ascq: 0x00)
        }
    } catch {
        dextLog("task \(task.taskTag) (opcode 0x\(String(task.opcode, radix: 16))) failed: \(error)")
        postFailure(link, table, task: task, key: SenseCode.mediumError,
                    asc: SenseCode.ascUnrecoveredRead, ascq: 0x00)
    }
}

private func serviceRead(_ task: FetchedTask,
                         link: DextLink,
                         table: InFlightTable,
                         handle: String,
                         core: DaemonCore,
                         blockSize: Int) async throws {
    guard blockSize > 0 else {
        postFailure(link, table, task: task, key: SenseCode.mediumError,
                    asc: SenseCode.ascNotReady, ascq: 0x00)
        return
    }
    guard let payload = link.payload(slot: task.slotIndex) else {
        postFailure(link, table, task: task, key: SenseCode.mediumError,
                    asc: SenseCode.ascLBAOutOfRange, ascq: 0x00)
        return
    }
    let (lba, blocks) = cdbRange(cdb: task.cdb, sixteenByte: task.opcode == SCSIOpcode.read16)
    let byCDB = Int(blocks) * blockSize
    let length = transferBytes(blocks: blocks, requested: task.transferLength, blockSize: blockSize)
    if length < byCDB {
        // Same single-segment truncation hazard as writes: a short read would
        // return a partial buffer the kernel treats as complete.
        dextLog("SHORT READ lba=\(lba) cdb=\(byCDB)B mapped=\(task.transferLength)B — failing task \(task.taskTag)")
        postFailure(link, table, task: task, key: SenseCode.illegalRequest,
                    asc: SenseCode.ascInvalidOpcode, ascq: 0x00)
        return
    }
    guard length > 0 else {
        postCompletion(link, table, tag: task.taskTag, status: SAMStatus.good, dataLength: 0)
        return
    }

    let data = try await core.read(handle, offset: lba * UInt64(blockSize), length: length)
    if traceTasks {
        dextLog("R lba=\(lba) len=\(length) got=\(data.count) crc=\(String(format: "%08x", CRC32C.checksum(data))) tag=\(task.taskTag)")
    }
    let copied = min(data.count, length)
    if copied > 0 {
        data.withUnsafeBytes { raw in
            if let src = raw.baseAddress {
                payload.copyMemory(from: src, byteCount: copied)
            }
        }
    }
    postCompletion(link, table, tag: task.taskTag, status: SAMStatus.good, dataLength: copied)
}

private func serviceWrite(_ task: FetchedTask,
                          link: DextLink,
                          table: InFlightTable,
                          handle: String,
                          core: DaemonCore,
                          blockSize: Int) async throws {
    guard blockSize > 0 else {
        postFailure(link, table, task: task, key: SenseCode.mediumError,
                    asc: SenseCode.ascNotReady, ascq: 0x00)
        return
    }
    guard let payload = link.payload(slot: task.slotIndex) else {
        postFailure(link, table, task: task, key: SenseCode.mediumError,
                    asc: SenseCode.ascLBAOutOfRange, ascq: 0x00)
        return
    }
    let (lba, blocks) = cdbRange(cdb: task.cdb, sixteenByte: task.opcode == SCSIOpcode.write16)
    let byCDB = Int(blocks) * blockSize
    let length = transferBytes(blocks: blocks, requested: task.transferLength, blockSize: blockSize)
    if length < byCDB {
        // The CDB asks for more bytes than the dext could map from the task's
        // buffer (the single-physical-segment framework limitation). Writing a
        // truncated chunk would CORRUPT the LBA range silently — fail loudly.
        dextLog("SHORT WRITE lba=\(lba) cdb=\(byCDB)B mapped=\(task.transferLength)B — failing task \(task.taskTag)")
        postFailure(link, table, task: task, key: SenseCode.illegalRequest,
                    asc: SenseCode.ascInvalidOpcode, ascq: 0x00)
        return
    }
    guard length > 0 else {
        postCompletion(link, table, tag: task.taskTag, status: SAMStatus.good, dataLength: 0)
        return
    }

    // The dext already staged the outgoing bytes in our slot.
    let data = Data(bytes: payload, count: length)
    try await core.write(handle, offset: lba * UInt64(blockSize), data: data)
    // We advertise DPOFUA, so the kernel may set the FUA bit (journal
    // commits, barriers) expecting the data on stable media at completion.
    if task.cdb[1] & 0x08 != 0 {
        try await core.flush(handle)
    }
    if traceTasks {
        let fua = task.cdb[1] & 0x08 != 0 ? " FUA" : ""
        dextLog("W lba=\(lba) len=\(length) crc=\(String(format: "%08x", CRC32C.checksum(data))) tag=\(task.taskTag)\(fua)")
    }
    postCompletion(link, table, tag: task.taskTag, status: SAMStatus.good, dataLength: length)
}

// MARK: - The pump

/// Fetch tasks from the dext and service up to `maxInFlight` of them at once.
///
/// A free function, not an actor method, on purpose: `withTaskGroup` and every
/// child it spawns therefore start with no actor context at all, and the only
/// thing the loop ever blocks on is `group.next()` when it is genuinely at
/// capacity. Fetching stays cheap and never queues behind servicing.
private func pump(link: DextLink,
                  handle: String,
                  core: DaemonCore,
                  blockSize: Int,
                  maxInFlight: Int,
                  taskTimeout: Duration) async {
    let table = InFlightTable()
    let gate = OrderingGate()
    var consecutiveFetchFailures = 0

    await withTaskGroup(of: Void.self) { group in
        var inFlight = 0

        loop: while !Task.isCancelled {
            // At capacity: reclaim one servicer before taking on more work.
            // This is the ONLY place the loop waits on servicing.
            if inFlight >= maxInFlight {
                if await group.next() == nil { inFlight = 0 } else { inFlight -= 1 }
                continue
            }

            let fetched: FetchedTask?
            do {
                fetched = try link.fetch()
                consecutiveFetchFailures = 0
            } catch {
                consecutiveFetchFailures += 1
                dextLog("FetchTask failed (\(consecutiveFetchFailures)): \(error)")
                // Back off; a persistently dead connection shouldn't hot-spin.
                if consecutiveFetchFailures >= 50 {
                    dextLog("giving up on the dext connection")
                    break loop
                }
                if (try? await Task.sleep(for: .milliseconds(10))) == nil { break loop }
                continue
            }

            guard let task = fetched else {
                // Idle: nothing pending. Poll again shortly. When tasks ARE
                // pending we come straight back around without sleeping.
                if (try? await Task.sleep(for: .microseconds(500))) == nil { break loop }
                continue
            }

            table.add(tag: task.taskTag, slot: task.slotIndex)
            inFlight += 1
            // Ticket BEFORE addTask: the pump loop is the only place fetch
            // order is still known, and overlapping ranges must be serviced in
            // that order (see OrderingGate).
            let ticket = taskRange(task, blockSize: blockSize).map { gate.enqueue($0) }
            group.addTask {
                let completed = await withTimeout(taskTimeout) {
                    if let ticket {
                        await gate.admitted(ticket)
                    }
                    defer { if let ticket { gate.release(ticket) } }
                    await service(task, link: link, table: table,
                                  handle: handle, core: core, blockSize: blockSize)
                }
                if !completed {
                    // Timed out, or the pump is winding down. Free the dext's
                    // slot rather than leaving it parked forever; `postFailure`
                    // is a no-op if the servicer got there first.
                    postFailure(link, table, task: task, key: SenseCode.mediumError,
                                asc: SenseCode.ascUnrecoveredRead, ascq: 0x00)
                }
            }
        }

        // Leaving the pump — cancelled, or the connection gave up. Tell the
        // servicers to stop and answer anything still parked in the dext with
        // CHECK CONDITION: an unanswered task would leave the kernel's storage
        // stack waiting on a completion that is never coming. Completion is
        // one-shot (see InFlightTable), so a servicer that finishes during this
        // wind-down simply finds its tag already claimed and does nothing.
        group.cancelAll()
        let parked = table.drain()
        if !parked.isEmpty {
            dextLog("winding down: failing \(parked.count) task(s) still in flight")
            for entry in parked {
                let senseLength = link.stageSense(slot: entry.slot,
                                                  key: SenseCode.mediumError,
                                                  asc: SenseCode.ascUnrecoveredRead,
                                                  ascq: 0x00)
                link.complete(taskTag: entry.tag,
                              status: SAMStatus.checkCondition,
                              dataLength: 0,
                              senseLength: senseLength)
            }
        }
    }
}

// MARK: - DextBridge

/// User-space half of the DriverKit bridge: opens the dext's IOUserClient,
/// maps the shared payload arena, publishes LUN geometry, then pumps SCSI
/// tasks from the dext into `DaemonCore` and posts the results back.
///
/// Typical use:
/// ```swift
/// let bridge = DextBridge()
/// try await bridge.open()
/// await bridge.run(handle: handle, core: core)   // long-running; cancel to stop
/// ```
/// `run` publishes the LUN itself (from `core.capacity`) unless told not to.
///
/// The actor owns setup and teardown only. Task servicing runs outside it (see
/// `pump`), because macOS keeps many small SCSI tasks outstanding at once and
/// funnelling them through the actor's executor would serialise the whole
/// storage stack behind one iSCSI round trip.
public actor DextBridge {
    /// Name used to find the dext in the IORegistry (its `IOUserClass`).
    private let serviceName: String
    /// Byte offset of the payload arena inside the mapped region.
    ///
    /// The contract as specified addresses payloads at
    /// `slotIndex * slotPayloadBytes` from the mapping base, which is the
    /// default (0). Note that the dext currently maps header + request ring +
    /// completion ring + arena as ONE descriptor (see iSCSIUserClient.cpp), so
    /// if the dext keeps that layout this must become
    /// `sizeof(ISCSIRingHeader) + 256 * sizeof(ISCSIRequestSlot) + 256 * sizeof(ISCSICompletionSlot)`
    /// (64 + 14336 + 30720 = 45120). One knob, one place to change.
    private let dataRegionOffset: Int
    /// How many SCSI tasks may be in flight at once. The dext parks 256 tasks;
    /// keeping a slice of that busy is what stops the queue from wedging under
    /// sustained load, while the bound keeps the CmdSN window sane.
    private let maxInFlight: Int
    /// How long a single task may take before we fail it back to the kernel.
    ///
    /// MUST stay comfortably below the dext watchdog (~16s,
    /// kWatchdogTimeoutTicks × kWatchdogIntervalMs): the daemon failing first
    /// produces a clean CHECK CONDITION through the normal completion path,
    /// while the watchdog firing first zombie-quarantines the slot and can
    /// only answer with a delivery failure. The watchdog is the backstop for a
    /// wedged/dead daemon, not the routine timeout.
    private let taskTimeout: Duration

    private var link: DextLink?
    private var blockSize: Int = 0

    public init(serviceName: String = "iSCSIDext",
                dataRegionOffset: Int = 0,
                maxInFlight: Int = 16,
                taskTimeout: Duration = .seconds(10)) {
        self.serviceName = serviceName
        self.dataRegionOffset = dataRegionOffset
        self.maxInFlight = max(1, maxInFlight)
        self.taskTimeout = taskTimeout
    }

    public var isOpen: Bool { link != nil }
    /// Block size learned from `core.capacity`; 0 until `run`/`publish` sets it.
    public var lunBlockSize: Int { blockSize }
    /// Size of the mapped shared region, 0 when closed.
    public var arenaSize: Int { link?.arenaSize ?? 0 }
    /// Ceiling on concurrently serviced SCSI tasks.
    public var concurrencyLimit: Int { maxInFlight }

    // MARK: Lifecycle

    /// Find the dext, open its user client and map the shared arena.
    public func open() throws {
        guard link == nil else { return }
        guard let service = Self.findService(named: serviceName) else {
            throw DextBridgeError.serviceNotFound(serviceName)
        }
        defer { IOObjectRelease(service) }

        var connection: io_connect_t = 0
        let openKR = IOServiceOpen(service, mach_task_self_, 0, &connection)
        guard openKR == KERN_SUCCESS, connection != 0 else {
            throw DextBridgeError.openFailed(openKR)
        }

        var address: mach_vm_address_t = 0
        var size: mach_vm_size_t = 0
        let mapKR = IOConnectMapMemory64(
            connection,
            DextSelector.setRingBuffer,
            mach_task_self_,
            &address,
            &size,
            IOOptionBits(kIOMapAnywhere)
        )
        guard mapKR == KERN_SUCCESS,
              size > 0,
              let base = UnsafeMutableRawPointer(bitPattern: UInt(address))
        else {
            IOServiceClose(connection)
            throw DextBridgeError.mapFailed(mapKR)
        }

        link = DextLink(
            connection: connection,
            arena: base,
            arenaAddress: address,
            arenaSize: Int(size),
            dataRegionOffset: dataRegionOffset
        )
        log("opened user client, arena \(size) bytes (expected >= \(dataRegionBytes))")
    }

    /// Unmap the arena and close the connection. Idempotent.
    public func close() {
        link?.close()
        link = nil
    }

    // MARK: Control

    /// Publish LUN geometry so the dext can answer TEST UNIT READY / READ CAPACITY.
    public func publish(blockSize: Int, blockCount: UInt64) throws {
        self.blockSize = blockSize
        try callScalar(DextSelector.publishLUN, input: [UInt64(blockSize), blockCount])
    }

    /// Withdraw the LUN (the disk disappears from the system).
    public func unpublish() throws {
        try callScalar(DextSelector.unpublishLUN, input: [])
    }

    /// Drop the dext's IOUserResources nub so a replacement can match without a reboot.
    public func teardownNub() throws {
        try callScalar(DextSelector.teardownNub, input: [])
    }

    private func callScalar(_ selector: UInt32, input: [UInt64]) throws {
        guard let link else { throw DextBridgeError.notConnected }
        try link.callScalar(selector, input: input)
    }

    // MARK: Run loop

    /// Pump SCSI tasks from the dext into `core` until the task is cancelled or
    /// the connection dies. Never throws: a failed task is answered with CHECK
    /// CONDITION, never allowed to break the loop.
    ///
    /// - Parameter publishLUN: when true (default) the LUN geometry is read
    ///   from `core.capacity(handle)` and published before pumping starts.
    public func run(handle: String, core: DaemonCore, publishLUN: Bool = true) async {
        guard let link else {
            log("run: not connected")
            return
        }

        // Block size drives all LBA math, so it must come from the target.
        if publishLUN || blockSize <= 0 {
            do {
                let (bs, count) = try await core.capacity(handle)
                blockSize = bs
                if publishLUN {
                    try publish(blockSize: bs, blockCount: count)
                    log("published LUN: \(bs)-byte blocks x \(count)")
                }
            } catch {
                log("capacity/publish failed: \(error)")
                if publishLUN { return }
            }
        }

        // Hand off to the non-isolated pump: from here on nothing the hot path
        // does touches this actor, so tasks are serviced genuinely in parallel.
        await pump(link: link,
                   handle: handle,
                   core: core,
                   blockSize: blockSize,
                   maxInFlight: maxInFlight,
                   taskTimeout: taskTimeout)
    }

    // MARK: Service lookup

    /// The dext's registry class is the SCSI family's kernel proxy
    /// (`IOUserSCSIParallelInterfaceController`), not our own class name, so a
    /// plain class match on "iSCSIDext" can miss. Try, in order: class match,
    /// name match, a property match on `IOUserClass`, then the SCSI proxy class.
    private static func findService(named name: String) -> io_service_t? {
        let builders: [() -> CFDictionary?] = [
            { IOServiceMatching(name) },
            { IOServiceNameMatching(name) },
            { ["IOPropertyMatch": ["IOUserClass": name]] as CFDictionary },
            { ["IOProviderClass": "IOUserSCSIParallelInterfaceController"] as CFDictionary },
        ]
        for build in builders {
            guard let matching = build() else { continue }
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
            if service != 0 { return service }
        }
        return nil
    }

    private nonisolated func log(_ message: String) {
        dextLog(message)
    }
}
#endif
