import Foundation
import Testing
@testable import iSCSIKit

/// Restarting fskitd takes down every FSKit volume on the Mac, in every
/// account (docs/open-questions.md item 14). What counts as one, and how the
/// refusal names them.
@Suite("Restarting fskitd")
struct FSKitRestartTests {
    private let ours = MountTableEntry(
        from: "iscsi://192.168.20.1/iqn.me.herko.planet-express:iscsi-driver-testing/0",
        on: "/Users/another/Library/Caches/me.herko.iSCSIInitiator/b23babc2ec98916d",
        isFSKit: true)

    @Test("every FSKit mount counts, and this app's count even without the flag")
    func whatARestartWouldDisconnect() {
        let usb = MountTableEntry(from: "/dev/disk9s1", on: "/Volumes/USBSTICK", isFSKit: true)
        let unflagged = MountTableEntry(from: "nvme://192.168.20.1:4420/nqn.2011-06.com.truenas:uuid:1:disk/1",
                                        on: "/Users/herko/Library/Caches/me.herko.iSCSIInitiator/0123")
        let apfs = MountTableEntry(from: "/dev/disk3s1", on: "/System/Volumes/Data")
        let autofs = MountTableEntry(from: "map auto_home", on: "/System/Volumes/Data/home")
        #expect(FSKitRestart.mountsItWouldDisconnect([ours, usb, unflagged, apfs, autofs])
                == [ours, usb, unflagged])
        #expect(FSKitRestart.mountsItWouldDisconnect([apfs, autofs]).isEmpty)
    }

    @Test("an update or uninstall counts this app's mounts in every account, and nobody else's")
    func whatReplacingTheAppWouldDisconnect() {
        let usb = MountTableEntry(from: "/dev/disk9s1", on: "/Volumes/USBSTICK", isFSKit: true)
        let unflagged = MountTableEntry(from: "nvme://192.168.20.1:4420/nqn.2011-06.com.truenas:uuid:1:disk/1",
                                        on: "/Users/herko/Library/Caches/me.herko.iSCSIInitiator/0123")
        // The APFS volume DiskImages mounts from lun0.img is not one: the
        // FSKit mount under it is, and stays up as long as it does.
        let image = MountTableEntry(from: "/dev/disk12s1", on: "/Volumes/Planet Express")
        #expect(AppReplacement.mountsItWouldDisconnect([ours, usb, unflagged, image])
                == [ours, unflagged])
        #expect(AppReplacement.mountsItWouldDisconnect([usb, image]).isEmpty)
    }

    @Test("the refusal names this app's disks and whose they are, and anything else by where it is")
    func theRefusalSaysWhat() {
        let usb = MountTableEntry(from: "/dev/disk9s1", on: "/Volumes/USBSTICK", isFSKit: true)
        let refused = FSKitRestart.Refused(mounted: [ours, usb])
        #expect(refused.mounted == [
            "iqn.me.herko.planet-express:iscsi-driver-testing LUN 0 (another's)",
            "/Volumes/USBSTICK",
        ])
        #expect(refused.errorDescription?.contains("in every account") == true)
        #expect(refused.recoverySuggestion?.contains("restart this Mac") == true)
    }
}

/// Uninstall empties the cache directory, which holds URLSession's cache as
/// well as mount points, and must never delete through a mount.
@Suite("Mounted at or below a path")
struct AnyMountedTests {
    private let root = "/Users/herko/Library/Caches/me.herko.iSCSIInitiator"

    @Test("a mount at the path or beneath it counts; a sibling sharing its prefix does not")
    func atOrBelow() {
        let mounts = [MountTableEntry(from: "iscsi://h/iqn.x/0", on: root + "/b23babc2ec98916d"),
                      MountTableEntry(from: "/dev/disk9s1", on: root + "/debris/deeper/still")]
        #expect(MountTableEntry.anyMounted(atOrBelow: root + "/b23babc2ec98916d", in: mounts))
        #expect(MountTableEntry.anyMounted(atOrBelow: root + "/b23babc2ec98916d/", in: mounts))
        #expect(MountTableEntry.anyMounted(atOrBelow: root + "/debris", in: mounts))
        #expect(MountTableEntry.anyMounted(atOrBelow: root, in: mounts))
        #expect(!MountTableEntry.anyMounted(atOrBelow: root + "/b23babc2ec98916", in: mounts))
        #expect(!MountTableEntry.anyMounted(atOrBelow: root + "/Cache.db", in: mounts))
        #expect(!MountTableEntry.anyMounted(atOrBelow: root + "/fsCachedData", in: []))
    }
}
