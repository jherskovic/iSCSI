import Foundation
import iSCSIKit

/// Serializes a PDU to wire bytes: CH + PSH [+ HDGST] + data [+ DDGST].
///
/// Always HPDA = 0 (we never ask the controller to align data) and CPDA = 0
/// is required of the controller at ICResp, so PDO is exactly HLEN + HDGST
/// and no padding is ever emitted.
public struct NVMeTCPSerializer: Sendable {
    public var digests: NVMeTCPDigests

    public init(digests: NVMeTCPDigests = NVMeTCPDigests()) {
        self.digests = digests
    }

    public func serialize(_ raw: RawNVMeTCPPDU) -> Data {
        let hlen = raw.hlen
        let hdgst = digests.header ? 4 : 0
        let hasData = !raw.data.isEmpty
        let ddgst = (digests.data && hasData) ? 4 : 0
        var flags = raw.flags.subtracting([.headerDigest, .dataDigest])
        if hdgst > 0 { flags.insert(.headerDigest) }
        if ddgst > 0 { flags.insert(.dataDigest) }
        let pdo = hasData ? hlen + hdgst : 0
        let plen = hlen + hdgst + raw.data.count + ddgst

        var out = Data(capacity: plen)
        out.append(NVMeTCPHeader(type: raw.type, flags: flags, hlen: UInt8(hlen),
                                 pdo: UInt8(pdo), plen: UInt32(plen)).encoded)
        out.append(raw.psh)
        // HDGST covers CH + PSH only.
        if hdgst > 0 { out.append(CRC32C.wireDigest(out)) }
        if hasData {
            out.append(raw.data)
            // DDGST covers the DATA field only — never the header, never padding.
            if ddgst > 0 { out.append(CRC32C.wireDigest(raw.data)) }
        }
        return out
    }
}

/// Incremental deframer: feed arbitrary byte chunks, pull complete PDUs.
/// Verifies digests, enforces a PLEN ceiling before buffering a byte of the
/// payload, and locates data by PDO (which absorbs the header digest and any
/// controller-side alignment padding) rather than by HLEN.
///
/// Same buffer discipline as iSCSIKit's `PDUDeframer`: an index over one
/// growing buffer, compacted by copy, never `removeFirst`.
public struct NVMeTCPDeframer: Sendable {
    public var digests: NVMeTCPDigests
    /// Upper bound accepted for PLEN. Bounds memory per PDU against a hostile
    /// or broken peer; sized by the caller from MAXH2CDATA / the transfer cap.
    public var maxPDUBytes: Int

    private var buffer = Data()
    private var consumed = 0
    private static let compactThreshold = 64 * 1024

    public init(digests: NVMeTCPDigests = NVMeTCPDigests(), maxPDUBytes: Int = 1 << 20) {
        self.digests = digests
        self.maxPDUBytes = maxPDUBytes
    }

    public mutating func append(_ bytes: Data) {
        compactIfNeeded()
        buffer.append(bytes)
    }

    /// Bytes buffered but not yet consumed as a complete PDU.
    public var buffered: Int { buffer.count - consumed }

    private mutating func compactIfNeeded() {
        guard consumed > 0 else { return }
        guard consumed >= Self.compactThreshold || consumed * 2 >= buffer.count else { return }
        if consumed >= buffer.count {
            buffer = Data()
        } else {
            var fresh = Data(capacity: buffer.count - consumed)
            fresh.append(contentsOf: buffer[(buffer.startIndex + consumed)...])
            buffer = fresh
        }
        consumed = 0
    }

    /// Returns the next complete PDU, or nil if more bytes are needed. On a
    /// thrown error the deframer is poisoned: any framing or digest error
    /// tears the connection down, so no resync is attempted.
    public mutating func next() throws -> RawNVMeTCPPDU? {
        let avail = buffer.count - consumed
        guard avail >= NVMeTCPHeader.size else { return nil }
        let header = try NVMeTCPHeader(bytes: buffer.sub(consumed, NVMeTCPHeader.size))
        let hlen = Int(header.hlen)
        let pdo = Int(header.pdo)
        let plen = Int(header.plen)

        guard plen <= maxPDUBytes else {
            throw NVMeTCPError.pduTooLarge(length: plen, limit: maxPDUBytes)
        }
        guard hlen >= NVMeTCPHeader.size else {
            throw NVMeTCPError.malformed("HLEN \(hlen) is shorter than the common header")
        }
        // The digest bits must agree with what was negotiated; the Linux host
        // treats a disagreement as a protocol error, and so do we.
        guard header.flags.contains(.headerDigest) == digests.header else {
            throw NVMeTCPError.malformed("HDGSTF does not match the negotiated header digest")
        }
        let hdgst = digests.header ? 4 : 0
        guard plen >= hlen + hdgst else {
            throw NVMeTCPError.malformed("PLEN \(plen) is shorter than the header (\(hlen + hdgst))")
        }

        let dataLen: Int
        let ddgst: Int
        if pdo == 0 {
            guard plen == hlen + hdgst else {
                throw NVMeTCPError.malformed("PDO 0 but PLEN \(plen) exceeds the header (\(hlen + hdgst))")
            }
            guard !header.flags.contains(.dataDigest) else {
                throw NVMeTCPError.malformed("DDGSTF set on a PDU with no data")
            }
            dataLen = 0
            ddgst = 0
        } else {
            guard header.flags.contains(.dataDigest) == digests.data else {
                throw NVMeTCPError.malformed("DDGSTF does not match the negotiated data digest")
            }
            ddgst = digests.data ? 4 : 0
            guard pdo >= hlen + hdgst, pdo + ddgst <= plen else {
                throw NVMeTCPError.malformed("PDO \(pdo) is inconsistent with HLEN \(hlen) / PLEN \(plen)")
            }
            dataLen = plen - pdo - ddgst
        }

        guard avail >= plen else { return nil }

        if hdgst > 0 {
            let expected = CRC32C.checksum(buffer.sub(consumed, hlen))
            guard expected == buffer.leU32(consumed + hlen) else {
                throw NVMeTCPError.headerDigestMismatch
            }
        }
        let dataStart = consumed + pdo
        if ddgst > 0 {
            let expected = CRC32C.checksum(buffer.sub(dataStart, dataLen))
            guard expected == buffer.leU32(dataStart + dataLen) else {
                throw NVMeTCPError.dataDigestMismatch
            }
        }

        let raw = RawNVMeTCPPDU(
            rawType: header.type,
            flags: header.flags,
            psh: Data(buffer.sub(consumed + NVMeTCPHeader.size, hlen - NVMeTCPHeader.size)),
            data: Data(buffer.sub(dataStart, dataLen))
        )
        consumed += plen
        return raw
    }
}
