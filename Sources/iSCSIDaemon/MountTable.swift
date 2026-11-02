//
//  MountTable.swift
//  Every mount on the Mac, every account's, as the daemon sees it.
//
//  The app reads the same table for its own purposes (AttachmentManager);
//  the daemon needs it for the one thing it does that reaches past a single
//  user: restarting fskitd (`FSKitRestart`).
//

#if canImport(Darwin)
import Darwin
import iSCSIKit

enum MountTable {
    /// getmntinfo with a buffer of our own and `MNT_NOWAIT`, so a wedged
    /// network volume cannot block it.
    static func read() -> [MountTableEntry] {
        var buffer: UnsafeMutablePointer<statfs>?
        let count = getmntinfo_r_np(&buffer, MNT_NOWAIT)
        guard let buffer else { return [] }
        defer { free(buffer) }
        guard count > 0 else { return [] }
        return (0 ..< Int(count)).map { index in
            var entry = buffer[index]
            return MountTableEntry(from: cString(&entry.f_mntfromname),
                                   on: cString(&entry.f_mntonname),
                                   isFSKit: entry.f_flags_ext & UInt32(MNT_EXT_FSKIT) != 0)
        }
    }

    private static func cString<T>(_ field: inout T) -> String {
        withUnsafeBytes(of: &field) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    }
}
#endif
