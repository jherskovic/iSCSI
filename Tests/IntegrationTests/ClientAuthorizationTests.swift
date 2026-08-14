//
//  ClientAuthorizationTests.swift
//
//  The requirement string is a string. Nothing in the compiler checks it, and
//  the API that consumes it — setCodeSigningRequirement — does not throw on a
//  malformed one: it raises an Objective-C exception that Swift cannot catch.
//  So a typo here is a daemon that either crashes on first connection or, worse,
//  fails open in a way nobody notices.
//
//  These tests are the only thing standing between a typo and that.
//

import Foundation
import Security
import Testing
@testable import iSCSIDaemon

@Suite("XPC client authorization")
struct ClientAuthorizationTests {

    @Test("the requirement string parses as a code requirement")
    func requirementParses() throws {
        var parsed: SecRequirement?
        let status = SecRequirementCreateWithString(
            ClientAuthorization.requirement as CFString, [], &parsed)

        // Comment is not ExpressibleByStringInterpolation, so build it
        // explicitly — the requirement text is the whole point of the message.
        #expect(status == errSecSuccess,
                Comment(rawValue: "SecRequirementCreateWithString rejected: "
                        + ClientAuthorization.requirement))
        #expect(parsed != nil)
    }

    @Test("isWellFormed agrees with the Security framework")
    func wellFormedMatchesSecurity() {
        #expect(ClientAuthorization.isWellFormed(ClientAuthorization.requirement))
        #expect(!ClientAuthorization.isWellFormed("this is not a requirement"))
        // Unbalanced parenthesis — the shape a typo in the identifier list takes.
        #expect(!ClientAuthorization.isWellFormed(
            "anchor apple generic and (identifier \"a\""))
    }

    @Test("the requirement pins the team")
    func pinsTeam() {
        #expect(ClientAuthorization.requirement.contains(
            "certificate leaf[subject.OU] = \"4A27X5PJP3\""))
    }

    /// The distinction that makes this a real check rather than a gesture. An
    /// Apple Development certificate for the same team satisfies a bare
    /// team-identifier requirement, and those are handed to everyone on a team
    /// and sit on every machine with Xcode signed in. The Developer ID OIDs are
    /// what exclude them.
    @Test("the requirement demands Developer ID, not merely the right team")
    func demandsDeveloperID() {
        let requirement = ClientAuthorization.requirement
        #expect(requirement.contains("1.2.840.113635.100.6.2.6"),
                "missing the Developer ID intermediate OID")
        #expect(requirement.contains("1.2.840.113635.100.6.1.13"),
                "missing the Developer ID Application leaf OID")
    }

    @Test("only the app and the FSKit extension are allowed")
    func allowsExactlyTheTwoClients() {
        #expect(ClientAuthorization.allowedIdentifiers.sorted() == [
            "me.herko.iSCSIInitiator",
            "me.herko.iSCSIInitiator.fsext",
        ])
        // iscsictl is ad-hoc signed by `swift build`; a root daemon must not
        // accept a binary that anyone can produce.
        #expect(!ClientAuthorization.allowedIdentifiers.contains { $0.contains("iscsictl") })
    }

    @Test("every allowed identifier appears in the requirement")
    func identifiersReachTheRequirement() {
        for identifier in ClientAuthorization.allowedIdentifiers {
            #expect(ClientAuthorization.requirement.contains("identifier \"\(identifier)\""))
        }
    }
}
