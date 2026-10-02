//
//  NetworkInterfaceNames.swift
//  The names System Settings shows for each network interface.
//

import Foundation
import SystemConfiguration

/// Display names ("Wi-Fi", "USB 10/100/1G/2.5G LAN") keyed by BSD name. Best
/// effort: an interface SystemConfiguration does not know keeps its BSD name
/// alone in the picker.
enum NetworkInterfaceNames {
    static func localized() -> [String: String] {
        let all = (SCNetworkInterfaceCopyAll() as? [SCNetworkInterface]) ?? []
        var names: [String: String] = [:]
        for interface in all {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let shown = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            names[bsd] = shown
        }
        return names
    }
}
