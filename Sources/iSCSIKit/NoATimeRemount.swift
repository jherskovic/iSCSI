//
//  NoATimeRemount.swift
//  The mount options that turn off access-time updates on an attached volume
//  without changing anything else about the mount.
//
//  Why: on a default mount, reading a file can update its access time, and on
//  a LUN every such update is a metadata write to the target — on the network,
//  and with write-through, waited for. Read-heavy work (issue #4's Rust builds
//  read thousands of `.rlib` files) pays for writes nobody asked for. Measured
//  on a disk image's APFS volume, 2026-10-31: a read moved the access time on
//  a default mount and left it alone under `noatime`.
//
//  How: `hdiutil attach` cannot pass mount options (neither its man page nor
//  its binary has one; `diskutil image attach --mountOptions` can, but that is
//  not the attach path), so the app remounts each volume with `mount -u`.
//  And `mount -u` does not keep options it is not given: `-o noatime` alone
//  dropped `noowners`, and the volume then refused the user's own writes. So
//  the options are rebuilt from the mount's current flags, plus `noatime`.
//

import Darwin

public enum NoATimeRemount {

    /// Flags carried into the remount, with the `mount -o` names for them, in
    /// the order they are emitted.
    private static let preserved: [(flag: UInt32, option: String)] = [
        (bit(MNT_RDONLY), "rdonly"),            // never upgrade a read-only volume
        (bit(MNT_IGNORE_OWNERSHIP), "noowners"), // what lets the user write to it
        (bit(MNT_NOSUID), "nosuid"),
        (bit(MNT_NODEV), "nodev"),
        (bit(MNT_NOEXEC), "noexec"),
        (bit(MNT_DONTBROWSE), "nobrowse"),
        (bit(MNT_SYNCHRONOUS), "sync"),
    ]

    /// The `-o` argument for `mount -u` that adds `noatime` and keeps the
    /// mount's other options, or nil when the volume should be left alone:
    /// - already `noatime`: nothing to do;
    /// - quarantined: `mount -o` has no name for quarantine, so a remount
    ///   could clear it, and that is a security property, not a tuning one;
    /// - `strictatime`: someone asked for access times explicitly.
    public static func options(forMountFlags flags: UInt32) -> String? {
        if flags & bit(MNT_NOATIME) != 0 { return nil }
        if flags & bit(MNT_QUARANTINE) != 0 { return nil }
        if flags & strictATime != 0 { return nil }
        let kept = preserved.filter { flags & $0.flag != 0 }.map(\.option)
        return (["noatime"] + kept).joined(separator: ",")
    }

    /// `MNT_STRICTATIME` is 0x80000000, which does not fit the `Int32` the
    /// other `MNT_` macros import as; spelled out rather than depend on how
    /// the importer types it.
    static let strictATime: UInt32 = 0x8000_0000

    private static func bit(_ flag: Int32) -> UInt32 { UInt32(bitPattern: flag) }
}
