//
//  LUNStore.swift
//
//  The bytes behind the volume: read-modify-write, the chunk cache wiring,
//  the ioLock that pins cache-patch order to device order, and every XPC call
//  the volume makes. Lives in the package, not the FSKit extension, so
//  `swift test` can reach the shipping data path; the extension keeps only
//  what conforms to FSKit and imports this.
//

import Foundation
import iSCSIKit
import os

public let fsLog = Logger(subsystem: "me.herko.iSCSIInitiator.fsext", category: "fs")

/// Prototype image size (512 MiB).
private let kDefaultImageBytes: UInt64 = 512 * 1024 * 1024

/// Block size for the local prototype store only; see `BackingStore.blockSize`.
private let kProtoBlockSize: UInt64 = 4096

/// Per-operation tracing. Gated on a marker file — FSKit launches the
/// extension, so its environment is not ours to set, and a rebuild costs a
/// re-register cycle. Touch
/// ~/Library/Containers/me.herko.iSCSIInitiator.fsext/Data/Documents/trace
/// to enable for the next mount.
public let traceEnabled: Bool = FileManager.default.fileExists(atPath: NSHomeDirectory() + "/Documents/trace")

@inline(__always)
public func trace(_ message: @autoclosure () -> String) {
    guard traceEnabled else { return }
    // Evaluate before interpolating: os_log's interpolation would make the
    // autoclosure escaping, which it is not.
    let rendered = message()
    fsLog.log("TRACE \(rendered, privacy: .public)")
}

// MARK: - Backing store

/// The bytes behind `lun0.img`: `BackingStore` (local file, no target needed)
/// or `DaemonStore` (forwards to iscsid over XPC). The volume only sees this
/// protocol.
public protocol LUNStore: AnyObject {
    var byteCount: UInt64 { get }
    /// Device block size, reported through statfs so the layers above align
    /// to it — advertising 512 against a 4Kn LUN makes DiskImages issue
    /// 512-granularity I/O and turns every partial write into an RMW round trip.
    var blockSize: UInt64 { get }
    var summary: String { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, length: Int) throws -> Int
    func write(_ data: Data, at offset: UInt64) throws -> Int
    func flush() throws
}

/// A local sparse file (resource URL host `proto`); isolates FSKit problems
/// from network ones.
public final class BackingStore: LUNStore {
    /// Prototype-only: 4096 exercises the same alignment as a 4Kn LUN.
    /// DaemonStore measures the real block size at login.
    public let blockSize: UInt64 = kProtoBlockSize
    private let fd: Int32
    private let lock = NSLock()
    public let byteCount: UInt64

    /// Call accounting: proves whether I/O reaches this extension at all.
    /// Logged in bulk (`summary`), not per call.
    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var readBytes: UInt64 = 0
    private(set) var writeBytes: UInt64 = 0
    private(set) var flushCount = 0
    private(set) var maxIOSize = 0

    public var summary: String {
        lock.lock(); defer { lock.unlock() }
        return snapshotLocked()
    }

    /// Must be called with `lock` held; `summary` would deadlock here.
    private func snapshotLocked() -> String {
        "reads=\(readCount)/\(readBytes)B writes=\(writeCount)/\(writeBytes)B "
        + "flushes=\(flushCount) maxIO=\(maxIOSize)"
    }

    /// Snapshot every 2048 operations, so counters survive an unclean unmount.
    private func periodicLogLocked() -> String? {
        let total = readCount + writeCount
        return total % 2048 == 0 ? snapshotLocked() : nil
    }

    /// Opens (creating if needed) a sparse file of `kDefaultImageBytes`.
    /// `O_NOFOLLOW`: the path lives in a world-writable directory, so a
    /// planted symlink could otherwise redirect this extension's writes.
    public init(path: String) throws {
        // The container's Documents directory may not exist on first use.
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let opened = open(path, O_RDWR | O_CREAT | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { throw POSIXError.Code(rawValue: errno).map { POSIXError($0) } ?? POSIXError(.EIO) }
        fd = opened

        var st = stat()
        if fstat(fd, &st) == 0, st.st_size > 0 {
            byteCount = UInt64(st.st_size)
        } else {
            // Sparse: ftruncate does not allocate blocks until written.
            guard ftruncate(fd, off_t(kDefaultImageBytes)) == 0 else {
                close(opened)
                throw POSIXError(.EIO)
            }
            byteCount = kDefaultImageBytes
        }
        fsLog.log("BackingStore opened \(path, privacy: .public) size=\(self.byteCount)")
    }

    deinit { close(fd) }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, length: Int) throws -> Int {
        guard offset < byteCount else { return 0 }
        let clamped = min(Int(byteCount - offset), length)
        lock.lock(); defer { lock.unlock() }
        let n = pread(fd, buffer.baseAddress, clamped, off_t(offset))
        guard n >= 0 else { throw POSIXError(.EIO) }
        if readCount == 0 { fsLog.log("FIRST READ off=\(offset) len=\(clamped)") }
        readCount += 1
        readBytes += UInt64(n)
        maxIOSize = max(maxIOSize, clamped)
        if let snap = periodicLogLocked() { fsLog.log("io: \(snap, privacy: .public)") }
        return n
    }

    public func write(_ data: Data, at offset: UInt64) throws -> Int {
        guard offset < byteCount else { throw POSIXError(.ENOSPC) }
        let clamped = min(Int(byteCount - offset), data.count)
        lock.lock(); defer { lock.unlock() }
        let n = data.withUnsafeBytes { raw in
            pwrite(fd, raw.baseAddress, clamped, off_t(offset))
        }
        guard n >= 0 else { throw POSIXError(.EIO) }
        if writeCount == 0 { fsLog.log("FIRST WRITE off=\(offset) len=\(clamped)") }
        writeCount += 1
        writeBytes += UInt64(n)
        maxIOSize = max(maxIOSize, clamped)
        if let snap = periodicLogLocked() { fsLog.log("io: \(snap, privacy: .public)") }
        return n
    }

    public func flush() throws {
        lock.lock()
        flushCount += 1
        lock.unlock()
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
    }
}

// MARK: - Daemon-backed store (the real Backend A path)

/// Forwards block I/O to `iscsid` over XPC, which owns the live iSCSI session.
/// Each call blocks on a semaphore with a timeout: a hung daemon must surface
/// as an I/O error, not an unkillable filesystem.
public final class DaemonStore: LUNStore {
    /// nil when a proxy was injected — see `init(daemon:session:blockSize:byteCount:)`.
    private let connection: NSXPCConnection?
    /// Set only by the testing initialiser; call sites go through `daemon()`
    /// so the two paths differ in one place.
    private let injectedDaemon: ISCSIDaemonProtocol?
    private let session: String
    private let lock = NSLock()
    /// Serialises read-modify-write so two partial writes to the same block
    /// cannot interleave and lose one of the updates.
    private let ioLock = NSLock()
    public let byteCount: UInt64

    /// `ISCSIBlockDevice` rejects unaligned requests, and FSKit hands us
    /// arbitrary byte ranges (DiskImages reads at 512-byte granularity against
    /// a 4Kn LUN), so every request is realigned here. The arithmetic lives in
    /// `BlockAligner` (iSCSIKit) so it is unit-testable without a live target.
    private let aligner: BlockAligner
    public let blockSize: UInt64

    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var readBytes: UInt64 = 0
    private(set) var writeBytes: UInt64 = 0
    private(set) var flushCount = 0

    /// Most recent request size, for the summary line; cache and speculation
    /// accounting lives in `PrefetchChunkCache.Stats`.
    private(set) var lastRequestBytes = 0

    /// Seconds to wait for any single daemon call.
    private static let timeout: TimeInterval = 30

    /// Consecutive unanswered daemon calls before the volume is declared dead.
    /// Three, not one: a single timeout can be a target pausing under load;
    /// three in a row with nothing between is a session not coming back.
    private static let timeoutsBeforeDead = 3

    /// Guards the two fields below across FSKit's arbitrary calling threads.
    private let healthLock = NSLock()
    private var consecutiveTimeouts = 0
    private var isDead = false

    /// Whether this volume has given up. Latched: it never goes back.
    var hasFailed: Bool {
        healthLock.lock(); defer { healthLock.unlock() }
        return isDead
    }

    /// Speculative bytes allowed in flight once a stream earns that depth
    /// (`ReadaheadPolicy`). FSKit issues one read at a time and waits, so
    /// readahead is the only source of link depth. This only seeds the first
    /// second of a mount; `ReadaheadDepthController` steers it afterwards on
    /// measured waste. See docs/queue-depth.md.
    private static let readaheadBytes = WorkloadProfile.mixed.readaheadBudgetBytes

    /// Ceiling on in-flight chunks (each an outstanding XPC call and a
    /// buffer). A resource rail, not a throughput tuning — it exists so a
    /// deeper `WorkloadProfile` rung cannot silently uncap depth.
    private static let readaheadMaxSlots = 32

    /// Consecutive bytes a run must cover before anything is speculated:
    /// a 256 KiB stream opens its window on the second read, while a guest's
    /// 16 KiB reads need sixteen in a row — a two-request trigger speculated
    /// between every pair of writes and wasted all of it.
    private static let readaheadMinStream = 256 * 1024

    /// The cache's unit of fetch and residence: the single-command throughput
    /// sweet spot, and never smaller than a block (geometry allows up to 1 MiB).
    private static func chunkBytes(forBlockSize bs: Int) -> Int { max(256 << 10, bs) }

    /// Resident cache ceiling. 16 MiB churned — chunks evicted before their
    /// neighbours were read back; 32 MiB is the next measured step.
    private static let maxCachedBytes = 32 << 20

    /// The whole read path: reads are served from aligned chunks, a miss
    /// fetches the covering span in one round trip and keeps it, so small
    /// neighbouring reads become memory copies. Set once in `init`; IUO only
    /// because the fetch closures need `self`.
    private var cache: PrefetchChunkCache!

    /// A block-aligned read, served from the chunk cache.
    private func readAligned(offset: UInt64, length: Int) throws -> Data {
        try checkAlive()
        lock.lock(); lastRequestBytes = length; lock.unlock()
        do {
            let data = try cache.read(offset: offset, length: length)
            guard data.count == length else { throw POSIXError(.EIO) }
            return data
        } catch let error as PrefetchChunkCache.CacheError {
            switch error {
            case .unanswered:
                // A speculative read the daemon never answered. Not retried —
                // that would spend a second timeout on a session that just
                // failed one. Count it; the death latch does the rest.
                throw recordTimeout()
            case .shortRead:
                throw POSIXError(.EIO)
            }
        }
    }

    /// The death latch: without it, every I/O to a dead session costs a full
    /// 30 s timeout, reads as retryable, and is retried forever — an
    /// unkillable mount dragging down everything that touches the mount
    /// table. Timeouts are counted (success clears the count); at the limit
    /// the volume is dead and every later call fails *immediately*, which is
    /// what lets DiskImages/APFS reach a conclusion in seconds. Only
    /// unanswered calls count — a SCSI error is an answer, and a bad block
    /// must not condemn a healthy volume.
    private func checkAlive() throws {
        healthLock.lock()
        let dead = isDead
        healthLock.unlock()
        if dead { throw POSIXError(.EIO) }
    }

    /// An answer arrived, so whatever came before was not a pattern.
    private func recordSuccess() {
        healthLock.lock()
        consecutiveTimeouts = 0
        healthLock.unlock()
    }

    /// Count one unanswered call and return the error to throw: ETIMEDOUT
    /// while there is still hope, EIO once there is not. Returns rather than
    /// throws so the direct and readahead paths account identically.
    private func recordTimeout() -> any Error {
        healthLock.lock()
        consecutiveTimeouts += 1
        let count = consecutiveTimeouts
        if count >= Self.timeoutsBeforeDead { isDead = true }
        let nowDead = isDead
        healthLock.unlock()
        if nowDead {
            fsLog.error("""
                volume declared dead after \(count, privacy: .public) unanswered \
                daemon calls; all further I/O fails immediately
                """)
            return POSIXError(.EIO)
        }
        return POSIXError(.ETIMEDOUT)
    }

    private func daemonCall(_ body: (@escaping () -> Void) -> Void) throws {
        try checkAlive()
        do {
            try Self.blocking(body)
            recordSuccess()
        } catch let error as POSIXError where error.code == .ETIMEDOUT {
            throw recordTimeout()
        }
    }

    public var summary: String {
        // Cache stats first: `cache.stats` takes the cache's lock, so it must
        // not be fetched while holding `lock`.
        let s = cache.stats
        lock.lock(); defer { lock.unlock() }
        let served = s.hits + s.misses
        let rate = served > 0 ? (s.hits * 100 / served) : 0
        // Averaged: the last request alone misrepresents the run.
        let avgRequest = readCount > 0 ? Int(readBytes / UInt64(readCount)) : 0
        // `unused` = speculative chunks never touched; `readAround` = bytes
        // fetched beyond what callers asked. hit% alone cannot indict the
        // cache; these can.
        return "reads=\(readCount)/\(readBytes)B writes=\(writeCount)/\(writeBytes)B "
             + "flushes=\(flushCount) avgReq=\(avgRequest)B lastReq=\(lastRequestBytes)B "
             + "cache=\(rate)% (\(s.hits) hit, \(s.misses) miss, \(s.unanswered) unanswered) "
             + "maxDepth=\(s.maxDepth) cap=\(s.currentCap) "
             + "speculated=\(s.chunksSpeculated)/\(s.speculatedBytes)B "
             + "unused=\(s.chunksSpeculated - s.speculatedUsed) "
             + "settled=\(s.resolvedUsed)used/\(s.resolvedWasted)wasted "
             + "readAround=\(s.readAroundBytes)B"
    }

    /// Connects to iscsid, logs in, and learns the LUN geometry; throws so
    /// `loadResource` reports a real error instead of an empty volume.
    /// No `chapUser`: `mount(8)` needs no root, so anything this extension
    /// forwards is attacker-chosen — credentials stay the daemon's business.
    public convenience init(host: String, port: Int, target: String, lun: UInt64) throws {
        let xpc = NSXPCConnection(machServiceName: iscsiDaemonServiceName, options: .privileged)
        xpc.remoteObjectInterface = NSXPCInterface(with: ISCSIDaemonProtocol.self)
        xpc.resume()

        let proxy = try Self.proxy(xpc)

        var handle: String?
        var loginError: Error?
        try Self.blocking { done in
            proxy.login(host: host, port: NSNumber(value: port), targetIQN: target,
                        lun: NSNumber(value: lun)) { h, e in
                handle = h; loginError = e; done()
            }
        }
        if let loginError { throw loginError }
        guard let handle else { throw POSIXError(.EIO) }

        var blockSize: NSNumber = 0
        var blockCount: NSNumber = 0
        var capError: Error?
        try Self.blocking { done in
            proxy.capacity(session: handle) { bs, bc, e in
                blockSize = bs; blockCount = bc; capError = e; done()
            }
        }
        if let capError { throw capError }
        // Check before multiplying: `*` traps on overflow, and a trap
        // mid-`mount` wedges the mount rather than failing it. The daemon
        // validates geometry at the parse site; this stays because the trap
        // is one line from values arriving over XPC.
        let bs = blockSize.uint64Value
        let count = blockCount.uint64Value
        guard bs > 0, count > 0 else { throw POSIXError(.EIO) }
        let (product, overflowed) = bs.multipliedReportingOverflow(by: count)
        guard !overflowed, product > 0 else { throw POSIXError(.EIO) }

        // Readahead budget: 0 unless the target record pins an explicit
        // `workloadProfile` override; otherwise depth is adaptive. Failure is
        // deliberately not fatal — a mount must not die for a tuning
        // parameter.
        var budgetReply: NSNumber = 0
        try? Self.blocking { done in
            proxy.readaheadBudget(session: handle) { bytes, error in
                if error == nil { budgetReply = bytes }
                done()
            }
        }
        let pinned = budgetReply.intValue > 0
        let budgetBytes = pinned ? budgetReply.intValue : Self.readaheadBytes
        self.init(connection: xpc, injectedDaemon: nil, session: handle,
                  blockSize: bs, byteCount: product,
                  budgetBytes: budgetBytes, pinned: pinned)
    }

    /// Shared by both initialisers; the split lets tests inject a daemon and
    /// reach the RMW/cache/ioLock path without a privileged XPC connection.
    private init(connection: NSXPCConnection?, injectedDaemon: ISCSIDaemonProtocol?,
                 session: String, blockSize bs: UInt64, byteCount: UInt64,
                 budgetBytes: Int, pinned: Bool) {
        self.connection = connection
        self.injectedDaemon = injectedDaemon
        self.session = session
        self.byteCount = byteCount
        self.blockSize = bs
        self.aligner = BlockAligner(blockSize: bs, capacity: byteCount)

        let chunk = Self.chunkBytes(forBlockSize: Int(bs))
        cache = PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: byteCount,
            maxCachedBytes: Self.maxCachedBytes,
            policy: ReadaheadPolicy(budgetBytes: budgetBytes,
                                    maxSlots: Self.readaheadMaxSlots,
                                    minStreamBytes: Self.readaheadMinStream,
                                    chunkBytes: chunk),
            timeout: Self.timeout,
            adaptiveDepth: !pinned,
            fetchSync: { [weak self] offset, length in
                guard let self else { throw POSIXError(.EIO) }
                return try self.rawRead(offset: offset, length: length)
            },
            fetchAsync: { [weak self] offset, length, done in
                guard let self, let proxy = try? self.daemon() else {
                    done(nil)
                    return
                }
                proxy.read(session: self.session, offset: NSNumber(value: offset),
                           length: NSNumber(value: length)) { data, error in
                    done(error == nil ? data : nil)
                }
            })

        fsLog.log("DaemonStore session=\(session, privacy: .public) size=\(self.byteCount) blockSize=\(bs) chunk=\(chunk)")
    }

    /// Build a store around an injected daemon, for tests. Takes the geometry
    /// so a fake daemon only answers `read`, `write` and `flush`.
    public convenience init(daemon: ISCSIDaemonProtocol, session: String,
                            blockSize: UInt64, byteCount: UInt64,
                            readaheadBudgetBytes: Int? = nil) {
        self.init(connection: nil, injectedDaemon: daemon, session: session,
                  blockSize: blockSize, byteCount: byteCount,
                  budgetBytes: readaheadBudgetBytes ?? Self.readaheadBytes,
                  pinned: readaheadBudgetBytes != nil)
    }


    deinit {
        if let proxy = try? daemon() {
            try? Self.blocking { done in proxy.logout(session: self.session) { _ in done() } }
        }
        connection?.invalidate()
    }

    /// The daemon, however this store was given one.
    private func daemon() throws -> ISCSIDaemonProtocol {
        if let injectedDaemon { return injectedDaemon }
        guard let connection else { throw POSIXError(.EIO) }
        return try Self.proxy(connection)
    }

    private static func proxy(_ connection: NSXPCConnection) throws -> ISCSIDaemonProtocol {
        // A synchronous proxy would deadlock the reply-handler style used here;
        // errors surface through the error handler instead.
        guard let p = connection.remoteObjectProxyWithErrorHandler({ error in
            fsLog.error("daemon XPC error: \(error.localizedDescription, privacy: .public)")
        }) as? ISCSIDaemonProtocol else {
            throw POSIXError(.ENOTCONN)
        }
        return p
    }

    /// Runs an async XPC call and waits for its reply, or throws ETIMEDOUT.
    private static func blocking(_ body: (@escaping () -> Void) -> Void) throws {
        let sem = DispatchSemaphore(value: 0)
        body { sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            fsLog.error("daemon call timed out after \(Int(timeout))s")
            throw POSIXError(.ETIMEDOUT)
        }
    }

    /// Reads exactly `[offset, offset+length)` where both are already
    /// block-aligned. Every aligned access funnels through here.
    private func rawRead(offset: UInt64, length: Int) throws -> Data {
        let proxy = try daemon()
        var data: Data?
        var err: Error?
        try daemonCall { done in
            proxy.read(session: session, offset: NSNumber(value: offset),
                       length: NSNumber(value: length)) { d, e in
                data = d; err = e; done()
            }
        }
        if let err { throw err }
        guard let data, data.count == length else { throw POSIXError(.EIO) }
        return data
    }

    private func rawWrite(offset: UInt64, data: Data) throws {
        let proxy = try daemon()
        var err: Error?
        try daemonCall { done in
            proxy.write(session: session, offset: NSNumber(value: offset), data: data) { e in
                err = e; done()
            }
        }
        if let err { throw err }
    }

    public func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, length: Int) throws -> Int {
        guard let plan = aligner.plan(offset: offset, length: min(length, buffer.count)) else { return 0 }

        let data = try readAligned(offset: plan.alignedOffset, length: plan.alignedLength)
        let n = min(plan.count, data.count - plan.skip)
        data.withUnsafeBytes { src in
            buffer.baseAddress?.copyMemory(from: src.baseAddress! + plan.skip, byteCount: n)
        }
        lock.lock(); readCount += 1; readBytes += UInt64(n); lock.unlock()
        return n
    }

    public func write(_ data: Data, at offset: UInt64) throws -> Int {
        guard offset < byteCount else { throw POSIXError(.ENOSPC) }
        guard let plan = aligner.plan(offset: offset, length: data.count) else { return 0 }
        let payload = plan.count == data.count ? data : Data(data.prefix(plan.count))

        // Writes go through the cache in three acts. `willWrite` (before the
        // device write): arms the write generation against a racing miss
        // fetch and drops overlapping in-flight speculation. `didWrite`
        // (after the acknowledgement): patches acknowledged bytes into cached
        // chunks so write-then-read-back stays a hit. `writeFailed`: what
        // reached the media is unknowable, so the overlap is dropped. The
        // range is the RMW-widened one throughout. The RMW branch reads via
        // `rawRead`, never the cache, so it cannot pick up a stale edge block.
        cache.willWrite(offset: plan.alignedOffset, length: plan.alignedLength)
        do {
            // `ioLock` covers every write: it serialises RMW (two partial
            // writes to one block must not lose an update) and pins
            // cache-patch order to device order, or the cache diverges from
            // the media. FSKit currently delivers one operation at a time;
            // nothing here relies on that.
            ioLock.lock()
            defer { ioLock.unlock() }
            if plan.isExact {
                try rawWrite(offset: plan.alignedOffset, data: payload)
                cache.didWrite(payload, at: plan.alignedOffset)
            } else {
                // Read-modify-write the partial edge blocks.
                var block = try rawRead(offset: plan.alignedOffset, length: plan.alignedLength)
                block.replaceSubrange(plan.skip ..< (plan.skip + plan.count), with: payload)
                try rawWrite(offset: plan.alignedOffset, data: block)
                cache.didWrite(block, at: plan.alignedOffset)
            }
        } catch {
            cache.writeFailed(offset: plan.alignedOffset, length: plan.alignedLength)
            throw error
        }

        lock.lock(); writeCount += 1; writeBytes += UInt64(plan.count); lock.unlock()
        // rmw=true: this write cost an extra round trip for the edge blocks.
        trace("write off=\(offset) len=\(plan.count) rmw=\(!plan.isExact)")
        return plan.count
    }

    /// SYNCHRONIZE CACHE. FSKit never signals barriers (see
    /// docs/backend-a-fskit-notes.md), so this only runs on final close — which
    /// is why the target should also be configured write-through.
    public func flush() throws {
        let proxy = try daemon()
        var err: Error?
        try daemonCall { done in
            proxy.flush(session: session) { e in err = e; done() }
        }
        if let err { throw err }
        lock.lock(); flushCount += 1; lock.unlock()
    }
}

// MARK: - Items

/// A file or directory in the prototype volume. The volume is flat: a root
/// directory containing exactly one file.
