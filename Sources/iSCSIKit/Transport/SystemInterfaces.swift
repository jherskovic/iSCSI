#if canImport(Darwin)
import Darwin
import Foundation

/// The interfaces and addresses the kernel reports right now. Lives beside
/// `NetworkTransport` because it reads system state, which the rest of
/// iSCSIKit deliberately does not.
public enum SystemInterfaces {
    /// Every interface `getifaddrs` lists, and the IPv4/IPv6 addresses of
    /// those that are up and running. Read fresh on every call: DHCP and a
    /// re-plugged cable both change it, and a pin resolves on every connect.
    public static func snapshot() -> InterfaceSnapshot {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else {
            return InterfaceSnapshot(present: [], addresses: [])
        }
        defer { freeifaddrs(head) }

        var present = Set<String>()
        var addresses: [InterfaceAddress] = []
        for entry in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = entry.pointee
            let name = String(cString: ifa.ifa_name)
            present.insert(name)
            let up = ifa.ifa_flags & UInt32(IFF_UP) != 0
            let running = ifa.ifa_flags & UInt32(IFF_RUNNING) != 0
            guard up, running, let sa = ifa.ifa_addr else { continue }
            let family = Int32(sa.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size
                                                     : MemoryLayout<sockaddr_in6>.size)
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, length, &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = host.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            addresses.append(InterfaceAddress(name: name, address: address,
                                              isIPv6: family == AF_INET6))
        }
        return InterfaceSnapshot(present: present, addresses: addresses)
    }

    /// The addresses `host` resolves to through macOS's ordinary, unscoped
    /// resolver: numeric strings, in the resolver's order, without
    /// duplicates. A literal comes back as itself. Blocks; see
    /// `resolveDetached`.
    public static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var head: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &head)
        guard status == 0, let first = head else {
            throw TransportError.connectFailed(
                "could not resolve \(host): \(String(cString: gai_strerror(status)))")
        }
        defer { freeaddrinfo(head) }
        var out: [String] = []
        for entry in sequence(first: first, next: { $0.pointee.ai_next }) {
            guard let sa = entry.pointee.ai_addr else { continue }
            var name = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(sa, entry.pointee.ai_addrlen, &name, socklen_t(name.count),
                              nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let address = name.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
            if !out.contains(address) { out.append(address) }
        }
        guard !out.isEmpty else { throw TransportError.connectFailed("could not resolve \(host)") }
        return out
    }

    /// `resolve` on a dispatch queue, so a slow DNS server ties up a thread
    /// of its own rather than one of Swift concurrency's few.
    public static func resolveDetached(_ host: String) async throws -> [String] {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global(qos: .userInitiated).async {
                c.resume(with: Result { try resolve(host) })
            }
        }
    }
}
#endif
