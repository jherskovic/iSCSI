import Foundation
@testable import iSCSIDaemon
@testable import iSCSIKit
import MockTarget
import NVMeKit

/// Every binding a transport factory was handed, and the transports it made,
/// in order.
final class BindingLog: @unchecked Sendable {
    private let lock = NSLock()
    private var bindings: [InterfaceBinding?] = []
    private var made: [any ConnectionTransport] = []

    func add(_ binding: InterfaceBinding?, _ transport: any ConnectionTransport) {
        lock.lock(); bindings.append(binding); made.append(transport); lock.unlock()
    }
    var all: [InterfaceBinding?] { lock.lock(); defer { lock.unlock() }; return bindings }
    var transports: [any ConnectionTransport] { lock.lock(); defer { lock.unlock() }; return made }
}

/// An in-memory transport that reports a fixed path, standing in for what
/// `NetworkTransport` reports over a real socket.
final class PathReportingTransport: ConnectionTransport, ConnectionPathReporting, @unchecked Sendable {
    private let inner: any ConnectionTransport
    let connectedPath: ConnectedPath

    init(_ inner: any ConnectionTransport, path: ConnectedPath) {
        self.inner = inner
        self.connectedPath = path
    }
    func send(_ data: Data) async throws { try await inner.send(data) }
    func receive() async throws -> Data? { try await inner.receive() }
    func close() async { await inner.close() }
}

let spyIQN = MockTargetConfig().targetName
let spyNQN = MockNVMeConfig().subsystemNQN

/// A daemon whose factory logs every binding and reports `path`: iSCSI
/// MockTarget on 3260 (offering `spyIQN` to discovery), the NVMe mock on 4420.
func makeSpyCore(path: ConnectedPath = ConnectedPath(interfaceName: "en18"))
    -> (DaemonCore, BindingLog, HarnessBox) {
    let log = BindingLog()
    let harnesses = HarnessBox()
    let iscsiDisk = RAMDisk()
    let subsystem = MockNVMeSubsystem(disk: RAMDisk(blockSize: 4096, capacityBlocks: 4096))
    let core = DaemonCore(initiatorName: "iqn.test:initiator", policy: testPolicy(),
                          hostIdentity: testHost) { _, port, binding in
        let (initiatorSide, targetSide) = MemoryPipe.pair()
        if port == 4420 {
            harnesses.add(Task { await subsystem.serve(targetSide) })
        } else {
            var config = MockTargetConfig()
            config.discoveryTargets = [(name: spyIQN, addresses: ["127.0.0.1:3260,1"])]
            let target = MockTarget(config: config, disk: iscsiDisk, transport: targetSide)
            harnesses.add(Task { await target.run() })
        }
        let transport = PathReportingTransport(initiatorSide, path: path)
        log.add(binding, transport)
        return transport
    }
    return (core, log, harnesses)
}
