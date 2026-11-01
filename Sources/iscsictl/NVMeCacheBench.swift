import ArgumentParser
import Foundation
import NVMeKit
import iSCSIKit

// iscsictl nvme cache-bench — the FSKit extension's read cache, driven over
// raw NVMe/TCP. Read-only.
//
// It answers the half of issue #4 that does not need FSKit: what each read
// costs on the wire with whole-chunk read-around against the adaptive unit.
// No FSKit, no XPC, no DiskImages, so it does not reproduce the shipping
// path's one-read-at-a-time delivery or its per-read XPC hop — the latencies
// are the cache's and the target's, nothing above.

struct NVMeCacheBench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "cache-bench",
        abstract: "Reads through the extension's chunk cache over raw NVMe/TCP: bytes fetched against bytes asked, whole-chunk against adaptive read-around. Read-only."
    )

    enum Pattern: String, ExpressibleByArgument, CaseIterable {
        /// Anywhere in the region, uniformly: fio's randread.
        case random
        /// Bursts of reads at random sectors of one random chunk: locality
        /// without streams, the shape read-around was built for.
        case clustered
        /// Back to back from the region's start.
        case sequential
    }

    enum Mode: String, ExpressibleByArgument, CaseIterable {
        case fixed, adaptive, both
    }

    @OptionGroup var options: NVMeOptions

    @Option(help: "Subsystem NQN to connect to.")
    var subsystem: String

    @Option(help: "Namespace ID.")
    var nsid: UInt32 = 1

    @Option(help: "Access pattern: random, clustered or sequential.")
    var pattern: Pattern = .random

    @Option(help: "Bytes per read.")
    var readSize: Int = 4096

    @Option(help: "Reads per run.")
    var reads: Int = 5000

    @Option(help: "Region size in MiB. Each run reads its own region, so one run cannot warm the target's cache for the next.")
    var regionMB: Int = 1024

    @Option(help: "Where the first run's region starts, in MiB.")
    var offsetMB: Int = 0

    @Option(help: "Reads per chunk in a clustered burst.")
    var burst: Int = 8

    @Option(help: "fixed (whole-chunk read-around, as shipped), adaptive, or both.")
    var readAround: Mode = .both

    @Option(help: "Threads issuing reads, each one at a time. 1 is what FSKit delivers.")
    var threads: Int = 1

    @Option(help: "Seed for the read plan, so runs are comparable.")
    var seed: UInt64 = 1

    func validate() throws {
        guard reads > 0, readSize > 0, regionMB > 0, threads >= 1, burst >= 1 else {
            throw ValidationError("--reads, --read-size, --region-mb, --threads and --burst must be positive")
        }
    }

    func run() async throws {
        let controller = try options.controller(subsystem: subsystem)
        try await controller.activate()
        let device = NVMeBlockDevice(controller: controller, nsid: nsid)
        let (blockSize, blockCount) = try await device.readCapacity()
        let capacity = UInt64(blockSize) * blockCount
        guard readSize % blockSize == 0 else {
            throw ValidationError("--read-size must be a multiple of the \(blockSize)-byte block")
        }
        let modes: [Mode] = readAround == .both ? [.fixed, .adaptive] : [readAround]
        let region = UInt64(regionMB) << 20
        let first = UInt64(offsetMB) << 20
        guard first + region * UInt64(modes.count) <= capacity else {
            throw ValidationError("the namespace holds \(capacity >> 20) MiB; "
                                  + "\(modes.count) region(s) of \(regionMB) MiB from \(offsetMB) MiB do not fit")
        }
        print("namespace \(capacity >> 20) MiB, block \(blockSize) B; \(pattern.rawValue) reads of "
              + "\(readSize) B x \(reads), \(threads) thread(s), \(regionMB) MiB region per run")

        for (i, mode) in modes.enumerated() {
            let start = first + region * UInt64(i)
            let plan = Self.plan(pattern: pattern, reads: reads, readSize: readSize, burst: burst,
                                 start: start, region: region, seed: seed)
            let result = await Self.measure(device: device, capacity: capacity, blockSize: blockSize,
                                            adaptive: mode == .adaptive, plan: plan,
                                            readSize: readSize, threads: threads)
            result.report(mode: mode.rawValue, regionStartMB: Int(start >> 20))
        }
        try await controller.logout()
    }

    // MARK: Plan

    private static func plan(pattern: Pattern, reads: Int, readSize: Int, burst: Int,
                             start: UInt64, region: UInt64, seed: UInt64) -> [UInt64] {
        var rng = SplitMix(state: seed)
        let size = UInt64(readSize)
        let slots = max(1, region / size)
        switch pattern {
        case .random:
            return (0 ..< reads).map { _ in start + UInt64.random(in: 0 ..< slots, using: &rng) * size }
        case .sequential:
            return (0 ..< reads).map { start + (UInt64($0) % slots) * size }
        case .clustered:
            let chunk = UInt64(BenchGeometry.chunkBytes)
            let chunks = max(1, region / chunk)
            let perChunk = max(1, chunk / size)
            var out: [UInt64] = []
            while out.count < reads {
                let base = start + UInt64.random(in: 0 ..< chunks, using: &rng) * chunk
                var picks = Array(0 ..< perChunk)
                picks.shuffle(using: &rng)
                for p in picks.prefix(burst) where out.count < reads { out.append(base + p * size) }
            }
            return out
        }
    }

    // MARK: Measure

    private static func measure(device: NVMeBlockDevice, capacity: UInt64, blockSize: Int,
                                adaptive: Bool, plan: [UInt64], readSize: Int,
                                threads: Int) async -> BenchResult {
        let counters = FetchCounters()
        let chunk = max(BenchGeometry.chunkBytes, blockSize)
        let cache = PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: capacity,
            maxCachedBytes: BenchGeometry.maxCachedBytes,
            policy: ReadaheadPolicy(budgetBytes: WorkloadProfile.mixed.readaheadBudgetBytes,
                                    maxSlots: BenchGeometry.maxSlots,
                                    minStreamBytes: BenchGeometry.minStreamBytes,
                                    chunkBytes: chunk),
            timeout: 30,
            adaptiveDepth: true,
            sectorBytes: adaptive ? max(4096, blockSize) : nil,
            fetchSync: { offset, length in
                let box = ResultBox()
                let done = DispatchSemaphore(value: 0)
                Task {
                    do { box.set(.success(try await device.read(offset: offset, length: length))) }
                    catch { box.set(.failure(error)) }
                    done.signal()
                }
                done.wait()
                counters.add(sync: length)
                return try box.get()
            },
            fetchAsync: { offset, length, done in
                counters.add(async: length)
                // The cache's completion is called once, from this task alone.
                let reply = Unchecked(done)
                Task { reply.value(try? await device.read(offset: offset, length: length)) }
            })

        // On threads of their own: `fetchSync` blocks, as the extension's
        // does, and must never block the cooperative pool the device runs on.
        return await withCheckedContinuation { continuation in
            let latencies = LatencyLog()
            let units = UnitLog()
            let group = DispatchGroup()
            let started = Date()
            let sampler = Sampler(counters: counters, cache: cache)
            sampler.start()
            for t in 0 ..< threads {
                group.enter()
                let mine = stride(from: t, to: plan.count, by: threads).map { plan[$0] }
                Thread {
                    var zeros = 0
                    var failures = 0
                    var local: [Double] = []
                    local.reserveCapacity(mine.count)
                    for (n, offset) in mine.enumerated() {
                        let t0 = DispatchTime.now().uptimeNanoseconds
                        do {
                            let data = try cache.read(offset: offset, length: readSize)
                            if data.allSatisfy({ $0 == 0 }) { zeros += 1 }
                        } catch {
                            failures += 1
                        }
                        local.append(Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6)
                        counters.completedRead()
                        if t == 0 { units.note(read: n * threads, unit: cache.stats.readAroundUnit) }
                    }
                    latencies.add(local, zeros: zeros, failures: failures)
                    group.leave()
                }.start()
            }
            group.notify(queue: .global()) {
                let elapsed = Date().timeIntervalSince(started)
                let seconds = sampler.stop()
                continuation.resume(returning: BenchResult(
                    reads: plan.count, readSize: readSize, elapsed: elapsed,
                    latencies: latencies.all, zeros: latencies.zeros, failures: latencies.failures,
                    syncBytes: counters.sync, asyncBytes: counters.async,
                    stats: cache.stats, units: units.changes, seconds: seconds))
            }
        }
    }
}

/// What `DaemonStore` builds its cache with. Mirrored, not shared: the
/// store's figures are private to the extension's data path, and a bench
/// that quietly diverged from them would measure something that does not
/// ship — so check these against `LUNStore.swift` when it changes.
private enum BenchGeometry {
    static let chunkBytes = 256 << 10
    static let maxCachedBytes = 32 << 20
    static let maxSlots = 32
    static let minStreamBytes = 256 * 1024
}

// MARK: Result

private struct BenchResult {
    let reads: Int
    let readSize: Int
    let elapsed: TimeInterval
    let latencies: [Double]
    let zeros: Int
    let failures: Int
    let syncBytes: UInt64
    let asyncBytes: UInt64
    let stats: PrefetchChunkCache.Stats
    let units: [(read: Int, unit: Int)]
    /// One sample per second of the run: cumulative reads and bytes fetched.
    let seconds: [Sampler.Sample]

    func report(mode: String, regionStartMB: Int) {
        let asked = UInt64(reads) * UInt64(readSize)
        let fetched = syncBytes + asyncBytes
        let sorted = latencies.sorted()
        func pct(_ p: Double) -> Double { sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * p))] }
        let mean = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        print("")
        print("[\(mode)] region at \(regionStartMB) MiB")
        print(String(format: "  %d reads in %.2fs = %.0f reads/s; latency mean %.3f ms, p50 %.3f, p99 %.3f",
                     reads, elapsed, Double(reads) / elapsed, mean, pct(0.5), pct(0.99)))
        print(String(format: "  asked %.1f MB, fetched %.1f MB (misses %.1f MB, speculation %.1f MB) = %.2fx",
                     Double(asked) / 1e6, Double(fetched) / 1e6, Double(syncBytes) / 1e6,
                     Double(asyncBytes) / 1e6, Double(fetched) / Double(max(asked, 1))))
        print("  hits \(stats.hits), misses \(stats.misses), speculated \(stats.chunksSpeculated), "
              + "final unit \(stats.readAroundUnit >> 10) KiB")
        if units.count > 1 {
            print("  unit: " + units.map { "\($0.unit >> 10) KiB from read \($0.read)" }.joined(separator: ", "))
        }
        if seconds.count > 1 {
            var previous = Sampler.Sample(reads: 0, fetched: 0, unit: 0)
            for (i, now) in seconds.enumerated() {
                let n = now.reads - previous.reads
                let f = now.fetched - previous.fetched
                print(String(format: "    second %2d: %5d reads, %.2fx, unit %d KiB",
                             i + 1, n, Double(f) / Double(max(1, n * readSize)), now.unit >> 10))
                previous = now
            }
        }
        if zeros > 0 {
            print(String(format: "  %d reads (%.2f%%) returned only zeros — likely unwritten, so the target synthesised them",
                         zeros, Double(zeros) * 100 / Double(reads)))
        }
        if failures > 0 { print("  \(failures) reads FAILED") }
    }
}

// MARK: Plumbing

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private struct Unchecked<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Data, Error> = .failure(POSIXError(.EIO))
    func set(_ r: Result<Data, Error>) { lock.lock(); result = r; lock.unlock() }
    func get() throws -> Data { lock.lock(); defer { lock.unlock() }; return try result.get() }
}

private final class FetchCounters: @unchecked Sendable {
    private let lock = NSLock()
    private var syncBytes: UInt64 = 0
    private var asyncBytes: UInt64 = 0
    private var readsDone = 0
    var sync: UInt64 { lock.lock(); defer { lock.unlock() }; return syncBytes }
    var async: UInt64 { lock.lock(); defer { lock.unlock() }; return asyncBytes }
    var snapshot: (reads: Int, fetched: UInt64) {
        lock.lock(); defer { lock.unlock() }
        return (readsDone, syncBytes + asyncBytes)
    }
    func add(sync n: Int) { lock.lock(); syncBytes += UInt64(n); lock.unlock() }
    func add(async n: Int) { lock.lock(); asyncBytes += UInt64(n); lock.unlock() }
    func completedRead() { lock.lock(); readsDone += 1; lock.unlock() }
}

/// Samples the counters once a second on a thread of its own, so the
/// timeline shows when the unit moved and what each second cost after it.
private final class Sampler: @unchecked Sendable {
    struct Sample { let reads: Int; let fetched: UInt64; let unit: Int }
    private let counters: FetchCounters
    private let cache: PrefetchChunkCache
    private let lock = NSLock()
    private var samples: [Sample] = []
    private var running = true

    init(counters: FetchCounters, cache: PrefetchChunkCache) {
        self.counters = counters
        self.cache = cache
    }

    private func take() -> Sample {
        let (reads, fetched) = counters.snapshot
        return Sample(reads: reads, fetched: fetched, unit: cache.stats.readAroundUnit)
    }

    func start() {
        Thread {
            var next = Date().addingTimeInterval(1)
            while true {
                Thread.sleep(until: next)
                next = next.addingTimeInterval(1)
                self.lock.lock()
                let go = self.running
                if go { self.samples.append(self.take()) }
                self.lock.unlock()
                if !go { break }
            }
        }.start()
    }

    /// Stop, and return every whole second plus the partial one at the end.
    func stop() -> [Sample] {
        lock.lock()
        running = false
        samples.append(take())
        let out = samples
        lock.unlock()
        return out
    }
}

private final class LatencyLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var all: [Double] = []
    private(set) var zeros = 0
    private(set) var failures = 0
    func add(_ l: [Double], zeros z: Int, failures f: Int) {
        lock.lock(); all += l; zeros += z; failures += f; lock.unlock()
    }
}

private final class UnitLog: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var changes: [(read: Int, unit: Int)] = []
    func note(read: Int, unit: Int) {
        lock.lock(); defer { lock.unlock() }
        if changes.last?.unit != unit { changes.append((read, unit)) }
    }
}
