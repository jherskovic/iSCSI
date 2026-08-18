//
//  LUNStore.swift
//
//  The bytes behind the volume, and the two ways of getting at them.
//
//  This lives in its own SwiftPM target rather than inside the FSKit extension
//  because it has no FSKit in it — verified before the move: the only `FS`
//  symbols in these six hundred lines were the word "FSKit" in prose and
//  `F_FULLFSYNC`. What it does have is the read-modify-write path, the chunk
//  cache wiring, the ioLock that pins cache-patch order to device order, and
//  every XPC call the volume makes. That is the shipping data path, and while
//  it sat in the Xcode target `swift test` could not reach a line of it.
//
//  The extension keeps everything that actually conforms to FSKit —
//  `ISCSIUnaryFileSystem`, `ProtoVolume`, `ProtoItem` — and imports this.
//

import Foundation
import iSCSIKit
import os

public let fsLog = Logger(subsystem: "me.herko.iSCSIInitiator.fsext", category: "fs")

/// Prototype image size (512 MiB), matching the dext's scratch disk so the
/// existing probes in scripts/vm-scratch-apfs.sh compare like with like.
private let kDefaultImageBytes: UInt64 = 512 * 1024 * 1024

/// Block size for the local prototype store only; see `BackingStore.blockSize`.
private let kProtoBlockSize: UInt64 = 4096

/// Per-operation tracing, for correlating barriers with close calls.
///
/// Gated on a marker file rather than a build flag or environment variable: the
/// extension is launched by FSKit, so its environment is not ours to set, and a
/// rebuild costs a full re-register-and-reboot cycle. Touching
/// ~/Library/Containers/me.herko.iSCSIInitiator.fsext/Data/Documents/trace
/// turns it on for the next mount.
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

/// The bytes behind `lun0.img`.
///
/// Two implementations: `BackingStore` (a local file, for prototyping and
/// regression-testing the FSKit plumbing without a target) and `DaemonStore`
/// (the real thing, forwarding to iscsid over XPC). The volume only ever sees
/// this protocol.
public protocol LUNStore: AnyObject {
    var byteCount: UInt64 { get }
    /// The underlying device's block size. Reported up through statfs so the
    /// layers above align to it: the LUN is 4Kn, and advertising 512 made
    /// DiskImages issue 512-granularity I/O, turning every partial write into
    /// a read-modify-write round trip.
    var blockSize: UInt64 { get }
    var summary: String { get }
    func read(into buffer: UnsafeMutableRawBufferPointer, at offset: UInt64, length: Int) throws -> Int
    func write(_ data: Data, at offset: UInt64) throws -> Int
    func flush() throws
}

/// A local sparse file. No iSCSI involved — used when the resource URL host is
/// `proto`, which keeps a working configuration available for isolating FSKit
/// problems from network ones.
public final class BackingStore: LUNStore {
    /// Prototype-only default. A plain file has no device block size to
    /// measure, so one is chosen; 4096 makes the local path exercise the same
    /// alignment as a 4Kn LUN. Nothing on the real path uses this — DaemonStore
    /// measures the LUN's block size with READ CAPACITY at login.
    public let blockSize: UInt64 = kProtoBlockSize
    private let fd: Int32
    private let lock = NSLock()
    public let byteCount: UInt64

    /// Call accounting. The absence of `synchronize` calls in the first
    /// end-to-end run raised the question of whether the kernel routes disk
    /// image I/O through this extension at all, or offloads it — so read/write
    /// are counted rather than assumed. Logged in bulk (see `summary`) instead
    /// of per call, which would be thousands of lines.
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

    /// Emits a counter snapshot every 2048 operations, so the numbers are
    /// visible even if the volume never unmounts cleanly.
    private func periodicLogLocked() -> String? {
        let total = readCount + writeCount
        return total % 2048 == 0 ? snapshotLocked() : nil
    }

    /// Opens (creating if needed) a sparse file of `kDefaultImageBytes`.
    ///
    /// `O_NOFOLLOW` is deliberate: the backing path lives in a world-writable
    /// directory, so without it anyone could plant a symlink there and redirect
    /// this extension's writes to a file of their choosing.
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

    /// Whether a flush ever reaches us is precisely question (2) above.
    public func flush() throws {
        lock.lock()
        flushCount += 1
        lock.unlock()
        guard fcntl(fd, F_FULLFSYNC) == 0 else { throw POSIXError(.EIO) }
    }
}

// MARK: - Daemon-backed store (the real Backend A path)

/// Forwards block I/O to `iscsid` over XPC, which owns the live iSCSI session.
///
/// The FSKit operations that call into this are reply-handler based but the
/// `LUNStore` API is synchronous, so each call blocks on a semaphore with a
/// timeout. That is deliberate: a hung daemon must surface as an I/O error
/// rather than an unkillable filesystem, which is exactly the failure mode that
/// made the DriverKit wedge so painful to diagnose.
public final class DaemonStore: LUNStore {
    private let connection: NSXPCConnection
    private let session: String
    private let lock = NSLock()
    /// Serialises read-modify-write so two partial writes to the same block
    /// cannot interleave and lose one of the updates.
    private let ioLock = NSLock()
    public let byteCount: UInt64

    /// The LUN's block size. `ISCSIBlockDevice` rejects any request that is not
    /// block-aligned with a whole-block length (`BlockDeviceError.misaligned`),
    /// and truncates on `length / blockSize`. FSKit hands us arbitrary byte
    /// ranges — DiskImages reads the backing file at 512-byte granularity,
    /// which is unaligned against a 4Kn LUN — so every request is realigned
    /// here. Skipping this makes the APFS probe fail with EIO while ordinary
    /// file reads still work, because the page cache happens to be aligned.
    ///
    /// The arithmetic lives in `BlockAligner` (iSCSIKit) so it can be unit
    /// tested without a mounted volume and a live target.
    private let aligner: BlockAligner
    public let blockSize: UInt64

    private(set) var readCount = 0
    private(set) var writeCount = 0
    private(set) var readBytes: UInt64 = 0
    private(set) var writeBytes: UInt64 = 0
    private(set) var flushCount = 0

    /// The request size most recently seen, for the summary line. Cache and
    /// speculation accounting lives in `PrefetchChunkCache.Stats` — including
    /// the cost side (`speculated`, `unused`, `readAround`), which the first
    /// counters here famously lacked.
    private(set) var lastRequestBytes = 0

    /// Seconds to wait for any single daemon call.
    private static let timeout: TimeInterval = 30

    /// Consecutive unanswered daemon calls before the volume is declared dead.
    ///
    /// Three, not one: a single timeout can be a target pausing under load, and
    /// failing a healthy volume for that would be its own bug. Three in a row,
    /// with nothing in between, is a session that is not coming back.
    private static let timeoutsBeforeDead = 3

    /// Guards the two fields below, which the death latch reads and writes from
    /// whatever thread FSKit happens to call in on.
    private let healthLock = NSLock()
    private var consecutiveTimeouts = 0
    private var isDead = false

    /// Whether this volume has given up. Latched: it never goes back.
    var hasFailed: Bool {
        healthLock.lock(); defer { healthLock.unlock() }
        return isDead
    }

    /// How much data may be kept speculatively in flight, once the stream has
    /// earned that depth (see `ReadaheadPolicy`).
    ///
    /// FSKit issues one read at a time and waits for each, so without this the
    /// link is idle for a full round trip between requests — measured at 206
    /// MB/s through the extension against 1160 MB/s that the same target and
    /// link sustain with commands in flight. Reading ahead is the only way to
    /// get depth, because the depth cannot come from a caller that will not
    /// issue a second request until the first returns.
    ///
    /// Where the adaptive controller starts, and what a target that pins no
    /// `WorkloadProfile` override begins its first second at. From here
    /// `ReadaheadDepthController` moves it on measured waste, so this decides
    /// the first second of a mount and nothing after it.
    ///
    /// It was a hardcoded 8 MiB (32 chunks) and then 4 MiB (16) before the
    /// budget became per-target. `WorkloadProfile` carries the measurements
    /// that set the rungs; the short version is that hit rate did not move
    /// across a 8x range of depth, so the extra depth bought queue occupancy
    /// rather than residency. See docs/queue-depth.md.
    private static let readaheadBytes = WorkloadProfile.mixed.readaheadBudgetBytes

    /// Never more chunks in flight than this. Each is an outstanding XPC call
    /// and a buffer. 32 x 256 KiB commands showed no degradation out to 64
    /// outstanding; the 1 MiB command cliff no longer applies because
    /// speculation is issued chunk-wise, never larger.
    ///
    /// No longer the binding constraint, and in the shipping configuration it
    /// cannot be: `chunkBytes` is never below 256 KiB and the deepest
    /// `WorkloadProfile` rung is 4 MiB, so `chunkCap` tops out at 16 and takes
    /// the lower of the two. It stays at 32 as the rail it is described as — a
    /// ceiling on outstanding XPC calls and buffers, a resource limit rather
    /// than a throughput tuning — so that adding a deeper rung cannot silently
    /// uncap depth. Depth is tuned in `WorkloadProfile`; this is the thing that
    /// stops it running away.
    private static let readaheadMaxSlots = 32

    /// Consecutive bytes a run must cover before anything is speculated.
    ///
    /// 256 KiB keeps the benchmark behaviour — a 256 KiB stream still opens
    /// its window on the second read — while a VM guest's 16 KiB reads need
    /// sixteen in a row. Chosen from the first real VM run, where the old
    /// two-requests trigger re-opened a window between every pair of writes
    /// and wasted 100% of twelve minutes' speculation.
    private static let readaheadMinStream = 256 * 1024

    /// The cache's unit of fetch and residence. 256 KiB is the measured
    /// throughput sweet spot for a single SCSI command (`maxTransferBytes`),
    /// and geometry allows blocks up to 1 MiB, so never smaller than a block.
    private static func chunkBytes(forBlockSize bs: Int) -> Int { max(256 << 10, bs) }

    /// Resident cache ceiling. Started at 16 MiB out of caution — the appex's
    /// memory limits are not documented — but the first VM run at 16 MiB
    /// showed 5.5x read-around amplification (3 GB fetched for 549 MB
    /// served), which reads as eviction churn: chunks dropped before the
    /// guest came back for their neighbours. 32 MiB is the next measured
    /// step, not a destination.
    private static let maxCachedBytes = 32 << 20

    /// The chunk cache is the whole read path (`PrefetchChunkCache`,
    /// iSCSIKit, unit-tested against an in-memory LUN). Reads are served from
    /// 256 KiB aligned chunks; a miss fetches the covering span in one round
    /// trip and keeps it, so a VM guest's small neighbouring reads — measured
    /// at ~80 round trips/s through the old exact-match path, which is why a
    /// boot took minutes — become memory copies. Speculation is still gated
    /// on `readaheadMinStream` of proven consecutive stream.
    ///
    /// Set once in `init` and never reassigned; IUO only because its fetch
    /// closures need `self`.
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
                // A speculative read the daemon never answered. Deliberately
                // not retried: re-asking would spend a second full timeout on
                // a session that just failed to answer the first. Count it and
                // fail now; the death latch trips after three and everything
                // afterwards fails immediately.
                throw recordTimeout()
            case .shortRead:
                throw POSIXError(.EIO)
            }
        }
    }

    /// Runs a daemon call, and stops running them once the volume is dead.
    ///
    /// **This is what stands between a lost reply and a Mac that has to be
    /// rebooted.** Without it, every I/O to a session that no longer answers
    /// costs a full 30-second timeout, fails with something the layers above
    /// read as retryable, and is retried — for ever. An 82GB soak ended with
    /// eight hours of that: `diskimages-helper` in uninterruptible wait, and
    /// behind it `diskarbitrationd`, Finder, Time Machine and everything else
    /// that touches the mount table, none of them killable.
    ///
    /// A timeout is not by itself fatal, so it is counted rather than acted on,
    /// and any successful call clears the count. Once the count is reached the
    /// volume is dead and every later call fails *immediately* with EIO. The
    /// speed is the point: DiskImages retries, and a retry that returns at once
    /// lets APFS reach its own conclusion in seconds instead of never.
    ///
    /// Only unanswered calls count. A SCSI error is an answer — a bad block
    /// must not be able to condemn a healthy volume.
    /// Throws once the volume has been declared dead, so no call is even tried.
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

    /// Count one unanswered call and return the error the caller should throw:
    /// ETIMEDOUT while there is still hope, EIO once there is not.
    ///
    /// Returns the error rather than throwing it so both the direct path and
    /// the readahead path can account for a timeout the same way.
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
        // Averaged, not the last one. `lastRequestBytes` was reported first and
        // was actively misleading: a volume whose reads averaged 978 KB showed
        // `req=4096B` because one small trailing request happened to be last.
        // The average describes the run.
        let avgRequest = readCount > 0 ? Int(readBytes / UInt64(readCount)) : 0
        // The cost lines: `unused` is speculative chunks paid for at the
        // target and never touched, and `readAround` is bytes fetched beyond
        // what callers asked for — the read-around bet. hit% alone cannot rule
        // the cache in or out as a latency problem; these can.
        return "reads=\(readCount)/\(readBytes)B writes=\(writeCount)/\(writeBytes)B "
             + "flushes=\(flushCount) avgReq=\(avgRequest)B lastReq=\(lastRequestBytes)B "
             + "cache=\(rate)% (\(s.hits) hit, \(s.misses) miss, \(s.unanswered) unanswered) "
             + "maxDepth=\(s.maxDepth) cap=\(s.currentCap) "
             + "speculated=\(s.chunksSpeculated)/\(s.speculatedBytes)B "
             + "unused=\(s.chunksSpeculated - s.speculatedUsed) "
             + "settled=\(s.resolvedUsed)used/\(s.resolvedWasted)wasted "
             + "readAround=\(s.readAroundBytes)B"
    }

    /// Connects to iscsid, logs in to `target`/`lun` at `host:port`, and learns
    /// the LUN geometry. Throws if any step fails, so `loadResource` can report
    /// a real error rather than presenting an empty volume.
    /// No `chapUser`: credentials are the daemon's business, resolved from the
    /// target the user saved. This extension is reachable by any local user via
    /// `mount(8)` — which needs no root — so anything it forwards is effectively
    /// attacker-chosen, and it used to forward the mount URL's user component
    /// straight into a keychain lookup.
    public init(host: String, port: Int, target: String, lun: UInt64) throws {
        connection = NSXPCConnection(machServiceName: iscsiDaemonServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ISCSIDaemonProtocol.self)
        connection.resume()

        let proxy = try Self.proxy(connection)

        // Log in.
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
        session = handle

        // Learn geometry.
        var blockSize: NSNumber = 0
        var blockCount: NSNumber = 0
        var capError: Error?
        try Self.blocking { done in
            proxy.capacity(session: handle) { bs, bc, e in
                blockSize = bs; blockCount = bc; capError = e; done()
            }
        }
        if let capError { throw capError }
        // Check before multiplying, not after. `*` traps on overflow, so the
        // guard that used to follow this line could not run: a target claiming
        // 2^48 blocks of 64 KiB makes the product exactly 2^64 and killed the
        // extension mid-`mount`, which wedges the mount rather than failing it.
        //
        // The daemon validates geometry at the parse site now
        // (`ISCSIBlockDevice.geometry(fromReadCapacity16:)`) so these values
        // should already be sane; this stays because the trap is one line away
        // from the values arriving over XPC, and defence here costs nothing.
        let bs = blockSize.uint64Value
        let count = blockCount.uint64Value
        guard bs > 0, count > 0 else { throw POSIXError(.EIO) }
        let (product, overflowed) = bs.multipliedReportingOverflow(by: count)
        guard !overflowed, product > 0 else { throw POSIXError(.EIO) }
        byteCount = product
        aligner = BlockAligner(blockSize: bs, capacity: byteCount)
        self.blockSize = blockSize.uint64Value

        // Built last: the fetch closures need `self`, which only exists once
        // every stored property above is set. `weak` breaks the cycle the
        // cache owning closures over its owner would otherwise create; a
        // fetch after the store is gone just fails the volume's I/O, which is
        // what a torn-down volume should do.
        // Does this target pin its readahead depth? Almost none do: the daemon
        // reports 0 unless the record carries an explicit `workloadProfile`
        // override, and then `PrefetchChunkCache` steers depth itself from
        // measured waste. The override exists to pin depth for debugging and
        // A/B measurement, which is exactly what was needed to establish that
        // the setting should not exist.
        //
        // A failure here is deliberately not fatal, and lands on the adaptive
        // path: failing a mount because a tuning parameter could not be
        // fetched would trade a working filesystem for a readahead depth.
        var budgetReply: NSNumber = 0
        try? Self.blocking { done in
            proxy.readaheadBudget(session: handle) { bytes, error in
                if error == nil { budgetReply = bytes }
                done()
            }
        }
        let pinned = budgetReply.intValue > 0
        let budgetBytes = pinned ? budgetReply.intValue : Self.readaheadBytes

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
                guard let self, let proxy = try? Self.proxy(self.connection) else {
                    done(nil)
                    return
                }
                proxy.read(session: self.session, offset: NSNumber(value: offset),
                           length: NSNumber(value: length)) { data, error in
                    done(error == nil ? data : nil)
                }
            })

        fsLog.log("DaemonStore session=\(handle, privacy: .public) size=\(self.byteCount) blockSize=\(blockSize.uint64Value) chunk=\(chunk)")
    }

    deinit {
        if let proxy = try? Self.proxy(connection) {
            try? Self.blocking { done in proxy.logout(session: self.session) { _ in done() } }
        }
        connection.invalidate()
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
        let proxy = try Self.proxy(connection)
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
        let proxy = try Self.proxy(connection)
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

        // Writes go *through* the cache, in three acts. `willWrite` before
        // the device write: resets the speculation ramp, arms the write
        // generation against a racing miss fetch caching era-ambiguous bytes,
        // and drops overlapping in-flight speculation. `didWrite` after the
        // acknowledgement: patches the acknowledged bytes into overlapping
        // cached chunks, so a guest's write-then-read-back — its journal,
        // thousands of times per boot — stays a hit instead of costing a
        // 256 KiB refetch per write. `writeFailed` on any error: which blocks
        // reached the media is unknowable, so the overlap is dropped. The
        // range is the RMW-widened one throughout — the edge blocks change
        // too — and the patched bytes are the full aligned block in that
        // branch, which is exactly what went to the target.
        //
        // Chunks the write does not touch stay servable: this initiator is
        // the only writer of the LUN. The read-modify-write branch below
        // reads through `rawRead`, never the cache, so it cannot pick up a
        // stale edge block either.
        cache.willWrite(offset: plan.alignedOffset, length: plan.alignedLength)
        do {
            // `ioLock` now covers *every* write, not just read-modify-write.
            // It always serialised RMW so two partial writes to one block
            // cannot lose an update; with write-through it also pins patch
            // order to device order — two concurrent overlapping writes must
            // not reach the target in one order and patch the cache in the
            // other, or the cache diverges from the media until the next
            // drop. FSKit delivers one operation at a time today, but none of
            // the code around this leans on that observation, and neither
            // does this.
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
        // rmw=true means this write cost an extra round trip to read the edge
        // blocks — the thing the 4096-byte statfs block size aims to eliminate.
        trace("write off=\(offset) len=\(plan.count) rmw=\(!plan.isExact)")
        return plan.count
    }

    /// SYNCHRONIZE CACHE. FSKit never signals barriers (see
    /// docs/backend-a-fskit-notes.md), so this only runs on final close — which
    /// is why the target should also be configured write-through.
    public func flush() throws {
        let proxy = try Self.proxy(connection)
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
