import Foundation
import MockTarget

/// The verbs the control socket understands. The teardown verbs are
/// deliberately distinct — conflating them makes a crash test prove nothing:
/// - `drop`   — kill the TCP connection; cached writes stay cached.
/// - `reboot` — drop, then commit the cache: orderly restart, no data lost.
/// - `crash`  — drop, then *discard* the cache: power loss with `WCE=1`.
///              FUA writes survive, others are gone — proves `writeThrough`.
struct ControlCommands: Sendable {
    let disk: RAMDisk
    let server: MockTargetServer
    let faults: FaultBox
    let stop: StopSignal
    /// Which protocol the simulator serves: a fault the other one reads is
    /// refused rather than silently doing nothing.
    let served: FaultSetting.Served

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
            return applyFault(name: args[0], value: args.count >= 2 ? args[1] : nil)

        case "quit", "shutdown":
            await stop.signal()
            return "ok stopping"

        default:
            return "err unknown verb '\(verb)' (try help)"
        }
    }

    // MARK: - Faults

    private func applyFault(name: String, value: String?) -> String {
        var refusal: String?
        faults.mutate { f in
            do {
                try FaultSetting.apply(name, value, to: &f, serving: served)
            } catch {
                refusal = "\(error)"
            }
        }
        if let refusal { return "err \(refusal)" }
        return "ok fault \(name)=\(value ?? "on")"
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
        if let until = f.holdIOUntil, ContinuousClock.now < until {
            set.append("holdIO=\(ContinuousClock.now.duration(to: until)) more")
        }
        if f.statSNJump != 0 { set.append("statSNJump=\(f.statSNJump)") }
        return set.isEmpty ? "none" : set.joined(separator: ",")
    }
}
