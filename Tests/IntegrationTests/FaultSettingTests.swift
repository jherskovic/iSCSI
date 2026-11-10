import Foundation
import Testing
@testable import MockTarget

/// The simulator's `fault <name> [value]`: a value it cannot read, or a
/// fault the served protocol never consults, is an error that leaves the
/// script alone — never a silent no-op or a silent switch-off.
@Suite("Simulator fault settings")
struct FaultSettingTests {
    private func applying(_ name: String, _ value: String?, to faults: MockTargetFaults = MockTargetFaults(),
                          serving served: FaultSetting.Served = .iSCSI) throws -> MockTargetFaults {
        var faults = faults
        try FaultSetting.apply(name, value, to: &faults, serving: served)
        return faults
    }

    @Test func aSwitchTakesOnOffOrNothing() throws {
        #expect(try applying("corruptdatain", nil).corruptDataInPayload)
        #expect(try applying("CorruptDataIn", "yes").corruptDataInPayload)
        var on = MockTargetFaults()
        on.corruptDataInPayload = true
        #expect(try !applying("corruptdatain", "off", to: on).corruptDataInPayload)
    }

    /// `fault corruptdatain maybe` used to switch the fault off.
    @Test func anUnreadableSwitchValueIsRefusedAndChangesNothing() throws {
        var on = MockTargetFaults()
        on.corruptDataInPayload = true
        var faults = on
        #expect(throws: FaultSetting.Refusal(description: "fault corruptdatain takes on or off, not 'maybe'")) {
            try FaultSetting.apply("corruptdatain", "maybe", to: &faults, serving: .iSCSI)
        }
        #expect(faults.corruptDataInPayload)
        #expect(throws: FaultSetting.Refusal.self) { _ = try applying("rejectlogin", "sometimes") }
    }

    @Test func aCountTakesAPositiveNumberOrOff() throws {
        #expect(try applying("dropafterpdus", "5").dropAfterSentPDUs == 5)
        #expect(try applying("responsedelayms", "250").responseDelay == .milliseconds(250))
        #expect(try applying("statsnjump", "3").statSNJump == 3)
        var set = MockTargetFaults()
        set.dropAfterSentPDUs = 5
        set.responseDelay = .milliseconds(9)
        #expect(try applying("dropafterpdus", "off", to: set).dropAfterSentPDUs == nil)
        #expect(try applying("responsedelayms", "0", to: set).responseDelay == nil)
    }

    /// Before: no value or a word read as Int(...) == nil, which switched
    /// the drop off (or set StatSN jump to 0) and answered "ok".
    @Test func anUnreadableCountIsRefused() throws {
        var set = MockTargetFaults()
        set.dropAfterSentPDUs = 5
        for value in [nil, "on", "abc", "-1", "1.5"] as [String?] {
            var faults = set
            #expect(throws: FaultSetting.Refusal.self, "dropafterpdus \(value ?? "<none>")") {
                try FaultSetting.apply("dropafterpdus", value, to: &faults, serving: .iSCSI)
            }
            #expect(faults.dropAfterSentPDUs == 5)
        }
        #expect(throws: FaultSetting.Refusal.self) { _ = try applying("statsnjump", "lots") }
        #expect(throws: FaultSetting.Refusal.self) { _ = try applying("responsedelayms", "soon") }
    }

    @Test func faultsNVMeNeverReadsAreRefusedUnderNVMe() throws {
        for name in FaultSetting.iSCSIOnly {
            let value = ["dropduringdatain", "statsnjump"].contains(name) ? "2" : "on"
            #expect(throws: FaultSetting.Refusal(description: "fault \(name) has no effect on NVMe/TCP")) {
                _ = try applying(name, value, serving: .nvme)
            }
            _ = try applying(name, value, serving: .iSCSI)
        }
        // And the ones it does read still work there.
        for name in ["corruptdatain", "corruptheader", "stallcommands", "stallafterr2t", "swallownops",
                     "checkcondition", "rejectlogin"] {
            _ = try applying(name, "on", serving: .nvme)
        }
        _ = try applying("dropafterpdus", "3", serving: .nvme)
        _ = try applying("responsedelayms", "10", serving: .nvme)
    }

    /// Only the NVMe target holds I/O; under iSCSI it would do nothing.
    @Test func holdingIOCountsFromNowAndIsNVMeOnly() throws {
        let before = ContinuousClock.now
        let held = try #require(try applying("holdioms", "45000", serving: .nvme).holdIOUntil)
        #expect(held >= before + .seconds(45) && held <= ContinuousClock.now + .seconds(45))
        var set = MockTargetFaults()
        set.holdIOUntil = .now + .seconds(9)
        #expect(try applying("holdioms", "off", to: set, serving: .nvme).holdIOUntil == nil)
        #expect(throws: FaultSetting.Refusal(description: "fault holdioms has no effect on iSCSI")) {
            _ = try applying("holdioms", "45000", serving: .iSCSI)
        }
    }

    @Test func anUnknownFaultIsRefused() {
        #expect(throws: FaultSetting.Refusal(description: "unknown fault 'nosuchfault'")) {
            _ = try applying("nosuchfault", "on")
        }
    }
}
