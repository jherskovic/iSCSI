import Foundation
import MockTarget

/// The verbs the control socket understands.
///
/// The three teardown verbs are deliberately distinct, because conflating them
/// is how a crash test ends up proving nothing:
///
/// - `drop`   — kill the TCP connection. Nothing else changes; cached writes
///              stay cached. Tests reconnect and recovery.
/// - `reboot` — drop, then commit the cache. An orderly target restart: no data
///              is lost, so anything the initiator can no longer find is the
///              initiator's bug.
/// - `crash`  — drop, then *discard* the cache. Target power loss with `WCE=1`.
///              Writes that carried FUA survive; writes that did not are gone.
///              This is the arm that makes `writeThrough` provable.
struct ControlCommands: Sendable {
    let disk: RAMDisk
    let server: MockTargetServer
    let faults: FaultBox
    let stop: StopSignal

    func run(_ line: String) async -> String {
        let parts = line.split(separator: " ").map(String.init)
        guard let verb = parts.first?.lowercased() else { return "err empty" }
        let args = Array(parts.dropFirst())

        switch verb {
        case "ping":
            return "ok"

        case "help":
            return "verbs: ping status stats drop reboot crash flush pause resume "
                + "fault clear faults quit"

        case "status":
            let paused = await server.isPaused
            let liveCount = await server.liveConnections
            let accepted = await server.acceptedCount
            let refused = await server.refusedWhilePaused
            let port = await server.port
            return "ok port=\(port) paused=\(paused) live=\(liveCount) "
                + "accepted=\(accepted) refusedWhilePaused=\(refused)"

        case "stats":
            let dirty = await disk.dirtyBlocks
            let flushes = await disk.flushCount
            let fua = await disk.fuaWrites
            let cached = await disk.cachedWrites
            let crashes = await disk.crashCount
            let lost = await disk.blocksLostToCrash
            let pressure = await disk.pressureCommits
            return "ok dirtyBlocks=\(dirty) flushes=\(flushes) fuaWrites=\(fua) "
                + "cachedWrites=\(cached) crashes=\(crashes) blocksLost=\(lost) "
                + "pressureCommits=\(pressure)"

        case "drop":
            let dropped = await server.dropAll()
            return "ok dropped=\(dropped)"

        case "reboot":
            let dropped = await server.dropAll()
            await disk.reboot()
            return "ok dropped=\(dropped) cacheCommitted"

        case "crash":
            let dropped = await server.dropAll()
            let lost = await disk.crash()
            return "ok dropped=\(dropped) blocksLost=\(lost)"

        case "flush":
            await disk.flush()
            return "ok cacheCommitted"

        case "pause":
            await server.pauseAccepting()
            return "ok paused"

        case "resume":
            await server.resumeAccepting()
            return "ok accepting"

        case "clear":
            faults.clear()
            return "ok faultsCleared"

        case "faults":
            return "ok " + describeFaults(faults.value)

        case "fault":
            guard args.count >= 1 else { return "err usage: fault <name> [value]" }
            let value = args.count >= 2 ? args[1] : "on"
            return applyFault(name: args[0], value: value)

        case "quit", "shutdown":
            await stop.signal()
            return "ok stopping"

        default:
            return "err unknown verb '\(verb)' (try help)"
        }
    }

    // MARK: - Faults

    private func applyFault(name: String, value: String) -> String {
        let on = ["on", "true", "yes", "1"].contains(value.lowercased())
        let off = ["off", "false", "no", "0"].contains(value.lowercased())
        var applied = true

        faults.mutate { f in
            switch name.lowercased() {
            case "corruptdatain":
                f.corruptDataInPayload = on
            case "corruptheader":
                f.corruptHeaderDigestOnce = on
            case "stallcommands":
                f.stallCommands = on
            case "stallafterr2t":
                f.stallAfterR2T = on
            case "swallownops":
                f.swallowNops = on
            case "checkcondition":
                f.checkConditionAll = on
            case "rejectcommands":
                f.rejectAllCommands = on
            case "freezewindow":
                f.freezeWindow = on
            case "duplicatestatsn":
                f.duplicateStatSN = on
            case "oversizedatain":
                f.oversizeDataIn = on
            case "unsolicitedr2t":
                f.unsolicitedR2T = on
            case "rejectlogin":
                // Class 2 / detail 1: authentication failure.
                f.rejectLoginStatus = on ? (class: 2, detail: 1) : nil
            case "dropafterpdus":
                f.dropAfterSentPDUs = off ? nil : Int(value)
            case "dropduringdatain":
                f.dropDuringDataInAt = off ? nil : Int(value)
            case "responsedelayms":
                if off || value == "0" {
                    f.responseDelay = nil
                } else if let ms = Int(value) {
                    f.responseDelay = .milliseconds(ms)
                }
            case "statsnjump":
                f.statSNJump = UInt32(value) ?? 0
            default:
                applied = false
            }
        }
        return applied ? "ok fault \(name)=\(value)" : "err unknown fault '\(name)'"
    }

    private func describeFaults(_ f: MockTargetFaults) -> String {
        var set: [String] = []
        if f.corruptDataInPayload { set.append("corruptDataIn") }
        if f.corruptHeaderDigestOnce { set.append("corruptHeader") }
        if f.stallCommands { set.append("stallCommands") }
        if f.stallAfterR2T { set.append("stallAfterR2T") }
        if f.swallowNops { set.append("swallowNops") }
        if f.checkConditionAll { set.append("checkCondition") }
        if f.rejectAllCommands { set.append("rejectCommands") }
        if f.freezeWindow { set.append("freezeWindow") }
        if f.duplicateStatSN { set.append("duplicateStatSN") }
        if f.oversizeDataIn { set.append("oversizeDataIn") }
        if f.unsolicitedR2T { set.append("unsolicitedR2T") }
        if f.rejectLoginStatus != nil { set.append("rejectLogin") }
        if let n = f.dropAfterSentPDUs { set.append("dropAfterPDUs=\(n)") }
        if let n = f.dropDuringDataInAt { set.append("dropDuringDataIn=\(n)") }
        if let d = f.responseDelay { set.append("responseDelay=\(d)") }
        if f.statSNJump != 0 { set.append("statSNJump=\(f.statSNJump)") }
        return set.isEmpty ? "none" : set.joined(separator: ",")
    }
}
