import Foundation

/// Chooses how much a cache miss fetches around the bytes it was asked for
/// (the read-around unit), from what every candidate unit would have cost on
/// the reads actually seen.
///
/// Why it exists: a fixed 256 KiB read-around is what got a VM guest to its
/// desktop (docs/queue-depth.md), and it is also 64x the traffic of a 4 KiB
/// random read that has no neighbours worth fetching (issue #4: 62x on the
/// wire, ~350 IOPS at any queue depth, because each 4 KiB answer waited for
/// 256 KiB). Neither workload is wrong; the unit has to follow the workload.
///
/// How it decides without trying each unit: a *ghost* of the cache keeps,
/// for the chunks a whole-chunk cache of this size would still hold, which
/// parts each candidate unit would have fetched by now. Every read is played
/// against every unit at once — a simulated miss is one round trip plus the
/// bytes of its window — so the estimate for a unit does not depend on which
/// unit is live. That is what keeps this from hunting: a loop that judged
/// the live unit by its own hit rate would see long residencies at small
/// units (many small entries fit) and short ones at large units, and swing.
///
/// Cost is round trips plus bytes priced at `roundTripBytes` each per round
/// trip. Once a second of activity, the cheapest unit over the last three
/// seconds is adopted if it beats the current one by `hysteresis`.
///
/// One bias, on purpose: the ghost holds as many chunks as the real cache
/// holds whole chunks, so it is exact for the largest unit and pessimistic
/// for smaller ones (their entries are smaller, more fit, and in reality
/// some of their simulated misses would have been hits). It leans towards
/// the read-around the cache already had.
///
/// Pure state, no clock and no locking — the caller serialises access and
/// feeds elapsed time, as with `ReadaheadDepthController`.
public struct ReadAroundController: Sendable {

    /// What one round trip is worth in bytes of transfer, which is the
    /// exchange rate between "fetch more now" and "come back later". Chosen,
    /// not measured per link: issue #4's 2.5 GbE path moved ~265 MB/s
    /// sequentially, where 128 KiB takes about half a millisecond — the order
    /// of one round trip there. On 10 GbE a round trip is worth more like
    /// 1 MiB, so this errs towards less traffic, which is the direction a
    /// shared NAS link wants. At this rate, whole-chunk read-around pays once
    /// a chunk sees about three scattered reads while it would be resident.
    public static let roundTripBytes = 128 << 10

    /// Adopt a different unit only if its cost is below this fraction of the
    /// current unit's — so near-ties do not flip the unit back and forth.
    public static let hysteresis = 0.9

    /// Reads the window must hold before any decision.
    public static let minSamples = 20

    private static let bucketNanos: UInt64 = 1_000_000_000
    /// Longest read gap that still counts as activity — the same rule as
    /// `ReadaheadDepthController`: an idle volume is steered by nothing.
    private static let idleCapNanos: UInt64 = 100_000_000
    /// Most recent second first.
    private static let weights = [0.6, 0.3, 0.1]

    /// The finest unit: the resolution of a chunk's bitmaps.
    public let sectorBytes: Int
    public let chunkBytes: Int
    /// Candidate units are `sectorBytes << level` for `level` in
    /// `0 ..< levels`; the last is the whole chunk.
    public let levels: Int

    /// What a miss fetches around its request right now. Starts at the whole
    /// chunk: that is the behaviour the VM measurements were taken with, and
    /// a scattered workload leaves it within seconds.
    public private(set) var unitBytes: Int

    /// The per-level costs the last evaluation compared (nil: declined).
    /// Exposed so tests can see the decision, which `unitBytes` alone hides.
    public private(set) var lastCosts: [Double]?

    private let ghostCapacity: Int
    private var ghost = LRUOrder<UInt64>()
    /// Per ghost chunk, per level: which groups of `1 << level` sectors that
    /// unit would have fetched during the chunk's residency.
    private var fetched: [UInt64: [UInt64]] = [:]

    private struct Bucket {
        var reads = 0
        var trips: [Int]
        var sectors: [Int]
        init(levels: Int) {
            trips = Array(repeating: 0, count: levels)
            sectors = Array(repeating: 0, count: levels)
        }
    }

    private var buckets: [Bucket]
    private var activeNanos: UInt64 = 0

    /// nil when there is nothing to choose between: the chunk is one sector,
    /// or the geometry cannot be expressed as a power-of-two count of at most
    /// 64 sectors (one bitmap word).
    /// - Parameter ghostChunks: how many whole chunks the real cache holds.
    public init?(sectorBytes: Int, chunkBytes: Int, ghostChunks: Int) {
        guard sectorBytes > 0, chunkBytes > sectorBytes, chunkBytes % sectorBytes == 0 else { return nil }
        let sectors = chunkBytes / sectorBytes
        guard sectors.nonzeroBitCount == 1, sectors <= 64 else { return nil }
        self.sectorBytes = sectorBytes
        self.chunkBytes = chunkBytes
        self.levels = sectors.trailingZeroBitCount + 1
        self.unitBytes = chunkBytes
        self.ghostCapacity = max(1, ghostChunks)
        self.buckets = Array(repeating: Bucket(levels: levels), count: 3)
    }

    /// Start somewhere other than the whole chunk. A power-of-two multiple of
    /// the sector, at most the chunk; anything else is ignored.
    public mutating func start(atUnitBytes bytes: Int) {
        guard bytes >= sectorBytes, bytes <= chunkBytes, bytes % sectorBytes == 0,
              (bytes / sectorBytes).nonzeroBitCount == 1 else { return }
        unitBytes = bytes
    }

    /// Play one read against every candidate unit. Call for reads the miss
    /// path could have had to serve — not for reads speculation answered,
    /// whose cost no read-around unit changes.
    public mutating func observe(offset: UInt64, length: Int) {
        guard length > 0 else { return }
        let chunk = UInt64(chunkBytes)
        let sector = UInt64(sectorBytes)
        let end = offset &+ UInt64(length)

        // The chunks this read touches, and the sectors it touches in each.
        var touched: [(key: UInt64, first: Int, last: Int)] = []
        var co = (offset / chunk) * chunk
        while co < end {
            let s = max(offset, co)
            let e = min(end, co &+ chunk)
            touched.append((co, Int((s - co) / sector), Int((e - 1 - co) / sector)))
            co &+= chunk
        }

        for t in touched {
            if fetched[t.key] == nil { fetched[t.key] = Array(repeating: 0, count: levels) }
            ghost.touch(t.key)
        }

        buckets[0].reads += 1
        for level in 0 ..< levels {
            // A miss at this unit fetches the whole window — every group the
            // read touches, in every chunk — in one round trip, as the real
            // miss path does.
            var missed = false
            var groups = 0
            for t in touched {
                let g = Self.groups(first: t.first >> level, last: t.last >> level)
                if fetched[t.key]![level] & g != g { missed = true }
                groups += g.nonzeroBitCount
            }
            guard missed else { continue }
            buckets[0].trips[level] += 1
            buckets[0].sectors[level] += groups << level
            for t in touched {
                fetched[t.key]![level] |= Self.groups(first: t.first >> level, last: t.last >> level)
            }
        }

        // Only now, so a read wider than the ghost cannot evict its own chunks
        // before they are scored.
        while ghost.count > ghostCapacity, let cold = ghost.oldest {
            ghost.remove(cold)
            fetched[cold] = nil
        }
    }

    /// Feed the gap since the previous read. Rolls the window and re-decides
    /// each time a second of activity has accumulated; true if the unit
    /// changed.
    @discardableResult
    public mutating func advance(sinceLastReadNanos gap: UInt64) -> Bool {
        activeNanos &+= min(gap, Self.idleCapNanos)
        guard activeNanos >= Self.bucketNanos else { return false }
        activeNanos -= Self.bucketNanos
        // Decide before rolling, while the second just finished is index 0
        // and carries the heaviest weight.
        let changed = adjust()
        buckets = [Bucket(levels: levels), buckets[0], buckets[1]]
        return changed
    }

    /// Weighted cost of each candidate unit over the window, in round trips;
    /// nil when the window holds too few reads to act on.
    public var costs: [Double]? {
        let reads = buckets.reduce(0) { $0 + $1.reads }
        guard reads >= Self.minSamples else { return nil }
        let rate = Double(sectorBytes) / Double(Self.roundTripBytes)
        return (0 ..< levels).map { level in
            var cost = 0.0
            for (i, b) in buckets.enumerated() {
                cost += Self.weights[i] * (Double(b.trips[level]) + Double(b.sectors[level]) * rate)
            }
            return cost
        }
    }

    private mutating func adjust() -> Bool {
        lastCosts = costs
        guard let costs else { return false }
        let current = (unitBytes / sectorBytes).trailingZeroBitCount
        // `min(by:)` keeps the first minimum: on an exact tie, the smaller unit.
        guard let best = costs.indices.min(by: { costs[$0] < costs[$1] }),
              best != current, costs[best] < costs[current] * Self.hysteresis else { return false }
        unitBytes = sectorBytes << best
        return true
    }

    /// Bits `first ... last` of a word, inclusive.
    private static func groups(first: Int, last: Int) -> UInt64 {
        let upper: UInt64 = last >= 63 ? .max : (UInt64(1) << UInt64(last + 1)) &- 1
        let lower: UInt64 = (UInt64(1) << UInt64(first)) &- 1
        return upper & ~lower
    }
}
