import Foundation

/// The FSKit resource URL is separate from the legacy mountpoint hash input.
public enum MountResourceURL {
    public static func make(host: String, port: UInt16, target: String, lun: UInt64) throws -> URL {
        var components = URLComponents()
        components.scheme = IQN.isNQN(target) ? "nvme" : "iscsi"
        // URL authorities require brackets around IPv6 literals. URLComponents
        // also escapes a scoped address's zone separator (e.g. %en0 to %25en0).
        components.host = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        components.port = port == 3260 ? nil : Int(port)
        components.path = "/\(target)/\(lun)"
        guard !host.isEmpty, let url = components.url else {
            throw URLError(.badURL)
        }
        return url
    }
}
