import Foundation

// Lives in iSCSIKit rather than iSCSIDaemon so that *both* sides of the wire can
// see it: the daemon implements it, and the FSKit app extension — which links
// iSCSIKit but must not pull in the daemon's session engine — calls it.
//
// Gated to macOS because @objc/NSXPC requires the Objective-C runtime; the rest
// of iSCSIKit stays portable and free of platform I/O.
#if os(macOS)

/// XPC surface the daemon exposes to clients (the FSKit extension, the CLI,
/// and eventually the dext-side helper). Kept `@objc` and NSSecureCoding-
/// friendly (Data/NSNumber/NSString) so it crosses the XPC boundary.
///
/// The daemon owns the live ISCSISession; clients issue block I/O and session
/// management through this protocol. All methods are async via reply blocks.
@objc public protocol ISCSIDaemonProtocol {
    /// Discover targets at a portal. Reply: array of "iqn\taddr,addr" strings.
    func discover(host: String, port: NSNumber, reply: @escaping ([String]?, Error?) -> Void)

    /// Log in and establish a session for `targetIQN`. Reply: session handle.
    ///
    /// The portal identifies a target the daemon **already has on file**; there
    /// is deliberately no credential parameter. The daemon resolves
    /// (host, port, targetIQN, lun) against its own `TargetStore` and takes the
    /// CHAP identity from that record, so a client can neither choose which
    /// stored secret is used nor point one at a portal the user never
    /// configured. A portal with no matching record is refused.
    ///
    /// No username or id parameter: a client-supplied lookup key either misses
    /// (silent downgrade to `AuthMethod=None`) or lets a client spend any
    /// stored secret against an attacker's portal.
    func login(
        host: String,
        port: NSNumber,
        targetIQN: String,
        lun: NSNumber,
        reply: @escaping (String?, Error?) -> Void
    )

    func logout(session: String, reply: @escaping (Error?) -> Void)

    /// Geometry. Reply: (blockSize, blockCount).
    func capacity(session: String, reply: @escaping (NSNumber, NSNumber, Error?) -> Void)

    /// Readahead byte budget for this session's target, from its
    /// `WorkloadProfile`. Reply: bytes.
    ///
    /// Keyed on the session handle the daemon already owns — the FSKit
    /// extension holds only a mount URL and deliberately forwards nothing
    /// from it, keeping the lookup on the daemon's side of the trust boundary.
    func readaheadBudget(session: String, reply: @escaping (NSNumber, Error?) -> Void)

    /// Block read. offset/length in bytes, block-aligned. Reply: data.
    func read(session: String, offset: NSNumber, length: NSNumber, reply: @escaping (Data?, Error?) -> Void)

    /// Block write. Reply: error or nil.
    func write(session: String, offset: NSNumber, data: Data, reply: @escaping (Error?) -> Void)

    /// SYNCHRONIZE CACHE. Reply: error or nil.
    func flush(session: String, reply: @escaping (Error?) -> Void)

    /// Live session handles.
    func listSessions(reply: @escaping ([String]) -> Void)

    /// Identity and liveness. Reply carries a JSON-encoded `DaemonInfo`.
    ///
    /// The first call the setup flow makes and the only one that has to work
    /// before anything is configured, so it deliberately touches no session
    /// state and cannot fail for any reason other than the daemon being absent.
    func daemonInfo(reply: @escaping (Data?, Error?) -> Void)

    /// Make `fskitd` re-read `enabledModules.plist`.
    ///
    /// Needed only on macOS 26.x, where the System Settings switch refuses to
    /// enable a third-party module and the app writes the entry itself. The
    /// write alone changes nothing: `fskitd` caches the enabled set and only
    /// re-reads it when it restarts, so `mount` keeps reporting
    /// "Module … is disabled!" until it does.
    ///
    /// It lives here because signalling a system daemon needs root, and this
    /// process already is. Deliberately takes no arguments: it is one fixed
    /// action, not a "run this as root" primitive. Every caller is pinned by
    /// the code-signing requirement in ClientAuthorization.
    func refreshFSKitEnablement(reply: @escaping (Error?) -> Void)

    // MARK: - Configured targets
    //
    // All of these carry JSON-encoded Codable values as `Data`. See XPCModels
    // for why that is preferred over NSSecureCoding object graphs.

    /// Reply: JSON `[TargetRecord]`.
    func listTargets(reply: @escaping (Data?, Error?) -> Void)
    /// `record` is a JSON `TargetRecord`. Inserts or updates.
    ///
    /// Replies with the record **as stored**, whose id may differ from the one
    /// sent: the store treats (host, port, targetIQN, lun) as identity, and when
    /// the incoming record duplicates an existing target the existing id is
    /// kept. Callers must use the returned id for anything keyed by it —
    /// notably the CHAP secret — or they will file it under an id nothing
    /// refers to.
    func saveTarget(_ record: Data, reply: @escaping (Data?, Error?) -> Void)
    func deleteTarget(id: String, reply: @escaping (Error?) -> Void)

    // MARK: - Credentials
    //
    // Secrets only ever travel *into* the daemon. There is deliberately no call
    // that returns one: a compromised client should not be able to read back
    // what an earlier, trusted one stored.

    func setCHAPSecret(targetID: String, secret: String, reply: @escaping (Error?) -> Void)
    func deleteCHAPSecret(targetID: String, reply: @escaping (Error?) -> Void)
    /// So the UI can show "secret saved" without ever handling the secret.
    func hasCHAPSecret(targetID: String, reply: @escaping (Bool) -> Void)

    /// The *target's* secret, for mutual CHAP: what the target must prove it
    /// knows before we trust the block device it is serving. Stored under a
    /// separate keychain account from the initiator secret so the two cannot
    /// collide for one target.
    func setMutualCHAPSecret(targetID: String, secret: String, reply: @escaping (Error?) -> Void)
    func deleteMutualCHAPSecret(targetID: String, reply: @escaping (Error?) -> Void)
    func hasMutualCHAPSecret(targetID: String, reply: @escaping (Bool) -> Void)

    // MARK: - Discovery and inspection

    /// SendTargets against a portal, with optional CHAP. Reply: JSON
    /// `[DiscoveredTargetInfo]`.
    func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                         chapSecret: String?, reply: @escaping (Data?, Error?) -> Void)

    /// REPORT LUNS against an established session. Reply: JSON `[LUNInfo]`.
    func reportLUNs(session: String, reply: @escaping (Data?, Error?) -> Void)

    /// Every live session with its negotiated parameters, recovery count and
    /// cache state. Reply: JSON `[SessionInfo]`.
    func listSessionsDetailed(reply: @escaping (Data?, Error?) -> Void)

    /// Log in, read the geometry, and log out again — entirely inside the
    /// daemon, so a client can check reachability/credentials without holding
    /// a session (handles are owned by the XPC connection that created them,
    /// so client-side login-then-logout leaks a session per attach). Resolves
    /// credentials like `login` and refuses a portal not on file — anything
    /// else is a credential oracle. Reply: a JSON `LUNInfo`.
    func testConnection(host: String, port: NSNumber, targetIQN: String, lun: NSNumber,
                        reply: @escaping (Data?, Error?) -> Void)

    /// Delete everything the daemon owns: targets file, its directory, every
    /// stored CHAP secret. Must run while the daemon still exists — the
    /// secrets live in *its* keychain context and are unreachable after
    /// unregistration.
    func removeAllData(reply: @escaping (Error?) -> Void)
}

/// The Mach service name the daemon registers and clients connect to.
public let iscsiDaemonServiceName = "me.herko.iSCSIInitiator.daemon"

#endif // os(macOS)
