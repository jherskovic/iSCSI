import Foundation

/// Which block size a disk's GPT was written with, read from the disk itself.
///
/// The attach presents a LUN to DiskImages as a raw image, and DiskImages
/// assumes 512-byte blocks unless told otherwise. A GPT names its locations in
/// blocks, so a 4Kn LUN partitioned by a 4Kn-aware initiator keeps its primary
/// header at byte 4096 — LBA 1 of 4096 — and at 512 DiskImages finds only the
/// protective MBR and calls the disk unformatted (GitHub issue #2). The reverse
/// holds just as hard: every disk this app has partitioned so far, 4Kn ones
/// included, has its header at byte 512, and presenting it at 4096 hides it the
/// same way (both measured with DiskImages alone, 2026-10-05). So the block
/// size follows the header, not the LUN.
public enum PartitionTableProbe {
    /// The bytes a caller should read: enough to hold a header at 4096.
    public static let prefixLength = 8192

    /// 512 or 4096 when `prefix` — the first bytes of the disk — holds a
    /// primary GPT header written with that block size; nil when it holds
    /// neither: blank, MBR only, a filesystem on the whole disk.
    ///
    /// A header counts when it carries the signature and names itself LBA 1.
    /// The CRC is not checked: on a 512-block disk byte 4096 falls inside the
    /// partition entry array, which never holds the signature, so the two
    /// cannot be confused. 512 is checked first; it is what attaches today.
    public static func gptBlockSize(prefix: Data) -> Int? {
        for blockSize in [512, 4096] where isPrimaryHeader(prefix, at: blockSize) {
            return blockSize
        }
        return nil
    }

    private static let signature = Array("EFI PART".utf8)
    /// `MyLBA`, a little-endian UInt64 at offset 24 of the header.
    private static let myLBAOffset = 24

    private static func isPrimaryHeader(_ data: Data, at offset: Int) -> Bool {
        let start = data.startIndex + offset
        guard data.count >= offset + myLBAOffset + 8 else { return false }
        guard data[start ..< start + signature.count].elementsEqual(signature) else { return false }
        let lba = data[(start + myLBAOffset) ..< (start + myLBAOffset + 8)]
            .reversed().reduce(UInt64(0)) { $0 << 8 | UInt64($1) }
        return lba == 1
    }
}
