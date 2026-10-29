//
//  MountResourceURL.swift
//  The URL `mount -F` hands the FSKit extension: scheme://host[:port]/<target>/<lun>.
//
//  Not the portal string `MountpointTag` hashes. That one is a compatibility
//  contract and stays unbracketed; this one is a URL authority, where an IPv6
//  literal must be bracketed or the whole URL fails to parse. The extension
//  reads it back with `url.host`, which drops the brackets and decodes `%25`,
//  so the daemon is asked for exactly the host string the record holds.
//

import Darwin
import Foundation

public enum MountResourceURL {
    /// nil for a host no login could reach: empty, already bracketed, or
    /// carrying a colon without being an IPv6 literal (a port typed into the
    /// address). The caller explains; a URL built anyway would fail later and
    /// somewhere less obvious.
    public static func make(host: String, port: UInt16, target: String, lun: UInt64) -> URL? {
        let isIPv6 = isIPv6Literal(host)
        guard !host.isEmpty, isIPv6 || !host.contains(where: { ":[]".contains($0) }) else {
            return nil
        }
        var components = URLComponents()
        components.scheme = IQN.isNQN(target) ? "nvme" : "iscsi"
        // URLComponents escapes a scoped address's zone separator (%en0 to %25en0).
        components.host = isIPv6 ? "[\(host)]" : host
        components.port = port == 3260 ? nil : Int(port)
        components.path = "/\(target)/\(lun)"
        return components.url
    }

    /// Darwin's `inet_pton` accepts a `%zone` suffix, and agrees with what
    /// `NWEndpoint.Host` treats as an address rather than a name to resolve.
    private static func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1
    }
}
