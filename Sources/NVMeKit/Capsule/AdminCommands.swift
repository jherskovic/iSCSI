import Foundation
import iSCSIKit

public enum NVMeOpcode {
    public enum Admin {
        public static let getLogPage: UInt8 = 0x02
        public static let identify: UInt8 = 0x06
        public static let setFeatures: UInt8 = 0x09
        public static let getFeatures: UInt8 = 0x0A
        public static let keepAlive: UInt8 = 0x18
        public static let fabrics: UInt8 = 0x7F
    }

    public enum NVM {
        public static let flush: UInt8 = 0x00
        public static let write: UInt8 = 0x01
        public static let read: UInt8 = 0x02
    }
}

/// Fabrics command types (NVMe-oF 1.1 §3): the byte at SQE offset 4.
public enum FabricsCommandType {
    public static let propertySet: UInt8 = 0x00
    public static let connect: UInt8 = 0x01
    public static let propertyGet: UInt8 = 0x04
}

/// Controller property (register) offsets reachable over Fabrics.
public enum NVMeProperty {
    public static let cap: UInt32 = 0x00
    public static let vs: UInt32 = 0x08
    public static let cc: UInt32 = 0x14
    public static let csts: UInt32 = 0x1C
}

public enum NVMeFeature {
    public static let numberOfQueues: UInt8 = 0x07
    public static let keepAliveTimer: UInt8 = 0x0F
}

public enum NVMeLogPage {
    public static let discovery: UInt8 = 0x70
}

public enum IdentifyCNS {
    public static let namespace: UInt8 = 0x00
    public static let controller: UInt8 = 0x01
    public static let activeNamespaces: UInt8 = 0x02
}

/// CAP register (NVMe Base 2.0 §3.1.3.1), as read by Property Get.
public struct ControllerCapabilities: Sendable, Equatable {
    public let raw: UInt64
    public init(raw: UInt64) { self.raw = raw }

    /// MQES is 0's based: the largest I/O queue the controller allows.
    public var maxQueueEntries: Int { Int(raw & 0xFFFF) + 1 }
    /// TO, in 500 ms units: how long CSTS.RDY may take to follow CC.EN.
    public var readyTimeoutMS: Int { Int((raw >> 24) & 0xFF) * 500 }
    /// CSS bit 0: the NVM command set.
    public var supportsNVMCommandSet: Bool { (raw >> 37) & 1 == 1 }
    /// MPSMIN: the smallest memory page size, which is the MDTS unit.
    public var minPageBytes: Int { 1 << (12 + Int((raw >> 48) & 0xF)) }
}

/// CSTS register.
public struct ControllerStatus: Sendable, Equatable {
    public let raw: UInt32
    public init(raw: UInt32) { self.raw = raw }
    public var ready: Bool { raw & 0x1 != 0 }
    public var fatal: Bool { raw & 0x2 != 0 }
}

/// SQE builders for every command this initiator sends. Each returns a
/// complete SQE with the command ID and an SGL set; nvmet requires PSDT =
/// SGL on every command, so data-less ones carry a null transport SGL
/// exactly as the Linux host does.
public enum NVMeCommands {
    public static let connectDataSize = 4096

    /// CC value that enables the controller: EN, CSS = NVM, MPS = 0 (4 KiB),
    /// AMS = round robin, IOSQES = 6 (64 B), IOCQES = 4 (16 B).
    public static let controllerConfigurationEnable: UInt32 = 0x0046_0001

    // MARK: Fabrics

    /// Fabrics Connect. The 4 KiB data (HOSTID, CNTLID, SUBNQN, HOSTNQN) is
    /// always in-capsule. `queueEntries` is the real size; SQSIZE on the
    /// wire is 0's based. KATO is only meaningful on the admin queue (QID 0)
    /// and must be 0 on I/O queues. CATTR stays 0: SQ flow control on.
    public static func connect(
        commandID: UInt16, queueID: UInt16, queueEntries: UInt16, keepAliveMS: UInt32,
        hostID: Data, controllerID: UInt16, subsystemNQN: String, hostNQN: String
    ) -> (sqe: SQE, data: Data) {
        precondition(hostID.count == 16, "HOSTID is 16 bytes")
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.Admin.fabrics
        sqe.fabricsType = FabricsCommandType.connect
        sqe.commandID = commandID
        sqe.sgl = .inCapsule(length: UInt32(connectDataSize))
        sqe.bytes.setLE16(0, 40)                       // RECFMT
        sqe.bytes.setLE16(queueID, 42)
        sqe.bytes.setLE16(queueEntries - 1, 44)        // SQSIZE, 0's based
        sqe.bytes.setU8(0, 46)                         // CATTR
        sqe.bytes.setLE32(keepAliveMS, 48)             // KATO

        var data = Data(count: connectDataSize)
        data.setSub(hostID, 0)
        data.setLE16(controllerID, 16)
        data.setSub(nqnField(subsystemNQN), 256)
        data.setSub(nqnField(hostNQN), 512)
        return (sqe, data)
    }

    /// An NQN as a 256-byte NUL-padded field.
    static func nqnField(_ nqn: String) -> Data {
        var field = Data(count: 256)
        let bytes = Data(nqn.utf8.prefix(255))
        field.setSub(bytes, 0)
        return field
    }

    /// Property Get. `wide` selects an 8-byte read (CAP); CC and CSTS are
    /// 4 bytes. The value comes back in CQE DW0/DW1.
    public static func propertyGet(commandID: UInt16, offset: UInt32, wide: Bool) -> SQE {
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.Admin.fabrics
        sqe.fabricsType = FabricsCommandType.propertyGet
        sqe.commandID = commandID
        sqe.sgl = .transport(length: 0)
        sqe.bytes.setU8(wide ? 1 : 0, 40)              // ATTRIB
        sqe.bytes.setLE32(offset, 44)
        return sqe
    }

    /// Property Set, 4-byte attribute only: nvmet answers Invalid Field to
    /// an 8-byte set, and every register we write (CC) is 32 bits.
    public static func propertySet(commandID: UInt16, offset: UInt32, value: UInt32) -> SQE {
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.Admin.fabrics
        sqe.fabricsType = FabricsCommandType.propertySet
        sqe.commandID = commandID
        sqe.sgl = .transport(length: 0)
        sqe.bytes.setU8(0, 40)                         // ATTRIB: 4 bytes
        sqe.bytes.setLE32(offset, 44)
        sqe.bytes.setLE64(UInt64(value), 48)
        return sqe
    }

    // MARK: Admin

    /// Identify: CNS 00h (namespace, `nsid`), 01h (controller), 02h (active
    /// namespace list starting after `nsid`). Always 4096 bytes back.
    public static func identify(commandID: UInt16, cns: UInt8, nsid: UInt32 = 0) -> SQE {
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.Admin.identify
        sqe.commandID = commandID
        sqe.nsid = nsid
        sqe.sgl = .transport(length: 4096)
        sqe.bytes.setU8(cns, 40)
        return sqe
    }

    public static func setFeatures(commandID: UInt16, featureID: UInt8, dword11: UInt32) -> SQE {
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.Admin.setFeatures
        sqe.commandID = commandID
        sqe.sgl = .transport(length: 0)
        sqe.cdw10 = UInt32(featureID)
        sqe.cdw11 = dword11
        return sqe
    }

    /// Get Log Page for `length` bytes (a multiple of 4) at `offset`.
    /// NUMDL/NUMDU carry the 0's-based dword count.
    public static func getLogPage(commandID: UInt16, logID: UInt8, offset: UInt64, length: UInt32) -> SQE {
        precondition(length >= 4 && length % 4 == 0, "log page reads are whole dwords")
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.Admin.getLogPage
        sqe.commandID = commandID
        sqe.sgl = .transport(length: length)
        let numd = length / 4 - 1
        sqe.bytes.setU8(logID, 40)
        sqe.bytes.setLE16(UInt16(numd & 0xFFFF), 42)
        sqe.bytes.setLE16(UInt16(numd >> 16), 44)
        sqe.bytes.setLE64(offset, 48)
        return sqe
    }

    public static func keepAlive(commandID: UInt16) -> SQE {
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.Admin.keepAlive
        sqe.commandID = commandID
        sqe.sgl = .transport(length: 0)
        return sqe
    }

    // MARK: NVM

    public static func read(commandID: UInt16, nsid: UInt32, slba: UInt64, blocks: UInt32, blockSize: Int) -> SQE {
        precondition(blocks >= 1 && blocks <= 0x1_0000, "NLB is a 16-bit 0's-based field")
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.NVM.read
        sqe.commandID = commandID
        sqe.nsid = nsid
        sqe.sgl = .transport(length: blocks * UInt32(blockSize))
        sqe.bytes.setLE64(slba, 40)
        sqe.bytes.setLE16(UInt16(blocks - 1), 48)
        return sqe
    }

    /// Write with optional Force Unit Access (CDW12 bit 30, i.e. bit 14 of
    /// the control word at byte 50). `inCapsule` decides the SGL: data
    /// following the SQE in the capsule, or data the controller will R2T for.
    public static func write(commandID: UInt16, nsid: UInt32, slba: UInt64, blocks: UInt32,
                             blockSize: Int, fua: Bool, inCapsule: Bool) -> SQE {
        precondition(blocks >= 1 && blocks <= 0x1_0000, "NLB is a 16-bit 0's-based field")
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.NVM.write
        sqe.commandID = commandID
        sqe.nsid = nsid
        let length = blocks * UInt32(blockSize)
        sqe.sgl = inCapsule ? .inCapsule(length: length) : .transport(length: length)
        sqe.bytes.setLE64(slba, 40)
        sqe.bytes.setLE16(UInt16(blocks - 1), 48)
        sqe.bytes.setLE16(fua ? 0x4000 : 0, 50)
        return sqe
    }

    public static func flush(commandID: UInt16, nsid: UInt32) -> SQE {
        var sqe = SQE()
        sqe.opcode = NVMeOpcode.NVM.flush
        sqe.commandID = commandID
        sqe.nsid = nsid
        sqe.sgl = .transport(length: 0)
        return sqe
    }
}
