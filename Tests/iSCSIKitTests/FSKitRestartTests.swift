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
