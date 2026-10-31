//
//  DaemonUnitError.swift
//  The requested LUN (or namespace) is not one the target reports.
//
//  Why this is a login-time refusal and not a READ CAPACITY failure: a Linux
//  LIO target — Synology, TrueNAS, most NAS firmware — answers LUN 0 even when
//  nothing is mapped there, with a 32 KiB placeholder ramdisk ("virtual LUN
//  0"). Its geometry is perfectly plausible, so attaching it produces a
//  healthy-looking 64-block disk and an offer to format it (GitHub #3).
//  REPORT LUNS is the one answer that names what is actually there.
//

import Foundation

public enum DaemonUnitError: Error, LocalizedError, Equatable {
    /// The target's unit list does not include the one the record names.
    case notPresent(requested: UInt64, available: [UInt64], isNVMe: Bool)

    public var errorDescription: String? {
        switch self {
        case .notPresent(let requested, let available, let isNVMe):
            let unit = isNVMe ? "namespace" : "LUN"
            let list = available.map(String.init).joined(separator: ", ")
            return "The target has no \(unit) \(requested); it reports "
                 + (available.count == 1 ? "\(unit) \(list)." : "\(unit)s \(list).")
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notPresent(let requested, let available, let isNVMe):
            let unit = isNVMe ? "Namespace ID" : "LUN"
            if available.count == 1, let only = available.first {
                return "Edit the target and set its \(unit) to \(only)."
            }
            var text = "Edit the target and set its \(unit) to one of those."
            if !isNVMe, requested == 0 {
                text += " Some targets answer LUN 0 with a tiny placeholder disk "
                      + "when nothing is mapped there, which is why this is refused "
                      + "rather than attached."
            }
            return text
        }
    }
}
