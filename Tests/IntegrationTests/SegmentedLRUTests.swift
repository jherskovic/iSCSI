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
