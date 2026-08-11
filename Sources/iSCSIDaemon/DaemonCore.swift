import Foundation
import iSCSIKit

/// The daemon's session registry and block-I/O engine, independent of the XPC
/// transport so it can be unit-tested directly. Each session handle maps to a
/// live ISCSISession + ISCSIBlockDevice.
public actor DaemonCore {
    struct SessionEntry {
        let session: ISCSISession
        let device: ISCSIBlockDevice
        let targetIQN: String
        let lun: UInt64
    }

    private var sessions: [String: SessionEntry] = [:]
    private var handleCounter: UInt64 = 0
    private let initiatorName: String
    /// How to build a transport to a portal. Injected so tests can use
    /// MemoryPipe and production uses NetworkTransport.
    private let transportFactory: @Sendable (String, UInt16) async throws -> any ConnectionTransport

    public init(
        initiatorName: String,
        transportFactory: @escaping @Sendable (String, UInt16) async throws -> any ConnectionTransport
    ) {
        self.initiatorName = initiatorName
        self.transportFactory = transportFactory
    }

    public func discover(host: String, port: UInt16, chap: CHAP.Credentials? = nil) async throws -> [DiscoveredTarget] {
        let transport = try await transportFactory(host, port)
        return try await Discovery.sendTargets(
            transport: transport,
            initiatorName: initiatorName,
            chap: chap
        )
    }

    public func login(
        host: String,
        port: UInt16,
        targetIQN: String,
        lun: UInt64,
        chap: CHAP.Credentials? = nil
    ) async throws -> String {
        var config = LoginConfig(
            initiatorName: initiatorName,
            sessionType: .normal,
            targetName: targetIQN,
            chap: chap
        )
        config.desired.offerDigests = true
        let factory = transportFactory
        let session = ISCSISession(login: config) {
            try await factory(host, port)
        }
        try await session.activate()
        let device = ISCSIBlockDevice(session: session, lun: lun)
        _ = try await device.readCapacity() // fail fast if the LUN is bad

        handleCounter += 1
        let handle = "s\(handleCounter)"
        sessions[handle] = SessionEntry(session: session, device: device, targetIQN: targetIQN, lun: lun)
        return handle
    }

    public func logout(_ handle: String) async throws {
        guard let entry = sessions.removeValue(forKey: handle) else { return }
        try await entry.session.logout()
    }

    public func capacity(_ handle: String) async throws -> (blockSize: Int, blockCount: UInt64) {
        try await device(handle).readCapacity()
    }

    public func read(_ handle: String, offset: UInt64, length: Int) async throws -> Data {
        try await device(handle).read(offset: offset, length: length)
    }

    public func write(_ handle: String, offset: UInt64, data: Data) async throws {
        try await device(handle).write(offset: offset, data: data)
    }

    public func flush(_ handle: String) async throws {
        try await device(handle).flush()
    }

    public func sessionHandles() -> [String] {
        Array(sessions.keys).sorted()
    }

    private func device(_ handle: String) throws -> ISCSIBlockDevice {
        guard let entry = sessions[handle] else { throw BlockDeviceError.notReady }
        return entry.device
    }
}
