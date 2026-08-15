//
//  MountpointTagTests.swift
//
//  This is a compatibility test, not a correctness test. The derivation is not
//  "right" in any absolute sense — it is right because it matches what the shell
//  scripts produced, and every volume attached before this code existed lives at
//  a path named by that older derivation.
//
//  If one of these fails, the fix is almost never to update the expectation.
//

import Foundation
import Testing
@testable import iSCSIKit

@Suite("Mountpoint tag compatibility")
struct MountpointTagTests {

    /// Golden value taken from the shell derivation this replaced:
    ///
    ///     $ printf '%s|%s|%s' "192.168.0.101" "iqn.2026-08.me.herko:disk0" "0" \
    ///         | shasum -a 256 | cut -c1-16
    ///     2d1215fedb21fea9
    ///
    /// Changing the derivation strands every volume attached by an older
    /// version: it stops being recognised as attached, detach cannot find it,
    /// and attaching again stacks a second mount on a path already in use.
    @Test("matches the shell derivation byte for byte")
    func matchesShellGolden() {
        #expect(MountpointTag.derive(portal: "192.168.0.101",
                                     targetIQN: "iqn.2026-08.me.herko:disk0",
                                     lun: 0) == "2d1215fedb21fea9")
    }

    @Test("the tag is 16 lowercase hex characters")
    func shape() {
        let tag = MountpointTag.derive(portal: "nas.local", targetIQN: "iqn.x", lun: 3)
        #expect(tag.count == 16)
        #expect(tag.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    /// Each of the three inputs must actually participate, or two different
    /// targets would share a mount point and detaching one would tear down the
    /// other.
    @Test("portal, target and LUN each change the tag")
    func everyInputParticipates() {
        let base = MountpointTag.derive(portal: "a", targetIQN: "b", lun: 0)
        #expect(MountpointTag.derive(portal: "z", targetIQN: "b", lun: 0) != base)
        #expect(MountpointTag.derive(portal: "a", targetIQN: "z", lun: 0) != base)
        #expect(MountpointTag.derive(portal: "a", targetIQN: "b", lun: 1) != base)
    }

    /// The scripts were handed a bare host, so anything configured before this
    /// code existed hashed a bare host. Spelling the default port explicitly
    /// would compute a different tag for the same target.
    @Test("the default port is omitted from the portal string")
    func defaultPortIsImplicit() {
        #expect(MountpointTag.portal(host: "nas.local", port: 3260) == "nas.local")
        #expect(MountpointTag.portal(host: "nas.local", port: 3261) == "nas.local:3261")

        #expect(MountpointTag.derive(portal: MountpointTag.portal(host: "192.168.0.101",
                                                                  port: 3260),
                                     targetIQN: "iqn.2026-08.me.herko:disk0",
                                     lun: 0) == "2d1215fedb21fea9")
    }
}
