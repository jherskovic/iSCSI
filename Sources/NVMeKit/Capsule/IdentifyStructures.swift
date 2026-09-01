import Foundation
import iSCSIKit

/// Pure parsers for the data structures the controller returns. All static
/// or `init(data:)` over bytes, so the fuzzer can reach every one without a
/// session. Offsets are NVMe Base 2.0 / NVMe-oF 1.1 (cross-checked against
/// Linux `struct nvme_id_ctrl`, `nvme_id_ns`, `nvmf_disc_rsp_page_*`).

/// An ASCII field: up to the first NUL, whitespace trimmed (SN/MN/FR are
/// space-padded; NQNs and discovery strings are NUL-padded, and nvmet's
/// TRADDR can carry trailing spaces).
func asciiField(_ data: Data, _ offset: Int, _ length: Int) -> String {
    let raw = data.sub(offset, length)
    let end = raw.firstIndex(of: 0) ?? raw.endIndex
    return String(decoding: raw[raw.startIndex ..< end], as: UTF8.self)
        .trimmingCharacters(in: .whitespaces)
}

/// Identify Controller (CNS 01h), the fields this initiator uses.
public struct IdentifyController: Sendable, Equatable {
    public static let size = 4096

    public var serial: String
    public var model: String
    public var firmware: String
    /// Maximum Data Transfer Size as a power of two of `minPageBytes`; 0 = unlimited.
    public var mdts: UInt8
    public var controllerID: UInt16
    /// KAS in 100 ms units, as milliseconds; 0 when Keep Alive is unsupported.
    public var keepAliveGranularityMS: Int
    /// MAXCMD: the most commands the controller will have outstanding per queue.
    public var maxOutstandingCommands: Int
    public var namespaceCount: UInt32
    /// VWC bit 0: a volatile write cache exists, so FUA and Flush matter.
    public var volatileWriteCachePresent: Bool
    public var sgls: UInt32
    public var subsystemNQN: String
    /// NVMe-oF: I/O command capsule size in 16-byte units (includes the SQE).
    public var ioccsz: UInt32
    public var iorcsz: UInt32
    /// NVMe-oF: in-capsule data offset in 16-byte units.
    public var icdoff: UInt16

    public init(data: Data) throws {
        guard data.count >= Self.size else {
            throw NVMeTCPError.malformed("Identify Controller returned \(data.count) bytes, needs 4096")
        }
        serial = asciiField(data, 4, 20)
        model = asciiField(data, 24, 40)
        firmware = asciiField(data, 64, 8)
        mdts = data.u8(77)
        controllerID = data.leU16(78)
        keepAliveGranularityMS = Int(data.leU16(320)) * 100
        maxOutstandingCommands = Int(data.leU16(514))
        namespaceCount = data.leU32(516)
        volatileWriteCachePresent = data.u8(525) & 0x01 != 0
        sgls = data.leU32(536)
        subsystemNQN = asciiField(data, 768, 256)
        ioccsz = data.leU32(1792)
        iorcsz = data.leU32(1796)
        icdoff = data.leU16(1800)
    }

    /// Bytes of data that may follow the SQE in an I/O command capsule.
    public var inCapsuleDataBytes: Int { max(0, Int(ioccsz) * 16 - SQE.size) }

    public var inCapsuleDataOffsetBytes: Int { Int(icdoff) * 16 }

    /// MDTS in bytes for the given MPSMIN page size; nil when unlimited.
    public func maxTransferBytes(pageBytes: Int) -> Int? {
        mdts == 0 ? nil : (1 << Int(mdts)) * pageBytes
    }
}

/// Identify Namespace (CNS 00h): geometry, with the same sanity rules as
/// `ISCSIBlockDevice.geometry(fromReadCapacity16:)` — a power-of-two block
/// size between 512 and 1 MiB, a non-zero count, no overflow — plus one of
/// its own: no per-block metadata, which this initiator cannot carry.
public enum IdentifyNamespace {
    public static let size = 4096

    public static func geometry(from data: Data) throws -> (blockSize: Int, blockCount: UInt64) {
        guard data.count >= Self.size else {
            throw NVMeTCPError.malformed("Identify Namespace returned \(data.count) bytes, needs 4096")
        }
        let nsze = data.leU64(0)
        let nlbaf = Int(data.u8(25))                   // 0's based
        let flbas = data.u8(26)
        // Bits 3:0 index the format; bits 6:5 extend it when more than 16
        // formats are defined (NVMe 2.0).
        var index = Int(flbas & 0x0F)
        if nlbaf >= 16 { index |= Int((flbas >> 5) & 0x03) << 4 }
        guard index <= nlbaf, index < 64 else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: 0, blockCount: nsze,
                reason: "FLBAS selects LBA format \(index) but only \(nlbaf + 1) are defined")
        }
        let entry = 128 + 4 * index
        let metadata = data.leU16(entry)
        let lbads = data.u8(entry + 2)
        guard metadata == 0 else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: 1 << Int(lbads), blockCount: nsze,
                reason: "LBA format carries \(metadata) bytes of metadata per block, which is unsupported")
        }
        guard lbads >= 9, lbads <= 20 else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: 0, blockCount: nsze,
                reason: "LBA data size 2^\(lbads) is outside 512 bytes to 1 MiB")
        }
        let blockSize = 1 << Int(lbads)
        guard nsze > 0 else {
            throw BlockDeviceError.invalidGeometry(blockSize: blockSize, blockCount: 0, reason: "zero blocks")
        }
        guard !blockSize.multipliedReportingOverflow(by: Int(clamping: nsze)).overflow,
              !UInt64(blockSize).multipliedReportingOverflow(by: nsze).overflow else {
            throw BlockDeviceError.invalidGeometry(
                blockSize: blockSize, blockCount: nsze,
                reason: "block size x block count exceeds 2^64 bytes")
        }
        return (blockSize, nsze)
    }
}

/// Identify Active Namespace ID list (CNS 02h): up to 1024 ascending NSIDs,
/// zero-terminated.
public enum ActiveNamespaceList {
    public static func parse(_ data: Data) -> [UInt32] {
        var out: [UInt32] = []
        var offset = 0
        while offset + 4 <= data.count, out.count < 1024 {
            let id = data.leU32(offset)
            if id == 0 { break }
            out.append(id)
            offset += 4
        }
        return out
    }
}

/// One 1024-byte entry of the Discovery Log Page.
public struct DiscoveryLogEntry: Sendable, Equatable {
    public static let size = 1024

    /// 3 = TCP.
    public var trtype: UInt8
    public var adrfam: UInt8
    /// 1 = discovery subsystem, 2 = NVM subsystem.
    public var subtype: UInt8
    public var treq: UInt8
    public var portID: UInt16
    public var controllerID: UInt16
    public var adminQueueEntries: UInt16
    public var trsvcid: String
    public var subnqn: String
    public var traddr: String

    public static let transportTCP: UInt8 = 3
    public static let subtypeNVM: UInt8 = 2

    public init(data: Data) throws {
        guard data.count >= Self.size else {
            throw NVMeTCPError.malformed("discovery entry is \(data.count) bytes, needs 1024")
        }
        trtype = data.u8(0)
        adrfam = data.u8(1)
        subtype = data.u8(2)
        treq = data.u8(3)
        portID = data.leU16(4)
        controllerID = data.leU16(6)
        adminQueueEntries = data.leU16(8)
        trsvcid = asciiField(data, 32, 32)
        subnqn = asciiField(data, 256, 256)
        traddr = asciiField(data, 512, 256)
    }
}

/// Discovery Log Page (LID 70h): a 1024-byte header then 1024-byte entries.
public struct DiscoveryLogPage: Sendable, Equatable {
    public static let headerSize = 1024

    public var genctr: UInt64
    public var numrec: UInt64
    public var recfmt: UInt16
    public var entries: [DiscoveryLogEntry]

    /// Parses whatever entries are actually present: NUMREC is what the
    /// controller claims, and a first read of just the header, or a page that
    /// grew between reads, legitimately carries fewer. A torn trailing entry
    /// is dropped, not misread.
    public static func parse(_ data: Data) throws -> DiscoveryLogPage {
        guard data.count >= headerSize else {
            throw NVMeTCPError.malformed("discovery log page is \(data.count) bytes, needs at least 1024")
        }
        let genctr = data.leU64(0)
        let numrec = data.leU64(8)
        let recfmt = data.leU16(16)
        let available = (data.count - headerSize) / DiscoveryLogEntry.size
        let count = Int(min(numrec, UInt64(available)))
        var entries: [DiscoveryLogEntry] = []
        entries.reserveCapacity(count)
        for i in 0 ..< count {
            entries.append(try DiscoveryLogEntry(
                data: data.sub(headerSize + i * DiscoveryLogEntry.size, DiscoveryLogEntry.size)))
        }
        return DiscoveryLogPage(genctr: genctr, numrec: numrec, recfmt: recfmt, entries: entries)
    }
}
