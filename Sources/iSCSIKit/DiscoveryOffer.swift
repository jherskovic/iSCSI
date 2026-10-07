import Foundation

/// What Discover offers for a target it found, given what is already saved.
///
/// Discover used to show a saved target as "Added" whatever its CHAP fields
/// held, so credentials that had just listed the target went nowhere and the
/// next attach offered AuthMethod=None. A saved target now takes them when
/// asked.
public enum DiscoveryOffer: Equatable, Sendable {
    /// Not saved yet.
    case add
    /// Saved, and nothing typed in Discover would change it.
    case saved
    /// Saved without the CHAP user Discover holds; these records would take it.
    case updateCredentials([TargetRecord])

    /// - Only credentials the editor would accept are offered: a short secret
    ///   saved from here would fail later with a bare "authentication failure".
    /// - A record already naming the typed user stays as it is. Its secret
    ///   cannot be read back to compare, and re-saving it on every discovery
    ///   would quietly replace one changed in the editor.
    /// - Only records at the portal Discover asked (`host`:`port`) take them.
    ///   The daemon sends a record's CHAP responses to that record's host, and
    ///   IQNs are not authenticated: a portal can name any target, so matching
    ///   on the IQN alone would bind these credentials to whatever address a
    ///   same-named record points at. A record saved under another spelling
    ///   of the address is left alone rather than guessed at.
    /// - NVMe subsystems have no CHAP.
    public static func `for`(_ targetIQN: String, at host: String, port: UInt16,
                             saved records: [TargetRecord],
                             chapUser: String, chapSecret: String) -> DiscoveryOffer {
        let matching = records.filter { $0.targetIQN == targetIQN }
        guard !matching.isEmpty else { return .add }
        guard !IQN.isNQN(targetIQN),
              (try? CHAP.Credentials.validated(name: chapUser, secret: chapSecret)) != nil
        else { return .saved }
        let lacking = matching.filter {
            $0.host == host && $0.port == port && $0.chapUser != chapUser
        }
        return lacking.isEmpty ? .saved : .updateCredentials(lacking)
    }
}
