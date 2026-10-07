import Foundation

/// Log a new connection in, following login redirects (RFC 7143 §11.13.5).
///
/// An EqualLogic group answers every normal login on its group address with
/// "moved temporarily" and a member port, so an initiator that stops at the
/// redirect can never attach. `ISCSISession` logs in through this; so do
/// iscsictl's commands that drive a bare connection, so the CLI and the
/// daemon cannot disagree about a redirecting target.
public enum RedirectingLogin {
    /// Redirects followed in one login before giving up. One is all a real
    /// target uses (group address to member port); the bound is for a target
    /// that sends us in a circle.
    public static let maxRedirects = 4

    public struct Outcome: Sendable {
        public let connection: ISCSIConnection
        public let result: LoginResult
        /// Where a permanent redirect moved the target, for the caller's later
        /// logins; nil when every redirect was temporary, or there was none.
        public let movedPermanentlyTo: TargetPortal?
    }

    /// Log in at `start` (nil: the caller's configured portal), following each
    /// redirect to the address it names.
    ///
    /// - Parameter connect: opens a transport to a portal, or to the
    ///   configured portal when given nil.
    /// - Parameter followRedirects: false surfaces the first redirect as
    ///   `ConnectionError.redirected`, for callers that cannot reach an
    ///   arbitrary address.
    ///
    /// An address we cannot read surfaces the redirect too: a guessed port
    /// connects to the wrong service, and the error that comes back blames
    /// the network.
    public static func login(
        _ config: LoginConfig,
        startingAt start: TargetPortal? = nil,
        followRedirects: Bool = true,
        connect: @Sendable (TargetPortal?) async throws -> any ConnectionTransport
    ) async throws -> Outcome {
        var portal = start
        var moved: TargetPortal?
        var hops = 0
        while true {
            let connection = ISCSIConnection(transport: try await connect(portal), login: config)
            do {
                let result = try await connection.login()
                return Outcome(connection: connection, result: result, movedPermanentlyTo: moved)
            } catch let ConnectionError.redirected(address, permanent) {
                guard followRedirects, hops < maxRedirects,
                      let next = TargetPortal(targetAddress: address) else {
                    throw ConnectionError.redirected(address: address, permanent: permanent)
                }
                hops += 1
                if permanent { moved = next }
                portal = next
            }
        }
    }
}
