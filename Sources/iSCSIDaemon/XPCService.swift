#if canImport(Network)
import Foundation
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

    public init(core: DaemonCore) {
        self.core = core
    }

    public func discover(host: String, port: NSNumber, reply: @escaping ([String]?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                let targets = try await core.discover(host: host, port: port.uint16Value)
                box.value(targets.map { "\($0.name)\t\($0.addresses.joined(separator: ","))" }, nil)
            } catch {
                box.value(nil, error as NSError)
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
                box.value(handle, nil)
            } catch {
                box.value(nil, error as NSError)
            }
        }
    }

    public func logout(session: String, reply: @escaping (Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do { try await core.logout(session); box.value(nil) }
            catch { box.value(error as NSError) }
        }
    }

    public func capacity(session: String, reply: @escaping (NSNumber, NSNumber, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                let (bs, count) = try await core.capacity(session)
                box.value(NSNumber(value: bs), NSNumber(value: count), nil)
            } catch {
                box.value(0, 0, error as NSError)
            }
        }
    }

    public func read(session: String, offset: NSNumber, length: NSNumber, reply: @escaping (Data?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                let data = try await core.read(session, offset: offset.uint64Value, length: length.intValue)
                box.value(data, nil)
            } catch {
                box.value(nil, error as NSError)
            }
        }
    }

    public func write(session: String, offset: NSNumber, data: Data, reply: @escaping (Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do { try await core.write(session, offset: offset.uint64Value, data: data); box.value(nil) }
            catch { box.value(error as NSError) }
        }
    }

    public func flush(session: String, reply: @escaping (Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do { try await core.flush(session); box.value(nil) }
            catch { box.value(error as NSError) }
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
