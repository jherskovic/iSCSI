import Foundation
import Testing
@testable import MockTarget
@testable import NVMeKit
@testable import iSCSIKit

/// A transport factory over one `MockNVMeSubsystem`: every call is a fresh
/// in-memory connection, so the controller's two queues (and every
/// recovered pair after them) get their own pipe while sharing one
/// controller registry and one `RAMDisk`. Fault scripts are consumed one per
/// connection, the last one repeating — the NVMe twin of `TargetFleet`.
actor NVMeFleet {
    let subsystem: MockNVMeSubsystem
    let disk: RAMDisk
    private var faultScripts: [MockTargetFaults]
    private var serveTasks: [Task<Void, Never>] = []
    private var transports: [MemoryPipe] = []
    private(set) var connectionsServed = 0

    /// `faultScripts` nil means every connection runs `config.faults`.
    init(config: MockNVMeConfig = MockNVMeConfig(), disk: RAMDisk? = nil,
         faultScripts: [MockTargetFaults]? = nil) {
        let scripts = faultScripts ?? [config.faults]
        precondition(!scripts.isEmpty)
        let disk = disk ?? RAMDisk(blockSize: 4096, capacityBlocks: 4096)
        self.disk = disk
        self.subsystem = MockNVMeSubsystem(config: config, disk: disk)
        self.faultScripts = scripts
    }

    func makeTransport() -> any ConnectionTransport {
        let faults = faultScripts.count > 1 ? faultScripts.removeFirst() : faultScripts[0]
        let (initiatorSide, targetSide) = MemoryPipe.pair()
        let subsystem = self.subsystem
        serveTasks.append(Task { await subsystem.serve(targetSide, faultBox: FaultBox(faults)) })
        transports.append(targetSide)
        connectionsServed += 1
        return initiatorSide
    }

    /// Tear down every connection served so far, as a target reboot would.
    func shutdown() async {
        for t in transports { await t.close() }
        for task in serveTasks { task.cancel() }
        transports = []
        serveTasks = []
    }
}

let testHost = NVMeHostIdentity(uuid: UUID(uuidString: "6BA7B810-9DAD-11D1-80B4-00C04FD430C8")!)

func testControllerConfig(
    subsystemNQN: String = MockNVMeConfig().subsystemNQN,
    tune: (inout NVMeControllerConfig) -> Void = { _ in }
) -> NVMeControllerConfig {
    var config = NVMeControllerConfig(host: testHost, subsystemNQN: subsystemNQN)
    tune(&config)
    return config
}

/// A controller with both queues up, over `fleet`.
func activatedController(
    fleet: NVMeFleet,
    policy: SessionPolicy = testPolicy(),
    tune: (inout NVMeControllerConfig) -> Void = { _ in }
) async throws -> NVMeController {
    let controller = NVMeController(config: testControllerConfig(tune: tune), policy: policy) {
        await fleet.makeTransport()
    }
    try await controller.activate()
    return controller
}
