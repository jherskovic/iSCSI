//
//  FSKitEnablement.swift
//  The macOS 26.x branch of setup step E.
//
//  On macOS 27 the System Settings switch works and this file is not used: the
//  app deep-links to the pane with FSClient.openFileSystemExtensionsSettings()
//  and watches FSModuleIdentity.isEnabled. On 26.x the switch is present but
//  refuses to move, and the deep link does not even navigate, so there is no way
//  to hand the user the problem — the app has to do it.
//
//  What the app has to do is small and is fully measured
//  (docs/backend-a-fskit-notes.md): append our bundle identifier to
//  enabledModules.plist in the FSKit settings group container, then get fskitd
//  to re-read it. Nothing else. No reboot, no logout.
//
//  The one unmeasured thing, and the reason this exists as a probe before it
//  exists as a feature: every successful write so far came from an ssh shell,
//  which inherits the terminal's TCC grants. This is a *foreign* group container
//  — group.com.apple.fskit.settings is Apple's, not ours — and macOS 14+ TCC
//  intercepts non-owner access to those. A freshly installed app may get a
//  consent prompt or a silent EPERM where the shell sailed through. `Report`
//  therefore records every step and every errno rather than returning a Bool,
//  because "it failed" is not an actionable answer and "it failed with EPERM at
//  the write, having read fine" is.
//

import Foundation

enum FSKitEnablement {
    static let moduleBundleID = "me.herko.iSCSIInitiator.fsext"
    static let groupIdentifier = "group.com.apple.fskit.settings"

    /// Everything observed during one attempt, in the order it happened.
    /// Sendable so the attempt can run off the main actor — a TCC denial can
    /// block on a consent prompt, and that must not freeze the UI.
    struct Report: Sendable {
        var containerSource: String = "(not resolved)"
        var path: String = ""
        var before: [String]?
        var after: [String]?
        var alreadyEnabled = false
        var writeMode: String?
        var failure: String?

        var succeeded: Bool { failure == nil }

        /// One block of text, meant to be read off a screen and pasted into an
        /// issue. Ordering matters more than prettiness.
        var transcript: String {
            var out = ["container: \(containerSource)", "path:      \(path)"]
            if let before { out.append("before:    \(before.joined(separator: ", "))") }
            if alreadyEnabled { out.append("note:      already present; rewrote anyway to test the write") }
            if let writeMode { out.append("write:     \(writeMode)") }
            if let after { out.append("after:     \(after.joined(separator: ", "))") }
            if let failure { out.append("FAILED:    \(failure)") }
            else { out.append("OK — now kick fskitd (root) to make it live") }
            return out.joined(separator: "\n")
        }
    }

    /// `containerURL(forSecurityApplicationGroupIdentifier:)` is the correct API,
    /// but it is documented to return nil when the caller is not a member of the
    /// group — which we are not, and never will be. Falling back to the literal
    /// path is not a hack here: an unsandboxed app's home *is* the real home, so
    /// the constructed path is the same one the shell used. Which route produced
    /// the URL is recorded, because if the API ever starts working that is a
    /// meaningful change in what Apple permits.
    static func locateContainer() -> (url: URL, source: String) {
        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupIdentifier) {
            return (url, "containerURL(forSecurityApplicationGroupIdentifier:)")
        }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Group Containers")
            .appendingPathComponent(groupIdentifier)
        return (url, "constructed from homeDirectoryForCurrentUser")
    }

    /// Add our module to the enabled list, preserving everything already there.
    ///
    /// Deduplicates first. The recipe in the notes uses `plutil -insert`, which
    /// appends a second copy every time it runs — harmless on the first run and
    /// steadily less harmless after an update re-triggers the repair path.
    static func enableModule() -> Report {
        var report = Report()

        let (container, source) = locateContainer()
        report.containerSource = source
        let plist = container.appendingPathComponent("enabledModules.plist")
        report.path = plist.path

        // Read.
        var identifiers: [String]
        do {
            let data = try Data(contentsOf: plist)
            guard let list = try PropertyListSerialization.propertyList(
                from: data, format: nil) as? [String] else {
                report.failure = "enabledModules.plist is not an array of strings"
                return report
            }
            identifiers = list
            report.before = list
        } catch {
            // A missing file is a different problem from a denied one, and only
            // one of them is fatal. Say which.
            let ns = error as NSError
            if ns.domain == NSCocoaErrorDomain && ns.code == NSFileReadNoSuchFileError {
                report.failure = "no enabledModules.plist at that path — refusing to "
                    + "invent one, since writing a fresh file would drop Apple's own "
                    + "modules from the enabled set"
            } else {
                report.failure = "read failed: \(describe(error))"
            }
            return report
        }

        report.alreadyEnabled = identifiers.contains(moduleBundleID)
        identifiers.removeAll { $0 == moduleBundleID }
        identifiers.insert(moduleBundleID, at: 0)

        // Write. Atomic first, because that is what shipping code should do —
        // a truncated enabledModules.plist would disable every filesystem on the
        // machine, including the ones the user's disks are mounted with. If the
        // atomic replace is what TCC objects to (it creates a new inode in a
        // directory we do not own), fall back to an in-place rewrite and say so,
        // because that distinction decides how the shipping version is written.
        do {
            let data = try PropertyListSerialization.data(
                fromPropertyList: identifiers, format: .binary, options: 0)
            do {
                try data.write(to: plist, options: .atomic)
                report.writeMode = "atomic replace"
            } catch {
                let atomicFailure = describe(error)
                do {
                    try data.write(to: plist)
                    report.writeMode = "in-place (atomic replace failed: \(atomicFailure))"
                } catch {
                    report.failure = "atomic: \(atomicFailure) — in-place: \(describe(error))"
                    return report
                }
            }
        } catch {
            report.failure = "could not serialize: \(describe(error))"
            return report
        }

        // Read back rather than trusting the write. A write that reports success
        // into a redirected or shadowed location is exactly the failure mode TCC
        // and sandbox containers produce, and it is invisible from the write side.
        if let data = try? Data(contentsOf: plist),
           let list = try? PropertyListSerialization.propertyList(
            from: data, format: nil) as? [String] {
            report.after = list
            if !list.contains(moduleBundleID) {
                report.failure = "write reported success but the entry is not there on re-read"
            }
        } else {
            report.failure = "wrote, but could not read the file back to confirm"
        }

        return report
    }

    /// errno is worth more than localizedDescription here — "You don't have
    /// permission" does not distinguish EPERM from EACCES, and the setup flow
    /// needs to tell "grant Full Disk Access" apart from "this can never work".
    private static func describe(_ error: Error) -> String {
        let ns = error as NSError
        var parts = ["\(ns.domain) \(ns.code): \(ns.localizedDescription)"]
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? NSError {
            parts.append("underlying \(underlying.domain) \(underlying.code)")
            if underlying.domain == NSPOSIXErrorDomain {
                parts.append("errno \(underlying.code) "
                             + "(\(String(cString: strerror(Int32(underlying.code)))))")
            }
        }
        return parts.joined(separator: "; ")
    }
}
