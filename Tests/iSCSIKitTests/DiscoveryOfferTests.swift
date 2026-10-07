//
//  DiscoveryOfferTests.swift
//
//  Discover used to show an already-saved target as "Added" whatever was
//  typed into its CHAP fields. Credentials that had just listed the target
//  went nowhere, the saved record still had no CHAP user, and the next attach
//  offered AuthMethod=None and was refused — with nothing on screen saying
//  the credentials had not been kept.
//

import Testing
@testable import iSCSIKit

@Suite("What Discover offers for a target it found")
struct DiscoveryOfferTests {
    static let iqn = "iqn.me.herko.planet-express:iscsi-driver-testing"
    static let secret = "mimamamemima"

    static func record(_ id: String = "t1", lun: UInt64 = 0, chapUser: String? = nil,
                       iqn: String = iqn) -> TargetRecord {
        TargetRecord(id: id, displayName: "testing", host: "192.168.20.1",
                     targetIQN: iqn, lun: lun, chapUser: chapUser)
    }

    @Test("a target not saved yet is offered for adding")
    func notSaved() {
        #expect(DiscoveryOffer.for(Self.iqn, saved: [], chapUser: "herko", chapSecret: Self.secret)
                == .add)
    }

    @Test("a saved target with nothing typed stays as it is")
    func savedNothingTyped() {
        #expect(DiscoveryOffer.for(Self.iqn, saved: [Self.record()], chapUser: "", chapSecret: "")
                == .saved)
    }

    /// The case that was reported: saved before the target required CHAP,
    /// then discovered with credentials.
    @Test("a target saved without CHAP takes the credentials Discover holds")
    func savedWithoutCHAP() {
        let saved = Self.record()
        #expect(DiscoveryOffer.for(Self.iqn, saved: [saved], chapUser: "herko", chapSecret: Self.secret)
                == .updateCredentials([saved]))
    }

    @Test("a target saved under another CHAP user takes the typed one")
    func savedWithOtherUser() {
        let saved = Self.record(chapUser: "someone-else")
        #expect(DiscoveryOffer.for(Self.iqn, saved: [saved], chapUser: "herko", chapSecret: Self.secret)
                == .updateCredentials([saved]))
    }

    /// The stored secret cannot be read back to compare, and re-saving it on
    /// every discovery would silently replace a secret changed in the editor.
    @Test("a target saved under the same CHAP user stays as it is")
    func savedWithSameUser() {
        #expect(DiscoveryOffer.for(Self.iqn, saved: [Self.record(chapUser: "herko")],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .saved)
    }

    /// Every LUN of the target authenticates the same way; only the records
    /// that differ need the update.
    @Test("only the saved LUNs that lack these credentials are updated")
    func severalLUNs() {
        let lun0 = Self.record("a", lun: 0, chapUser: "herko")
        let lun1 = Self.record("b", lun: 1)
        let other = Self.record("c", iqn: "iqn.me.herko.planet-express:zoidberg")
        #expect(DiscoveryOffer.for(Self.iqn, saved: [lun0, lun1, other],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .updateCredentials([lun1]))
    }

    /// A secret no target honours must not be saved from here either; the
    /// editor enforces the same floor.
    @Test("credentials that would not validate are not offered",
          arguments: [("herko", "short"), ("herko", ""), ("", "mimamamemima")])
    func unusableCredentials(_ user: String, _ secret: String) {
        #expect(DiscoveryOffer.for(Self.iqn, saved: [Self.record()], chapUser: user, chapSecret: secret)
                == .saved)
    }

    @Test("NVMe subsystems never take CHAP from Discover")
    func nvmeHasNoCHAP() {
        let nqn = "nqn.2011-06.com.truenas:uuid:abc:name-testing"
        #expect(DiscoveryOffer.for(nqn, saved: [Self.record(iqn: nqn)],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .saved)
    }
}
