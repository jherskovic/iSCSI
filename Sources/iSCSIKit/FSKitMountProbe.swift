import Foundation

/// Reading a `mount -F` of the FSKit extension's local test store.
///
/// Setup asks FSKit which modules are installed (`FSClient.installedExtensions`),
/// and FSKit can leave ours out while using it perfectly well: on the SIP-on
/// VM after a reboot and an update (2026-10-05) the list omitted it, yet a
/// `mount -F` started the extension and mounted. Earlier the same state sat on
/// a SIP-off VM for days (docs/backend-a-fskit-notes.md, "An unexplained
/// state"). Attaching depends on `mount -F`, not on the list, so when the list
/// disagrees Setup mounts the extension's own test store — a sparse file in its
/// sandbox, no network — and believes the mount.
public enum FSKitMountProbe {
    public enum Outcome: Equatable, Sendable {
        /// Mounted: registered and enabled.
        case mounts
        /// FSKit knows the module and refuses it: registered, not enabled.
        case disabled
        /// FSKit cannot resolve the module at all.
        case notFound
        /// Anything else, as `mount` printed it.
        case failed(String)
    }

    /// The extension's local test store: host `proto` never reaches a network.
    public static let testURL = "iscsi://proto/setup-probe"

    /// What `mount`'s exit status and output say about the module. The strings
    /// are `mount`'s own (backend-a-fskit-notes: "Module … is disabled!",
    /// "File system named iSCSI not found", "No extension with fsShortName").
    public static func classify(status: Int32, output: String) -> Outcome {
        if status == 0 { return .mounts }
        if output.contains("is disabled") { return .disabled }
        if output.contains("File system named") && output.contains("not found")
            || output.contains("No extension with fsShortName") {
            return .notFound
        }
        let text = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return .failed(text.isEmpty ? "exited \(status)" : text)
    }
}
