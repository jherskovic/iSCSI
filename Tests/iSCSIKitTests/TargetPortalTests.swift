//
//  TargetPortalTests.swift
//
//  A login redirect is only as good as our reading of its TargetAddress: a
//  misparsed port or a mangled IPv6 literal sends the reconnect somewhere
//  that is not the target, and the error that comes back blames the network.
//

import Testing
@testable import iSCSIKit

@Suite("TargetAddress parsing (RFC 7143 §13.8)")
struct TargetPortalTests {

    @Test("address, port and portal group tag")
    func full() {
        #expect(TargetPortal(targetAddress: "192.168.1.31:3261,2")
                == TargetPortal(host: "192.168.1.31", port: 3261, portalGroupTag: 2))
    }

    @Test("the port defaults to 3260")
    func defaultPort() {
        #expect(TargetPortal(targetAddress: "192.168.1.31")
                == TargetPortal(host: "192.168.1.31", port: 3260))
        #expect(TargetPortal(targetAddress: "192.168.1.31,1")
                == TargetPortal(host: "192.168.1.31", port: 3260, portalGroupTag: 1))
    }

    @Test("a DNS name is kept as a name")
    func dnsName() {
        #expect(TargetPortal(targetAddress: "member2.san.example:3260,1")
                == TargetPortal(host: "member2.san.example", port: 3260, portalGroupTag: 1))
    }

    @Test("bracketed IPv6 loses its brackets, keeps its colons")
    func ipv6() {
        #expect(TargetPortal(targetAddress: "[2001:db8::31]:3261,1")
                == TargetPortal(host: "2001:db8::31", port: 3261, portalGroupTag: 1))
        #expect(TargetPortal(targetAddress: "[fe80::1]")
                == TargetPortal(host: "fe80::1", port: 3260))
    }

    @Test("malformed addresses are refused, not guessed at",
          arguments: ["", ",1", ":3260", "[2001:db8::1", "[]:3260", "[2001:db8::1]x",
                      "host:", "host:0", "host:65536", "host:http", "host:3260,",
                      "host:3260,tag", "host:3260,70000", "2001:db8::1"])
    func malformed(_ address: String) {
        #expect(TargetPortal(targetAddress: address) == nil)
    }
}

/// The Address field, as typed, against the host string a record must hold:
/// the daemon looks targets up by it and Network.framework connects to it, and
/// neither accepts the brackets a URL habit puts around an IPv6 address.
@Suite("Typed target addresses")
struct TypedHostTests {

    @Test("surrounding whitespace and an IPv6 literal's brackets are dropped",
          arguments: [(" nas.local ", "nas.local"),
                      ("192.168.20.1", "192.168.20.1"),
                      ("[fdbd:dc02:d:274::34]", "fdbd:dc02:d:274::34"),
                      (" [fe80::1%en0] ", "fe80::1%en0")])
    func normalized(typed: String, host: String) {
        #expect(TargetPortal.host(typed: typed) == host)
    }

    /// Left for attach to refuse with a message that says where the port goes.
    @Test("a bracketed address with a port glued on is left alone")
    func gluedPort() {
        #expect(TargetPortal.host(typed: "[fdbd::34]:3261") == "[fdbd::34]:3261")
    }
}
