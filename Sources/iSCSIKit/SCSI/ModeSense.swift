import Foundation

/// Parsing of MODE SENSE(10) responses. Pure functions over target-controlled
/// (untrusted) bytes so they can be fuzzed directly; `Data`'s accessors trap on
/// out-of-range offsets, so every read must be provably in bounds.
public enum ModeSense {
    /// The caching mode page's WCE bit: whether the target's write cache is
    /// enabled (and therefore volatile). nil = truncated/malformed/no page
    /// 0x08 — "unknown", never "disabled", which would suggest durability
    /// that may not exist.
    public static func writeCacheEnabled(inResponse data: Data) -> Bool? {
        // MODE SENSE(10) header is 8 bytes: 2 length, 1 medium type, 1 device
        // specific, 2 reserved/longlba, 2 block descriptor length.
        guard data.count >= 8 else { return nil }

        let blockDescLen = Int(data.beU16(6))
        // Refuse a descriptor length past the buffer rather than clamp:
        // clamping would parse whatever followed as a mode page.
        guard blockDescLen >= 0, 8 + blockDescLen <= data.count else { return nil }

        var i = 8 + blockDescLen
        // Each page: byte 0 page code (low 6 bits), byte 1 length of the rest.
        // The loop condition guarantees i, i+1 and i+2 are all in bounds.
        while i + 2 < data.count {
            let pageCode = data.u8(i) & 0x3F
            let pageLen = Int(data.u8(i + 1))
            if pageCode == 0x08 {
                // Caching page: byte 2 bit 2 is WCE.
                return (data.u8(i + 2) & 0x04) != 0
            }
            // A zero-length page would loop forever.
            guard pageLen > 0 else { return nil }
            i += 2 + pageLen
        }
        return nil
    }
}
