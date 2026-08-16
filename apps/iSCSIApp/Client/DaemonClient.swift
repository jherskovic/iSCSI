//
//  DaemonClient.swift
//  async/await over the daemon's XPC surface.
//
//  Deliberately async rather than the blocking `DispatchSemaphore` wrapper the
//  FSKit extension uses (iSCSIFSExtension.swift:355). That wrapper exists
//  because FSKit calls the extension on a thread it must not suspend; doing the
//  same here would block the main thread on a call that can take a 30-second
//  task timeout, which is a beachball at exactly the moment the user is
//  wondering why their storage is slow.
//
//  Every call opens its own connection. A cached one that has gone stale answers
//  liveness questions wrongly and in the direction that looks like success, and
//  these calls are infrequent enough that the setup cost does not matter.
//

import Foundation
import iSCSIKit

extension DaemonConnection {

    // MARK: - Configured targets

    static func listTargets() async throws -> [TargetRecord] {
        try await decode([TargetRecord].self) { proxy, finish in
            proxy.listTargets { data, error in finish(data, error) }
        }
    }

    /// Returns the record as stored. The id can differ from the one sent — see
    /// the protocol note — so anything keyed by it must use the result.
    @discardableResult
    static func saveTarget(_ record: TargetRecord) async throws -> TargetRecord {
        let encoded = try JSONEncoder().encode(record)
        return try await decode(TargetRecord.self) { proxy, finish in
            proxy.saveTarget(encoded) { data, error in finish(data, error) }
        }
    }

    static func deleteTarget(id: String) async throws {
        try await call { proxy, finish in
            proxy.deleteTarget(id: id) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    // MARK: - Credentials
    //
    // One-way by design: there is no `getCHAPSecret`. The GUI can ask whether a
    // secret exists so it can say "saved", and can replace it, but cannot read
    // it back — so a client compromised later cannot recover what an earlier
    // trusted one stored.

    static func setCHAPSecret(targetID: String, secret: String) async throws {
        try await call { proxy, finish in
            proxy.setCHAPSecret(targetID: targetID, secret: secret) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    static func deleteCHAPSecret(targetID: String) async throws {
        try await call { proxy, finish in
            proxy.deleteCHAPSecret(targetID: targetID) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    static func hasCHAPSecret(targetID: String) async throws -> Bool {
        try await call { proxy, finish in
            proxy.hasCHAPSecret(targetID: targetID) { finish(.success($0)) }
        }
    }

    static func setMutualCHAPSecret(targetID: String, secret: String) async throws {
        try await call { proxy, finish in
            proxy.setMutualCHAPSecret(targetID: targetID, secret: secret) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    static func deleteMutualCHAPSecret(targetID: String) async throws {
        try await call { proxy, finish in
            proxy.deleteMutualCHAPSecret(targetID: targetID) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    static func hasMutualCHAPSecret(targetID: String) async throws -> Bool {
        try await call { proxy, finish in
            proxy.hasMutualCHAPSecret(targetID: targetID) { finish(.success($0)) }
        }
    }

    // MARK: - Discovery and sessions

    static func discoverTargets(host: String, port: UInt16,
                                chapUser: String?, chapSecret: String?)
        async throws -> [DiscoveredTargetInfo] {
        try await decode([DiscoveredTargetInfo].self) { proxy, finish in
            proxy.discoverTargets(host: host, port: NSNumber(value: port),
                                  chapUser: chapUser, chapSecret: chapSecret) { data, error in
                finish(data, error)
            }
        }
    }

    /// Check reachability and credentials without holding a session. See the
    /// protocol note — this exists because handles are connection-scoped and
    /// this client opens a connection per call.
    /// No credential parameter: the daemon resolves the portal against its own
    /// saved targets and uses that record's CHAP identity. Passing one was the
    /// bug — it let a caller pick which stored secret got spent, and where.
    static func testConnection(host: String, port: UInt16, targetIQN: String,
                               lun: UInt64) async throws -> LUNInfo {
        try await decode(LUNInfo.self) { proxy, finish in
            proxy.testConnection(host: host, port: NSNumber(value: port),
                                 targetIQN: targetIQN,
                                 lun: NSNumber(value: lun)) { data, error in finish(data, error) }
        }
    }

    static func login(host: String, port: UInt16, targetIQN: String,
                      lun: UInt64) async throws -> String {
        try await call { proxy, finish in
            proxy.login(host: host, port: NSNumber(value: port), targetIQN: targetIQN,
                        lun: NSNumber(value: lun)) { handle, error in
                if let error { finish(.failure(error)) }
                else if let handle { finish(.success(handle)) }
                else { finish(.failure(Unreachable(reason: "the daemon returned no session"))) }
            }
        }
    }

    static func logout(session: String) async throws {
        try await call { proxy, finish in
            proxy.logout(session: session) { error in
                finish(error.map { .failure($0) } ?? .success(()))
            }
        }
    }

    static func reportLUNs(session: String) async throws -> [LUNInfo] {
        try await decode([LUNInfo].self) { proxy, finish in
            proxy.reportLUNs(session: session) { data, error in finish(data, error) }
        }
    }

    static func sessions() async throws -> [SessionInfo] {
        try await decode([SessionInfo].self) { proxy, finish in
            proxy.listSessionsDetailed { data, error in finish(data, error) }
        }
    }

    // MARK: - Plumbing

    /// Shared shape for every call that replies with JSON in `Data`.
    ///
    /// The three failure modes — an error, a nil payload, and a payload that
    /// will not decode — are all real across a version skew between the app and
    /// the daemon, and each needs to be distinguishable in a bug report rather
    /// than collapsed into "something went wrong".
    private static func decode<T: Decodable & Sendable>(
        _ type: T.Type,
        _ body: @escaping @Sendable (ISCSIDaemonProtocol,
                                     @escaping @Sendable (Data?, Error?) -> Void) -> Void
    ) async throws -> T {
        let data: Data = try await call { proxy, finish in
            body(proxy) { data, error in
                if let error { finish(.failure(error)) }
                else if let data { finish(.success(data)) }
                else { finish(.failure(Unreachable(reason: "the daemon replied with nothing"))) }
            }
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw Unreachable(reason:
                "the daemon sent a reply this version cannot read (\(error)). "
                + "This usually means the app and the background service are "
                + "different versions; the Setup screen can reinstall it.")
        }
    }
}
