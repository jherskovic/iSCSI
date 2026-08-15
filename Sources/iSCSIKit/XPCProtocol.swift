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
    func login(
        host: String,
        port: NSNumber,
        targetIQN: String,
        lun: NSNumber,
        chapUser: String?,
        reply: @escaping (String?, Error?) -> Void
    )

    func logout(session: String, reply: @escaping (Error?) -> Void)

    /// Geometry. Reply: (blockSize, blockCount).
    func capacity(session: String, reply: @escaping (NSNumber, NSNumber, Error?) -> Void)

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
    /// `record` is a JSON `TargetRecord`. Inserts or replaces by id.
    func saveTarget(_ record: Data, reply: @escaping (Error?) -> Void)
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

    // MARK: - Discovery and inspection

    /// SendTargets against a portal, **with** optional CHAP.
    ///
    /// The older `discover(host:port:)` silently dropped credentials that
    /// `DaemonCore.discover` has always accepted, which made discovery against
    /// any authenticated portal impossible from the app. Reply: JSON
    /// `[DiscoveredTargetInfo]`.
    func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                         chapSecret: String?, reply: @escaping (Data?, Error?) -> Void)

    /// REPORT LUNS against an established session. Reply: JSON `[LUNInfo]`.
    func reportLUNs(session: String, reply: @escaping (Data?, Error?) -> Void)

    /// Every live session with its negotiated parameters, recovery count and
    /// cache state. Reply: JSON `[SessionInfo]`.
    func listSessionsDetailed(reply: @escaping (Data?, Error?) -> Void)
}

/// The Mach service name the daemon registers and clients connect to.
public let iscsiDaemonServiceName = "me.herko.iSCSIInitiator.daemon"

#endif // os(macOS)
