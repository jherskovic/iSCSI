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
    static let portal = "192.168.20.1"

    static func record(_ id: String = "t1", lun: UInt64 = 0, chapUser: String? = nil,
                       iqn: String = iqn, host: String = portal,
                       port: UInt16 = 3260) -> TargetRecord {
        TargetRecord(id: id, displayName: "testing", host: host, port: port,
                     targetIQN: iqn, lun: lun, chapUser: chapUser)
    }

    @Test("a target not saved yet is offered for adding")
    func notSaved() {
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [], chapUser: "herko", chapSecret: Self.secret)
                == .add)
    }

    @Test("a saved target with nothing typed stays as it is")
    func savedNothingTyped() {
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [Self.record()], chapUser: "", chapSecret: "")
                == .saved)
    }

    /// The case that was reported: saved before the target required CHAP,
    /// then discovered with credentials.
    @Test("a target saved without CHAP takes the credentials Discover holds")
    func savedWithoutCHAP() {
        let saved = Self.record()
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [saved], chapUser: "herko", chapSecret: Self.secret)
                == .updateCredentials([saved]))
    }

    @Test("a target saved under another CHAP user takes the typed one")
    func savedWithOtherUser() {
        let saved = Self.record(chapUser: "someone-else")
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [saved], chapUser: "herko", chapSecret: Self.secret)
                == .updateCredentials([saved]))
    }

    /// The stored secret cannot be read back to compare, and re-saving it on
    /// every discovery would silently replace a secret changed in the editor.
    @Test("a target saved under the same CHAP user stays as it is")
    func savedWithSameUser() {
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [Self.record(chapUser: "herko")],
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
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [lun0, lun1, other],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .updateCredentials([lun1]))
    }

    /// The credentials authenticated at the portal in the Discover form, and
    /// a secret is bound to the address it is spent at: the daemon sends a
    /// record's CHAP responses to that record's host. IQNs are not
    /// authenticated, so a portal can name any target; matching on the IQN
    /// alone would hand these credentials to whatever host a same-named
    /// record points at.
    @Test("a same-named target saved at another host does not take them")
    func otherHostIsNotUpdated() {
        let elsewhere = Self.record(host: "192.168.20.199")
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [elsewhere],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .saved)
    }

    @Test("a same-named target saved on another port does not take them")
    func otherPortIsNotUpdated() {
        let elsewhere = Self.record(port: 3261)
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [elsewhere],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .saved)
    }

    @Test("of two same-named records, only the one at this portal takes them")
    func onlyThisPortal() {
        let here = Self.record("here")
        let elsewhere = Self.record("there", host: "nas.example")
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [here, elsewhere],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .updateCredentials([here]))
    }

    /// A secret no target honours must not be saved from here either; the
    /// editor enforces the same floor.
    @Test("credentials that would not validate are not offered",
          arguments: [("herko", "short"), ("herko", ""), ("", "mimamamemima")])
    func unusableCredentials(_ user: String, _ secret: String) {
        #expect(DiscoveryOffer.for(Self.iqn, at: Self.portal, port: 3260, saved: [Self.record()], chapUser: user, chapSecret: secret)
                == .saved)
    }

    @Test("NVMe subsystems never take CHAP from Discover")
    func nvmeHasNoCHAP() {
        let nqn = "nqn.2011-06.com.truenas:uuid:abc:name-testing"
        #expect(DiscoveryOffer.for(nqn, at: Self.portal, port: 4420, saved: [Self.record(iqn: nqn)],
                                   chapUser: "herko", chapSecret: Self.secret)
                == .saved)
    }
}
