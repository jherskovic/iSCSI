//
//  FSKitRegistrationAudit.swift
//  Finding the case where the extension is registered *too many times*.
//
//  `mount -F` resolves a module by its FSShortName. When more than one bundle
//  claims `iSCSI`, it cannot pick and reports:
//
//      mount: File system named iSCSI not found
//      (com.apple.extensionKit.errorDomain error 2)
//
//  which reads as "not installed" and sends the user to a Setup screen that
//  correctly reports everything green — because every check it runs is about
//  presence, and presence is not the problem. Being registered twice is.
//
//  Where the copies come from:
//
//    * Building. Every `xcodebuild` leaves a registered copy in DerivedData;
//      fourteen accumulated on the author's Mac in a single day.
//    * A mounted DMG. LaunchServices registers the app inside it, and detaching
//      does not unregister it. A user who leaves the disk image mounted after
//      installing has two, which is enough.
//
//  `pluginkit` will not show this: it deduplicates by bundle identifier and
//  reports one entry. Only LaunchServices sees them all, and FSKit reads
//  LaunchServices.
//
//  The scan costs ~2.3 seconds over a 300k-line dump, so it is deliberately not
//  part of the routine setup checks — it runs when a mount has already failed,
//  where the time is free because the user is stuck anyway.
//

import Foundation

enum FSKitRegistrationAudit {
    private static let lsregister =
        "/System/Library/Frameworks/CoreServices.framework"
        + "/Frameworks/LaunchServices.framework/Support/lsregister"

    /// Every app bundle LaunchServices believes provides our filesystem module.
    /// One is healthy. More than one is the bug.
    static func registeredAppBundles() -> [String] {
        guard let dump = run(lsregister, ["-dump"]) else { return [] }
        var found: Set<String> = []
        for line in dump.split(separator: "\n") {
            guard line.contains("iSCSIFSExtension.appex") else { continue }
            // Records appear as `path: /…/X.app/Contents/Extensions/…appex (0x…)`.
            // Take the containing .app, which is what `lsregister -u` accepts.
            guard let appRange = line.range(of: #"/[^"]*?\.app(?=/Contents/Extensions/)"#,
                                            options: .regularExpression) else { continue }
            found.insert(String(line[appRange]))
        }
        return found.sorted()
    }

    /// Bundles other than the running one. These are the ones to remove.
    static func duplicates() -> [String] {
        let mine = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        return registeredAppBundles().filter {
            URL(fileURLWithPath: $0).resolvingSymlinksInPath().path != mine
        }
    }

    /// Unregister every copy that is not the running app.
    ///
    /// Deliberately never touches the running bundle: removing that would take
    /// a working install down to none, turning a confusing failure into a
    /// complete one.
    @discardableResult
    static func pruneDuplicates() -> [String] {
        let removed = duplicates()
        for bundle in removed {
            _ = run(lsregister, ["-u", bundle])
        }
        return removed
    }

    private static func run(_ path: String, _ arguments: [String]) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            // Drained before waiting: a 300k-line dump fills the pipe buffer,
            // and a child blocked on a full pipe never exits.
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
