import Foundation

/// iSCSI node-name helpers (RFC 3721 / RFC 7143 §4.2.7). An iqn-format name is
/// `iqn.yyyy-mm.reverse.domain:identifier`, lowercase, using only ASCII
/// letters, digits, and `-` `.` `:`. Anything else must be stripped.
public enum IQN {
    /// True if `name` is a syntactically valid iqn/eui node name.
    public static func isValid(_ name: String) -> Bool {
        guard name.count <= 223, !name.isEmpty else { return false }
        if name.hasPrefix("iqn.") {
            let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-.:")
            return name.allSatisfy { allowed.contains($0) }
        }
        if name.hasPrefix("eui.") {
            let hex = name.dropFirst(4)
            return hex.count == 16 && hex.allSatisfy { $0.isHexDigit }
        }
        return false
    }

    /// Sanitize an arbitrary identifier into the `:identifier` tail of an IQN:
    /// lowercase, spaces/underscores → `-`, everything else dropped.
    public static func sanitizeIdentifier(_ raw: String) -> String {
        let lowered = raw.lowercased()
        var out = ""
        for ch in lowered {
            if ch.isLetter || ch.isNumber || ch == "-" || ch == "." {
                out.append(ch)
            } else if ch == " " || ch == "_" {
                out.append("-")
            }
            // else: drop parentheses, punctuation, etc.
        }
        // Collapse repeats and trim separators.
        while out.contains("--") { out = out.replacingOccurrences(of: "--", with: "-") }
        let trimmed = out.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        return trimmed.isEmpty ? "host" : trimmed
    }

    /// True for an NVMe Qualified Name. iSCSI names begin `iqn.`, `eui.` or
    /// `naa.` and NQNs begin `nqn.`, so a target's name alone says which
    /// protocol it speaks — the one discriminator the daemon, the app and
    /// the extension all use, and nothing is stored to say it twice.
    public static func isNQN(_ name: String) -> Bool {
        name.hasPrefix("nqn.")
    }

    /// A default initiator name for this host, guaranteed valid.
    ///
    /// The naming authority must be a domain the author owns on the given
    /// date (RFC 3721 §1.1); com.example is reserved for documentation and
    /// must never appear on the wire.
    public static func defaultInitiatorName(
        naming reverseDomain: String = "me.herko",
        date: String = "2026-08",
        hostIdentifier: String
    ) -> String {
        "iqn.\(date).\(reverseDomain):\(sanitizeIdentifier(hostIdentifier))"
    }
}
