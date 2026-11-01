import Foundation

/// Recency order over keys, most recent first, O(1) per operation. Pure
/// bookkeeping: the owner keeps the values and decides what to evict.
///
/// `PrefetchChunkCache` used to find its coldest chunk by scanning every
/// entry, which was cheap at 128 whole chunks and is not once a miss can
/// keep a single 4 KiB sector: the same 32 MiB then holds thousands.
struct LRUOrder<Key: Hashable & Sendable>: Sendable {
    private struct Links: Sendable {
        var newer: Key?
        var older: Key?
    }

    private var links: [Key: Links] = [:]
    private(set) var newest: Key?
    private(set) var oldest: Key?

    var count: Int { links.count }

    func contains(_ key: Key) -> Bool { links[key] != nil }

    /// Make `key` the most recent, inserting it if it is new.
    mutating func touch(_ key: Key) {
        if newest == key { return }
        unlink(key)
        links[key] = Links(newer: nil, older: newest)
        if let previous = newest { links[previous]?.newer = key }
        newest = key
        if oldest == nil { oldest = key }
    }

    mutating func remove(_ key: Key) { unlink(key) }

    /// The key one step more recent than `key`, for walking up from `oldest`.
    func newer(than key: Key) -> Key? { links[key]?.newer }

    private mutating func unlink(_ key: Key) {
        guard let l = links.removeValue(forKey: key) else { return }
        if let n = l.newer { links[n]?.older = l.older } else { newest = l.older }
        if let o = l.older { links[o]?.newer = l.newer } else { oldest = l.newer }
    }
}
