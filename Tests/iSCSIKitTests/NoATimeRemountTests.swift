import Darwin
import Testing
@testable import iSCSIKit

/// Rebuilding a volume's mount options so `mount -u` adds `noatime` and
/// changes nothing else. `mount -u` keeps only what it is given: measured
/// 2026-10-31, a bare `-o noatime` dropped `noowners` from a disk image's APFS
/// volume, and the user's writes to it were then refused.
@Suite("noatime remount options")
struct NoATimeRemountTests {

    private static func flags(_ bits: Int32...) -> UInt32 {
        bits.reduce(0) { $0 | UInt32(bitPattern: $1) }
    }

    /// What Disk Arbitration gives a disk image's APFS volume, as `mount`
    /// showed it: local, nodev, nosuid, journaled, noowners.
    @Test("a default disk image mount keeps noowners, nosuid and nodev")
    func defaultDiskImageMount() {
        let f = Self.flags(MNT_LOCAL, MNT_NODEV, MNT_NOSUID, MNT_JOURNALED, MNT_IGNORE_OWNERSHIP)
        #expect(NoATimeRemount.options(forMountFlags: f) == "noatime,noowners,nosuid,nodev")
    }

    @Test("a read-only volume stays read-only")
    func readOnlyIsKept() {
        let f = Self.flags(MNT_RDONLY, MNT_NODEV, MNT_NOSUID, MNT_IGNORE_OWNERSHIP)
        #expect(NoATimeRemount.options(forMountFlags: f) == "noatime,rdonly,noowners,nosuid,nodev")
    }

    @Test("noexec, nobrowse and sync are kept")
    func otherUserVisibleOptionsAreKept() {
        let f = Self.flags(MNT_NOEXEC, MNT_DONTBROWSE, MNT_SYNCHRONOUS)
        #expect(NoATimeRemount.options(forMountFlags: f) == "noatime,noexec,nobrowse,sync")
    }

    @Test("a mount with none of the kept options gets noatime alone")
    func bareMount() {
        #expect(NoATimeRemount.options(forMountFlags: Self.flags(MNT_LOCAL, MNT_JOURNALED)) == "noatime")
    }

    @Test("an existing noatime mount is left alone")
    func alreadyNoATime() {
        #expect(NoATimeRemount.options(forMountFlags: Self.flags(MNT_NOATIME, MNT_IGNORE_OWNERSHIP)) == nil)
    }

    /// `mount -o` has no name for quarantine, so a remount could clear it.
    @Test("a quarantined volume is left alone")
    func quarantinedIsNotTouched() {
        #expect(NoATimeRemount.options(forMountFlags: Self.flags(MNT_QUARANTINE, MNT_NOSUID)) == nil)
    }

    @Test("an explicit strictatime mount is left alone")
    func strictATimeIsRespected() {
        #expect(NoATimeRemount.options(forMountFlags: NoATimeRemount.strictATime) == nil)
    }

    /// The constant is spelled out in the source; pin it to the SDK's.
    @Test("the strictatime constant matches the SDK")
    func strictATimeConstant() {
        #expect(NoATimeRemount.strictATime == UInt32(truncatingIfNeeded: MNT_STRICTATIME))
    }
}
