/// RFC 1982 serial-number arithmetic over 32-bit sequence numbers
/// (CmdSN, StatSN, DataSN, ... all wrap; comparisons must respect the wrap).
public enum Serial {
    /// a < b in serial arithmetic.
    @inlinable
    public static func lt(_ a: UInt32, _ b: UInt32) -> Bool {
        a != b && (b &- a) < 0x8000_0000
    }

    /// a <= b in serial arithmetic.
    @inlinable
    public static func lte(_ a: UInt32, _ b: UInt32) -> Bool {
        a == b || lt(a, b)
    }

    /// Is `x` inside the window [lo, hi] (inclusive), all serial-compared?
    @inlinable
    public static func inWindow(_ x: UInt32, lo: UInt32, hi: UInt32) -> Bool {
        lte(lo, x) && lte(x, hi)
    }
}
