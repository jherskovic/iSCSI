import Foundation

/// A read cache of fixed-size, offset-aligned chunks over a block device,
/// with gated speculation — what stands between a VM guest and a round trip
/// per read. A miss fetches the whole covering span in one round trip
/// (read-around); requests match by range, not size, so a variable-size
/// sequential stream still hits. Speculation is gated by `ReadaheadPolicy`
/// and issues whole chunks.
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
        /// Depth cap currently in force. Constant when a `workloadProfile`
        /// override pins it; otherwise the controller's live figure, which is
        /// the only way to see what the loop is doing from a soak.
        public var currentCap = 0
    }

    private final class Entry {
        enum State { case pending, ready(Data), failed }
        let cond = NSCondition()
        /// Guarded by `cond`; `fill` is the only writer after init.
        private(set) var state: State
        let length: Int
        let speculative: Bool
        /// LRU tick and first-use flag, guarded by the cache's lock.
        var lastTouch: UInt64
        var used = false

        init(ready data: Data, lastTouch: UInt64) {
            state = .ready(data)
            length = data.count
            speculative = false
            self.lastTouch = lastTouch
        }

        init(pendingSpeculativeOf length: Int, lastTouch: UInt64) {
            state = .pending
            self.length = length
            speculative = true
            self.lastTouch = lastTouch
        }

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

    private let lock = NSLock()
    private var map: [UInt64: Entry] = [:]
    private var policy: ReadaheadPolicy
    private var tick: UInt64 = 0
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
    /// the target pinned its depth with a `workloadProfile` override.
    private var depthController: ReadaheadDepthController?
    /// `DispatchTime` rather than `Date`: monotonic, so a clock adjustment
    /// cannot make a gap negative or enormous. It also does not advance while
    /// the machine is asleep, which suits a window that is supposed to measure
    /// activity — a sleeping volume is the idlest kind there is.
    private var lastReadNanos: UInt64 = 0

    public init(chunkBytes: Int, capacity: UInt64, maxCachedBytes: Int,
                policy: ReadaheadPolicy, timeout: TimeInterval,
                adaptiveDepth: Bool = false,
                fetchSync: @escaping (UInt64, Int) throws -> Data,
                fetchAsync: @escaping (UInt64, Int, @escaping (Data?) -> Void) -> Void) {
        precondition(chunkBytes > 0)
        self.chunkBytes = chunkBytes
        self.capacity = capacity
        self.maxCachedBytes = maxCachedBytes
        self.policy = policy
        self.timeout = timeout
        self.fetchSync = fetchSync
        self.fetchAsync = fetchAsync
        if adaptiveDepth {
            let c = ReadaheadDepthController(initialCap: policy.chunkCap,
                                             ceiling: policy.maxSlots)
            self.policy.adaptiveCap = c.cap
            self.depthController = c
        }
        statsStore.currentCap = self.policy.chunkCap
    }

    /// Called under `lock` at the top of every read: the controller's clock is
    /// the read stream itself, so an idle volume schedules nothing and is
    /// steered by nothing. This is why there is no timer anywhere here.
    private func noteReadLocked() {
        guard depthController != nil else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        let gap = lastReadNanos == 0 ? 0 : now &- lastReadNanos
        lastReadNanos = now
        if depthController!.advance(sinceLastReadNanos: gap) {
            policy.adaptiveCap = depthController!.cap
            statsStore.currentCap = policy.chunkCap
        }
    }

    /// Serve `[offset, offset+length)`, from cache when the covering chunks
    /// are cached or already on their way, and by fetching the whole covering
    /// span in one call when they are not.
    public func read(offset: UInt64, length: Int) throws -> Data {
        guard length > 0, offset < capacity else { return Data() }
        let chunk = UInt64(chunkBytes)
        let end = min(offset &+ UInt64(length), capacity)
        let count = Int(end - offset)
        let spanStart = (offset / chunk) * chunk
        let spanEnd = min(((end &+ chunk &- 1) / chunk) * chunk, capacity)

        // Collect the covering chunks, if every one is at least on its way.
        lock.lock()
        noteReadLocked()
        var entries: [Entry] = []
        var allPresent = true
        var co = spanStart
        while co < spanEnd {
            guard let e = map[co] else { allPresent = false; break }
            entries.append(e)
            co += chunk
        }
        if allPresent {
            tick += 1
            for e in entries {
                e.lastTouch = tick
                if e.speculative, !e.used {
                    e.used = true
                    statsStore.speculatedUsed += 1
                }
            }
        }
        lock.unlock()

        if allPresent {
            var collected: [Data] = []
            var anyFailed = false
            for e in entries {
                e.cond.lock()
                let deadline = Date().addingTimeInterval(timeout)
                var timedOut = false
                while case .pending = e.state {
                    if !e.cond.wait(until: deadline) { timedOut = true; break }
                }
                let state = e.state
                e.cond.unlock()
                switch state {
                case .ready(let data): collected.append(data)
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
                let out = Self.assemble(collected, skip: Int(offset - spanStart), count: count)
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

        // Miss: one synchronous fetch of the whole aligned span (read-around),
        // cached chunk-wise so the next nearby read is a memory copy.
        let spanLen = Int(spanEnd - spanStart)
        lock.lock()
        statsStore.misses += 1
        statsStore.readAroundBytes += UInt64(spanLen - count)
        let generation = writeGeneration
        lock.unlock()
        let data = try fetchSync(spanStart, spanLen)
        guard data.count == spanLen else { throw CacheError.shortRead }

        lock.lock()
        if writeGeneration == generation {
            tick += 1
            var index = 0
            co = spanStart
            while co < spanEnd {
                let clen = Int(min(chunk, spanEnd - co))
                // Overwrites any pending entry outright; its late reply then
                // fills an orphan and is discarded, never resurrected into
                // the map.
                map[co] = Entry(ready: data.subdata(in: index ..< index + clen), lastTouch: tick)
                co += chunk
                index += clen
            }
            evictLocked()
        }
        lock.unlock()

        speculateAfter(offset: offset, length: count)
        let skip = Int(offset - spanStart)
        return data.subdata(in: skip ..< skip + count)
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
                    let entryEnd = co &+ UInt64(old.count)
                    let isectStart = max(offset, co)
                    let isectEnd = min(end, entryEnd)
                    guard isectStart < isectEnd else { return }
                    var patched = old
                    patched.replaceSubrange(
                        Int(isectStart - co) ..< Int(isectEnd - co),
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
                if map[co] == nil {
                    let clen = Int(min(chunk, capacity - co))
                    tick += 1
                    let e = Entry(pendingSpeculativeOf: clen, lastTouch: tick)
                    map[co] = e
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
        var total = map.values.reduce(0) { $0 + $1.length }
        while total > maxCachedBytes {
            var coldest: (key: UInt64, touch: UInt64)? = nil
            for (key, e) in map {
                guard case .ready = e.snapshot else { continue }
                if coldest == nil || e.lastTouch < coldest!.touch {
                    coldest = (key, e.lastTouch)
                }
            }
            guard let victim = coldest, let removed = removeLocked(victim.key) else { break }
            total -= removed.length
        }
    }

    /// Splice `[skip, skip+count)` out of consecutive chunk buffers.
    private static func assemble(_ chunks: [Data], skip: Int, count: Int) -> Data {
        var out = Data(capacity: count)
        var toSkip = skip
        var remaining = count
        for data in chunks {
            if toSkip >= data.count { toSkip -= data.count; continue }
            let take = min(data.count - toSkip, remaining)
            out.append(data.subdata(in: toSkip ..< toSkip + take))
            toSkip = 0
            remaining -= take
            if remaining == 0 { break }
        }
        return out
    }
}
