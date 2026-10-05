import Foundation

/// What a daemon from another build may be asked.
///
/// The app replaces the extension the moment it is updated; the daemon stays
/// the old one until Setup reinstalls it. In that window the new extension
/// talks to the old daemon, and asking a method the daemon's XPC interface
/// lacks does not merely go unanswered: NSXPC drops the connection, and the
/// daemon, which keys sessions by connection, logs out every session it
/// carried. Measured with the 0.7.1 extension against the 0.6.1 daemon
/// (2026-10-05): the mount came up, then every read failed with EIO. So a
/// method added after a release is asked only of daemons known to have it,
/// judged from `daemonInfo` — which every daemon has answered since 0.4.
public enum DaemonCapabilities {
    /// The first build whose daemon answers `localCacheBytes`: 0.7.0's RC1.
    public static let localCacheSinceBuild = 40

    public static func answersLocalCache(_ info: DaemonInfo?) -> Bool {
        guard let info else { return false }
        // A loose `swift run` daemon is the code it was built from.
        if info.version == "dev" { return true }
        guard let build = Int(info.build) else { return false }
        return build >= localCacheSinceBuild
    }
}
