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
