import Foundation

/// One SCSI task as submitted to a session: CDB + data direction.
public struct SCSITask: Sendable {
    public enum Direction: Sendable, Equatable {
        case none
        case read(expectedLength: UInt32)
        case write(Data)
    }

    public var lun: UInt64
    public var cdb: Data
    public var direction: Direction
    public var attribute: SCSICommandPDU.TaskAttribute

    public init(
        lun: UInt64,
        cdb: Data,
        direction: Direction = .none,
        attribute: SCSICommandPDU.TaskAttribute = .simple
    ) {
        self.lun = lun
        self.cdb = cdb
        self.direction = direction
        self.attribute = attribute
    }
}

/// Completion of a SCSI task.
public struct SCSITaskResult: Sendable, Equatable {
    /// SAM status byte: 0x00 GOOD, 0x02 CHECK CONDITION, 0x08 BUSY, 0x28 TASK
    /// SET FULL, ...
    public var status: UInt8
    /// Data-In payload (reads).
    public var data: Data
    /// Sense bytes when status is CHECK CONDITION.
    public var sense: Data?
    public var residualCount: UInt32
    public var residualIsOverflow: Bool

    public var isGood: Bool { status == 0x00 }

    public init(
        status: UInt8,
        data: Data = Data(),
        sense: Data? = nil,
        residualCount: UInt32 = 0,
        residualIsOverflow: Bool = false
    ) {
        self.status = status
        self.data = data
        self.sense = sense
        self.residualCount = residualCount
        self.residualIsOverflow = residualIsOverflow
    }
}

/// Fixed-format sense data essentials (SPC-4 §4.5.3).
public struct SenseData: Sendable, Equatable {
    public var key: UInt8
    public var asc: UInt8
    public var ascq: UInt8

    public init?(_ bytes: Data) {
        guard bytes.count >= 14 else { return nil }
        let code = bytes.u8(0) & 0x7F
        guard code == 0x70 || code == 0x71 else { return nil } // fixed format
        key = bytes.u8(2) & 0x0F
        asc = bytes.u8(12)
        ascq = bytes.u8(13)
    }

    public var description: String {
        String(format: "sense key 0x%02x asc 0x%02x ascq 0x%02x", key, asc, ascq)
    }
}

/// CDB builders for the commands the initiator issues itself. LBA/length
/// fields are big-endian per SBC/SPC.
public enum CDB {
    public static func testUnitReady() -> Data {
        Data(count: 6)
    }

    public static func inquiry(allocationLength: UInt16 = 255) -> Data {
        var cdb = Data(count: 6)
        cdb.setU8(0x12, 0)
        cdb.setBE16(allocationLength, 3)
        return cdb
    }

    public static func readCapacity10() -> Data {
        var cdb = Data(count: 10)
        cdb.setU8(0x25, 0)
        return cdb
    }

    /// READ CAPACITY(16) — service action in of READ CAPACITY.
    public static func readCapacity16(allocationLength: UInt32 = 32) -> Data {
        var cdb = Data(count: 16)
        cdb.setU8(0x9E, 0)
        cdb.setU8(0x10, 1)
        cdb.setBE32(allocationLength, 10)
        return cdb
    }

    public static func read16(lba: UInt64, blocks: UInt32) -> Data {
        var cdb = Data(count: 16)
        cdb.setU8(0x88, 0)
        cdb.setBE64(lba, 2)
        cdb.setBE32(blocks, 10)
        return cdb
    }

    /// WRITE(16). Set `fua` to force the data to stable media before the target
    /// returns status (Force Unit Access, CDB byte 1 bit 3).
    ///
    /// This matters for Backend A: FSKit signals no barriers, so the extension
    /// cannot know when a filesystem above the disk image wanted a flush. If
    /// the target has a volatile write cache, the only way to keep APFS's
    /// ordering guarantees meaningful is to make each write durable as it is
    /// acknowledged.
    public static func write16(lba: UInt64, blocks: UInt32, fua: Bool = false) -> Data {
        var cdb = Data(count: 16)
        cdb.setU8(0x8A, 0)
        cdb.setU8(fua ? 0x08 : 0x00, 1)
        cdb.setBE64(lba, 2)
        cdb.setBE32(blocks, 10)
        return cdb
    }

    /// MODE SENSE(10) for one mode page. Page 0x08 is the caching page, whose
    /// WCE bit says whether the target's write cache is volatile — i.e. whether
    /// FUA / SYNCHRONIZE CACHE are doing anything.
    public static func modeSense10(pageCode: UInt8, allocationLength: UInt16 = 192) -> Data {
        var cdb = Data(count: 10)
        cdb.setU8(0x5A, 0)
        cdb.setU8(pageCode & 0x3F, 2)   // PC=0: current values
        cdb.setBE16(allocationLength, 7)
        return cdb
    }

    public static func synchronizeCache16(lba: UInt64 = 0, blocks: UInt32 = 0) -> Data {
        var cdb = Data(count: 16)
        cdb.setU8(0x91, 0)
        cdb.setBE64(lba, 2)
        cdb.setBE32(blocks, 10)
        return cdb
    }

    public static func reportLuns(allocationLength: UInt32 = 1024) -> Data {
        var cdb = Data(count: 12)
        cdb.setU8(0xA0, 0)
        cdb.setBE32(allocationLength, 6)
        return cdb
    }
}
