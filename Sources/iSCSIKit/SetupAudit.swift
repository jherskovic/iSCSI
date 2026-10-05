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

/// The rules behind Setup's "Only this copy registered" step. Pure: the
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

    /// The app bundles an `lsregister -dump` attributes our filesystem
    /// extension to. Records appear as
    /// `path: /…/X.app/Contents/Extensions/iSCSIFSExtension.appex (0x…)`;
    /// the containing `.app` is what `lsregister -u` accepts. Sorted, once each.
    public static func appBundles(inDump dump: String) -> [String] {
        var found: Set<String> = []
        for line in dump.split(separator: "\n") {
            guard line.contains("iSCSIFSExtension.appex") else { continue }
            guard let appRange = line.range(of: #"/[^"]*?\.app(?=/Contents/Extensions/)"#,
                                            options: .regularExpression) else { continue }
            found.insert(String(line[appRange]))
        }
        return found.sorted()
    }

    /// What the step says about copies that still exist — the orange state.
    /// Measured on the SIP-on VM (2026-10-05): launching the app from its disk
    /// image was enough for launchd to run the daemon from there, which kept
    /// the image from ejecting and broke every attach once it was forced off.
    public static func summary(_ copies: [RegisteredCopy], home: String) -> String {
        let listed = copies.map { shown($0.path, home: home) }.joined(separator: "; ")
        if copies.count == 1 {
            return "Another copy is registered at \(listed). macOS can run the background "
                + "service from it instead of this one; if it is on a disk image, the image "
                + "can't be ejected and attaching stops working once it is gone."
        }
        return "\(copies.count) other copies are registered: \(listed). macOS can run the "
            + "background service from any of them instead of this one; if one is on a disk "
            + "image, the image can't be ejected and attaching stops working once it is gone."
    }

    /// What the step says about records of copies that no longer exist — a
    /// note on a row that stays green. With the copy gone, the daemon came back
    /// from this one and FSKit listed only this one (SIP-on VM, 2026-10-05).
    public static func goneNote(_ copies: [RegisteredCopy], home: String) -> String {
        let listed = copies.map { shown($0.path, home: home) }.joined(separator: "; ")
        if copies.count == 1 {
            return "macOS still has a record of \(listed), which no longer exists — usually "
                + "an ejected disk image. Nothing uses it."
        }
        return "macOS still has records of \(copies.count) copies that no longer exist — "
            + "usually ejected disk images: \(listed). Nothing uses them."
    }

    /// A path for display: the home directory as `~`.
    private static func shown(_ path: String, home: String) -> String {
        path.hasPrefix(home + "/") ? "~" + path.dropFirst(home.count) : path
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
