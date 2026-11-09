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

    /// What a mount URL asks the extension for.
    public enum Destination: Equatable, Sendable {
        /// Host `proto`: the local sparse file, for telling FSKit problems
        /// from network ones.
        case prototype
        /// A session through the daemon. `host` is `url.host`: brackets
        /// dropped and `%25` decoded, which is the record's spelling.
        case daemon(host: String, port: Int, target: String, unit: UInt64)
    }

    /// Reads back what `make` built; nil for anything else. Strict on
    /// purpose: `mount(8)` needs no privilege, so this is caller input, and
    /// the old reading turned a malformed unit ("1a", "-1") or a missing one
    /// into LUN 0, and a URL with no host into the prototype's local file —
    /// each one a volume that looks attached and is something else.
    public static func parse(_ url: URL) -> Destination? {
        guard let host = url.host, !host.isEmpty else { return nil }
        if host == "proto" { return .prototype }
        // /<target>/<unit>: an IQN and LUN, or an NQN and namespace ID.
        // Neither name contains a slash. The scheme is not consulted; the
        // daemon tells the protocols apart by the name's prefix.
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty,
              parts[1].allSatisfy(\.isASCII), let unit = UInt64(parts[1]) else { return nil }
        return .daemon(host: host, port: url.port ?? 3260, target: parts[0], unit: unit)
    }

    /// Darwin's `inet_pton` accepts a `%zone` suffix, and agrees with what
    /// `NWEndpoint.Host` treats as an address rather than a name to resolve.
    private static func isIPv6Literal(_ host: String) -> Bool {
        var address = in6_addr()
        return inet_pton(AF_INET6, host, &address) == 1
    }
}
