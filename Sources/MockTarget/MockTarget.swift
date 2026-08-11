import Foundation
import iSCSIKit

/// Scriptable in-process iSCSI target for integration testing.
/// Grows in Phase 3: login handling, a RAM-backed LUN, and a fault-injection
/// scripting API (delay/drop/corrupt/reject/stall/reboot).
public enum MockTargetPlaceholder {
    public static let version = "0.0.1"
}
