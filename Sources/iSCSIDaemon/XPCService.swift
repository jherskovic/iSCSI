#if canImport(Network)
import Foundation
import os
import iSCSIKit

/// XPC reply blocks are safe to invoke from any thread but aren't typed
/// Sendable; wrap them to cross into a Task without a data-race diagnostic.
private struct SendableBox<T>: @unchecked Sendable {
    let value: T
    init(_ value: T) { self.value = value }
}

/// Bridges the @objc XPC protocol to the async `DaemonCore`. One instance per
/// XPC connection. Runs on macOS where NSXPCConnection is available.
public final class ISCSIXPCService: NSObject, ISCSIDaemonProtocol, @unchecked Sendable {
    private let core: DaemonCore

    private let targets: TargetStore

    /// Handles created on *this* connection.
    ///
    /// The registry in DaemonCore is one flat namespace of "s1", "s2", … shared
    /// by every client, so any connected process could log out, read from, or
    /// write to a session it did not open, by guessing a two-character string.
    /// The code-signing requirement means only our own app and extension can
    /// connect, which makes it a correctness bug rather than a way in — but both
    /// of those are connected at the same time, so it is reachable in normal
    /// operation rather than theoretical.
    ///
    /// A lock rather than an actor: this is consulted on every read and write,
    /// and the object is created per connection so contention is nil.
    private let owned = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(core: DaemonCore, targets: TargetStore = TargetStore()) {
        self.core = core
        self.targets = targets
    }

    private func claim(_ handle: String) {
        owned.withLock { $0.insert(handle) }
    }

    private func release(_ handle: String) {
        owned.withLock { $0.remove(handle) }
    }

    /// Refuses rather than silently doing nothing: a client using a handle it
    /// does not own is a bug in that client, and it should hear about it.
    private func checkOwned(_ handle: String) -> NSError? {
        guard owned.withLock({ $0.contains(handle) }) else {
            return ISCSIError.nsError(
                from: SessionError.notActive,
                context: "Session \(handle) does not belong to this connection")
        }
        return nil
    }

    public func discover(host: String, port: NSNumber, reply: @escaping ([String]?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                let targets = try await core.discover(host: host, port: port.uint16Value)
                box.value(targets.map { "\($0.name)\t\($0.addresses.joined(separator: ","))" }, nil)
            } catch {
                box.value(nil, ISCSIError.nsError(from: error,
                                                  context: "Discovering targets at \(host)"))
            }
        }
    }

    public func login(
        host: String, port: NSNumber, targetIQN: String, lun: NSNumber,
        chapUser: String?, reply: @escaping (String?, Error?) -> Void
    ) {
        let box = SendableBox(reply)
        Task {
            do {
                // CHAP secret is fetched from the keychain by user name, if any.
                let chap = chapUser.flatMap { user in
                    KeychainStore.chapSecret(for: user).map {
                        CHAP.Credentials(name: user, secret: $0)
                    }
                }
                let handle = try await core.login(
                    host: host, port: port.uint16Value,
                    targetIQN: targetIQN, lun: lun.uint64Value, chap: chap
                )
                self.claim(handle)
                box.value(handle, nil)
            } catch {
                box.value(nil, ISCSIError.nsError(from: error,
                                                  context: "Connecting to \(targetIQN)"))
            }
        }
    }

    public func logout(session: String, reply: @escaping (Error?) -> Void) {
        if let denied = checkOwned(session) { reply(denied); return }
        release(session)
        let box = SendableBox(reply)
        Task {
            do { try await core.logout(session); box.value(nil) }
            catch { box.value(ISCSIError.nsError(from: error, context: "Disconnecting")) }
        }
    }

    public func capacity(session: String, reply: @escaping (NSNumber, NSNumber, Error?) -> Void) {
        if let denied = checkOwned(session) { reply(0, 0, denied); return }
        let box = SendableBox(reply)
        Task {
            do {
                let (bs, count) = try await core.capacity(session)
                box.value(NSNumber(value: bs), NSNumber(value: count), nil)
            } catch {
                box.value(0, 0, ISCSIError.nsError(from: error,
                                                   context: "Reading the device size"))
            }
        }
    }

    public func read(session: String, offset: NSNumber, length: NSNumber, reply: @escaping (Data?, Error?) -> Void) {
        if let denied = checkOwned(session) { reply(nil, denied); return }
        let box = SendableBox(reply)
        Task {
            do {
                let data = try await core.read(session, offset: offset.uint64Value, length: length.intValue)
                box.value(data, nil)
            } catch {
                box.value(nil, ISCSIError.nsError(from: error, context: "Reading"))
            }
        }
    }

    public func write(session: String, offset: NSNumber, data: Data, reply: @escaping (Error?) -> Void) {
        if let denied = checkOwned(session) { reply(denied); return }
        let box = SendableBox(reply)
        Task {
            do { try await core.write(session, offset: offset.uint64Value, data: data); box.value(nil) }
            catch { box.value(ISCSIError.nsError(from: error, context: "Writing")) }
        }
    }

    public func flush(session: String, reply: @escaping (Error?) -> Void) {
        if let denied = checkOwned(session) { reply(denied); return }
        let box = SendableBox(reply)
        Task {
            do { try await core.flush(session); box.value(nil) }
            catch { box.value(ISCSIError.nsError(from: error, context: "Flushing")) }
        }
    }

    /// Deliberately synchronous and stateless: it must answer even when the
    /// session engine is wedged, because "the daemon is alive but its sessions
    /// are stuck" and "the daemon is not running" need different instructions
    /// and this is the call that tells them apart.
    public func daemonInfo(reply: @escaping (Data?, Error?) -> Void) {
        // Bundle.main for an executable inside <app>/Contents/MacOS resolves to
        // the containing .app, so the daemon reports the version of the app it
        // shipped with — exactly what the version-mismatch check needs. Running
        // loose from `swift run` there is no Info.plist, hence "dev".
        let info = Bundle.main.infoDictionary
        let relaxed: Bool
        #if DEBUG
        relaxed = true
        #else
        relaxed = false
        #endif
        let payload = DaemonInfo(
            version: info?["CFBundleShortVersionString"] as? String ?? "dev",
            build: info?["CFBundleVersion"] as? String ?? "0",
            pid: ProcessInfo.processInfo.processIdentifier,
            authorizationRelaxed: relaxed
        )
        do {
            reply(try JSONEncoder().encode(payload), nil)
        } catch {
            reply(nil, error)
        }
    }

    public func refreshFSKitEnablement(reply: @escaping (Error?) -> Void) {
        // killall, not `launchctl kickstart -k`. SIP forbids launchctl job
        // control on Apple's daemons — "150: Operation not permitted while
        // System Integrity Protection is engaged" — while signalling a process
        // as root is allowed, and launchd respawns it on demand. Measured, see
        // docs/backend-a-fskit-notes.md.
        //
        // The argument list is a literal. Nothing from the client reaches it.
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["fskitd"]
        do {
            try killall.run()
            killall.waitUntilExit()
            // killall exits 1 when nothing matched. That is not a failure here:
            // fskitd is on-demand, so "not running" means the next mount starts
            // a fresh one that reads the file we just wrote — which is the goal.
            DaemonLog.lifecycle("refreshFSKitEnablement: killall fskitd exited "
                                + "\(killall.terminationStatus)")
            reply(nil)
        } catch {
            DaemonLog.error("refreshFSKitEnablement failed: \(error)")
            reply(error)
        }
    }

    public func listSessions(reply: @escaping ([String]) -> Void) {
        let box = SendableBox(reply)
        Task { box.value(await core.sessionHandles()) }
    }

    // MARK: - Configured targets

    public func listTargets(reply: @escaping (Data?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do { box.value(try JSONEncoder().encode(await targets.all()), nil) }
            catch { box.value(nil, ISCSIError.nsError(from: error, context: "Reading saved targets")) }
        }
    }

    public func saveTarget(_ record: Data, reply: @escaping (Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                try await targets.save(JSONDecoder().decode(TargetRecord.self, from: record))
                box.value(nil)
            } catch {
                box.value(ISCSIError.nsError(from: error, context: "Saving the target"))
            }
        }
    }

    public func deleteTarget(id: String, reply: @escaping (Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                try await targets.delete(id: id)
                // Remove the secret with the target it belonged to. Leaving an
                // orphaned keychain item behind means a later target that reuses
                // the id silently inherits someone else's credentials.
                KeychainStore.deleteCHAPSecret(for: id)
                box.value(nil)
            } catch {
                box.value(ISCSIError.nsError(from: error, context: "Deleting the target"))
            }
        }
    }

    // MARK: - Credentials

    public func setCHAPSecret(targetID: String, secret: String, reply: @escaping (Error?) -> Void) {
        KeychainStore.setCHAPSecret(secret, for: targetID)
        reply(KeychainStore.chapSecret(for: targetID) == nil
              ? ISCSIError.nsError(from: KeychainStore.StoreFailure.notPersisted,
                                   context: "Saving the CHAP secret")
              : nil)
    }

    public func deleteCHAPSecret(targetID: String, reply: @escaping (Error?) -> Void) {
        KeychainStore.deleteCHAPSecret(for: targetID)
        reply(nil)
    }

    public func hasCHAPSecret(targetID: String, reply: @escaping (Bool) -> Void) {
        reply(KeychainStore.chapSecret(for: targetID) != nil)
    }

    // MARK: - Discovery and inspection

    public func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                                chapSecret: String?, reply: @escaping (Data?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                // The credentials actually reach DaemonCore here. The older
                // discover() accepted a chapUser and dropped it on the floor,
                // which made an authenticated portal undiscoverable from the app.
                let chap: CHAP.Credentials? = {
                    guard let chapUser, let chapSecret else { return nil }
                    return CHAP.Credentials(name: chapUser, secret: chapSecret)
                }()
                let found = try await core.discover(host: host, port: port.uint16Value, chap: chap)
                let info = found.map {
                    DiscoveredTargetInfo(targetIQN: $0.name, addresses: $0.addresses)
                }
                box.value(try JSONEncoder().encode(info), nil)
            } catch {
                box.value(nil, ISCSIError.nsError(from: error,
                                                  context: "Discovering targets at \(host)"))
            }
        }
    }

    public func reportLUNs(session: String, reply: @escaping (Data?, Error?) -> Void) {
        if let denied = checkOwned(session) { reply(nil, denied); return }
        let box = SendableBox(reply)
        Task {
            do { box.value(try JSONEncoder().encode(await core.reportLUNs(session)), nil) }
            catch { box.value(nil, ISCSIError.nsError(from: error, context: "Listing LUNs")) }
        }
    }

    public func listSessionsDetailed(reply: @escaping (Data?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do { box.value(try JSONEncoder().encode(await core.sessionDetails()), nil) }
            catch { box.value(nil, ISCSIError.nsError(from: error, context: "Listing sessions")) }
        }
    }
}

/// XPC listener delegate that hands each connection an ISCSIXPCService.
public final class ISCSIListenerDelegate: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    private let core: DaemonCore

    public init(core: DaemonCore) {
        self.core = core
    }

    public func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        // Before resume(), and before anything is exported. Once the connection
        // is resumed the peer can start calling, so a check made afterwards is
        // a race it can win.
        guard ClientAuthorization.authorize(connection) else { return false }

        let iface = NSXPCInterface(with: ISCSIDaemonProtocol.self)
        connection.exportedInterface = iface
        connection.exportedObject = ISCSIXPCService(core: core)
        connection.resume()
        return true
    }
}
#endif
