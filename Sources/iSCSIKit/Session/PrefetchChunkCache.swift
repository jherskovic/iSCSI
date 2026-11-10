import Foundation

/// A read cache of fixed-size, offset-aligned chunks over a block device,
/// with gated speculation — what stands between a VM guest and a round trip
/// per read. A miss fetches the requested range widened to the current
/// read-around unit in one round trip; requests match by range, not size, so
/// a variable-size sequential stream still hits. Speculation is gated by
/// `ReadaheadPolicy` and issues whole chunks.
///
/// Read-around: the unit is the whole chunk until `ReadAroundController`
/// (given a `sectorBytes` finer than the chunk) measures that the workload
/// does not use it, and then as little as one sector. A chunk's entry may
/// therefore hold only a contiguous part of it; a read is a hit only where
/// its entry covers it.
///
/// Coherence: write-through. `willWrite` runs before the device write (ramp
/// reset, generation bump, overlapping pending fetches dropped); `didWrite`
/// patches acknowledged bytes into overlapping ready chunks so
/// write-then-read-back hits; `writeFailed` drops the overlap (outcome
/// unknown). All of it assumes this initiator is the LUN's only writer.
///
/// Transport-agnostic so everything above is unit-tested against an
/// in-memory LUN: the owner supplies the synchronous (miss) and async
/// (speculation) fetches.
public final class PrefetchChunkCache: @unchecked Sendable {
    public enum CacheError: Error, Equatable {
        /// A previously issued speculative read never answered within the
        /// timeout. The session is in trouble; re-asking would spend a second
        /// timeout learning the same thing, so the caller should account it
        /// like any unanswered daemon call.
        case unanswered
        /// The synchronous fetch returned the wrong number of bytes.
        case shortRead
    }

    public struct Stats: Sendable {
        /// Reads served entirely from cached or in-flight chunks.
        public var hits = 0
        /// Reads that needed a synchronous fetch.
        public var misses = 0
        /// Pending-chunk waits that timed out.
        public var unanswered = 0
        /// Speculative chunk fetches issued.
        public var chunksSpeculated = 0
        public var speculatedBytes: UInt64 = 0
        /// Speculative chunks some read actually touched. `chunksSpeculated`
        /// minus this is the waste — traffic paid for and never used.
        public var speculatedUsed = 0
        /// Bytes fetched beyond what callers asked for (the read-around bet).
        /// Compare against hit traffic to see whether the bet pays.
        public var readAroundBytes: UInt64 = 0
        /// Deepest speculation window actually opened.
        public var maxDepth = 0

        /// Speculative chunks that left the cache read at least once / never
        /// read — the only *settled* verdict on speculation, and what steers
        /// depth. (`chunksSpeculated - speculatedUsed` cannot: it counts
        /// everything in flight as waste, so it rises exactly when depth does.)
        public var resolvedUsed = 0
        public var resolvedWasted = 0
        /// Depth cap currently in force. Constant when a test or bench
        /// override pins it; otherwise the controller's live figure, which is
        /// the only way to see what the loop is doing from a soak.
        public var currentCap = 0
        /// What a miss fetches around its request right now. The whole chunk
        /// unless `ReadAroundController` has chosen less.
        public var readAroundUnit = 0
    }

    private final class Entry {
        enum State { case pending, ready(Data), failed }
        let cond = NSCondition()
        /// Guarded by `cond`; `fill` is the only writer after init.
        private(set) var state: State
        /// Where this entry's bytes begin, counted from its chunk's start.
        /// Speculation always covers a whole chunk (0); a miss fetched at a
        /// unit smaller than the chunk holds only part of one. Fixed for the
        /// entry's life — growing the range means a new entry — so coverage
        /// can be checked under the cache's lock without `cond`.
        let lo: Int
        let length: Int
        let speculative: Bool
        /// First-use flag, guarded by the cache's lock.
        var used = false

        init(ready data: Data, lo: Int = 0) {
            state = .ready(data)
            self.lo = lo
            length = data.count
            speculative = false
        }

        init(pendingSpeculativeOf length: Int) {
            state = .pending
            lo = 0
            self.length = length
            speculative = true
        }

        /// Whether `[from, to)`, counted from the chunk's start, lies within
        /// this entry's bytes.
        func covers(_ from: Int, _ to: Int) -> Bool { from >= lo && to <= lo + length }

        /// Called by the async completion — possibly long after this entry
        /// was replaced in the map, in which case it fills an orphan nobody
        /// will ever consult.
        func fill(_ data: Data?) {
            cond.lock()
            state = data.map { State.ready($0) } ?? .failed
            cond.broadcast()
            cond.unlock()
        }

        /// Swap a ready chunk's bytes for a patched copy (write-through).
        /// A no-op in any other state: pending and failed entries are dropped
        /// by the caller instead, because there is nothing valid to patch.
        func replaceReady(_ data: Data) {
            cond.lock()
            if case .ready = state { state = .ready(data) }
            cond.unlock()
        }

        var snapshot: State {
            cond.lock(); defer { cond.unlock() }
            return state
        }
    }

    private let chunkBytes: Int
    private let capacity: UInt64
    private let maxCachedBytes: Int
    private let timeout: TimeInterval
    private let fetchSync: (UInt64, Int) throws -> Data
    private let fetchAsync: (UInt64, Int, @escaping (Data?) -> Void) -> Void
    /// Receives each chunk evicted for capacity that a caller actually read —
    /// the disk tier's only source. Called under the cache's lock: it must be
    /// quick and must never call back into the cache.
    private let onEvict: ((UInt64, Data) -> Void)?

    private let lock = NSLock()
    private var map: [UInt64: Entry] = [:]
    /// Recency over `map`'s keys, for eviction. Every key in `map` is in it.
    private var order = LRUOrder<UInt64>()
    /// Sum of every entry's `length`, pending ones included — kept rather
    /// than summed, because a cache of sector-sized entries holds thousands.
    private var residentBytes = 0
    private var policy: ReadaheadPolicy
    private var statsStore = Stats()
    /// Bumped by every `noteWrite`. A miss snapshots it before its fetch and
    /// declines to cache the result if it changed — bytes fetched while a
    /// write was landing may predate that write. The read still returns them;
    /// nothing stale persists. Deliberately coarse (any write anywhere):
    /// a fine-grained range check is how stale blocks get served.
    private var writeGeneration: UInt64 = 0

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return statsStore
    }

    /// Steers `policy.adaptiveCap` from settled speculation outcomes. nil when
    /// a test or bench pinned its depth.
    private var depthController: ReadaheadDepthController?
    /// Chooses the miss path's fetch unit. nil when the chunk is the only
    /// unit there is (no `sectorBytes` finer than it).
    private var readAround: ReadAroundController?
    /// Uptime in nanoseconds. `DispatchTime` rather than `Date` by default:
    /// monotonic, so a clock adjustment cannot make a gap negative or
    /// enormous. It also does not advance while the machine is asleep, which
    /// suits a window that is supposed to measure activity — a sleeping
    /// volume is the idlest kind there is. Injectable so tests can run a
    /// second of activity without waiting one.
    private let clock: @Sendable () -> UInt64
    private var lastReadNanos: UInt64?

    /// - Parameters:
    ///   - sectorBytes: the finest read-around unit. A power-of-two fraction
    ///     of the chunk, at most 64 to a chunk and a multiple of the device
    ///     block; anything else, or nil, keeps whole-chunk read-around.
    ///   - readAroundStartBytes: the unit to start at; nil is the whole chunk.
    ///   - onEvict: receives only whole chunks, never a partial entry.
    public init(chunkBytes: Int, capacity: UInt64, maxCachedBytes: Int,
                policy: ReadaheadPolicy, timeout: TimeInterval,
                adaptiveDepth: Bool = false,
                sectorBytes: Int? = nil,
                readAroundStartBytes: Int? = nil,
                clock: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                fetchSync: @escaping (UInt64, Int) throws -> Data,
                fetchAsync: @escaping (UInt64, Int, @escaping (Data?) -> Void) -> Void,
                onEvict: ((UInt64, Data) -> Void)? = nil) {
        precondition(chunkBytes > 0)
        self.chunkBytes = chunkBytes
        self.capacity = capacity
        self.maxCachedBytes = maxCachedBytes
        self.policy = policy
        self.timeout = timeout
        self.clock = clock
        self.fetchSync = fetchSync
        self.fetchAsync = fetchAsync
        self.onEvict = onEvict
        if adaptiveDepth {
            let c = ReadaheadDepthController(initialCap: policy.chunkCap,
                                             ceiling: policy.maxSlots)
            self.policy.adaptiveCap = c.cap
            self.depthController = c
        }
        if let sectorBytes,
           var c = ReadAroundController(sectorBytes: sectorBytes, chunkBytes: chunkBytes,
                                        ghostChunks: max(1, maxCachedBytes / chunkBytes)) {
            if let readAroundStartBytes { c.start(atUnitBytes: readAroundStartBytes) }
            self.readAround = c
        }
        statsStore.currentCap = self.policy.chunkCap
        statsStore.readAroundUnit = readAround?.unitBytes ?? chunkBytes
    }

    /// Called under `lock` at the top of every read: the controllers' clock is
    /// the read stream itself, so an idle volume schedules nothing and is
    /// steered by nothing. This is why there is no timer anywhere here.
    private func noteReadLocked() {
        guard depthController != nil || readAround != nil else { return }
        let now = clock()
        let gap = lastReadNanos.map { now &- $0 } ?? 0
        lastReadNanos = now
        if depthController != nil, depthController!.advance(sinceLastReadNanos: gap) {
            policy.adaptiveCap = depthController!.cap
            statsStore.currentCap = policy.chunkCap
        }
        if readAround != nil, readAround!.advance(sinceLastReadNanos: gap) {
            statsStore.readAroundUnit = readAround!.unitBytes
        }
    }

    /// The length of the chunk at `key`: the chunk size, or less for the last.
    private func fullLength(_ key: UInt64) -> Int {
        Int(min(UInt64(chunkBytes), capacity - key))
    }

    /// Serve `[offset, offset+length)`, from cache when the covering chunks
    /// hold those bytes or are already on their way, and by one fetch of the
    /// request widened to the read-around unit when they do not.
    public func read(offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < capacity else { return Data() }
        let chunk = UInt64(chunkBytes)
        let end = min(offset &+ UInt64(length), capacity)
        let count = Int(end - offset)
        let spanStart = (offset / chunk) * chunk
        let spanEnd = min(((end &+ chunk &- 1) / chunk) * chunk, capacity)

        // Collect the covering entries, if each holds (or will hold) the part
        // of the request that falls in its chunk.
        lock.lock()
        noteReadLocked()
        var entries: [(key: UInt64, entry: Entry)] = []
        var allPresent = true
        var co = spanStart
        while co < spanEnd {
            guard let e = map[co],
                  e.covers(Int(max(offset, co) - co), Int(min(end, co &+ chunk) - co)) else {
                allPresent = false
                break
            }
            entries.append((co, e))
            co += chunk
        }
        var observed = false
        if allPresent {
            var speculated = false
            for (key, e) in entries {
                order.touch(key)
                if e.speculative {
                    speculated = true
                    if !e.used {
                        e.used = true
                        statsStore.speculatedUsed += 1
                    }
                }
            }
            // Speculation answered this one, and would have whatever the
            // read-around unit: it is not evidence about the miss path.
            if !speculated {
                readAround?.observe(offset: offset, length: count)
                observed = true
            }
        }
        lock.unlock()

        if allPresent {
            var collected: [(start: UInt64, data: Data)] = []
            var anyFailed = false
            for (key, e) in entries {
                e.cond.lock()
                let deadline = Date().addingTimeInterval(timeout)
                var timedOut = false
                while case .pending = e.state {
                    if !e.cond.wait(until: deadline) { timedOut = true; break }
                }
                let state = e.state
                e.cond.unlock()
                switch state {
                case .ready(let data): collected.append((key &+ UInt64(e.lo), data))
                case .failed: anyFailed = true
                case .pending:
                    precondition(timedOut)
                    lock.lock()
                    statsStore.unanswered += 1
                    dropPendingLocked()
                    lock.unlock()
                    throw CacheError.unanswered
                }
                if anyFailed { break }
            }
            if !anyFailed {
                lock.lock(); statsStore.hits += 1; lock.unlock()
                let out = Self.assemble(collected, offset: offset, count: count)
                speculateAfter(offset: offset, length: count)
                return out
            }
            // A speculative read failed. Purge what failed and read for real:
            // speculation is only ever an optimisation, and the *real* read's
            // error handling belongs to the synchronous path below.
            lock.lock()
            co = spanStart
            while co < spanEnd {
                if let e = map[co], case .failed = e.snapshot {
                    removeLocked(co)
                }
                co += chunk
            }
            lock.unlock()
        }

        // Miss: one synchronous fetch of the request widened to the
        // read-around unit, kept chunk-wise so the next nearby read is a
        // memory copy. The unit divides the chunk, so the window never
        // reaches a chunk the request does not touch.
        lock.lock()
        if !observed { readAround?.observe(offset: offset, length: count) }
        let unit = UInt64(readAround?.unitBytes ?? chunkBytes)
        let fetchStart = (offset / unit) * unit
        let fetchEnd = min(((end &+ unit &- 1) / unit) * unit, capacity)
        let fetchLen = Int(fetchEnd - fetchStart)
        statsStore.misses += 1
        statsStore.readAroundBytes += UInt64(fetchLen - count)
        let generation = writeGeneration
        lock.unlock()
        let data = try fetchSync(fetchStart, fetchLen)
        guard data.count == fetchLen else { throw CacheError.shortRead }

        lock.lock()
        if writeGeneration == generation {
            co = spanStart
            while co < spanEnd {
                let pieceStart = max(fetchStart, co)
                let pieceEnd = min(fetchEnd, co &+ chunk)
                let piece = data.subdata(in: Int(pieceStart - fetchStart) ..< Int(pieceEnd - fetchStart))
                keepFetchedLocked(piece, chunk: co, at: Int(pieceStart - co))
                co += chunk
            }
            evictLocked()
        }
        lock.unlock()

        speculateAfter(offset: offset, length: count)
        let skip = Int(offset - fetchStart)
        return data.subdata(in: skip ..< skip + count)
    }

    /// Keep freshly fetched bytes `piece`, which start `lo` bytes into the
    /// chunk at `key`. A ready entry they overlap or touch is merged with
    /// them into one, so read-around that grows a run keeps all of it. A
    /// ready entry they are disjoint from is replaced: one contiguous range
    /// per chunk is what keeps coverage a comparison, and the bytes just asked
    /// for are the likelier to be asked for again. Disjoint pieces arise only
    /// below the whole chunk, which the controller chooses only once it has
    /// measured that a chunk's other bytes mostly go unread.
    ///
    /// A pending speculation is kept unless the piece is the whole chunk:
    /// it will hold all of it, and it is already paid for.
    ///
    /// Both sides are current: `didWrite` patches ready entries, and the
    /// caller keeps `piece` only if no write overlapped its fetch.
    private func keepFetchedLocked(_ piece: Data, chunk key: UInt64, at lo: Int) {
        var bytes = piece
        var start = lo
        if let old = map[key] {
            switch old.snapshot {
            case .pending:
                // Replaced outright by a whole chunk, as always: its late
                // reply fills an orphan, never resurrected into the map.
                guard lo == 0, piece.count == fullLength(key) else { return }
            case .ready(let oldBytes):
                if old.lo <= lo + piece.count, lo <= old.lo + oldBytes.count {
                    start = min(lo, old.lo)
                    let end = max(lo + piece.count, old.lo + oldBytes.count)
                    var merged = Data(count: end - start)
                    merged.replaceSubrange((old.lo - start) ..< (old.lo - start + oldBytes.count), with: oldBytes)
                    merged.replaceSubrange((lo - start) ..< (lo - start + piece.count), with: piece)
                    bytes = merged
                }
            case .failed:
                break
            }
        }
        replaceLocked(key, with: Entry(ready: bytes, lo: start))
    }

    /// A write is about to be issued. Resets the speculation ramp (the
    /// sequential pattern ended with the write), bumps the write generation
    /// (so a miss fetch racing this write cannot cache era-ambiguous bytes),
    /// and drops overlapping *pending* fetches, whose replies will be of
    /// unknowable era. Ready chunks stay: their bytes are correct until the
    /// device acknowledges the write, and `didWrite` patches them then.
    public func willWrite(offset: UInt64, length: Int) {
        lock.lock()
        policy.reset()
        writeGeneration &+= 1
        if length > 0 {
            forEachOverlappingChunkLocked(offset: offset, length: length) { co, e in
                if case .pending = e.snapshot { removeLocked(co) }
            }
        }
        lock.unlock()
    }

    /// The device acknowledged a write of exactly `data` at `offset`: patch
    /// it into overlapping cached chunks (write-then-read-back stays a hit).
    /// The bytes are authoritative under the single-writer assumption.
    public func didWrite(_ data: Data, at offset: UInt64) {
        lock.lock()
        writeGeneration &+= 1
        if !data.isEmpty {
            let end = offset &+ UInt64(data.count)
            forEachOverlappingChunkLocked(offset: offset, length: data.count) { co, e in
                switch e.snapshot {
                case .ready(let old):
                    let entryStart = co &+ UInt64(e.lo)
                    let entryEnd = entryStart &+ UInt64(old.count)
                    let isectStart = max(offset, entryStart)
                    let isectEnd = min(end, entryEnd)
                    guard isectStart < isectEnd else { return }
                    var patched = old
                    patched.replaceSubrange(
                        Int(isectStart - entryStart) ..< Int(isectEnd - entryStart),
                        with: data.subdata(in: Int(isectStart - offset) ..< Int(isectEnd - offset)))
                    e.replaceReady(patched)
                case .pending, .failed:
                    // Speculation issued between willWrite and now raced the
                    // write on the wire; if it has not resolved to usable
                    // bytes yet, its era is unknowable. Drop it.
                    removeLocked(co)
                }
            }
        }
        lock.unlock()
    }

    /// The write failed, or its outcome is unknown — which blocks of the
    /// range reached the media is unknowable, so every overlapping chunk is
    /// dropped rather than patched.
    public func writeFailed(offset: UInt64, length: Int) {
        lock.lock()
        writeGeneration &+= 1
        if length > 0 {
            forEachOverlappingChunkLocked(offset: offset, length: length) { co, _ in
                removeLocked(co)
            }
        }
        lock.unlock()
    }

    /// Walk the chunk-aligned keys covering `[offset, offset+length)` that
    /// are present in the map. Must be called with `lock` held.
    private func forEachOverlappingChunkLocked(
        offset: UInt64, length: Int, _ body: (UInt64, Entry) -> Void
    ) {
        let chunk = UInt64(chunkBytes)
        var co = (offset / chunk) * chunk
        let end = offset &+ UInt64(length)
        while co < end, co < capacity {
            if let e = map[co] { body(co, e) }
            co += chunk
        }
    }

    /// Ask the policy whether this read has earned speculation, and keep that
    /// many chunks on their way beyond it.
    private func speculateAfter(offset: UInt64, length: Int) {
        var toIssue: [(UInt64, Int, Entry)] = []
        lock.lock()
        let depth = policy.noteServed(offset: offset, length: length)
        if depth > 0 {
            statsStore.maxDepth = max(statsStore.maxDepth, depth)
            let chunk = UInt64(chunkBytes)
            var co = ((offset &+ UInt64(length) &+ chunk &- 1) / chunk) * chunk
            var considered = 0
            while considered < depth, co < capacity {
                let clen = fullLength(co)
                // Absent, or left partly cached by a miss: either way a
                // stream about to cross the chunk needs all of it.
                let wanted = map[co].map { e -> Bool in
                    if case .ready = e.snapshot { return !e.covers(0, clen) }
                    return false
                } ?? true
                if wanted {
                    let e = Entry(pendingSpeculativeOf: clen)
                    replaceLocked(co, with: e)
                    toIssue.append((co, clen, e))
                    statsStore.chunksSpeculated += 1
                    statsStore.speculatedBytes += UInt64(clen)
                }
                considered += 1
                co += chunk
            }
            evictLocked()
        }
        lock.unlock()

        for (co, clen, e) in toIssue {
            fetchAsync(co, clen) { data in
                e.fill(data?.count == clen ? data : nil)
            }
        }
    }

    /// Remove `key`, settling the verdict on it if it was speculative. Every
    /// removal goes through here: a chunk leaving the map is the only moment
    /// its speculation is decided, and a site that removed entries directly
    /// would silently drop that verdict.
    @discardableResult
    private func removeLocked(_ key: UInt64) -> Entry? {
        guard let e = map.removeValue(forKey: key) else { return nil }
        residentBytes -= e.length
        order.remove(key)
        if e.speculative {
            if e.used {
                statsStore.resolvedUsed += 1
                depthController?.recordResolved(used: 1, wasted: 0)
            } else {
                statsStore.resolvedWasted += 1
                depthController?.recordResolved(used: 0, wasted: 1)
            }
        }
        return e
    }

    /// Put `entry` at `key`, displacing whatever was there without a verdict:
    /// a miss's fetch or a new speculation supersedes it, and a late reply to
    /// a displaced pending fetch fills an orphan nobody consults. The one
    /// path into `map` besides `removeLocked`, so `order` and `residentBytes`
    /// cannot drift from it.
    private func replaceLocked(_ key: UInt64, with entry: Entry) {
        if let old = map[key] { residentBytes -= old.length }
        map[key] = entry
        residentBytes += entry.length
        order.touch(key)
    }

    /// Forget everything still pending — for the unanswered path, where the
    /// session is presumed in trouble and nobody should wait on those again.
    private func dropPendingLocked() {
        for (key, e) in map {
            if case .pending = e.snapshot { removeLocked(key) }
        }
    }

    /// Keep the resident set at `maxCachedBytes`, evicting the coldest ready
    /// chunk first. Pending chunks are never evicted: they represent traffic
    /// already bought, and a waiter may hold a reference.
    private func evictLocked() {
        var candidate = order.oldest
        while residentBytes > maxCachedBytes, let key = candidate {
            candidate = order.newer(than: key)
            guard let e = map[key], case .ready(let data) = e.snapshot else { continue }
            removeLocked(key)
            // Only what a caller read moves down a tier: unread speculation
            // was never wanted the first time. And only whole chunks: the
            // tier keys a slot by its chunk and serves it from the chunk's
            // first byte, so part of one would be served as the wrong bytes.
            if let onEvict, !e.speculative || e.used, e.lo == 0, data.count == fullLength(key) {
                onEvict(key, data)
            }
        }
    }

    /// Splice `[offset, offset+count)` out of entry buffers in ascending
    /// order, each starting at absolute offset `start`. The caller checked
    /// that together they cover the range.
    private static func assemble(_ parts: [(start: UInt64, data: Data)],
                                 offset: UInt64, count: Int) -> Data {
        var out = Data(capacity: count)
        let end = offset &+ UInt64(count)
        for (start, data) in parts {
            let s = max(offset, start)
            let e = min(end, start &+ UInt64(data.count))
            guard s < e else { continue }
            out.append(data.subdata(in: Int(s - start) ..< Int(e - start)))
        }
        return out
    }
}
