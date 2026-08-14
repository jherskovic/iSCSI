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
}

/// The Mach service name the daemon registers and clients connect to.
public let iscsiDaemonServiceName = "me.herko.iSCSIInitiator.daemon"

#endif // os(macOS)
