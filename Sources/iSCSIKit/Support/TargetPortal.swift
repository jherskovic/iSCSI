import Foundation

/// Where a target listens: what a `TargetAddress` names (RFC 7143 §13.8).
///
/// Exists for login redirects. A target that answers status class 1 says
/// where to log in instead, as `domainname[:port][,portal-group-tag]`, and
/// that string has to become a host and a port before anything can connect
/// to it.
public struct TargetPortal: Sendable, Equatable {
    public var host: String
    public var port: UInt16
    public var portalGroupTag: UInt16?

    public init(host: String, port: UInt16 = 3260, portalGroupTag: UInt16? = nil) {
        self.host = host
        self.port = port
        self.portalGroupTag = portalGroupTag
    }

    /// Parse `domainname[:port][,portal-group-tag]`. The domain name is a DNS
    /// name, a dotted-decimal IPv4 address, or a bracketed IPv6 address; the
    /// port defaults to 3260. Anything else is nil rather than a best guess:
    /// a guessed port connects to the wrong service.
    public init?(targetAddress: String) {
        var rest = Substring(targetAddress)

        var tag: UInt16?
        if let comma = rest.lastIndex(of: ",") {
            guard let parsed = UInt16(rest[rest.index(after: comma)...]) else { return nil }
            tag = parsed
            rest = rest[..<comma]
        }

        let host: Substring
        var portText: Substring?
        if rest.hasPrefix("[") {
            guard let close = rest.firstIndex(of: "]") else { return nil }
            host = rest[rest.index(after: rest.startIndex) ..< close]
            let after = rest[rest.index(after: close)...]
            if !after.isEmpty {
                guard after.hasPrefix(":") else { return nil }
                portText = after.dropFirst()
            }
        } else {
            // An unbracketed colon can only introduce the port; a bare IPv6
            // literal is ambiguous and §13.8 requires the brackets.
            let parts = rest.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count <= 2 else { return nil }
            host = parts[0]
            if parts.count == 2 { portText = parts[1] }
        }
        guard !host.isEmpty else { return nil }

        var port: UInt16 = 3260
        if let portText {
            guard let parsed = UInt16(portText), parsed != 0 else { return nil }
            port = parsed
        }
        self.init(host: String(host), port: port, portalGroupTag: tag)
    }

    /// An Address field's text in the spelling a record must hold: trimmed,
    /// and without the brackets a URL habit puts around an IPv6 literal. The
    /// daemon looks targets up by this string and `NWEndpoint.Host` resolves a
    /// bracketed one as a DNS name. No host name contains a bracket, so the
    /// pair is dropped unexamined; a port glued on after it is left for attach
    /// to refuse with a message that says where the port goes.
    public static func host(typed: String) -> String {
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 2, trimmed.hasPrefix("["), trimmed.hasSuffix("]") else {
            return trimmed
        }
        return String(trimmed.dropFirst().dropLast())
    }
}
