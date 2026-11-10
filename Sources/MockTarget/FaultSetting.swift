import Foundation

/// `fault <name> [value]` from the simulator's control socket, applied to a
/// fault script. It lives here rather than in the simulator so tests can
/// reach it.
///
/// Every value is parsed strictly: a setting that cannot be read, or one
/// the served protocol never consults, is an error and leaves the script
/// as it was. A fault that silently did nothing — `fault corruptdatain
/// maybe` used to switch it off, `fault statsnjump 5` under --nvme changed
/// nothing — makes a fault-injection run prove nothing.
public enum FaultSetting {
    public enum Served: Sendable {
        case iSCSI
        case nvme
    }

    public struct Refusal: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// Faults only the iSCSI target reads; `MockNVMeQueue` never consults
    /// them.
    public static let iSCSIOnly: Set<String> = [
        "rejectcommands", "freezewindow", "duplicatestatsn", "oversizedatain",
        "unsolicitedr2t", "dropduringdatain", "statsnjump",
    ]

    /// Faults only the NVMe/TCP target reads; `MockTarget` never consults
    /// them.
    public static let nvmeOnly: Set<String> = ["holdioms"]

    /// Apply `name` = `value` (nil: no value given) to `faults`.
    public static func apply(_ name: String, _ value: String?, to faults: inout MockTargetFaults,
                             serving served: Served) throws {
        let key = name.lowercased()
        if served == .nvme, iSCSIOnly.contains(key) {
            throw Refusal(description: "fault \(name) has no effect on NVMe/TCP")
        }
        if served == .iSCSI, nvmeOnly.contains(key) {
            throw Refusal(description: "fault \(name) has no effect on iSCSI")
        }
        var updated = faults
        switch key {
        case "corruptdatain": updated.corruptDataInPayload = try flag(name, value)
        case "corruptheader": updated.corruptHeaderDigestOnce = try flag(name, value)
        case "stallcommands": updated.stallCommands = try flag(name, value)
        case "stallafterr2t": updated.stallAfterR2T = try flag(name, value)
        case "swallownops": updated.swallowNops = try flag(name, value)
        case "checkcondition": updated.checkConditionAll = try flag(name, value)
        case "rejectcommands": updated.rejectAllCommands = try flag(name, value)
        case "freezewindow": updated.freezeWindow = try flag(name, value)
        case "duplicatestatsn": updated.duplicateStatSN = try flag(name, value)
        case "oversizedatain": updated.oversizeDataIn = try flag(name, value)
        case "unsolicitedr2t": updated.unsolicitedR2T = try flag(name, value)
        case "rejectlogin":
            // Class 2 / detail 1: authentication failure.
            updated.rejectLoginStatus = try flag(name, value) ? (class: 2, detail: 1) : nil
        case "dropafterpdus": updated.dropAfterSentPDUs = try count(name, value)
        case "dropduringdatain": updated.dropDuringDataInAt = try count(name, value)
        case "responsedelayms": updated.responseDelay = try count(name, value).map { .milliseconds($0) }
        case "holdioms":
            // From now: `fault holdioms 45000` holds NVMe I/O for 45 s.
            updated.holdIOUntil = try count(name, value).map { .now + .milliseconds($0) }
        case "statsnjump": updated.statSNJump = UInt32(try count(name, value) ?? 0)
        default:
            throw Refusal(description: "unknown fault '\(name)'")
        }
        faults = updated
    }

    private static let onWords: Set<String> = ["on", "true", "yes", "1"]
    private static let offWords: Set<String> = ["off", "false", "no", "0"]

    /// A switch; no value means on.
    private static func flag(_ name: String, _ value: String?) throws -> Bool {
        guard let value else { return true }
        if onWords.contains(value.lowercased()) { return true }
        if offWords.contains(value.lowercased()) { return false }
        throw Refusal(description: "fault \(name) takes on or off, not '\(value)'")
    }

    /// A positive count, or nil for off ("off", "0" and the other off words).
    private static func count(_ name: String, _ value: String?) throws -> Int? {
        guard let value else { throw Refusal(description: "fault \(name) needs a number, or off") }
        if offWords.contains(value.lowercased()) { return nil }
        guard let n = Int(value), n > 0, n <= Int(UInt32.max) else {
            throw Refusal(description: "fault \(name) takes a positive number or off, not '\(value)'")
        }
        return n
    }
}
