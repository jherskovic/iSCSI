import Foundation
import Testing
@testable import NVMeKit

@Suite("Host NQN and HOSTID")
struct HostIdentityTests {
    @Test func uuidFormIsCanonical() {
        let uuid = UUID(uuidString: "0123ABCD-4567-4EF0-8123-456789ABCDEF")!
        let host = NVMeHostIdentity(uuid: uuid)
        #expect(host.nqn == "nqn.2014-08.org.nvmexpress:uuid:0123abcd-4567-4ef0-8123-456789abcdef")
        #expect(host.hostID.count == 16)
        #expect(host.hostID == Data([0x01, 0x23, 0xAB, 0xCD, 0x45, 0x67, 0x4E, 0xF0,
                                     0x81, 0x23, 0x45, 0x67, 0x89, 0xAB, 0xCD, 0xEF]))
    }

    /// Derived, not persisted: the same machine always produces the same
    /// identity, and the platform UUID itself never leaves the machine.
    @Test func derivedIdentityIsStableAndDoesNotLeakThePlatformUUID() {
        let platform = "B3B9F7A2-1C6C-4C0F-9D4E-2E7B1F0C8A11"
        let a = NVMeHostIdentity.derived(fromPlatformUUID: platform)
        let b = NVMeHostIdentity.derived(fromPlatformUUID: platform)
        #expect(a == b)
        #expect(!a.nqn.lowercased().contains(platform.lowercased()))
        #expect(a.nqn.hasPrefix("nqn.2014-08.org.nvmexpress:uuid:"))
        #expect(NQN.isValid(a.nqn))
        let uuid = UUID(uuidString: String(a.nqn.dropFirst("nqn.2014-08.org.nvmexpress:uuid:".count)))
        #expect(uuid != nil)
        #expect(a.hostID == withUnsafeBytes(of: uuid!.uuid) { Data($0) })
        #expect(NVMeHostIdentity.derived(fromPlatformUUID: "other") != a)
        // Case-insensitive on the input: IOKit reports uppercase, nobody should care.
        #expect(NVMeHostIdentity.derived(fromPlatformUUID: platform.lowercased()) == a)
    }

    @Test func nqnSyntax() {
        #expect(NQN.isValid("nqn.2014-08.org.nvmexpress.discovery"))
        #expect(NQN.isValid("nqn.2011-06.com.truenas:disk0"))
        #expect(!NQN.isValid("iqn.2026-08.me.herko:x"))
        #expect(!NQN.isValid("nqn."))
        #expect(!NQN.isValid("nqn.2011-06.com.truenas:" + String(repeating: "a", count: 300)))
        #expect(!NQN.isValid("nqn.2011-06.com.truenas:dis\0k"))
        #expect(NQN.discovery == "nqn.2014-08.org.nvmexpress.discovery")
    }
}
