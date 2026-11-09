import Foundation
import Testing
@testable import iSCSIKit

@Suite("FSKit mount resource URLs")
struct MountResourceURLTests {
    @Test("IPv6 survives URL parsing for both storage protocols",
          arguments: ["nqn.2026-10.test:disk0", "iqn.2026-10.test:disk0"])
    func ipv6(target: String) throws {
        let host = "fdbd:dc02:d:274::34"
        let url = try #require(MountResourceURL.make(host: host, port: 4420, target: target, lun: 1))
        let parsed = try #require(URLComponents(string: url.absoluteString))
        #expect(parsed.scheme == (target.hasPrefix("nqn.") ? "nvme" : "iscsi"))
        #expect(parsed.host == "[fdbd:dc02:d:274::34]")
        #expect(parsed.port == 4420)
        #expect(parsed.path == "/\(target)/1")
    }

    @Test("scoped IPv6 escapes the zone separator")
    func scopedIPv6() throws {
        let url = try #require(MountResourceURL.make(host: "fe80::1%en0", port: 3260,
                                                     target: "iqn.test:disk0", lun: 0))
        #expect(url.absoluteString == "iscsi://[fe80::1%25en0]/iqn.test:disk0/0")
    }

    /// Reads the URL the way the extension's `makeStore` does — `url.host`,
    /// `url.port ?? 3260`, the path split on `/` — because the daemon looks the
    /// target up by that host string. A bracket left on, or a `%25` left
    /// encoded, refuses the login as "not configured".
    @Test("the extension reads back the host and port the target record holds",
          arguments: ["fdbd:dc02:d:274::34", "fe80::1%en0", "192.168.0.101", "nas.local"],
          [UInt16(3260), 4420])
    func extensionRoundTrip(host: String, port: UInt16) throws {
        let url = try #require(MountResourceURL.make(host: host, port: port, target: "nqn.test:disk0", lun: 1))
        let parsed = try #require(URL(string: url.absoluteString))
        #expect(parsed.host == host)
        #expect((parsed.port ?? 3260) == Int(port))
        #expect(parsed.path.split(separator: "/") == ["nqn.test:disk0", "1"])
    }

    @Test("IPv6 URL formatting leaves legacy mountpoint identity unchanged")
    func legacyIPv6Identity() throws {
        let host = "fdbd:dc02:d:274::34"
        let portal = MountpointTag.portal(host: host, port: 4420)
        #expect(portal == "fdbd:dc02:d:274::34:4420")
        #expect(MountpointTag.portal(host: host, port: 3260) == host)
        let url = try #require(MountResourceURL.make(host: host, port: 3260, target: "iqn.test:disk0", lun: 0))
        #expect(url.absoluteString == "iscsi://[fdbd:dc02:d:274::34]/iqn.test:disk0/0")
    }

    @Test("IPv4 and DNS retain their existing URL spelling", arguments: ["192.168.0.101", "nas.local"])
    func legacyHosts(host: String) throws {
        let url = try #require(MountResourceURL.make(host: host, port: 3260, target: "iqn.test:disk0", lun: 0))
        #expect(url.absoluteString == "iscsi://\(host)/iqn.test:disk0/0")
        let nvme = try #require(MountResourceURL.make(host: host, port: 4420, target: "nqn.test:disk0", lun: 1))
        #expect(nvme.absoluteString == "nvme://\(host):4420/nqn.test:disk0/1")
    }

    /// None of these can log in — the daemon would look a bracketed host up
    /// as typed and resolve it as a DNS name, and a glued port is part of no
    /// host — so attach refuses them with its own message instead of building
    /// a URL that fails somewhere less obvious.
    @Test("a host that is not a name, IPv4 or IPv6 address is refused",
          arguments: ["[fdbd:dc02:d:274::34]", "192.168.20.1:3261", "nas.local:3260"])
    func refusedHosts(host: String) {
        #expect(MountResourceURL.make(host: host, port: 3260, target: "iqn.test:disk0", lun: 0) == nil)
    }

    @Test("invalid host is rejected before invoking mount")
    func invalidHost() {
        #expect(MountResourceURL.make(host: "", port: 4420, target: "nqn.test:disk0", lun: 1) == nil)
    }

    @Test("what make builds, parse reads back, IPv6 and NVMe included")
    func roundTrip() throws {
        for (host, port, target, unit) in [
            ("192.168.20.1", UInt16(3260), "iqn.2005-10.org.freenas.ctl:disk", UInt64(0)),
            ("fe80::1%en0", 3261, "iqn.2005-10.org.freenas.ctl:disk", 7),
            ("nas.local", 4420, "nqn.2011-06.com.truenas:uuid:1:disk", 1),
        ] {
            let url = try #require(MountResourceURL.make(host: host, port: port, target: target, lun: unit))
            #expect(MountResourceURL.parse(url) == .daemon(host: host, port: Int(port),
                                                            target: target, unit: unit))
        }
    }

    @Test("host proto is the local prototype, whatever its path")
    func prototype() throws {
        #expect(MountResourceURL.parse(try #require(URL(string: "iscsi://proto/lun0"))) == .prototype)
    }

    @Test("a malformed or missing unit, or no host, is refused rather than guessed")
    func malformed() throws {
        for raw in [
            "iscsi://nas/iqn.x/1a",
            "iscsi://nas/iqn.x/-1",
            "iscsi://nas/iqn.x/",
            "iscsi://nas/iqn.x",
            "iscsi://nas/iqn.x/0/extra",
            "iscsi://nas/iqn.x/\u{0661}",   // an Arabic-Indic one: a digit, not ASCII
            "iscsi:/iqn.x/0",
            "iscsi:///iqn.x/0",
        ] {
            let url = try #require(URL(string: raw), "\(raw) is not a URL at all")
            #expect(MountResourceURL.parse(url) == nil, "\(raw)")
        }
    }
}
