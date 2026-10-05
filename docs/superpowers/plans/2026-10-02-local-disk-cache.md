# Local Disk Cache Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An optional per-target, session-scoped, encrypted read cache on the Mac's own disk (Off, or 1–16 GB), as a second tier under the FSKit extension's RAM chunk cache.

**Architecture:** `DiskChunkTier` (iSCSIVolume) holds chunks the RAM tier (`PrefetchChunkCache`) evicts after they were read, in an unlinked sparse file with AES-GCM per slot under an in-memory key, ordered by a segmented LRU. `DaemonStore` consults it inside the RAM tier's fetch closures, feeds it from a new `onEvict` hook, and invalidates it at both edges of every write. The size comes from `TargetRecord.localCacheGB` through a new XPC call, exactly as the readahead budget does.

**Tech Stack:** Swift 6 (language mode 6), CryptoKit (`AES.GCM`), Darwin file I/O (`pread`/`pwrite`/`F_NOCACHE`/`statfs`), NSXPC, SwiftUI, swift-testing, xcodegen.

**Spec:** `docs/superpowers/specs/2026-10-02-local-disk-cache-design.md`

## Global Constraints

- Every target is Swift 6 language mode; tests are swift-testing (`@Test` / `#expect`), not XCTest. CI runs `swift test --no-parallel`.
- `TargetRecord` gains only an **optional** key — "a new non-optional key would make every existing `targets.json` undecodable".
- `Sources/iSCSIKit` stays side-effect-free: the only iSCSIKit change is the `onEvict` hook. All file I/O and crypto live in `Sources/iSCSIVolume`.
- **A cache problem never fails a read.** Every disk-tier failure is a miss or disables the tier; no new throw reaches FSKit.
- **Write-through is unchanged.** FUA and the flush policy are untouched; the tier never holds the only copy of anything.
- The app builds against the **macOS 26 SDK**; the dev host has only Xcode 27, so CI (Xcode 26.6) is the authority. Use no API newer than macOS 26.
- After adding or changing app source files: `cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate`, and commit the regenerated `.pbxproj`. Never hand-edit it. `xcodebuild` rewrites `Package.resolved`'s `originHash`; restore it with `git checkout -- Package.resolved`, never commit it.
- Nothing is installed or registered on the dev host.
- Commit messages end with:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
  ```
- Work on branch `local-disk-cache`.

## Review Focus

1. A daemon that never answers `localCacheBytes` (an older build without the selector) must not stall the mount for the 30 s daemon timeout — test in Task 5.
2. The LUN's last chunk is shorter than 256 KiB when the size is not a multiple; it must spill and read back at its own length, and a full-length lookup there must miss — test in Task 2.
3. Two volumes attached at once in one extension process each get their own tier and file, with no cross-talk — test in Task 2.
4. A hand-edited `localCacheGB` of 0, −1, 17 or 1000 must mean Off — test in Task 4.
5. A slot reused for another chunk while a lookup is reading it must be a plain miss: not data, not counted as corruption, and it must not free the new owner's slot — test in Task 2.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/iSCSIVolume/SegmentedLRU.swift` (create) | Pure O(1) segmented-LRU order: probation/protected |
| `Sources/iSCSIVolume/DiskChunkTier.swift` (create) | `ChunkFile` protocol, `UnlinkedFile`, `DiskChunkTier` (slots, crypto, spill tickets, invalidation, disable, stats, `make`) |
| `Sources/iSCSIKit/Session/PrefetchChunkCache.swift` (modify) | `onEvict` hook in `evictLocked` |
| `Sources/iSCSIKit/XPCModels.swift` (modify) | `TargetRecord.localCacheGB`, `localCacheBytes` |
| `Sources/iSCSIKit/XPCProtocol.swift` (modify) | `localCacheBytes(session:reply:)` |
| `Sources/iSCSIDaemon/XPCService.swift` (modify) | Per-session budgets carry the cache size |
| `Sources/iSCSIVolume/LUNStore.swift` (modify) | `DaemonStore`: build the tier, route fetches, invalidate on writes, summary |
| `apps/iSCSIApp/Windows/TargetsView.swift` (modify) | "Local cache" picker |
| Tests (create) `Tests/IntegrationTests/SegmentedLRUTests.swift`, `Tests/IntegrationTests/ChunkFileDoubles.swift`, `Tests/IntegrationTests/DiskChunkTierTests.swift`, `Tests/iSCSIKitTests/TargetRecordCacheTests.swift`, `Tests/IntegrationTests/LocalCacheBudgetTests.swift`, `Tests/IntegrationTests/DiskTierDataPathTests.swift` | |
| Tests (modify) `Tests/iSCSIKitTests/PrefetchChunkCacheTests.swift`, `Tests/IntegrationTests/DaemonStoreTests.swift` (FakeDaemon) | |

---

### Task 1: Segmented LRU

**Files:**
- Create: `Sources/iSCSIVolume/SegmentedLRU.swift`
- Test: `Tests/IntegrationTests/SegmentedLRUTests.swift`

**Interfaces:**
- Produces: `struct SegmentedLRU<Key: Hashable>` with `enum Segment { case probation, protected }`, `init(protectedCapacity: Int)`, `var count: Int`, `func segment(of: Key) -> Segment?`, `mutating func insert(_:)`, `mutating func hit(_:)`, `mutating func remove(_:)`, `mutating func evict() -> Key?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IntegrationTests/SegmentedLRUTests.swift`:

```swift
import Testing
@testable import iSCSIVolume

/// The disk tier's eviction order. The property that matters is the last
/// test: one big sequential copy must not flush the re-read working set.
@Suite("Segmented LRU")
struct SegmentedLRUTests {

    private func drain(_ lru: inout SegmentedLRU<Int>) -> [Int] {
        var out: [Int] = []
        while let k = lru.evict() { out.append(k) }
        return out
    }

    @Test("new keys are evicted oldest first")
    func probationIsLRU() {
        var lru = SegmentedLRU<Int>(protectedCapacity: 2)
        for k in [1, 2, 3] { lru.insert(k) }
        #expect(drain(&lru) == [1, 2, 3])
    }

    @Test("a hit promotes a key past everything still on probation")
    func hitPromotes() {
        var lru = SegmentedLRU<Int>(protectedCapacity: 2)
        for k in [1, 2, 3] { lru.insert(k) }
        lru.hit(1)
        #expect(lru.segment(of: 1) == .protected)
        #expect(drain(&lru) == [2, 3, 1])
    }

    /// Inserts 1…4 (probation, newest first: 4 3 2 1), then hits 1, 2, 3 with
    /// room for two protected: 1 is demoted to the head of probation.
    @Test("protected overflow demotes its least recent key to the head of probation")
    func protectedOverflowDemotes() {
        var lru = SegmentedLRU<Int>(protectedCapacity: 2)
        for k in [1, 2, 3, 4] { lru.insert(k) }
        lru.hit(1); lru.hit(2); lru.hit(3)
        #expect(lru.segment(of: 1) == .probation)
        #expect(drain(&lru) == [4, 1, 2, 3])
    }

    @Test("remove takes a key out of whichever segment holds it")
    func removeEitherSegment() {
        var lru = SegmentedLRU<Int>(protectedCapacity: 2)
        for k in [1, 2, 3] { lru.insert(k) }
        lru.hit(2)
        lru.remove(2); lru.remove(1)
        #expect(lru.count == 1)
        #expect(lru.segment(of: 2) == nil)
        #expect(drain(&lru) == [3])
    }

    @Test("duplicates, unknown keys and an empty order are harmless")
    func edgeCases() {
        var lru = SegmentedLRU<Int>(protectedCapacity: 1)
        #expect(lru.evict() == nil)
        lru.insert(1); lru.insert(1)
        lru.hit(9); lru.remove(9)
        #expect(lru.count == 1)
        #expect(drain(&lru) == [1])
    }

    @Test("a long scan of new keys never evicts the protected working set")
    func scanResistance() {
        var lru = SegmentedLRU<Int>(protectedCapacity: 4)
        for k in 1 ... 4 { lru.insert(k); lru.hit(k) }
        for k in 100 ..< 200 {
            lru.insert(k)
            while lru.count > 6 { _ = lru.evict() }
        }
        #expect((1 ... 4).allSatisfy { lru.segment(of: $0) == .protected })
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter SegmentedLRU 2>&1 | grep -E "error:" | head -5`
Expected: build failure — `cannot find 'SegmentedLRU' in scope`.

- [ ] **Step 3: Implement**

Create `Sources/iSCSIVolume/SegmentedLRU.swift`:

```swift
//
//  SegmentedLRU.swift
//
//  The disk tier's eviction order. Pure bookkeeping; the tier owns capacity.
//

/// Segmented LRU. New keys enter *probation*; a hit promotes to *protected*,
/// which holds at most `protectedCapacity` keys and demotes its least recent
/// to the head of probation when it overflows. `evict` takes probation's least
/// recent, and protected's only once probation is empty. A sequential copy
/// reads every chunk once, so it only ever churns probation — the re-read
/// working set in protected outlives it. O(1) per operation.
struct SegmentedLRU<Key: Hashable> {
    enum Segment { case probation, protected }

    private struct Node {
        var prev: Key?
        var next: Key?
        var segment: Segment
    }

    /// `head` is the most recent.
    private struct List {
        var head: Key?
        var tail: Key?
        var count = 0
    }

    private var nodes: [Key: Node] = [:]
    private var probation = List()
    private var protectedList = List()
    let protectedCapacity: Int

    init(protectedCapacity: Int) {
        self.protectedCapacity = max(0, protectedCapacity)
    }

    var count: Int { nodes.count }

    func segment(of key: Key) -> Segment? { nodes[key]?.segment }

    mutating func insert(_ key: Key) {
        guard nodes[key] == nil else { return }
        pushFront(key, .probation)
    }

    mutating func hit(_ key: Key) {
        guard nodes[key] != nil else { return }
        unlink(key)
        pushFront(key, .protected)
        while protectedList.count > protectedCapacity, let oldest = protectedList.tail {
            unlink(oldest)
            pushFront(oldest, .probation)
        }
    }

    mutating func remove(_ key: Key) { unlink(key) }

    mutating func evict() -> Key? {
        guard let victim = probation.tail ?? protectedList.tail else { return nil }
        unlink(victim)
        return victim
    }

    private mutating func withList<R>(_ segment: Segment, _ body: (inout List) -> R) -> R {
        switch segment {
        case .probation: body(&probation)
        case .protected: body(&protectedList)
        }
    }

    private mutating func pushFront(_ key: Key, _ segment: Segment) {
        let oldHead = withList(segment) { $0.head }
        nodes[key] = Node(prev: nil, next: oldHead, segment: segment)
        if let oldHead { nodes[oldHead]?.prev = key }
        withList(segment) { list in
            list.head = key
            if list.tail == nil { list.tail = key }
            list.count += 1
        }
    }

    /// Take `key` out of its list and forget it.
    private mutating func unlink(_ key: Key) {
        guard let node = nodes.removeValue(forKey: key) else { return }
        if let prev = node.prev { nodes[prev]?.next = node.next }
        if let next = node.next { nodes[next]?.prev = node.prev }
        withList(node.segment) { list in
            if list.head == key { list.head = node.next }
            if list.tail == key { list.tail = node.prev }
            list.count -= 1
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter SegmentedLRU 2>&1 | grep -E "Test run with|✘"`
Expected: 6 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iSCSIVolume/SegmentedLRU.swift Tests/IntegrationTests/SegmentedLRUTests.swift
git commit -F - <<'EOF'
Add the segmented LRU the disk cache evicts by

Probation for new chunks, protected for re-hits: a big sequential copy
churns only probation, so the re-read working set survives it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 2: The disk tier

**Files:**
- Create: `Sources/iSCSIVolume/DiskChunkTier.swift`
- Create: `Tests/IntegrationTests/ChunkFileDoubles.swift`
- Test: `Tests/IntegrationTests/DiskChunkTierTests.swift`

**Interfaces:**
- Consumes: `SegmentedLRU` (Task 1); `fsLog` (`Sources/iSCSIVolume/LUNStore.swift`).
- Produces:
  - `protocol ChunkFile: AnyObject, Sendable { func read(at: Int64, count: Int) throws -> Data; func write(_: Data, at: Int64) throws; func discard() }`
  - `final class UnlinkedFile: ChunkFile` — `init(directory: URL) throws`
  - `public final class DiskChunkTier: @unchecked Sendable` with `public struct Stats { lookups, hits, savedBytes, spilled, corrupt, disabledReason }`, `enum Unavailable: Error, CustomStringConvertible`, `static let tagRoom = 4096`, `static let reserveBytes: Int64 = 10 << 30`, `static let minimumBytes = 1 << 30`, `let chunkBytes: Int`, `let slotCount: Int`, `var capacityBytes: Int`, `public var stats: Stats`, `init(file:budgetBytes:chunkBytes:spillQueue:)`, `static func make(directory:budgetBytes:chunkBytes:freeSpace:) -> Result<DiskChunkTier, Unavailable>`, `func spill(offset: UInt64, data: Data)`, `func lookup(offset: UInt64, length: Int) -> Data?`, `func invalidate(offset: UInt64, length: Int)`.
  - Test double `MemoryChunkFile` (IntegrationTests, internal).

- [ ] **Step 1: Write the test double**

Create `Tests/IntegrationTests/ChunkFileDoubles.swift`:

```swift
import Foundation
@testable import iSCSIVolume

/// An in-memory cache file that can be told to fail or to tamper, and that
/// records what it was asked to do. Reads are served at the offsets writes
/// were made at, which is all the tier ever does.
final class MemoryChunkFile: ChunkFile, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs: [Int64: Data] = [:]
    private var writeCount = 0
    private var readCount = 0
    private var wasDiscarded = false
    var failWrites = false
    var failReads = false
    /// Flip the first byte of everything read.
    var tamper = false
    /// Runs at the start of every read, outside this file's lock — for
    /// interleaving another operation into the middle of a lookup.
    var onRead: (() -> Void)?

    var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var discarded: Bool { lock.lock(); defer { lock.unlock() }; return wasDiscarded }
    /// One past the last byte ever written.
    var extent: Int64 {
        lock.lock(); defer { lock.unlock() }
        return blobs.map { $0.key + Int64($0.value.count) }.max() ?? 0
    }
    /// Whether any blob holds `needle` verbatim.
    func stores(_ needle: Data) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return blobs.values.contains { $0.range(of: needle) != nil }
    }

    func read(at offset: Int64, count: Int) throws -> Data {
        onRead?()
        lock.lock(); defer { lock.unlock() }
        readCount += 1
        if failReads { throw POSIXError(.EIO) }
        guard let blob = blobs[offset], blob.count >= count else { throw POSIXError(.EIO) }
        var data = Data(blob.prefix(count))
        if tamper, !data.isEmpty { data[data.startIndex] ^= 0xFF }
        return data
    }

    func write(_ data: Data, at offset: Int64) throws {
        lock.lock(); defer { lock.unlock() }
        if failWrites { throw POSIXError(.ENOSPC) }
        writeCount += 1
        blobs[offset] = Data(data)
    }

    func discard() {
        lock.lock(); defer { lock.unlock() }
        wasDiscarded = true
        blobs.removeAll()
    }
}
```

- [ ] **Step 2: Write the failing tests**

Create `Tests/IntegrationTests/DiskChunkTierTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIVolume

/// The disk tier on its own: storage, encryption, sizing, coherence tickets,
/// and the rule that no cache failure is ever more than a miss.
@Suite("Disk chunk tier", .timeLimit(.minutes(1)))
struct DiskChunkTierTests {

    private static let chunk = 4096
    private static let stride = chunk + DiskChunkTier.tagRoom

    private static func pattern(_ seed: UInt8, _ count: Int = chunk) -> Data {
        Data((0 ..< count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ Int(seed)) })
    }

    /// A tier over `slots` slots of an in-memory file, spilling on `queue`
    /// so a test can hold or drain it.
    private func makeTier(slots: Int, file: MemoryChunkFile = MemoryChunkFile(),
                          queue: DispatchQueue = DispatchQueue(label: "test.spill"))
        -> (DiskChunkTier, MemoryChunkFile, DispatchQueue) {
        let tier = DiskChunkTier(file: file, budgetBytes: slots * Self.stride,
                                 chunkBytes: Self.chunk, spillQueue: queue)
        return (tier, file, queue)
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Storage

    @Test("a spilled chunk reads back")
    func spillThenLookup() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: Self.chunk) == Self.pattern(1))
        let stats = tier.stats
        #expect(stats.spilled == 1 && stats.hits == 1 && stats.lookups == 1)
        #expect(stats.savedBytes == UInt64(Self.chunk))
    }

    @Test("a span is served only when every chunk of it is on disk")
    func partialSpanMisses() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: 2 * Self.chunk) == nil)
        tier.spill(offset: UInt64(Self.chunk), data: Self.pattern(2))
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: 2 * Self.chunk) == Self.pattern(1) + Self.pattern(2))
    }

    @Test("the file holds ciphertext, never the chunk itself")
    func storedBytesAreEncrypted() {
        let (tier, file, queue) = makeTier(slots: 4)
        let plain = Self.pattern(7)
        tier.spill(offset: 0, data: plain)
        queue.sync {}
        #expect(file.writes == 2, "ciphertext and tag")
        #expect(!file.stores(plain))
    }

    /// The LUN's last chunk is short when its size is not a multiple of the
    /// chunk size.
    @Test("a short final chunk round-trips at its own length")
    func shortChunk() {
        let (tier, _, queue) = makeTier(slots: 4)
        let tail = Self.pattern(3, 1000)
        tier.spill(offset: UInt64(8 * Self.chunk), data: tail)
        queue.sync {}
        #expect(tier.lookup(offset: UInt64(8 * Self.chunk), length: 1000) == tail)
        #expect(tier.lookup(offset: UInt64(8 * Self.chunk), length: Self.chunk) == nil)
    }

    @Test("the slots never outgrow the budget")
    func budgetIsRespected() {
        let (tier, file, queue) = makeTier(slots: 3)
        for i in 0 ..< 5 { tier.spill(offset: UInt64(i * Self.chunk), data: Self.pattern(UInt8(i))) }
        queue.sync {}
        #expect(tier.slotCount == 3)
        #expect(file.extent <= Int64(3 * Self.stride))
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil, "oldest evicted")
        #expect(tier.lookup(offset: UInt64(4 * Self.chunk), length: Self.chunk) == Self.pattern(4))
    }

    @Test("re-spilling a chunk already on disk writes nothing")
    func unchangedChunkIsNotRewritten() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(file.writes == 2)
        #expect(tier.stats.spilled == 1)
    }

    @Test("a chunk hit on disk survives a scan of new chunks")
    func hitChunkSurvivesScan() {
        let (tier, _, queue) = makeTier(slots: 5)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        _ = tier.lookup(offset: 0, length: Self.chunk)
        for i in 1 ... 20 { tier.spill(offset: UInt64(i * Self.chunk), data: Self.pattern(UInt8(i))) }
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: Self.chunk) == Self.pattern(1))
    }

    // MARK: - Coherence

    @Test("an invalidated chunk misses, and its neighbours stay")
    func invalidateIsPrecise() {
        let (tier, _, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        tier.spill(offset: UInt64(Self.chunk), data: Self.pattern(2))
        queue.sync {}
        tier.invalidate(offset: 10, length: 100)
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(tier.lookup(offset: UInt64(Self.chunk), length: Self.chunk) == Self.pattern(2))
    }

    /// The race the tickets exist for: a spill queued before a write must not
    /// land after the write's invalidation and serve pre-write bytes.
    @Test("a pending spill cancelled by an invalidation never lands")
    func invalidationCancelsPendingSpill() {
        let (tier, file, queue) = makeTier(slots: 4)
        queue.suspend()
        tier.spill(offset: 0, data: Self.pattern(1))
        tier.invalidate(offset: 0, length: Self.chunk)
        queue.resume()
        queue.sync {}
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(file.writes == 0)
        #expect(tier.stats.spilled == 0)
    }

    // MARK: - Never more than a miss

    @Test("a tampered slot is a miss, freed and counted, never data")
    func tamperedSlotIsAMiss() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        file.tamper = true
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(tier.stats.corrupt == 1)
        file.tamper = false
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil, "the slot was freed")
    }

    /// A lookup copies its slot under the lock and reads without it. Here the
    /// only slot is evicted and rewritten for another chunk mid-read:
    /// authentication fails (the AAD names the chunk asked for), and that is a
    /// plain miss — not corruption, and the new owner keeps its slot.
    @Test("a slot reused mid-read is a plain miss, not corruption")
    func slotReusedMidRead() {
        let file = MemoryChunkFile()
        let (tier, _, queue) = makeTier(slots: 1, file: file)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        var once = true
        file.onRead = {
            guard once else { return }
            once = false
            tier.spill(offset: UInt64(Self.chunk), data: Self.pattern(2))
            queue.sync {}
        }
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        file.onRead = nil
        #expect(tier.stats.corrupt == 0)
        #expect(tier.lookup(offset: UInt64(Self.chunk), length: Self.chunk) == Self.pattern(2))
    }

    @Test("a write failure disables the tier and returns its space")
    func writeFailureDisables() {
        let (tier, file, queue) = makeTier(slots: 4)
        file.failWrites = true
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        #expect(tier.stats.disabledReason != nil)
        #expect(file.discarded)
        file.failWrites = false
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        let readsBefore = file.reads
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(file.reads == readsBefore, "a disabled tier never touches its file")
    }

    @Test("a read failure disables the tier")
    func readFailureDisables() {
        let (tier, file, queue) = makeTier(slots: 4)
        tier.spill(offset: 0, data: Self.pattern(1))
        queue.sync {}
        file.failReads = true
        #expect(tier.lookup(offset: 0, length: Self.chunk) == nil)
        #expect(tier.stats.disabledReason != nil)
    }

    // MARK: - The real file, and sizing

    @Test("the cache file is gone from the directory the moment it exists")
    func fileIsUnlinked() throws {
        let dir = try temporaryDirectory()
        let file = try UnlinkedFile(directory: dir)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        try file.write(Data([1, 2, 3]), at: 8192)
        #expect(try file.read(at: 8192, count: 3) == Data([1, 2, 3]))
    }

    @Test("two tiers in one process keep their own files and bytes")
    func twoTiersDoNotMix() throws {
        let dir = try temporaryDirectory()
        let qa = DispatchQueue(label: "a"), qb = DispatchQueue(label: "b")
        let a = DiskChunkTier(file: try UnlinkedFile(directory: dir), budgetBytes: 4 * Self.stride,
                              chunkBytes: Self.chunk, spillQueue: qa)
        let b = DiskChunkTier(file: try UnlinkedFile(directory: dir), budgetBytes: 4 * Self.stride,
                              chunkBytes: Self.chunk, spillQueue: qb)
        a.spill(offset: 0, data: Self.pattern(1))
        b.spill(offset: 0, data: Self.pattern(2))
        qa.sync {}; qb.sync {}
        #expect(a.lookup(offset: 0, length: Self.chunk) == Self.pattern(1))
        #expect(b.lookup(offset: 0, length: Self.chunk) == Self.pattern(2))
    }

    @Test("the tier is sized to free space minus the reserve")
    func sizedToFreeSpace() throws {
        let dir = try temporaryDirectory()
        let result = DiskChunkTier.make(directory: dir, budgetBytes: 16 << 30, chunkBytes: 256 << 10,
                                        freeSpace: { _ in 12 << 30 })
        let tier = try result.get()
        // 2 GiB of slots, each a 256 KiB chunk plus a 4 KiB tag page.
        #expect(tier.capacityBytes <= 2 << 30)
        #expect(tier.capacityBytes > (2 << 30) * 9 / 10)
    }

    @Test("too little free space leaves the tier off")
    func tooLittleSpace() throws {
        let dir = try temporaryDirectory()
        let result = DiskChunkTier.make(directory: dir, budgetBytes: 4 << 30, chunkBytes: 256 << 10,
                                        freeSpace: { _ in (10 << 30) + (512 << 20) })
        guard case .failure(.tooLittleSpace) = result else {
            Issue.record("expected tooLittleSpace, got \(result)")
            return
        }
    }
}
```


- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter DiskChunkTier 2>&1 | grep -E "error:" | head -5`
Expected: build failure — `cannot find type 'ChunkFile' in scope` / `cannot find 'DiskChunkTier' in scope`.

- [ ] **Step 4: Implement**

Create `Sources/iSCSIVolume/DiskChunkTier.swift`:

```swift
//
//  DiskChunkTier.swift
//
//  The local disk cache: a second tier under `PrefetchChunkCache`, holding
//  chunks the RAM tier evicted after they were read. Session-scoped,
//  encrypted, and never a reason for a read to fail. Design and rationale:
//  docs/superpowers/specs/2026-10-02-local-disk-cache-design.md.
//

import CryptoKit
import Foundation

/// Positional I/O on the cache file. Injectable so tests can fail or tamper
/// with it; the real one is `UnlinkedFile`.
protocol ChunkFile: AnyObject, Sendable {
    /// Exactly `count` bytes at `offset`, or a throw.
    func read(at offset: Int64, count: Int) throws -> Data
    func write(_ data: Data, at offset: Int64) throws
    /// Give the space back. Called once, when the tier disables itself;
    /// reads after it fail, which the tier already treats as a miss.
    func discard()
}

/// A file that exists only as an open descriptor: created under a random
/// name and unlinked at once, so a detach, an exit or a crash all return its
/// space, and nothing is ever left behind to sweep.
final class UnlinkedFile: ChunkFile, @unchecked Sendable {
    private let fd: Int32

    init(directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.appendingPathComponent("chunks-\(UUID().uuidString)").path
        let opened = open(path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard opened >= 0 else { throw Self.posixError() }
        unlink(path)
        // The tier sits under the buffer cache; caching its file there too
        // would spend RAM twice on one chunk.
        _ = fcntl(opened, F_NOCACHE, 1)
        fd = opened
    }

    deinit { close(fd) }

    func read(at offset: Int64, count: Int) throws -> Data {
        var data = Data(count: count)
        let n = data.withUnsafeMutableBytes { pread(fd, $0.baseAddress, count, off_t(offset)) }
        guard n == count else { throw n < 0 ? Self.posixError() : POSIXError(.EIO) }
        return data
    }

    func write(_ data: Data, at offset: Int64) throws {
        let n = data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, off_t(offset)) }
        guard n == data.count else { throw n < 0 ? Self.posixError() : POSIXError(.EIO) }
    }

    func discard() { _ = ftruncate(fd, 0) }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
    }
}

/// Chunks on local disk, keyed by their LUN offset. Bytes arrive only by
/// `spill` — from the RAM tier, so they have already passed its write
/// generation guard — and leave by eviction, by `invalidate` (every write, at
/// both edges), or by failing authentication.
///
/// Each slot is `chunkBytes` of AES-GCM ciphertext and its 16-byte tag in a
/// page of its own. The key lives only in this object; the nonce is the slot
/// number and a per-tier seal counter, so it never repeats under the key; the
/// chunk's offset and length are the additional authenticated data, so a slot
/// read for the wrong chunk fails authentication instead of returning bytes.
public final class DiskChunkTier: @unchecked Sendable {

    public struct Stats: Sendable, Equatable {
        /// Fetches that consulted the tier, and those it served.
        public var lookups = 0
        public var hits = 0
        /// Bytes served from disk instead of fetched.
        public var savedBytes: UInt64 = 0
        /// Chunks written to the tier.
        public var spilled = 0
        /// Chunks that failed authentication.
        public var corrupt = 0
        /// Why the tier turned itself off, if it did.
        public var disabledReason: String?
    }

    /// Why no tier was made at attach. The volume mounts without one.
    enum Unavailable: Error, Equatable, CustomStringConvertible {
        case tooLittleSpace(availableBytes: Int64)
        case cannotCreate(String)

        var description: String {
            switch self {
            case .tooLittleSpace(let available): "space (\(available >> 30) GiB free)"
            case .cannotCreate(let why): "create (\(why))"
            }
        }
    }

    /// Bytes per slot beyond the chunk: the 16-byte GCM tag, in a page of its
    /// own so chunk data stays page-aligned.
    static let tagRoom = 4096
    /// Free space never handed to the tier.
    static let reserveBytes: Int64 = 10 << 30
    /// Below this, a tier is not worth its bookkeeping.
    static let minimumBytes = 1 << 30

    let chunkBytes: Int
    let slotCount: Int
    private let stride: Int
    private let file: ChunkFile
    private let key = SymmetricKey(size: .bits256)
    private let spillQueue: DispatchQueue

    private struct Slot {
        let index: Int
        let nonce: AES.GCM.Nonce
        let length: Int
        /// Unique per seal: tells a reader whether its slot was reused.
        let version: UInt64
    }

    private let lock = NSLock()
    private var slots: [UInt64: Slot] = [:]
    private var order: SegmentedLRU<UInt64>
    private var freeSlots: [Int]
    /// Chunk offset → ticket of the spill queued for it. `invalidate` removes
    /// the ticket; a queued spill lands only if its ticket is still current.
    private var tickets: [UInt64: UInt64] = [:]
    private var nextTicket: UInt64 = 0
    private var sealCount: UInt64 = 0
    private var statsStore = Stats()

    /// Chunk data the tier can hold.
    var capacityBytes: Int { slotCount * chunkBytes }

    public var stats: Stats {
        lock.lock(); defer { lock.unlock() }
        return statsStore
    }

    init(file: ChunkFile, budgetBytes: Int, chunkBytes: Int,
         spillQueue: DispatchQueue = DispatchQueue(label: "me.herko.iSCSIInitiator.fsext.spill",
                                                    qos: .utility)) {
        precondition(chunkBytes > 0)
        self.file = file
        self.chunkBytes = chunkBytes
        stride = chunkBytes + Self.tagRoom
        slotCount = max(1, budgetBytes / stride)
        freeSlots = Array((0 ..< slotCount).reversed())
        order = SegmentedLRU(protectedCapacity: slotCount * 4 / 5)
        self.spillQueue = spillQueue
    }

    /// The tier for an attach: an unlinked file under `directory`, sized to
    /// `min(budget, free space − reserve)`. A failure is a reason to log, never
    /// a reason to fail the mount.
    static func make(directory: URL, budgetBytes: Int, chunkBytes: Int,
                     freeSpace: (URL) -> Int64? = DiskChunkTier.freeSpace)
        -> Result<DiskChunkTier, Unavailable> {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            return .failure(.cannotCreate("\(error)"))
        }
        let available = freeSpace(directory) ?? 0
        let usable = min(Int64(budgetBytes), available - reserveBytes)
        guard usable >= Int64(minimumBytes) else {
            return .failure(.tooLittleSpace(availableBytes: available))
        }
        do {
            let file = try UnlinkedFile(directory: directory)
            return .success(DiskChunkTier(file: file, budgetBytes: Int(usable), chunkBytes: chunkBytes))
        } catch {
            return .failure(.cannotCreate("\(error)"))
        }
    }

    /// Bytes available to an unprivileged writer on the volume holding `url`.
    static func freeSpace(_ url: URL) -> Int64? {
        var st = statfs()
        guard statfs(url.path, &st) == 0 else { return nil }
        return Int64(st.f_bavail) * Int64(st.f_bsize)
    }

    // MARK: - Spill

    /// A chunk the RAM tier evicted after it was read. Records a ticket and
    /// writes it on the spill queue. Nothing to do if it is already on disk —
    /// unchanged since, because any write would have invalidated it — or
    /// already queued.
    func spill(offset: UInt64, data: Data) {
        lock.lock()
        guard statsStore.disabledReason == nil, !data.isEmpty, data.count <= chunkBytes,
              slots[offset] == nil, tickets[offset] == nil else {
            lock.unlock()
            return
        }
        nextTicket &+= 1
        let ticket = nextTicket
        tickets[offset] = ticket
        lock.unlock()
        spillQueue.async { self.store(offset: offset, data: data, ticket: ticket) }
    }

    private func store(offset: UInt64, data: Data, ticket: UInt64) {
        lock.lock()
        guard tickets[offset] == ticket, statsStore.disabledReason == nil else {
            lock.unlock()
            return
        }
        if freeSlots.isEmpty, let victim = order.evict(),
           let freed = slots.removeValue(forKey: victim) {
            freeSlots.append(freed.index)
        }
        guard let index = freeSlots.popLast() else {
            tickets[offset] = nil
            lock.unlock()
            return
        }
        sealCount &+= 1
        let seal = sealCount
        lock.unlock()

        let nonce = Self.nonce(slot: index, seal: seal)
        do {
            let sealed = try AES.GCM.seal(data, using: key, nonce: nonce,
                                          authenticating: Self.aad(offset: offset, length: data.count))
            let base = Int64(index) * Int64(stride)
            try file.write(sealed.ciphertext, at: base)
            try file.write(sealed.tag, at: base + Int64(chunkBytes))
        } catch {
            disable("write failed: \(error)")
            return
        }

        lock.lock()
        if tickets[offset] == ticket, statsStore.disabledReason == nil {
            tickets[offset] = nil
            slots[offset] = Slot(index: index, nonce: nonce, length: data.count, version: seal)
            order.insert(offset)
            statsStore.spilled += 1
        } else if statsStore.disabledReason == nil {
            // Invalidated while it was being written: the bytes are stale.
            freeSlots.append(index)
        }
        lock.unlock()
    }

    // MARK: - Lookup

    /// The bytes of `[offset, offset + length)` if every chunk of it is on
    /// disk and authentic, nil otherwise — never an error. `offset` is
    /// chunk-aligned, as every fetch the RAM tier makes is.
    func lookup(offset: UInt64, length: Int) -> Data? {
        guard length > 0 else { return nil }
        let chunk = UInt64(chunkBytes)
        let end = offset &+ UInt64(length)
        var wanted: [(offset: UInt64, slot: Slot)] = []

        lock.lock()
        guard statsStore.disabledReason == nil else {
            lock.unlock()
            return nil
        }
        statsStore.lookups += 1
        var co = offset
        while co < end {
            let clen = Int(min(chunk, end - co))
            guard let slot = slots[co], slot.length == clen else {
                lock.unlock()
                return nil
            }
            wanted.append((co, slot))
            co += chunk
        }
        lock.unlock()

        var out = Data(capacity: length)
        for (co, slot) in wanted {
            let base = Int64(slot.index) * Int64(stride)
            let ciphertext: Data
            let tag: Data
            do {
                ciphertext = try file.read(at: base, count: slot.length)
                tag = try file.read(at: base + Int64(chunkBytes), count: 16)
            } catch {
                disable("read failed: \(error)")
                return nil
            }
            guard let box = try? AES.GCM.SealedBox(nonce: slot.nonce, ciphertext: ciphertext, tag: tag),
                  let plain = try? AES.GCM.open(box, using: key,
                                                authenticating: Self.aad(offset: co, length: slot.length))
            else {
                notAuthentic(co, slot)
                return nil
            }
            out.append(plain)
        }

        lock.lock()
        statsStore.hits += 1
        statsStore.savedBytes += UInt64(length)
        for (co, slot) in wanted where slots[co]?.version == slot.version { order.hit(co) }
        lock.unlock()
        return out
    }

    /// Authentication failed. If the slot still belongs to this chunk at this
    /// version, the bytes really are bad: free and count it. If it changed —
    /// evicted and reused mid-read — it is a plain miss, and the new owner's
    /// slot must not be touched.
    private func notAuthentic(_ co: UInt64, _ slot: Slot) {
        lock.lock()
        if let current = slots[co], current.version == slot.version {
            slots[co] = nil
            order.remove(co)
            freeSlots.append(slot.index)
            statsStore.corrupt += 1
        }
        lock.unlock()
    }

    // MARK: - Invalidation

    /// Forget every chunk overlapping `[offset, offset + length)` and cancel
    /// any spill queued for one. Synchronous: no read after this returns can
    /// find the old bytes.
    func invalidate(offset: UInt64, length: Int) {
        guard length > 0 else { return }
        let chunk = UInt64(chunkBytes)
        let end = offset &+ UInt64(length)
        lock.lock()
        var co = (offset / chunk) * chunk
        while co < end {
            tickets[co] = nil
            if let slot = slots.removeValue(forKey: co) {
                order.remove(co)
                freeSlots.append(slot.index)
            }
            co += chunk
        }
        lock.unlock()
    }

    // MARK: - Failure

    /// Turn the tier off for the rest of the session: forget everything, give
    /// the file's space back, log once. Every later lookup misses without
    /// touching the file.
    private func disable(_ reason: String) {
        lock.lock()
        let first = statsStore.disabledReason == nil
        if first {
            statsStore.disabledReason = reason
            slots.removeAll()
            tickets.removeAll()
            freeSlots.removeAll()
            order = SegmentedLRU(protectedCapacity: 0)
        }
        lock.unlock()
        guard first else { return }
        file.discard()
        fsLog.error("local cache disabled: \(reason, privacy: .public); reads go to the network")
    }

    // MARK: - Crypto framing

    private static func nonce(slot: Int, seal: UInt64) -> AES.GCM.Nonce {
        let bytes = withUnsafeBytes(of: UInt32(truncatingIfNeeded: slot).bigEndian, Array.init)
            + withUnsafeBytes(of: seal.bigEndian, Array.init)
        // 12 bytes is always a valid GCM nonce.
        return try! AES.GCM.Nonce(data: bytes)
    }

    private static func aad(offset: UInt64, length: Int) -> Data {
        Data(withUnsafeBytes(of: offset.bigEndian, Array.init)
             + withUnsafeBytes(of: UInt64(length).bigEndian, Array.init))
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --filter "DiskChunkTier|SegmentedLRU" 2>&1 | grep -E "Test run with|✘"`
Expected: all pass (17 tier tests, 6 LRU tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/iSCSIVolume/DiskChunkTier.swift Tests/IntegrationTests/ChunkFileDoubles.swift \
        Tests/IntegrationTests/DiskChunkTierTests.swift
git commit -F - <<'EOF'
Add the disk chunk tier: encrypted, session-scoped, never fatal

An unlinked sparse file of fixed slots, each chunk sealed with AES-GCM
under an in-memory key and bound to its LUN offset. Spills carry tickets
an invalidation cancels; a failed authentication is a miss; any I/O
error turns the tier off and gives its space back.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 3: The RAM tier hands read chunks to an eviction hook

**Files:**
- Modify: `Sources/iSCSIKit/Session/PrefetchChunkCache.swift` (stored property, `init`, `evictLocked`)
- Test: `Tests/iSCSIKitTests/PrefetchChunkCacheTests.swift` (modify)

**Interfaces:**
- Produces: `PrefetchChunkCache.init(…, fetchAsync:, onEvict: ((UInt64, Data) -> Void)? = nil)` — called under the cache's lock for each chunk evicted for capacity that was read (demand-fetched, or speculative with `used`).

- [ ] **Step 1: Write the failing tests**

In `Tests/iSCSIKitTests/PrefetchChunkCacheTests.swift`, add above `@Suite("Prefetch chunk cache")`:

```swift
/// Every chunk the cache hands to `onEvict`, in order.
private final class EvictLog: @unchecked Sendable {
    private let lock = NSLock()
    private var seen: [(offset: UInt64, data: Data)] = []
    func add(_ offset: UInt64, _ data: Data) { lock.lock(); seen.append((offset, data)); lock.unlock() }
    var offsets: [UInt64] { lock.lock(); defer { lock.unlock() }; return seen.map(\.offset) }
    var all: [(offset: UInt64, data: Data)] { lock.lock(); defer { lock.unlock() }; return seen }
}
```

and add inside `struct PrefetchChunkCacheTests`:

```swift
    // MARK: - Eviction hook (the disk tier's only source)

    private static func makeEvictingCache(backing: FakeBacking, log: EvictLog,
                                          maxCachedBytes: Int,
                                          minStreamBytes: Int = .max) -> PrefetchChunkCache {
        PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: backing.capacity,
            maxCachedBytes: maxCachedBytes,
            policy: ReadaheadPolicy(budgetBytes: 8 * chunk, maxSlots: 32,
                                    minStreamBytes: minStreamBytes, chunkBytes: chunk),
            timeout: 5,
            fetchSync: backing.fetchSync,
            fetchAsync: backing.fetchAsync,
            onEvict: { log.add($0, $1) })
    }

    @Test("a chunk that was read is handed to onEvict with its bytes when evicted")
    func readChunkIsHandedToOnEvict() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log, maxCachedBytes: 2 * Self.chunk)
        for i in [0, 4, 8] { _ = try cache.read(offset: UInt64(i * Self.chunk), length: 100) }
        #expect(log.offsets == [0])
        #expect(log.all.first?.data == FakeBacking.pattern(offset: 0, length: Self.chunk))
    }

    /// Reads chunks 0 and 1 back to back (16 KiB stream gate at 8 KiB), which
    /// speculates 2 and 3; then four far reads evict everything older. Only
    /// the two chunks a caller read reach the hook — speculation nobody read
    /// was never wanted the first time and must not cost a disk write.
    @Test("unread speculation is never handed to onEvict")
    func unreadSpeculationIsNotHandedOn() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log,
                                           maxCachedBytes: 4 * Self.chunk, minStreamBytes: 8192)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        #expect(backing.asyncCount == 2, "chunks 2 and 3 speculated")
        for i in [7, 8, 9, 10] { _ = try cache.read(offset: UInt64(i * Self.chunk), length: 100) }
        #expect(log.offsets == [0, UInt64(Self.chunk)])
    }

    @Test("a speculative chunk that was read is handed to onEvict")
    func usedSpeculationIsHandedOn() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log,
                                           maxCachedBytes: 4 * Self.chunk, minStreamBytes: 8192)
        _ = try cache.read(offset: 0, length: Self.chunk)
        _ = try cache.read(offset: UInt64(Self.chunk), length: Self.chunk)
        _ = try cache.read(offset: UInt64(2 * Self.chunk), length: 100)   // speculated, now read
        for i in [7, 8, 9, 10] { _ = try cache.read(offset: UInt64(i * Self.chunk), length: 100) }
        #expect(log.offsets.contains(UInt64(2 * Self.chunk)))
    }

    @Test("chunks dropped by a failed write are not handed to onEvict")
    func writeRemovalsAreNotSpills() throws {
        let backing = Self.makeBacking()
        let log = EvictLog()
        let cache = Self.makeEvictingCache(backing: backing, log: log, maxCachedBytes: 4 * Self.chunk)
        _ = try cache.read(offset: 0, length: 100)
        cache.writeFailed(offset: 0, length: Self.chunk)
        #expect(log.offsets.isEmpty)
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "Prefetch chunk cache" 2>&1 | grep -E "error:" | head -3`
Expected: build failure — `extra argument 'onEvict' in call`.

- [ ] **Step 3: Implement**

In `Sources/iSCSIKit/Session/PrefetchChunkCache.swift`:

1. After `private let fetchAsync: (UInt64, Int, @escaping (Data?) -> Void) -> Void` add:
   ```swift
    /// Receives each chunk evicted for capacity that a caller actually read —
    /// the disk tier's only source. Called under the cache's lock: it must be
    /// quick and must never call back into the cache.
    private let onEvict: ((UInt64, Data) -> Void)?
   ```
2. In `init`, add the parameter after `fetchAsync`:
   ```swift
                fetchAsync: @escaping (UInt64, Int, @escaping (Data?) -> Void) -> Void,
                onEvict: ((UInt64, Data) -> Void)? = nil) {
   ```
   and `self.onEvict = onEvict` after `self.fetchAsync = fetchAsync`.
3. In `evictLocked`, replace
   ```swift
            guard let victim = coldest, let removed = removeLocked(victim.key) else { break }
            total -= removed.length
   ```
   with
   ```swift
            guard let victim = coldest, let removed = removeLocked(victim.key) else { break }
            total -= removed.length
            // Only what a caller read moves down a tier: unread speculation
            // was never wanted the first time.
            if let onEvict, !removed.speculative || removed.used,
               case .ready(let data) = removed.snapshot {
                onEvict(victim.key, data)
            }
   ```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "Prefetch chunk cache" 2>&1 | grep -E "Test run with|✘"`
Expected: all pass, including the four new tests and every existing cache test.

- [ ] **Step 5: Commit**

```bash
git add Sources/iSCSIKit/Session/PrefetchChunkCache.swift Tests/iSCSIKitTests/PrefetchChunkCacheTests.swift
git commit -F - <<'EOF'
Hand chunks the RAM cache evicts after a read to an eviction hook

The disk tier's only source. Unread speculation and chunks dropped by a
write never reach it.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 4: The setting, and how the extension learns it

**Files:**
- Modify: `Sources/iSCSIKit/XPCModels.swift` (`TargetRecord`)
- Modify: `Sources/iSCSIKit/XPCProtocol.swift`
- Modify: `Sources/iSCSIDaemon/XPCService.swift` (`budgets`, `claim`, `login`, `readaheadBudget`, new method)
- Modify: `Tests/IntegrationTests/DaemonStoreTests.swift` (`FakeDaemon`)
- Test: `Tests/iSCSIKitTests/TargetRecordCacheTests.swift` (create), `Tests/IntegrationTests/LocalCacheBudgetTests.swift` (create)

**Interfaces:**
- Produces:
  - `TargetRecord.localCacheGB: Int?`; init gains trailing `localCacheGB: Int? = nil` (after `interfaceFallback:`); `TargetRecord.localCacheBytes: Int` (0 = off).
  - `ISCSIDaemonProtocol.localCacheBytes(session: String, reply: @escaping (NSNumber, Error?) -> Void)`
  - `FakeDaemon.localCache: Int` (test double; what `localCacheBytes` answers), `FakeDaemon.answersLocalCache: Bool` (false = never replies).

- [ ] **Step 1: Write the failing tests**

Create `Tests/iSCSIKitTests/TargetRecordCacheTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIKit

@Suite("Target record local cache key")
struct TargetRecordCacheTests {

    @Test("a pre-0.7.0 record decodes with the cache off")
    func olderRecordIsOff() throws {
        let golden = """
            {"autoAttach":false,"displayName":"NAS","host":"192.168.20.1","id":"t1",
             "lun":0,"port":3260,"targetIQN":"iqn.2026-08.me.herko:disk0"}
            """
        let record = try JSONDecoder().decode(TargetRecord.self, from: Data(golden.utf8))
        #expect(record.localCacheGB == nil)
        #expect(record.localCacheBytes == 0)
    }

    @Test("1 through 16 GB are sizes, in GiB")
    func validSizes() {
        var record = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                                  targetIQN: "iqn.x", localCacheGB: 1)
        #expect(record.localCacheBytes == 1 << 30)
        record.localCacheGB = 16
        #expect(record.localCacheBytes == 16 << 30)
    }

    @Test("anything outside 1…16 is off")
    func invalidSizesAreOff() {
        for gb in [0, -1, 17, 1000] {
            let record = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                                      targetIQN: "iqn.x", localCacheGB: gb)
            #expect(record.localCacheBytes == 0, "\(gb) GB must mean off")
        }
    }

    @Test("the key round-trips")
    func roundTrips() throws {
        let record = TargetRecord(id: "t1", displayName: "NAS", host: "nas",
                                  targetIQN: "iqn.x", localCacheGB: 4)
        let decoded = try JSONDecoder().decode(TargetRecord.self, from: JSONEncoder().encode(record))
        #expect(decoded == record)
    }
}
```

Create `Tests/IntegrationTests/LocalCacheBudgetTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget

/// The cache size reaches the extension the way the readahead budget does:
/// resolved from the record at login, keyed by the session handle, and only
/// for the connection that owns it.
@Suite("Per-target local cache size over XPC")
struct LocalCacheBudgetTests {

    private static let targetIQN = "iqn.2026-08.test.example:disk0"

    private func makeService(cacheGB: Int?) async throws -> (DaemonCore, HarnessBox, TargetStore) {
        let disk = RAMDisk()
        let harnesses = HarnessBox()
        let core = DaemonCore(initiatorName: "iqn.test:initiator") { _, _, _ in
            let (initiatorSide, targetSide) = MemoryPipe.pair()
            let target = MockTarget(config: MockTargetConfig(), disk: disk, transport: targetSide)
            harnesses.add(Task { await target.run() })
            return initiatorSide
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
            .appendingPathComponent("targets.json")
        let store = TargetStore(url: url)
        try await store.save(TargetRecord(id: UUID().uuidString, displayName: "Mock",
                                          host: "mock", port: 3260,
                                          targetIQN: Self.targetIQN, lun: 0,
                                          localCacheGB: cacheGB))
        return (core, harnesses, store)
    }

    private func login(_ service: ISCSIXPCService) async throws -> String {
        try await withCheckedThrowingContinuation { c in
            service.login(host: "mock", port: 3260, targetIQN: Self.targetIQN, lun: 0) { h, e in
                if let e { c.resume(throwing: e) } else { c.resume(returning: h!) }
            }
        }
    }

    private func cacheBytes(_ service: ISCSIXPCService, session: String) async -> (NSNumber, Error?) {
        await withCheckedContinuation { c in
            service.localCacheBytes(session: session) { c.resume(returning: ($0, $1)) }
        }
    }

    @Test("a target set to 4 GB reports 4 GiB")
    func configuredSizeIsReported() async throws {
        let (core, _harness, store) = try await makeService(cacheGB: 4)
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)
        let (bytes, error) = await cacheBytes(service, session: handle)
        #expect(error == nil)
        #expect(bytes.intValue == 4 << 30)
    }

    @Test("a target with no cache setting reports 0")
    func unsetIsZero() async throws {
        let (core, _harness, store) = try await makeService(cacheGB: nil)
        let service = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(service)
        let (bytes, error) = await cacheBytes(service, session: handle)
        #expect(error == nil)
        #expect(bytes.intValue == 0)
    }

    @Test("a stranger cannot read the cache size of a session it did not open")
    func scoped() async throws {
        let (core, _harness, store) = try await makeService(cacheGB: 4)
        let owner = ISCSIXPCService(core: core, targets: store)
        let stranger = ISCSIXPCService(core: core, targets: store)
        let handle = try await login(owner)
        let (_, error) = await cacheBytes(stranger, session: handle)
        #expect(error != nil)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "TargetRecordCache|LocalCacheBudget" 2>&1 | grep -E "error:" | head -5`
Expected: build failure — `extra argument 'localCacheGB' in call`, `value of type 'ISCSIXPCService' has no member 'localCacheBytes'`.

- [ ] **Step 3: The record**

In `Sources/iSCSIKit/XPCModels.swift`, in `TargetRecord`, after `public var interfaceFallback: Bool?` add:

```swift
    /// Local disk cache size in GB (GiB), 1…16, used only while attached.
    /// nil — and any other value — is off. See `DiskChunkTier`.
    public var localCacheGB: Int?
```

Change the end of the init signature from `networkInterface: String? = nil, interfaceFallback: Bool? = nil) {` to:

```swift
                networkInterface: String? = nil, interfaceFallback: Bool? = nil,
                localCacheGB: Int? = nil) {
```

and add `self.localCacheGB = localCacheGB` after `self.interfaceFallback = interfaceFallback`. After the `interfaceBinding` computed property add:

```swift
    /// The cache size in bytes; 0 when off. A hand-edited value outside
    /// 1…16 is off rather than clamped: a typo must not silently claim disk.
    public var localCacheBytes: Int {
        guard let gb = localCacheGB, (1 ... 16).contains(gb) else { return 0 }
        return gb << 30
    }
```

- [ ] **Step 4: The XPC call**

In `Sources/iSCSIKit/XPCProtocol.swift`, after the `readaheadBudget` declaration add:

```swift
    /// Local disk cache size for this session's target, in bytes (0 = off),
    /// resolved at login. Keyed on the session handle for the same reason as
    /// `readaheadBudget`: the extension forwards nothing about the target.
    func localCacheBytes(session: String, reply: @escaping (NSNumber, Error?) -> Void)
```

In `Sources/iSCSIDaemon/XPCService.swift`:

1. Replace
   ```swift
    private let budgets = OSAllocatedUnfairLock(initialState: [String: Int]())

    private func claim(_ handle: String, readaheadBudget: Int) {
        owned.withLock { $0.insert(handle) }
        budgets.withLock { $0[handle] = readaheadBudget }
    }
   ```
   with
   ```swift
    private let budgets = OSAllocatedUnfairLock(initialState: [String: SessionBudgets]())

    /// What the extension asks for after login, resolved once from the record.
    private struct SessionBudgets {
        var readahead: Int
        var localCache: Int
    }

    private func claim(_ handle: String, budgets value: SessionBudgets) {
        owned.withLock { $0.insert(handle) }
        budgets.withLock { $0[handle] = value }
    }
   ```
   and update the doc comment above `budgets` to begin "Readahead budget and local cache size per owned handle, …".
2. In `login`, replace
   ```swift
                self.claim(handle, readaheadBudget: WorkloadProfile
                    .pinnedBudgetBytes(stored: record.workloadProfile) ?? 0)
   ```
   with
   ```swift
                self.claim(handle, budgets: SessionBudgets(
                    readahead: WorkloadProfile.pinnedBudgetBytes(stored: record.workloadProfile) ?? 0,
                    localCache: record.localCacheBytes))
   ```
3. In `readaheadBudget`, change `let bytes = budgets.withLock { $0[session] } ?? 0` to `let bytes = budgets.withLock { $0[session]?.readahead } ?? 0`.
4. After `readaheadBudget` add:
   ```swift
    public func localCacheBytes(session: String, reply: @escaping (NSNumber, Error?) -> Void) {
        if let denied = checkOwned(session) { reply(0, denied); return }
        // 0 is off — also the answer for a missing entry: a mount must never
        // fail for a cache.
        let bytes = budgets.withLock { $0[session]?.localCache } ?? 0
        reply(NSNumber(value: bytes), nil)
    }
   ```

- [ ] **Step 5: The fake daemon**

In `Tests/IntegrationTests/DaemonStoreTests.swift`, in `FakeDaemon`, after `var failNextWrite = false` add:

```swift
    /// What `localCacheBytes` answers.
    var localCache = 0
    /// false: `localCacheBytes` never replies, like an older daemon that
    /// lacks the selector.
    var answersLocalCache = true
```

and after its `readaheadBudget` method add:

```swift
    func localCacheBytes(session: String, reply: @escaping (NSNumber, Error?) -> Void) {
        guard answersLocalCache else { return }
        reply(NSNumber(value: localCache), nil)
    }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "TargetRecordCache|LocalCacheBudget|WorkloadBudget|TargetStore|DaemonStore" 2>&1 | grep -E "Test run with|✘"`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/iSCSIKit/XPCModels.swift Sources/iSCSIKit/XPCProtocol.swift \
        Sources/iSCSIDaemon/XPCService.swift Tests
git commit -F - <<'EOF'
Store a target's local cache size and serve it to the extension

An optional TargetRecord key (anything outside 1-16 GB is off), resolved
at login and served per session over XPC exactly as the readahead budget
is, to the owning connection only.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 5: Wire the tier into the volume's data path

**Files:**
- Modify: `Sources/iSCSIVolume/LUNStore.swift` (`DaemonStore`)
- Test: `Tests/IntegrationTests/DiskTierDataPathTests.swift` (create)

**Interfaces:**
- Consumes: `DiskChunkTier` (Task 2), `onEvict` (Task 3), `localCacheBytes(session:reply:)` and `FakeDaemon.localCache`/`answersLocalCache` (Task 4), `MemoryChunkFile` (Task 2).
- Produces:
  - `DaemonStore.init(daemon:session:blockSize:byteCount:readaheadBudgetBytes:ramCacheBytes: Int? = nil, diskTier: DiskChunkTier? = nil)` (test initializer)
  - `static func DaemonStore.localCacheSetting(from: ISCSIDaemonProtocol, session: String, timeout: TimeInterval = 5) -> Int`
  - Summary fields `disk=`, `diskSaved=`, `spilled=`, `diskCorrupt=`, `diskOff=`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/IntegrationTests/DiskTierDataPathTests.swift`:

```swift
import Foundation
import Testing
@testable import iSCSIKit
@testable import iSCSIVolume

/// The disk tier inside the real volume data path, against the in-memory
/// daemon: what reaches the "network", and whether every byte read back is
/// the byte last written.
@Suite("Disk tier in the volume data path", .timeLimit(.minutes(1)))
struct DiskTierDataPathTests {

    private static let blockSize: UInt64 = 4096
    private static let chunk = 256 << 10
    private static let capacity = 32 * chunk          // 8 MiB

    private struct Rig {
        let store: DaemonStore
        let daemon: FakeDaemon
        let tier: DiskChunkTier
        let file: MemoryChunkFile
        let spills: DispatchQueue
        func drain() { spills.sync {} }
        var daemonReads: Int { daemon.log.filter { $0.kind == "read" }.count }
        func daemonRead(at offset: Int) -> Bool {
            daemon.log.contains { $0.kind == "read" && $0.offset == UInt64(offset) }
        }
    }

    /// RAM tier of two chunks, so a third distinct chunk evicts the first.
    private func makeRig() -> Rig {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        let file = MemoryChunkFile()
        let spills = DispatchQueue(label: "test.spill")
        let tier = DiskChunkTier(file: file, budgetBytes: 64 * (Self.chunk + DiskChunkTier.tagRoom),
                                 chunkBytes: Self.chunk, spillQueue: spills)
        let store = DaemonStore(daemon: daemon, session: "s1", blockSize: Self.blockSize,
                                byteCount: UInt64(Self.capacity),
                                ramCacheBytes: 2 * Self.chunk, diskTier: tier)
        return Rig(store: store, daemon: daemon, tier: tier, file: file, spills: spills)
    }

    private func read(_ store: DaemonStore, at offset: Int, length: Int = 4096) throws -> Data {
        var out = Data(count: length)
        let got: Int = try out.withUnsafeMutableBytes { raw in
            try store.read(into: raw, at: UInt64(offset), length: length)
        }
        return out.prefix(got)
    }

    private static func pattern(_ seed: UInt8) -> Data {
        Data((0 ..< 4096).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ Int(seed)) })
    }

    /// Reads chunk 0, then chunks 4 and 8 (never consecutive, so nothing is
    /// speculated): the two-chunk RAM tier evicts 0 to disk.
    private func evictChunkZero(_ rig: Rig) throws {
        _ = try read(rig.store, at: 0)
        _ = try read(rig.store, at: 4 * Self.chunk)
        _ = try read(rig.store, at: 8 * Self.chunk)
        rig.drain()
    }

    @Test("a chunk re-read after RAM eviction costs no daemon call")
    func rereadIsServedFromDisk() throws {
        let rig = makeRig()
        _ = try rig.store.write(Self.pattern(1), at: 0)
        try evictChunkZero(rig)
        let before = rig.daemonReads
        #expect(try read(rig.store, at: 0) == Self.pattern(1))
        #expect(rig.daemonReads == before)
        #expect(rig.tier.stats.hits == 1)
        #expect(rig.store.summary.contains("disk=1/"))
        #expect(rig.store.summary.contains("diskSaved=\(Self.chunk)B"))
    }

    @Test("a write to a chunk held only on disk is read back new, from the daemon")
    func writeAfterEvictionReadsBackNew() throws {
        let rig = makeRig()
        _ = try rig.store.write(Self.pattern(1), at: 0)
        try evictChunkZero(rig)
        _ = try rig.store.write(Self.pattern(2), at: 0)
        #expect(rig.tier.lookup(offset: 0, length: Self.chunk) == nil, "the write invalidated it")
        let before = rig.daemonReads
        #expect(try read(rig.store, at: 0) == Self.pattern(2))
        #expect(rig.daemonReads == before + 1)
    }

    /// The spill of chunk 0 is queued (held) when the write lands; the write's
    /// invalidation must cancel it, or pre-write bytes reach disk after it.
    @Test("a write racing a pending spill is read back new")
    func writeRacingPendingSpill() throws {
        let rig = makeRig()
        _ = try rig.store.write(Self.pattern(1), at: 0)
        rig.spills.suspend()
        _ = try read(rig.store, at: 0)
        _ = try read(rig.store, at: 4 * Self.chunk)
        _ = try read(rig.store, at: 8 * Self.chunk)        // evicts 0: spill queued, held
        _ = try rig.store.write(Self.pattern(2), at: 0)
        rig.spills.resume()
        rig.drain()
        #expect(try read(rig.store, at: 0) == Self.pattern(2))
    }

    @Test("reads keep working after the tier disables itself")
    func readsSurviveDisable() throws {
        let rig = makeRig()
        rig.file.failWrites = true
        _ = try rig.store.write(Self.pattern(1), at: 0)
        try evictChunkZero(rig)
        #expect(rig.tier.stats.disabledReason != nil)
        #expect(try read(rig.store, at: 0) == Self.pattern(1))
        #expect(rig.store.summary.contains("diskOff="))
    }

    /// Chunks 2 and 3 are put on disk; then a full-chunk sequential pair
    /// (0, 1) opens the readahead gate and speculates 2 and 3 — which must
    /// come from disk, not the daemon.
    @Test("speculation is served from disk when the chunk is there")
    func speculationFromDisk() throws {
        let rig = makeRig()
        _ = try read(rig.store, at: 3 * Self.chunk, length: Self.chunk)
        _ = try read(rig.store, at: 2 * Self.chunk, length: Self.chunk)
        _ = try read(rig.store, at: 10 * Self.chunk)
        _ = try read(rig.store, at: 12 * Self.chunk)
        rig.drain()
        let logIndex = rig.daemon.log.count
        _ = try read(rig.store, at: 0, length: Self.chunk)
        _ = try read(rig.store, at: Self.chunk, length: Self.chunk)
        _ = try read(rig.store, at: 2 * Self.chunk, length: Self.chunk)   // waits on the speculation
        let after = rig.daemon.log.dropFirst(logIndex)
        #expect(!after.contains { $0.kind == "read" && $0.offset == UInt64(2 * Self.chunk) })
        #expect(rig.tier.stats.hits >= 1)
    }

    @Test("a daemon that never answers the cache-size call does not stall the mount")
    func unansweredCacheSizeIsOff() {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        daemon.answersLocalCache = false
        let start = Date()
        #expect(DaemonStore.localCacheSetting(from: daemon, session: "s1", timeout: 0.2) == 0)
        #expect(Date().timeIntervalSince(start) < 2)
    }

    @Test("the cache size the daemon reports is what the store asks for")
    func answeredCacheSize() {
        let daemon = FakeDaemon(byteCount: Self.capacity)
        daemon.localCache = 4 << 30
        #expect(DaemonStore.localCacheSetting(from: daemon, session: "s1") == 4 << 30)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "Disk tier in the volume" 2>&1 | grep -E "error:" | head -5`
Expected: build failure — `extra arguments 'ramCacheBytes', 'diskTier' in call`, `type 'DaemonStore' has no member 'localCacheSetting'`.

- [ ] **Step 3: Implement in `DaemonStore`**

In `Sources/iSCSIVolume/LUNStore.swift`, inside `DaemonStore`:

1. After `private var cache: PrefetchChunkCache!` add:
   ```swift
    /// The local disk cache under `cache`, when this target has one and the
    /// disk had room for it at attach. Set once in `init`.
    private let diskTier: DiskChunkTier?
    /// Why a configured tier could not be made at attach, for the summary.
    private let diskTierOff: String?

    /// Speculative fetches the disk tier can answer are read here, never on
    /// the caller's thread: speculation is issued from inside a read, and
    /// decrypting up to 32 chunks there would delay it.
    private static let diskReads = DispatchQueue(label: "me.herko.iSCSIInitiator.fsext.disk-reads",
                                                 qos: .userInitiated, attributes: .concurrent)

    /// The sandbox container's Caches. The tier's file is unlinked the moment
    /// it is opened, so nothing accumulates here.
    private static var cacheDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("chunks", isDirectory: true)
    }
   ```
2. Give `blocking` a timeout parameter: change
   ```swift
    private static func blocking(_ body: (@escaping () -> Void) -> Void) throws {
        let sem = DispatchSemaphore(value: 0)
        body { sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            fsLog.error("daemon call timed out after \(Int(timeout))s")
   ```
   to
   ```swift
    private static func blocking(timeout: TimeInterval = DaemonStore.timeout,
                                 _ body: (@escaping () -> Void) -> Void) throws {
        let sem = DispatchSemaphore(value: 0)
        body { sem.signal() }
        if sem.wait(timeout: .now() + timeout) == .timedOut {
            fsLog.error("daemon call timed out after \(Int(timeout))s")
   ```
3. Add, after `blocking`:
   ```swift
    /// The target's local cache size, or 0. Its own short timeout: an older
    /// daemon without the selector never replies, and that must cost a
    /// mount seconds, not the 30 s a data call is allowed.
    static func localCacheSetting(from proxy: ISCSIDaemonProtocol, session: String,
                                  timeout: TimeInterval = 5) -> Int {
        let reply = OSAllocatedUnfairLock(initialState: 0)
        try? blocking(timeout: timeout) { done in
            proxy.localCacheBytes(session: session) { bytes, error in
                if error == nil { reply.withLock { $0 = bytes.intValue } }
                done()
            }
        }
        return reply.withLock { $0 }
    }
   ```
4. In the XPC convenience `init(host:port:target:lun:)`, replace
   ```swift
        self.init(connection: xpc, injectedDaemon: nil, session: handle,
                  blockSize: bs, byteCount: product,
                  budgetBytes: budgetBytes, pinned: pinned)
   ```
   with
   ```swift
        // Local disk cache: best effort. Anything short of a usable tier
        // mounts without one and says why.
        let cacheBytes = Self.localCacheSetting(from: proxy, session: handle)
        var tier: DiskChunkTier?
        var tierOff: String?
        if cacheBytes > 0 {
            switch DiskChunkTier.make(directory: Self.cacheDirectory, budgetBytes: cacheBytes,
                                      chunkBytes: Self.chunkBytes(forBlockSize: Int(bs))) {
            case .success(let made):
                tier = made
                fsLog.log("local cache \(made.capacityBytes >> 20) MiB of \(cacheBytes >> 20) MiB configured")
            case .failure(let why):
                tierOff = why.description
                fsLog.log("local cache off: \(why.description, privacy: .public)")
            }
        }
        self.init(connection: xpc, injectedDaemon: nil, session: handle,
                  blockSize: bs, byteCount: product,
                  budgetBytes: budgetBytes, pinned: pinned,
                  ramCacheBytes: Self.maxCachedBytes, diskTier: tier, diskTierOff: tierOff)
   ```
5. Change the designated `private init(connection:injectedDaemon:session:blockSize:byteCount:budgetBytes:pinned:)` signature to add `ramCacheBytes: Int, diskTier: DiskChunkTier?, diskTierOff: String?` as its last three parameters; before `let chunk = Self.chunkBytes(forBlockSize: Int(bs))` add:
   ```swift
        self.diskTier = diskTier
        self.diskTierOff = diskTierOff
   ```
   and replace the `cache = PrefetchChunkCache(…)` construction with:
   ```swift
        cache = PrefetchChunkCache(
            chunkBytes: chunk,
            capacity: byteCount,
            maxCachedBytes: ramCacheBytes,
            policy: ReadaheadPolicy(budgetBytes: budgetBytes,
                                    maxSlots: Self.readaheadMaxSlots,
                                    minStreamBytes: Self.readaheadMinStream,
                                    chunkBytes: chunk),
            timeout: Self.timeout,
            adaptiveDepth: !pinned,
            fetchSync: { [weak self] offset, length in
                guard let self else { throw POSIXError(.EIO) }
                if let data = self.diskTier?.lookup(offset: offset, length: length) { return data }
                return try self.rawRead(offset: offset, length: length)
            },
            fetchAsync: { [weak self] offset, length, done in
                guard let self else { done(nil); return }
                guard let tier = self.diskTier else {
                    self.fetchFromDaemon(offset: offset, length: length, done)
                    return
                }
                Self.diskReads.async { [weak self] in
                    if let data = tier.lookup(offset: offset, length: length) { done(data); return }
                    guard let self else { done(nil); return }
                    self.fetchFromDaemon(offset: offset, length: length, done)
                }
            },
            onEvict: diskTier.map { tier -> (UInt64, Data) -> Void in
                { offset, data in tier.spill(offset: offset, data: data) }
            })
   ```
   Then, before `deinit`, add:
   ```swift
    /// One speculative chunk from the daemon; nil on any failure.
    private func fetchFromDaemon(offset: UInt64, length: Int, _ done: @escaping (Data?) -> Void) {
        guard let proxy = try? daemon() else { done(nil); return }
        proxy.read(session: session, offset: NSNumber(value: offset),
                   length: NSNumber(value: length)) { data, error in
            done(error == nil ? data : nil)
        }
    }
   ```
6. Replace the test convenience initializer with:
   ```swift
    /// Build a store around an injected daemon, for tests. Takes the geometry
    /// so a fake daemon only answers `read`, `write` and `flush`; a smaller
    /// RAM tier and an injected disk tier let tests force evictions.
    public convenience init(daemon: ISCSIDaemonProtocol, session: String,
                            blockSize: UInt64, byteCount: UInt64,
                            readaheadBudgetBytes: Int? = nil,
                            ramCacheBytes: Int? = nil,
                            diskTier: DiskChunkTier? = nil) {
        self.init(connection: nil, injectedDaemon: daemon, session: session,
                  blockSize: blockSize, byteCount: byteCount,
                  budgetBytes: readaheadBudgetBytes ?? Self.readaheadBytes,
                  pinned: readaheadBudgetBytes != nil,
                  ramCacheBytes: ramCacheBytes ?? Self.maxCachedBytes,
                  diskTier: diskTier, diskTierOff: nil)
    }
   ```
7. In `write(_:at:)`, invalidate the tier at both edges. Replace
   ```swift
        cache.willWrite(offset: plan.alignedOffset, length: plan.alignedLength)
        do {
   ```
   with
   ```swift
        cache.willWrite(offset: plan.alignedOffset, length: plan.alignedLength)
        diskTier?.invalidate(offset: plan.alignedOffset, length: plan.alignedLength)
        do {
   ```
   After the `if plan.isExact { … } else { … }` block, still inside the `do` (after the `ioLock` section's last statement), add:
   ```swift
            // After the RAM patch, never before: a chunk the RAM tier evicts
            // between the device write and here spills pre-write bytes, and
            // this cancels that spill.
            diskTier?.invalidate(offset: plan.alignedOffset, length: plan.alignedLength)
   ```
   and in the `catch`, after `cache.writeFailed(…)`, add `diskTier?.invalidate(offset: plan.alignedOffset, length: plan.alignedLength)`.
8. In `summary`, fetch the tier's stats before taking `lock` (next to `let s = cache.stats`): `let d = diskTier?.stats`. Change the `return "reads=…"` expression into `var line = "reads=…"` (same text), then append before returning:
   ```swift
        if let d {
            line += " disk=\(d.hits)/\(d.lookups) diskSaved=\(d.savedBytes)B"
                  + " spilled=\(d.spilled) diskCorrupt=\(d.corrupt)"
            if let why = d.disabledReason { line += " diskOff=\(why)" }
        } else if let why = diskTierOff {
            line += " diskOff=\(why)"
        }
        return line
   ```

If `OSAllocatedUnfairLock` is not yet imported in `LUNStore.swift`, it comes from `import os`, which the file already has.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "Disk tier in the volume|Volume data path|LUNStore" 2>&1 | grep -E "Test run with|✘"`
Expected: all pass — the seven new tests and every existing `DaemonStore` test.

- [ ] **Step 5: Commit**

```bash
git add Sources/iSCSIVolume/LUNStore.swift Tests/IntegrationTests/DiskTierDataPathTests.swift
git commit -F - <<'EOF'
Put the disk tier under the volume's RAM cache

Misses and speculation consult it before the daemon; evicted chunks that
were read spill to it; every write invalidates it before it is sent and
again after the RAM patch. The size comes from the daemon with a short
timeout of its own, so an older daemon cannot stall a mount, and the
summary line reports what the tier saved.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 6: The target editor

**Files:**
- Modify: `apps/iSCSIApp/Windows/TargetsView.swift`

**Interfaces:**
- Consumes: `TargetRecord.localCacheGB`, `localCacheBytes`, init `localCacheGB:` (Task 4).

No unit test: this is SwiftUI binding with no logic beyond what Task 4 tests (`localCacheBytes` decides on/off). The build in Step 3 is the check.

- [ ] **Step 1: Add the state and the picker**

In `apps/iSCSIApp/Windows/TargetsView.swift`:

1. After `@State private var interfaceFallback: Bool` add:
   ```swift
    /// nil = off. Mirrors `TargetRecord.localCacheGB` for valid sizes.
    @State private var localCacheGB: Int?
   ```
2. In `init`, after `_interfaceFallback = State(…)` add:
   ```swift
        // A hand-edited out-of-range size shows as Off, which is what it is.
        _localCacheGB = State(initialValue: (target?.localCacheBytes ?? 0) > 0 ? target?.localCacheGB : nil)
   ```
3. After the `Section("Write safety") { … }` block (before `.formStyle(.grouped)` closes the `Form`), add:
   ```swift
                Section {
                    Picker("Size", selection: $localCacheGB) {
                        Text("Off").tag(Int?.none)
                        ForEach(1 ... 16, id: \.self) { gb in
                            Text("\(gb) GB").tag(Int?.some(gb))
                        }
                    }
                } header: {
                    Text("Local cache")
                } footer: {
                    Text("Kept on this Mac's disk, encrypted, only while the target is attached. "
                         + "Takes effect the next time it is attached.")
                        .font(.caption).foregroundStyle(.secondary)
                }
   ```
4. In `save()`, change the end of the `TargetRecord(` call from
   ```swift
            interfaceFallback: networkInterface == nil ? nil : interfaceFallback)
   ```
   to
   ```swift
            interfaceFallback: networkInterface == nil ? nil : interfaceFallback,
            localCacheGB: localCacheGB)
   ```

- [ ] **Step 2: Regenerate the project**

Run: `cd apps && SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd .. && git diff --stat apps/iSCSIInitiator.xcodeproj`
Expected: no `.pbxproj` change (no files were added).

- [ ] **Step 3: Build the app**

Run: `cd apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"; cd .. && git checkout -- Package.resolved`
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 4: Commit**

```bash
git add apps/iSCSIApp/Windows/TargetsView.swift
git commit -F - <<'EOF'
Add the local cache size to the target editor

Off by default; 1-16 GB, kept on this Mac's disk, encrypted, only while
the target is attached.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```

---

### Task 7: Docs and full verification

**Files:**
- Modify: `README.md` (end of "Performance/testing", before the paragraph beginning "Writes default to Force Unit Access")
- Modify: `docs/open-questions.md` (new section before `## A note on method`)
- Modify: `docs/test-playbook.md` (new section before `## Fuzzing`)

- [ ] **Step 1: README**

Before the paragraph beginning "Writes default to Force Unit Access on every command", add:

```markdown
A target can keep an optional **local disk cache** (target editor → Local
cache, 1–16 GB, off by default): chunks read once and pushed out of the 32 MiB
memory cache are kept on this Mac's disk, encrypted with a key that exists
only in memory, for as long as the target is attached. It helps a working set
larger than memory and slow links; it cannot help a first read, and writes
still go to the target exactly as before.
```

- [ ] **Step 2: Open questions**

Before `## A note on method` add:

```markdown
## 12. Local disk cache (0.7.0): what is unverified

Built and tested against an in-memory daemon and an in-memory cache file
(`docs/superpowers/specs/2026-10-02-local-disk-cache-design.md`). Not yet run:

- **On hardware, with the cache on.** `scripts/readahead-soak.py` against a
  cached volume must report zero mismatches; its region must exceed the 32 MiB
  memory tier for the disk tier to be exercised at all. Rides with the 0.7.0 RC.
- **Whether it pays.** No reuse measurement exists: reads are not traced. The
  RC's long VM session and a run over Tailscale should show `diskSaved` in the
  summary line; if they barely move it, the segmented-LRU split (80% protected)
  and the admission rule are the first suspects, not the size.
- **`F_NOCACHE`'s effect** on the tier's own reads is assumed, not measured.
- **Several volumes at 16 GB each** on a small boot disk: each tier is sized at
  its own attach against the free space then, so attach order decides who gets
  room. Deliberate (per-target), unexercised.
```

- [ ] **Step 3: Test playbook**

Before `## Fuzzing` add:

```markdown
## Local disk cache (0.7.0)

On the SIP-off VM, with the RC installed from its notarized DMG. Set a scratch
target's Local cache to 4 GB, attach it, and confirm the extension logged its
size:

    /usr/bin/log show --last 5m --info --debug \
      --predicate 'subsystem == "me.herko.iSCSIInitiator.fsext"' | grep "local cache"

Then run the readahead soak over a region larger than the 32 MiB memory tier —
destructive, scratch LUN only:

    scripts/readahead-soak.py /Volumes/<scratch>/lun0.img --seconds 600

Zero mismatches is the bar. Detach, and read `disk=`, `diskSaved=`, `spilled=`
and `diskCorrupt=` from the unmount summary line; `diskCorrupt` must be 0.
```

- [ ] **Step 4: Full verification**

```bash
swift build -Xswiftc -DISCSI_BACKEND_B 2>&1 | grep -E "error:"; echo "backend-b build done"
swift test --no-parallel > "${TMPDIR:-/tmp}/cache-test.log" 2>&1; echo "exit=$?"
grep -E "Test run with|✘" "${TMPDIR:-/tmp}/cache-test.log"
cd apps && xcodebuild -project iSCSIInitiator.xcodeproj -scheme 'iSCSI Initiator' -configuration Release \
  -destination 'generic/platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
SWIFT_DETERMINISTIC_HASHING=1 xcodegen generate && cd .. && git checkout -- Package.resolved
git diff --exit-code apps/iSCSIInitiator.xcodeproj && echo "pbxproj in sync"
```

Expected: no Backend B errors; `exit=0` and every test run passes with no `✘`; `** BUILD SUCCEEDED **`; `pbxproj in sync`. Then list warnings in files this branch changed and confirm each predates the branch with `git blame`.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/open-questions.md docs/test-playbook.md
git commit -F - <<'EOF'
Document the local disk cache and its RC checks

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01ETZV7djaWWDHikqiKrQqGM
EOF
```
