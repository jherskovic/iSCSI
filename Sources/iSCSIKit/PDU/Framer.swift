import Foundation

/// Digest configuration for one connection direction pair, fixed at the end
/// of login negotiation.
public struct DigestConfig: Sendable, Equatable {
    public var headerDigest: Bool
    public var dataDigest: Bool

    public init(headerDigest: Bool = false, dataDigest: Bool = false) {
        self.headerDigest = headerDigest
        self.dataDigest = dataDigest
    }
}

/// Serializes framed PDUs to wire bytes: BHS + AHS [+ HeaderDigest] + data
/// (4-byte padded) [+ DataDigest].
public struct PDUSerializer: Sendable {
    public var digests: DigestConfig

    public init(digests: DigestConfig = DigestConfig()) {
        self.digests = digests
    }

    public func serialize(_ raw: RawPDU) -> Data {
        precondition(raw.ahs.count % 4 == 0, "AHS must be 4-byte aligned")
        var out = Data(capacity: 48 + raw.ahs.count + 8 + padded4(raw.data.count))
        var bhs = raw.bhs
        bhs.setU8(UInt8(raw.ahs.count / 4), 4)
        bhs.setBE24(UInt32(raw.data.count), 5)
        out.append(bhs)
        out.append(raw.ahs)
        if digests.headerDigest {
            out.append(CRC32C.wireDigest(out))
        }
        if !raw.data.isEmpty {
            let padLen = padded4(raw.data.count) - raw.data.count
            out.append(raw.data)
            if padLen > 0 { out.append(Data(count: padLen)) }
            if digests.dataDigest {
                // Digest the segment and its padding as a chain rather than
                // building `raw.data + padding` first: that concatenation
                // allocated and copied the entire data segment — up to a
                // megabyte per PDU — purely to compute four bytes.
                var crc = CRC32C.initial
                crc = raw.data.withUnsafeBytes { CRC32C.update(crc, $0) }
                if padLen > 0 {
                    // At most 3 bytes of zero padding.
                    let pad = [UInt8](repeating: 0, count: padLen)
                    crc = pad.withUnsafeBytes { CRC32C.update(crc, $0) }
                }
                out.append(CRC32C.wireBytes(CRC32C.finalize(crc)))
            }
        }
        return out
    }

    public func serialize(_ pdu: some ProtocolDataUnit) -> Data {
        serialize(pdu.encode())
    }
}

/// Incremental deframer: feed arbitrary byte chunks, pull complete PDUs.
/// Verifies digests and enforces a data-segment length limit (protects the
/// receive path from a hostile/broken peer allocating unbounded memory).
public struct PDUDeframer: Sendable {
    public var digests: DigestConfig
    /// Upper bound accepted for DataSegmentLength; our negotiated
    /// MaxRecvDataSegmentLength plus slack for login-phase PDUs.
    public var maxDataSegmentLength: Int

    private var buffer = Data()
    /// Bytes at the front of `buffer` already handed out as PDUs.
    ///
    /// Consuming with `removeFirst` on every PDU would be quadratic when one
    /// read delivers many — the normal case for a fast link. Advancing an index
    /// instead makes consumption O(1); the front is reclaimed in one copy when
    /// it grows large enough to be worth it.
    private var consumed = 0

    /// Compact once the dead prefix exceeds this, or half the buffer.
    private static let compactThreshold = 64 * 1024

    public init(digests: DigestConfig = DigestConfig(), maxDataSegmentLength: Int = 1 << 24) {
        self.digests = digests
        self.maxDataSegmentLength = min(maxDataSegmentLength, 1 << 24)
    }

    public mutating func append(_ bytes: Data) {
        compactIfNeeded()
        buffer.append(bytes)
    }

    /// Bytes buffered but not yet consumed as a complete PDU.
    public var buffered: Int { buffer.count - consumed }

    /// Reclaim the dead prefix by copying the live tail into a fresh buffer.
    ///
    /// **This must not use `removeFirst`, and that is the whole point.** `Data`
    /// is a slice type: `removeFirst` advances the slice's start and keeps the
    /// original backing store, so the dead prefix is never released and every
    /// later `append` reallocs that same store *larger*. The buffer then grows
    /// by the total number of bytes ever received on the connection.
    ///
    /// It is not a slow leak. Reading a file off the LUN grew a daemon's
    /// resident memory 1:1 with the bytes read — 2 GiB of reads cost 2 GB of
    /// RSS, and a real copy peaked at 37 GB — with `heap` showing a single live
    /// allocation and `malloc_history` naming
    /// `Data.InlineSlice.append(contentsOf:)` underneath this line.
    /// `InlineSlice` is the tell: that representation exists precisely to hold
    /// an offset into a larger store.
    ///
    /// Building a new `Data` and appending the tail into it forces a copy into
    /// a fresh allocation and drops the last reference to the old one.
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

    /// Returns the next complete PDU, or nil if more bytes are needed.
    /// On a thrown error the deframer state is poisoned — at ERL0 any framing
    /// or digest error tears down the connection, so no resync is attempted.
    public mutating func next() throws -> RawPDU? {
        let avail = buffer.count - consumed
        guard avail >= 48 else { return nil }

        let ahsLen = Int(buffer.u8(consumed + 4)) * 4
        let dataLen = Int(buffer.beU24(consumed + 5))
        guard dataLen <= maxDataSegmentLength else {
            throw PDUError.dataSegmentTooLarge(length: dataLen, limit: maxDataSegmentLength)
        }

        let headerLen = 48 + ahsLen
        let headerDigestLen = digests.headerDigest ? 4 : 0
        let paddedData = padded4(dataLen)
        let dataDigestLen = (digests.dataDigest && dataLen > 0) ? 4 : 0
        let total = headerLen + headerDigestLen + paddedData + dataDigestLen
        guard avail >= total else { return nil }

        if digests.headerDigest {
            let expected = CRC32C.checksum(buffer.sub(consumed, headerLen))
            let onWire = wireDigestValue(at: consumed + headerLen)
            guard expected == onWire else { throw PDUError.headerDigestMismatch }
        }
        let dataStart = consumed + headerLen + headerDigestLen
        if dataDigestLen > 0 {
            let expected = CRC32C.checksum(buffer.sub(dataStart, paddedData))
            let onWire = wireDigestValue(at: dataStart + paddedData)
            guard expected == onWire else { throw PDUError.dataDigestMismatch }
        }

        let raw = RawPDU(
            bhs: Data(buffer.sub(consumed, 48)),
            ahs: Data(buffer.sub(consumed + 48, ahsLen)),
            data: Data(buffer.sub(dataStart, dataLen))
        )
        consumed += total
        return raw
    }

    /// Little-endian digest value at `offset`.
    private func wireDigestValue(at offset: Int) -> UInt32 {
        UInt32(buffer.u8(offset))
            | UInt32(buffer.u8(offset + 1)) << 8
            | UInt32(buffer.u8(offset + 2)) << 16
            | UInt32(buffer.u8(offset + 3)) << 24
    }
}
