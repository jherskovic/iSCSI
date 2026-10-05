import Foundation

/// Another copy of the app that LaunchServices has registered.
public struct RegisteredCopy: Sendable, Equatable {
    public var path: String
    /// false: LaunchServices still holds a record, but the bundle is gone —
    /// an ejected disk image, a deleted build folder.
    public var exists: Bool

    public init(path: String, exists: Bool) {
        self.path = path
        self.exists = exists
    }
}

/// The rules behind Setup's "No other copies registered" step. Pure: the
/// caller supplies what LaunchServices reported and how to test existence,
/// so none of this needs LaunchServices to test. See
/// docs/superpowers/specs/2026-10-05-setup-repair-design.md.
public enum RegisteredCopies {
    /// The form two paths are compared in: symlinks resolved, standardized,
    /// no trailing slash.
    public static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    /// Every registered copy except the running one, once each, sorted.
    public static func others(registered: [String], running: String,
                              exists: (String) -> Bool) -> [RegisteredCopy] {
        let mine = canonical(running)
        var seen = Set<String>()
        var copies: [RegisteredCopy] = []
        for path in registered {
            let normal = canonical(path)
            guard normal != mine, seen.insert(normal).inserted else { continue }
            copies.append(RegisteredCopy(path: normal, exists: exists(normal)))
        }
        return copies.sorted { $0.path < $1.path }
    }

    /// What the step says when other copies exist: each one named, gone ones
    /// marked, the home directory shown as `~`, and why it matters.
    public static func summary(_ copies: [RegisteredCopy], home: String) -> String {
        let listed = copies.map { copy -> String in
            let shown = copy.path.hasPrefix(home + "/")
                ? "~" + copy.path.dropFirst(home.count)
                : copy.path
            return copy.exists ? shown : "\(shown) (no longer exists)"
        }.joined(separator: "; ")
        let lead = copies.count == 1
            ? "Another copy of iSCSI Initiator is registered with macOS: "
            : "\(copies.count) other copies of iSCSI Initiator are registered with macOS: "
        return lead + listed + ". macOS can load the filesystem extension or start the "
            + "background service from any of them, so attaching can fail while every "
            + "other step here is green."
    }
}

/// Which copy of the app the daemon runs from.
public enum DaemonPlacement {
    /// Whether the daemon belongs to a copy other than this one. nil — an
    /// older daemon, or one run loose — says nothing, so it is not "other".
    public static func isOtherCopy(daemonBundlePath: String?, appBundlePath: String) -> Bool {
        guard let daemonBundlePath else { return false }
        return RegisteredCopies.canonical(daemonBundlePath)
            != RegisteredCopies.canonical(appBundlePath)
    }

    /// The path a daemon reports for itself: its bundle's, but only when that
    /// bundle is an app — `iscsid` inside `<app>/Contents/MacOS` resolves to
    /// the containing app; anything else is a loose build.
    public static func bundlePath(ofBundleAt url: URL) -> String? {
        url.pathExtension == "app" ? url.path : nil
    }
}
