import Foundation
import Testing
@testable import iSCSIKit

@Suite("SCSI CDB builders")
struct SCSICDBTests {
    @Test func write16DefaultsToNoFUA() {
        let cdb = CDB.write16(lba: 0x1122_3344_5566_7788, blocks: 8)
        #expect(cdb.count == 16)
        #expect(cdb.u8(0) == 0x8A)
        // Byte 1 carries the flags; FUA is bit 3 and must be clear by default.
        #expect(cdb.u8(1) == 0x00)
        #expect(cdb.beU64(2) == 0x1122_3344_5566_7788)
        #expect(cdb.beU32(10) == 8)
    }

    @Test func write16SetsFUABit() {
        let cdb = CDB.write16(lba: 42, blocks: 1, fua: true)
        #expect(cdb.u8(0) == 0x8A)
        #expect(cdb.u8(1) & 0x08 == 0x08)
        // Only FUA — setting it must not disturb the other flag bits, notably
        // DPO (bit 4) or the protection field in bits 5-7.
        #expect(cdb.u8(1) == 0x08)
        #expect(cdb.beU64(2) == 42)
    }

    @Test func modeSense10RequestsTheCachingPage() {
        let cdb = CDB.modeSense10(pageCode: 0x08)
        #expect(cdb.count == 10)
        #expect(cdb.u8(0) == 0x5A)
        // PC field (bits 6-7 of byte 2) is 0 = current values; page code in 0-5.
        #expect(cdb.u8(2) == 0x08)
        #expect(cdb.beU16(7) == 192)
    }

    @Test func modeSense10MasksAnOversizedPageCode() {
        // Page code is six bits; a caller passing junk must not corrupt the PC
        // field and silently request changeable or saved values instead.
        let cdb = CDB.modeSense10(pageCode: 0xFF, allocationLength: 64)
        #expect(cdb.u8(2) == 0x3F)
        #expect(cdb.beU16(7) == 64)
    }

    @Test func read16IsUnaffectedByTheFUAChange() {
        let cdb = CDB.read16(lba: 7, blocks: 2)
        #expect(cdb.u8(0) == 0x88)
        #expect(cdb.u8(1) == 0x00)
        #expect(cdb.beU64(2) == 7)
        #expect(cdb.beU32(10) == 2)
    }
}
