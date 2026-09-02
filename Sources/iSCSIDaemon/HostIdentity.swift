import Foundation
import NVMeKit
#if canImport(IOKit)
import IOKit
#endif

/// This machine's NVMe host identity, derived from the platform UUID so
/// there is nothing to persist, nothing `removeAllData` can lose, and
/// nothing a hostname change can drift — the hostname-derived iSCSI name
/// has already broken a NAS allow-list once. `iscsictl` uses the same
/// function, so the NQN it prints is the one the daemon will present.
public enum HostIdentity {
    /// IOPlatformUUID from the platform expert device; nil when IOKit does
    /// not answer, which on a Mac it always does.
    public static func platformUUID() -> String? {
        #if canImport(IOKit)
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPlatformExpertDevice"))
        guard entry != 0 else { return nil }
        defer { IOObjectRelease(entry) }
        guard let property = IORegistryEntryCreateCFProperty(
            entry, kIOPlatformUUIDKey as CFString, kCFAllocatorDefault, 0
        ) else { return nil }
        return property.takeRetainedValue() as? String
        #else
        return nil
        #endif
    }

    /// The host NQN and HOSTID to present. Falls back to a random identity
    /// only where there is no platform UUID at all; the caller should say so.
    public static func nvmeHost() -> NVMeHostIdentity {
        if let uuid = platformUUID() {
            return .derived(fromPlatformUUID: uuid)
        }
        return NVMeHostIdentity(uuid: UUID())
    }
}
