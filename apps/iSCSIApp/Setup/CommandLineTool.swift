//
//  CommandLineTool.swift
//  Optional setup step: `iscsictl` on the PATH, by a link in /usr/local/bin.
//
//  A link and not a copy, because an update replaces the bundle at the same
//  path: the link goes on pointing at the current tool with nothing to do,
//  where a copy would go stale. A process started through it is still the
//  signed tool, by its real path, and satisfies the daemon's requirement
//  (26.7.2 VM, 2026-11-04). /usr/local/bin is already in /etc/paths, but it is
//  root's, and a clean Mac does not have it, hence `mkdir -p`.
//
//  An administrator prompt and not a call into iscsid. The daemon could do this
//  with no prompt, but then any account, administrator or not, could change a
//  system directory through it, and a root daemon would carry another path that
//  writes to the filesystem, for the sake of one link.
//
//  `osascript` and not `NSAppleScript`, which is main-thread only and would
//  freeze the app for as long as the password dialog stays up. The cost is that
//  the dialog is headed "osascript", which `with prompt` makes up for.
//
//  No `consentPrompt`: that dialog is the consent, and says what it is for.
//

import Foundation
import iSCSIKit

@MainActor
final class CommandLineTool: SetupStep {
    let id = "command-line"
    let title = "iscsictl on the command line"
    let isOptional = true
    private(set) var state: StepState = .checking
    /// Why the last attempt failed. Cancelling the prompt is not a failure.
    private var failure: String?

    func check() async {
        let path = CommandLineLink.path
        switch Self.currentLink() {
        case .ours:
            failure = nil
            state = .satisfied("\(path) links to this app")
        case .absent:
            state = .actionable(failure ?? "Optional. Adds a link in /usr/local/bin so "
                                + "iscsictl runs from any Terminal, for every account "
                                + "on this Mac. macOS asks for an administrator's password.")
        case .otherLink(let destination):
            state = .blocked("\(path) already links to \(destination), so it is left alone.")
        case .notALink:
            state = .blocked("\(path) already exists and is not a link, so it is left alone.")
        }
    }

    var actionLabel: String? {
        if case .actionable = state { return "Add Link" }
        return nil
    }

    func perform() async {
        failure = nil
        let tool = Self.tool
        // Off the main actor, like every subprocess the app waits on: this one
        // waits for a person to type a password.
        let outcome = await Task.detached {
            Self.asAdministrator(Self.addScript, arguments: [tool])
        }.value
        if case .failed(let why) = outcome {
            failure = "The link could not be added: \(why)"
        }
    }

    // MARK: - Shared with the uninstaller

    enum Outcome: Sendable, Equatable {
        case done
        case cancelled
        case failed(String)
    }

    /// The tool in this copy of the app.
    nonisolated static var tool: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/iscsictl").path
    }

    /// `lstat`, not `fileExists`, which follows the link and calls a dangling
    /// one absent; adding a link over it would then fail with "File exists".
    nonisolated static func currentLink() -> CommandLineLink {
        var info = stat()
        return .decide(exists: lstat(CommandLineLink.path, &info) == 0,
                       destination: try? FileManager.default
                           .destinationOfSymbolicLink(atPath: CommandLineLink.path),
                       tool: tool)
    }

    /// Only after `currentLink()` says `.ours`: the caller is what makes this
    /// safe, and `rm` with no flags is what keeps a mistake small.
    nonisolated static func removeLink() async -> Outcome {
        await Task.detached { asAdministrator(removeScript) }.value
    }

    // MARK: - Privileged commands

    /// The path comes in through `argv` and `quoted form of`, because it has a
    /// space in it and the app can be renamed. No `-f`: `ln` refuses to replace
    /// whatever appeared after the check.
    private nonisolated static let addScript = """
        on run argv
            do shell script "/bin/mkdir -p /usr/local/bin && /bin/ln -s " ¬
                & quoted form of (item 1 of argv) & " \(CommandLineLink.path)" ¬
                with prompt "iSCSI/NVMe/TCP Initiator wants to add the iscsictl command to /usr/local/bin." ¬
                with administrator privileges
        end run
        """

    private nonisolated static let removeScript = """
        do shell script "/bin/rm \(CommandLineLink.path)" ¬
            with prompt "iSCSI/NVMe/TCP Initiator wants to remove the iscsictl command from /usr/local/bin." ¬
            with administrator privileges
        """

    private nonisolated static func asAdministrator(
        _ script: String, arguments: [String] = []
    ) -> Outcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script] + arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return .failed(error.localizedDescription)
        }
        let output = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return .done }

        // `0:17: execution error: User canceled. (-128)`
        let text = String(decoding: output, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasSuffix("(-128)") { return .cancelled }
        return .failed(text.components(separatedBy: "execution error: ").last ?? text)
    }
}
