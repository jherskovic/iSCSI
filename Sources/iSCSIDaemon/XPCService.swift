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

    /// Handles created on *this* connection. DaemonCore's registry is one
    /// flat namespace shared by every client, so without this check any
    /// connected process could use a session it did not open — and the app
    /// and extension are connected at the same time. A lock, not an actor:
    /// consulted on every read/write, per-connection so contention is nil.
    private let owned = OSAllocatedUnfairLock(initialState: Set<String>())

    public init(core: DaemonCore, targets: TargetStore = TargetStore()) {
        self.core = core
        self.targets = targets
    }

    /// Readahead budget per owned handle, resolved once at login (like
    /// `FlushPolicy`): editing a target takes effect on the next attach, not
    /// under a live session.
    private let budgets = OSAllocatedUnfairLock(initialState: [String: Int]())

    private func claim(_ handle: String, readaheadBudget: Int) {
        owned.withLock { $0.insert(handle) }
        budgets.withLock { $0[handle] = readaheadBudget }
    }

    private func release(_ handle: String) {
        owned.withLock { $0.remove(handle) }
        budgets.withLock { $0[handle] = nil }
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

    /// Resolve a portal to the configured target and *that* target's
    /// credentials — the whole authorization model for login:
    /// - an unknown portal is refused, so the daemon only authenticates to
    ///   targets the user set up (`mount(8)` needs no root);
    /// - the CHAP identity comes from the record, so a client cannot choose
    ///   which stored secret is spent or where it goes;
    /// - a configured username with no secret throws, because a nil credential
    ///   makes `LoginStateMachine.start()` offer `AuthMethod=None`.
    private func credentials(host: String, port: UInt16, targetIQN: String, lun: UInt64)
        async throws -> (record: TargetRecord, chap: CHAP.Credentials?) {
        guard let record = await targets.record(host: host, port: port,
                                                targetIQN: targetIQN, lun: lun) else {
            throw DaemonAuthError.notConfigured(host: host, port: port,
                                                targetIQN: targetIQN, lun: lun)
        }
        guard let user = record.chapUser, !user.isEmpty else {
            return (record, nil)   // deliberately unauthenticated: the user configured no CHAP
        }
        guard let secret = KeychainStore.chapSecret(for: record.id) else {
            throw DaemonAuthError.secretMissing(user: user, target: record.displayName)
        }
        var chap = CHAP.Credentials(name: user, secret: secret)
        // Mutual CHAP only when both halves are configured — a mutual user
        // with no secret throws rather than silently going one-way. Gated on
        // CHAP.mutualIsOffered (see the note there); the record and keychain
        // item are left intact so re-enabling the flag restores the setup.
        if CHAP.mutualIsOffered, let mutualUser = record.mutualChapUser, !mutualUser.isEmpty {
            guard let mutualSecret = KeychainStore.chapSecret(for: record.id, kind: .mutual) else {
                throw DaemonAuthError.mutualSecretMissing(user: mutualUser,
                                                          target: record.displayName)
            }
            chap.mutualName = mutualUser
            chap.mutualSecret = mutualSecret
        } else if let mutualUser = record.mutualChapUser, !mutualUser.isEmpty {
            DaemonLog.auth("\(record.displayName): ignoring the stored mutual CHAP user "
                           + "“\(mutualUser)” — mutual CHAP is switched off in this build")
        }
        return (record, chap)
    }

    public func login(
        host: String, port: NSNumber, targetIQN: String, lun: NSNumber,
        reply: @escaping (String?, Error?) -> Void
    ) {
        let box = SendableBox(reply)
        Task {
            do {
                let (record, chap) = try await self.credentials(
                    host: host, port: port.uint16Value,
                    targetIQN: targetIQN, lun: lun.uint64Value)
                let handle = try await core.login(
                    host: host, port: port.uint16Value,
                    targetIQN: targetIQN, lun: lun.uint64Value, chap: chap,
                    flushPolicy: FlushPolicy(intervalSeconds: record.flushIntervalSeconds)
                )
                self.claim(handle, readaheadBudget: WorkloadProfile
                    .pinnedBudgetBytes(stored: record.workloadProfile) ?? 0)
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

    public func readaheadBudget(session: String, reply: @escaping (NSNumber, Error?) -> Void) {
        if let denied = checkOwned(session) { reply(0, denied); return }
        // 0 means nothing pinned, adapt — also the right answer for a missing
        // entry; failing a mount over a tuning parameter would be worse.
        let bytes = budgets.withLock { $0[session] } ?? 0
        reply(NSNumber(value: bytes), nil)
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

    /// Synchronous and stateless on purpose: it must answer even when the
    /// session engine is wedged — this call is what tells "daemon alive but
    /// stuck" apart from "daemon not running".
    public func daemonInfo(reply: @escaping (Data?, Error?) -> Void) {
        // Bundle.main inside <app>/Contents/MacOS resolves to the containing
        // .app, so this reports the shipping app's version; loose `swift run`
        // has no Info.plist, hence "dev".
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
        // killall, not `launchctl kickstart -k`: SIP forbids launchctl job
        // control on Apple's daemons, while signalling as root is allowed and
        // launchd respawns on demand (docs/backend-a-fskit-notes.md). The
        // argument list is a literal; nothing from the client reaches it.
        let killall = Process()
        killall.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        killall.arguments = ["fskitd"]
        do {
            try killall.run()
            killall.waitUntilExit()
            // Exit 1 (nothing matched) is fine: fskitd is on-demand, and the
            // next mount starts a fresh one that reads the new file.
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

    public func saveTarget(_ record: Data, reply: @escaping (Data?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                let stored = try await targets.save(
                    JSONDecoder().decode(TargetRecord.self, from: record))
                box.value(try JSONEncoder().encode(stored), nil)
            } catch {
                box.value(nil, ISCSIError.nsError(from: error, context: "Saving the target"))
            }
        }
    }

    public func deleteTarget(id: String, reply: @escaping (Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                try await targets.delete(id: id)
                // Both secret halves go with the target: an orphaned keychain
                // item would be inherited by a later target reusing the id.
                KeychainStore.deleteAllSecrets(for: id)
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

    public func setMutualCHAPSecret(targetID: String, secret: String,
                                    reply: @escaping (Error?) -> Void) {
        KeychainStore.setCHAPSecret(secret, for: targetID, kind: .mutual)
        reply(KeychainStore.chapSecret(for: targetID, kind: .mutual) == nil
              ? ISCSIError.nsError(from: KeychainStore.StoreFailure.notPersisted,
                                   context: "Saving the mutual CHAP secret")
              : nil)
    }

    public func deleteMutualCHAPSecret(targetID: String, reply: @escaping (Error?) -> Void) {
        KeychainStore.deleteCHAPSecret(for: targetID, kind: .mutual)
        reply(nil)
    }

    public func hasMutualCHAPSecret(targetID: String, reply: @escaping (Bool) -> Void) {
        reply(KeychainStore.chapSecret(for: targetID, kind: .mutual) != nil)
    }

    // MARK: - Discovery and inspection

    public func discoverTargets(host: String, port: NSNumber, chapUser: String?,
                                chapSecret: String?, reply: @escaping (Data?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                // Unlike login, this legitimately takes a secret from the
                // caller: discovery happens before a target is saved, so there
                // is no record to resolve against. Validated here so a bad
                // secret fails with a reason, not the portal's bare
                // "authentication failure".
                let chap: CHAP.Credentials? = try {
                    guard let chapUser, let chapSecret else { return nil }
                    return try CHAP.Credentials.validated(name: chapUser, secret: chapSecret)
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

    public func testConnection(host: String, port: NSNumber, targetIQN: String,
                               lun: NSNumber,
                               reply: @escaping (Data?, Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            do {
                // Same credential resolution as login, deliberately: this is
                // the UI's "are these credentials right?" probe, and resolving
                // any differently would validate something the user never runs.
                let (_, chap) = try await self.credentials(
                    host: host, port: port.uint16Value,
                    targetIQN: targetIQN, lun: lun.uint64Value)
                // No flush policy: a probe lives milliseconds and stays
                // write-through rather than spinning up a flush timer.
                let handle = try await core.login(
                    host: host, port: port.uint16Value, targetIQN: targetIQN,
                    lun: lun.uint64Value, chap: chap)
                // Always close, even when reading the capacity fails: a probe
                // must not leave a session behind.
                defer { Task { try? await self.core.logout(handle) } }

                let (blockSize, blockCount) = try await core.capacity(handle)
                let info = LUNInfo(lun: lun.uint64Value, blockSize: blockSize,
                                   blockCount: blockCount)
                box.value(try JSONEncoder().encode(info), nil)
            } catch {
                box.value(nil, ISCSIError.nsError(from: error,
                                                  context: "Connecting to \(targetIQN)"))
            }
        }
    }

    public func removeAllData(reply: @escaping (Error?) -> Void) {
        let box = SendableBox(reply)
        Task {
            // Secrets first: the list of what to delete lives in the file we
            // are about to remove.
            for target in await targets.all() {
                KeychainStore.deleteAllSecrets(for: target.id)
            }
            do {
                let directory = TargetStore.defaultURL.deletingLastPathComponent()
                if FileManager.default.fileExists(atPath: directory.path) {
                    try FileManager.default.removeItem(at: directory)
                }
                DaemonLog.lifecycle("removeAllData: cleared \(directory.path)")
                box.value(nil)
            } catch {
                box.value(ISCSIError.nsError(from: error, context: "Removing saved data"))
            }
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
        // Before resume() and before anything is exported: once resumed the
        // peer can start calling, so a later check is a race it can win.
        guard ClientAuthorization.authorize(connection) else { return false }

        let iface = NSXPCInterface(with: ISCSIDaemonProtocol.self)
        connection.exportedInterface = iface
        connection.exportedObject = ISCSIXPCService(core: core)
        connection.resume()
        return true
    }
}
#endif
