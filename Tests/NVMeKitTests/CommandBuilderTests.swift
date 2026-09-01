import Foundation
import Testing
import iSCSIKit
@testable import NVMeKit

@Suite("Admin, Fabrics and NVM command builders")
struct CommandBuilderTests {
    @Test func fabricsConnectGoldenBytes() {
        let hostID = Data((0 ..< 16).map { UInt8($0) })
        let (sqe, data) = NVMeCommands.connect(
            commandID: 0x0102, queueID: 0, queueEntries: 32, keepAliveMS: 20_000,
            hostID: hostID, controllerID: 0xFFFF,
            subsystemNQN: "nqn.2026-08.test:disk", hostNQN: "nqn.2014-08.org.nvmexpress:uuid:1")
        let b = sqe.bytes
        #expect(b.u8(0) == 0x7F)                       // Fabrics
        #expect(b.u8(1) & 0xC0 == 0x40)                // SGL
        #expect(b.leU16(2) == 0x0102)
        #expect(b.u8(4) == 0x01)                       // FCTYPE Connect
        #expect(b.leU64(24) == 0 && b.leU32(32) == 1024 && b.u8(39) == 0x01)  // in-capsule SGL
        #expect(b.leU16(40) == 0)                      // RECFMT
        #expect(b.leU16(42) == 0)                      // QID
        #expect(b.leU16(44) == 31)                     // SQSIZE is 0's based
        #expect(b.u8(46) == 0)                         // CATTR: SQ flow control stays on
        #expect(b.leU32(48) == 20_000)                 // KATO in ms
        #expect(data.count == 1024)                    // sizeof(struct nvmf_connect_data)
        #expect(data.sub(0, 16) == hostID)
        #expect(data.leU16(16) == 0xFFFF)
        #expect(String(decoding: data.sub(256, 21), as: UTF8.self) == "nqn.2026-08.test:disk")
        #expect(data.u8(256 + 21) == 0)
        #expect(String(decoding: data.sub(512, 33), as: UTF8.self) == "nqn.2014-08.org.nvmexpress:uuid:1")
        #expect(data.u8(512 + 33) == 0)
    }

    @Test func ioQueueConnectCarriesTheControllerIDAndNoKATO() {
        let (sqe, data) = NVMeCommands.connect(
            commandID: 1, queueID: 1, queueEntries: 128, keepAliveMS: 0,
            hostID: Data(count: 16), controllerID: 0x0007,
            subsystemNQN: "nqn.a", hostNQN: "nqn.b")
        #expect(sqe.bytes.leU16(42) == 1)
        #expect(sqe.bytes.leU16(44) == 127)
        #expect(sqe.bytes.leU32(48) == 0)
        #expect(data.leU16(16) == 7)
    }

    @Test func propertyGetAndSet() {
        let get = NVMeCommands.propertyGet(commandID: 2, offset: NVMeProperty.csts, wide: false)
        #expect(get.bytes.u8(0) == 0x7F && get.bytes.u8(4) == 0x04)
        #expect(get.bytes.u8(40) == 0 && get.bytes.leU32(44) == 0x1C)
        let wide = NVMeCommands.propertyGet(commandID: 2, offset: NVMeProperty.cap, wide: true)
        #expect(wide.bytes.u8(40) == 1 && wide.bytes.leU32(44) == 0)

        // 4-byte attribute (ATTRIB 0): nvmet refuses 8-byte property sets, and
        // CC is a 32-bit register anyway.
        let set = NVMeCommands.propertySet(commandID: 3, offset: NVMeProperty.cc,
                                           value: NVMeCommands.controllerConfigurationEnable)
        #expect(set.bytes.u8(0) == 0x7F && set.bytes.u8(4) == 0x00)
        #expect(set.bytes.u8(40) == 0 && set.bytes.leU32(44) == 0x14)
        #expect(set.bytes.leU64(48) == 0x0046_0001)    // EN | CSS NVM | IOSQES 6 | IOCQES 4

        // nvmet requires PSDT = SGL on every command, data or not; a data-less
        // command carries a null transport SGL exactly as the Linux host sends.
        for sqe in [get, set, NVMeCommands.keepAlive(commandID: 4), NVMeCommands.flush(commandID: 5, nsid: 1)] {
            #expect(sqe.flags & 0xC0 == 0x40)
            #expect(sqe.bytes.leU32(32) == 0 && sqe.bytes.u8(39) == 0x5A)
        }
    }

    @Test func identifyAndFeaturesAndLogPage() {
        let ctrl = NVMeCommands.identify(commandID: 5, cns: 0x01)
        #expect(ctrl.bytes.u8(0) == 0x06 && ctrl.bytes.leU32(4) == 0 && ctrl.bytes.u8(40) == 0x01)
        #expect(ctrl.bytes.leU32(32) == 4096 && ctrl.bytes.u8(39) == 0x5A)
        let ns = NVMeCommands.identify(commandID: 6, cns: 0x00, nsid: 1)
        #expect(ns.bytes.leU32(4) == 1 && ns.bytes.u8(40) == 0)

        let feat = NVMeCommands.setFeatures(commandID: 7, featureID: 0x07, dword11: 0)
        #expect(feat.bytes.u8(0) == 0x09 && feat.bytes.leU32(40) == 7 && feat.bytes.leU32(44) == 0)

        let log = NVMeCommands.getLogPage(commandID: 8, logID: 0x70, offset: 1024, length: 2048)
        #expect(log.bytes.u8(0) == 0x02 && log.bytes.u8(40) == 0x70)
        #expect(log.bytes.leU16(42) == 511 && log.bytes.leU16(44) == 0)   // NUMD 0's based
        #expect(log.bytes.leU64(48) == 1024)
        #expect(log.bytes.leU32(32) == 2048 && log.bytes.u8(39) == 0x5A)

        let ka = NVMeCommands.keepAlive(commandID: 9)
        #expect(ka.bytes.u8(0) == 0x18)
    }

    @Test func nvmReadWriteFlush() {
        let read = NVMeCommands.read(commandID: 9, nsid: 1, slba: 0x1_0000_0000, blocks: 8, blockSize: 4096)
        #expect(read.bytes.u8(0) == 0x02 && read.bytes.leU32(4) == 1)
        #expect(read.bytes.leU64(40) == 0x1_0000_0000)
        #expect(read.bytes.leU16(48) == 7)                 // NLB is 0's based
        #expect(read.bytes.leU16(50) == 0)
        #expect(read.bytes.leU32(32) == 32768 && read.bytes.u8(39) == 0x5A)

        let fua = NVMeCommands.write(commandID: 10, nsid: 1, slba: 5, blocks: 1, blockSize: 512,
                                     fua: true, inCapsule: true)
        #expect(fua.bytes.u8(0) == 0x01)
        #expect(fua.bytes.leU16(48) == 0 && fua.bytes.leU16(50) == 0x4000)   // FUA bit 14
        #expect(fua.bytes.leU32(32) == 512 && fua.bytes.u8(39) == 0x01)

        let big = NVMeCommands.write(commandID: 11, nsid: 1, slba: 0, blocks: 64, blockSize: 4096,
                                     fua: false, inCapsule: false)
        #expect(big.bytes.leU16(50) == 0)
        #expect(big.bytes.leU32(32) == 262_144 && big.bytes.u8(39) == 0x5A)

        let flush = NVMeCommands.flush(commandID: 12, nsid: 1)
        #expect(flush.bytes.u8(0) == 0x00 && flush.bytes.leU32(4) == 1)
    }

    @Test func capabilitiesAndStatusRegisters() {
        // MQES 127, TO 30 (x 500 ms), CSS bit 37 (NVM command set), MPSMIN 0.
        let cap = ControllerCapabilities(raw: 0x0000_0020_1E00_007F)
        #expect(cap.maxQueueEntries == 128)
        #expect(cap.readyTimeoutMS == 15_000)
        #expect(cap.supportsNVMCommandSet)
        #expect(cap.minPageBytes == 4096)

        #expect(ControllerStatus(raw: 0x1).ready && !ControllerStatus(raw: 0x1).fatal)
        #expect(ControllerStatus(raw: 0x2).fatal)
    }
}
