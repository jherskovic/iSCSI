import Foundation
import Testing
@testable import iSCSIKit

@Suite("FSKit mount resource URLs")
struct MountResourceURLTests {
    @Test("IPv6 survives URL parsing for both storage protocols",
          arguments: ["fdbd:dc02:d:274::34", "[fdbd:dc02:d:274::34]"],
          ["nqn.2026-10.test:disk0", "iqn.2026-10.test:disk0"])
    func ipv6(host: String, target: String) throws {
        let url = try MountResourceURL.make(host: host, port: 4420, target: target, lun: 1)
        let parsed = try #require(URLComponents(string: url.absoluteString))
        #expect(parsed.scheme == (target.hasPrefix("nqn.") ? "nvme" : "iscsi"))
        #expect(parsed.host == "[fdbd:dc02:d:274::34]")
        #expect(parsed.port == 4420)
        #expect(parsed.path == "/\(target)/1")
    }

    @Test("scoped IPv6 escapes the zone separator")
    func scopedIPv6() throws {
        let url = try MountResourceURL.make(host: "fe80::1%en0", port: 3260,
                                            target: "iqn.test:disk0", lun: 0)
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
        let url = try MountResourceURL.make(host: host, port: port, target: "nqn.test:disk0", lun: 1)
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
        let url = try MountResourceURL.make(host: host, port: 3260, target: "iqn.test:disk0", lun: 0)
        #expect(url.absoluteString == "iscsi://[fdbd:dc02:d:274::34]/iqn.test:disk0/0")
    }

    @Test("IPv4 and DNS retain their existing URL spelling", arguments: ["192.168.0.101", "nas.local"])
    func legacyHosts(host: String) throws {
        let url = try MountResourceURL.make(host: host, port: 3260, target: "iqn.test:disk0", lun: 0)
        #expect(url.absoluteString == "iscsi://\(host)/iqn.test:disk0/0")
        let nvme = try MountResourceURL.make(host: host, port: 4420, target: "nqn.test:disk0", lun: 1)
        #expect(nvme.absoluteString == "nvme://\(host):4420/nqn.test:disk0/1")
    }

    @Test("invalid host is rejected before invoking mount")
    func invalidHost() {
        #expect(throws: URLError.self) {
            try MountResourceURL.make(host: "", port: 4420, target: "nqn.test:disk0", lun: 1)
        }
    }
}
