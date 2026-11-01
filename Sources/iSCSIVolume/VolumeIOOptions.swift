import Foundation
import iSCSIKit

/// How the FSKit volume answers reads and what kernel caching it grants for
/// `lun0.img`, chosen per mount from the mount URL's query.
///
/// The default is the behaviour every release shipped: blocking replies, and
/// kernel caching left to FSKit. That is what `hdiutil`'s attach engine needs,
/// and `hdiutil` is the default engine.
///
/// When the app attaches with DiskImages2 it adds `engine=diskimages2`
/// (`ImageAttachEngine.mountQuery`), and on macOS 27 the volume then serves that
/// engine the way it needs (docs/open-questions.md items 16-17): it answers
/// reads from a concurrent queue, so FSKit hands them over concurrently, and it
/// grants the kernel write-through caching for `lun0.img`, which is what keeps
/// DiskImages2's page cache from holding writes the target has not
/// acknowledged. FSKit 26 has no `FSVolume.DataCacheHandler`, so there the
/// profile is ignored; the app never uses DiskImages2 on 26 anyway.
///
/// Overrides for measurement, on a hand-made mount URL:
/// `reads=async|blocking`, `cache=writethrough|readcache|nocache|fskit`.
public struct VolumeIOOptions: Equatable, Sendable {

    /// What the volume grants the kernel for `lun0.img`, in the terms of
    /// FSKit's `FSVolume.KernelCacheCoherencyType`.
    public enum CacheGrant: String, Sendable {
        /// Reads cached; every write reaches the volume before it returns.
        case writeThrough = "writethrough"
        /// Reads cached; writes bypass the cache.
        case readCache = "readcache"
        /// Nothing cached.
        case noCache = "nocache"
    }

    /// Answer reads from a concurrent queue instead of FSKit's thread.
    public var asyncReads: Bool
    /// nil: leave kernel caching to FSKit (do not adopt the cache handler).
    public var cacheGrant: CacheGrant?

    public init(asyncReads: Bool, cacheGrant: CacheGrant?) {
        self.asyncReads = asyncReads
        self.cacheGrant = cacheGrant
    }

    /// What every release shipped, and what `hdiutil` needs.
    public static let shipping = VolumeIOOptions(asyncReads: false, cacheGrant: nil)

    /// What DiskImages2 needs, where FSKit can provide it.
    public static func diskImages2Profile(osMajor: Int) -> VolumeIOOptions {
        osMajor >= ImageAttachEngine.firstWriteThroughMajor
            ? VolumeIOOptions(asyncReads: true, cacheGrant: .writeThrough)
            : shipping
    }

    /// The options for a mount: the shipping behaviour, or the DiskImages2
    /// profile when the query carries `engine=diskimages2`, then any
    /// recognised override. Unrecognised values are ignored, so a typo falls
    /// back to the profile rather than to something unmeasured.
    public static func resolve(query: [URLQueryItem], osMajor: Int) -> VolumeIOOptions {
        let wantsDiskImages2 = query.contains {
            $0.name == ImageAttachEngine.mountQuery.name && $0.value == ImageAttachEngine.mountQuery.value
        }
        var options = wantsDiskImages2 ? diskImages2Profile(osMajor: osMajor) : shipping
        for item in query {
            switch (item.name, item.value) {
            case ("reads", "async"): options.asyncReads = true
            case ("reads", "blocking"): options.asyncReads = false
            case ("cache", "fskit"): options.cacheGrant = nil
            case ("cache", let value?):
                if let grant = CacheGrant(rawValue: value) { options.cacheGrant = grant }
            default: break
            }
        }
        return options
    }
}
