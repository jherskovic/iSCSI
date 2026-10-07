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
    /// - NVMe subsystems have no CHAP.
    public static func `for`(_ targetIQN: String, saved records: [TargetRecord],
                             chapUser: String, chapSecret: String) -> DiscoveryOffer {
        let matching = records.filter { $0.targetIQN == targetIQN }
        guard !matching.isEmpty else { return .add }
        guard !IQN.isNQN(targetIQN),
              (try? CHAP.Credentials.validated(name: chapUser, secret: chapSecret)) != nil
        else { return .saved }
        let lacking = matching.filter { $0.chapUser != chapUser }
        return lacking.isEmpty ? .saved : .updateCredentials(lacking)
    }
}
