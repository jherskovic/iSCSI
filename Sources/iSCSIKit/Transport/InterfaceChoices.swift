import Foundation

/// One row of the interface picker.
public struct InterfaceChoice: Sendable, Equatable, Identifiable {
    public var id: String { name }
    /// BSD name — what is stored in the target record.
    public var name: String
    /// What the user reads: "USB 10GbE (en18) — 192.168.20.2".
    public var label: String

    public init(name: String, label: String) {
        self.name = name
        self.label = label
    }
}

/// The picker's rows, built from a snapshot so the logic is testable without
/// the machine's real interfaces.
public enum InterfaceChoices {
    /// Every interface holding a usable address, except loopback (nothing
    /// remote is reachable through it), in natural order. The stored name is
    /// appended when it is not among them, so editing a target never silently
    /// drops its pin.
    public static func list(snapshot: InterfaceSnapshot,
                            displayNames: [String: String],
                            stored: String?) -> [InterfaceChoice] {
        var held: [String: [InterfaceAddress]] = [:]
        for address in snapshot.addresses
        where address.name != "lo0" && !InterfacePinning.isLinkLocal(address) {
            held[address.name, default: []].append(address)
        }
        func title(_ name: String) -> String {
            displayNames[name].map { "\($0) (\(name))" } ?? name
        }
        var rows = held.keys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            .map { name -> InterfaceChoice in
                let addresses = held[name] ?? []
                // IPv4 first: it is what a portal address almost always is.
                let shown = addresses.first(where: { !$0.isIPv6 }) ?? addresses[0]
                return InterfaceChoice(name: name, label: "\(title(name)) — \(shown.address)")
            }
        if let stored, !stored.isEmpty, held[stored] == nil {
            let state = snapshot.present.contains(stored) ? "no address" : "not present"
            rows.append(InterfaceChoice(name: stored, label: "\(title(stored)) — \(state)"))
        }
        return rows
    }
}
