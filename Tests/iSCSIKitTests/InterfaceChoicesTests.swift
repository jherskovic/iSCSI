import Foundation
import Testing
@testable import iSCSIKit

@Suite("Interface picker rows")
struct InterfaceChoicesTests {

    private static let snapshot = InterfaceSnapshot(
        present: ["lo0", "en0", "en2", "en10", "en7"],
        addresses: [
            InterfaceAddress(name: "lo0", address: "127.0.0.1", isIPv6: false),
            InterfaceAddress(name: "en10", address: "fe80::1%en10", isIPv6: true),
            InterfaceAddress(name: "en10", address: "192.168.20.2", isIPv6: false),
            InterfaceAddress(name: "en2", address: "2001:db8::5", isIPv6: true),
            InterfaceAddress(name: "en0", address: "192.168.0.22", isIPv6: false),
            InterfaceAddress(name: "en7", address: "169.254.3.4", isIPv6: false),
        ])

    @Test("only interfaces with a usable address are offered, in natural order")
    func offersAddressedInterfacesNaturally() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot, displayNames: [:], stored: nil)
        #expect(rows.map(\.name) == ["en0", "en2", "en10"],
                "lo0 and the link-local-only en7 are left out; en2 sorts before en10")
    }

    @Test("a row shows the display name, the BSD name and an IPv4 address first")
    func labelsReadLikeSystemSettings() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot,
                                         displayNames: ["en10": "USB 10GbE", "en0": "Wi-Fi"],
                                         stored: nil)
        #expect(rows.first { $0.name == "en10" }?.label == "USB 10GbE (en10) — 192.168.20.2")
        #expect(rows.first { $0.name == "en0" }?.label == "Wi-Fi (en0) — 192.168.0.22")
        #expect(rows.first { $0.name == "en2" }?.label == "en2 — 2001:db8::5")
    }

    @Test("a stored interface that is gone stays listed, marked not present")
    func storedAbsentInterfaceIsKept() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot,
                                         displayNames: ["en18": "USB 10GbE"], stored: "en18")
        #expect(rows.last == InterfaceChoice(name: "en18", label: "USB 10GbE (en18) — not present"))
    }

    @Test("a stored interface that is present without an address says so")
    func storedAddresslessInterfaceIsKept() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot, displayNames: [:], stored: "en7")
        #expect(rows.last == InterfaceChoice(name: "en7", label: "en7 — no address"))
    }

    @Test("a stored interface that is offered anyway is not listed twice")
    func storedPresentInterfaceIsNotDuplicated() {
        let rows = InterfaceChoices.list(snapshot: Self.snapshot, displayNames: [:], stored: "en0")
        #expect(rows.filter { $0.name == "en0" }.count == 1)
    }
}
