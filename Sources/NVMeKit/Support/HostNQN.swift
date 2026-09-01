import CryptoKit
import Foundation

/// NVMe Qualified Name helpers (NVMe Base 2.0 §4.5).
public enum NQN {
    /// The well-known discovery subsystem.
    public static let discovery = "nqn.2014-08.org.nvmexpress.discovery"
    /// The UUID-based NQN form for hosts without a naming authority.
    public static let uuidPrefix = "nqn.2014-08.org.nvmexpress:uuid:"
    public static let maxBytes = 223

    /// Syntactically an NQN: the `nqn.` prefix, at most 223 bytes, printable
    /// ASCII. iSCSI names (`iqn.`/`eui.`/`naa.`) never pass, which is what
    /// lets the daemon tell the two protocols apart by name alone.
    public static func isValid(_ name: String) -> Bool {
        guard name.hasPrefix("nqn."), name.utf8.count > 4, name.utf8.count <= maxBytes else {
            return false
        }
        return name.utf8.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }
}

/// Who this Mac is to a controller: the host NQN in the Connect data and the
/// 16-byte HOSTID, which for the uuid form of NQN is the same UUID.
public struct NVMeHostIdentity: Sendable, Equatable {
    public let nqn: String
    public let hostID: Data

    public init(uuid: UUID) {
        nqn = NQN.uuidPrefix + uuid.uuidString.lowercased()
        hostID = withUnsafeBytes(of: uuid.uuid) { Data($0) }
    }

    /// A stable identity with nothing to persist: a UUID derived from the
    /// platform UUID through SHA-256 under a fixed namespace, so it survives
    /// reinstalls and `removeAllData`, cannot drift the way a hostname-based
    /// name does, and never exposes the hardware UUID itself to a target.
    /// Version 8 (RFC 9562, custom) and the RFC 4122 variant are stamped so
    /// the result is a well-formed UUID everywhere one is validated.
    public static func derived(fromPlatformUUID platformUUID: String) -> NVMeHostIdentity {
        let seed = "me.herko.iSCSIInitiator.hostnqn|" + platformUUID.lowercased()
        let digest = SHA256.hash(data: Data(seed.utf8))
        var bytes = Array(digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x80
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        let uuid = bytes.withUnsafeBytes { $0.load(as: uuid_t.self) }
        return NVMeHostIdentity(uuid: UUID(uuid: uuid))
    }
}
