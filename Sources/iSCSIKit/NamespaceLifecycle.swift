import Foundation

/// Pure decisions shared by namespace CLI operations.
public enum NamespaceLifecycle {
    public static func record(in records: [TargetRecord], host: String, port: UInt16,
                              subsystem: String, nsid: UInt64) -> TargetRecord? {
        records.first {
            $0.host.caseInsensitiveCompare(host) == .orderedSame &&
            $0.port == port && $0.targetIQN == subsystem && $0.lun == nsid
        }
    }

    public static func canReuseDirectory(isDirectory: Bool, isSymbolicLink: Bool,
                                         isEmpty: Bool) -> Bool {
        isDirectory && !isSymbolicLink && isEmpty
    }

    public static func isAttached(mounted: Bool, device: String?) -> Bool {
        mounted || device != nil
    }
}
