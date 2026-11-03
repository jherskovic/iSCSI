import Foundation
import Testing
@testable import iSCSIKit

/// The login-time retry schedule, decided without a clock: every time here is
/// an offset from the start of the run, so nothing waits.
@Suite("Auto-attach run")
struct AutoAttachRunTests {

    private func record(_ id: String, autoAttach: Bool = true, lun: UInt64 = 0) -> TargetRecord {
        TargetRecord(id: id, displayName: id, host: "192.168.20.1",
                     targetIQN: "iqn.2026-08.me.herko:disk0", lun: lun, autoAttach: autoAttach)
    }

    private let home = "/Users/herko"

    private func mount(_ from: String, under home: String) -> MountTableEntry {
        MountTableEntry(from: from,
                        on: home + "/Library/Caches/me.herko.iSCSIInitiator/e7cf144d2c2ee621")
    }

    @Test("every pending target may start at once")
    func everyTargetStartsAtOnce() {
        let run = AutoAttachRun(targetIDs: ["a", "b"])
        #expect(run.canStart("a", at: .zero))
        #expect(run.canStart("b", at: .zero))
    }

    @Test("attempts start 15 s apart, start to start")
    func attemptsAreFifteenSecondsApart() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.finished("a", attached: false)
        #expect(run.nextStart(for: "a") == .seconds(15))
        #expect(!run.canStart("a", at: .seconds(14)))
        #expect(run.canStart("a", at: .seconds(15)))
    }

    @Test("an attempt that overruns delays the next one instead of overlapping it")
    func overrunDelaysInsteadOfOverlapping() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        #expect(!run.canStart("a", at: .seconds(20)))
        run.finished("a", attached: false)
        #expect(run.canStart("a", at: .seconds(20)))
    }

    @Test("no attempt starts at or after five minutes")
    func noAttemptStartsAtTheBudget() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .seconds(285))
        run.finished("a", attached: false)
        #expect(run.nextStart(for: "a") == nil)
        #expect(!run.canStart("a", at: .seconds(300)))
    }

    @Test("the deadline holds while an attempt is still in flight")
    func deadlineHoldsWithAttemptInFlight() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .seconds(290))
        #expect(!run.isOver(at: .seconds(299)))
        #expect(run.isOver(at: .seconds(300)))
        #expect(run.failures == ["a": .stillAttaching])
    }

    @Test("a target that kept failing is reported with its last attempt")
    func failedTargetReportsLastAttempt() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.finished("a", attached: false)
        #expect(run.isOver(at: .seconds(300)))
        #expect(run.failures == ["a": .lastAttemptFailed])
    }

    @Test("an attached target is not retried and is not a failure")
    func attachedTargetIsDone() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.finished("a", attached: true)
        #expect(run.nextStart(for: "a") == nil)
        #expect(run.isOver(at: .seconds(1)))
        #expect(run.failures.isEmpty)
    }

    @Test("the run ends early only once every target is resolved")
    func runEndsEarlyOnlyWhenAllResolved() {
        var run = AutoAttachRun(targetIDs: ["a", "b"])
        run.started("a", at: .zero)
        run.finished("a", attached: true)
        run.started("b", at: .zero)
        run.finished("b", attached: false)
        #expect(!run.isOver(at: .seconds(20)))
        run.cancel("b")
        #expect(run.isOver(at: .seconds(20)))
        #expect(run.failures.isEmpty)
    }

    @Test("a late result for a cancelled target does not bring it back")
    func cancelledTargetStaysCancelled() {
        var run = AutoAttachRun(targetIDs: ["a"])
        run.started("a", at: .zero)
        run.cancel("a")
        run.finished("a", attached: false)
        #expect(run.nextStart(for: "a") == nil)
        #expect(!run.canStart("a", at: .seconds(60)))
        #expect(run.failures.isEmpty)
    }

    @Test("a run with nothing to attach is over immediately")
    func emptyRunIsOverImmediately() {
        #expect(AutoAttachRun(targetIDs: []).isOver(at: .zero))
    }

    @Test("only marked targets that are not attached are pending")
    func onlyMarkedUnattachedTargetsArePending() {
        let targets = [record("t1"), record("t2"), record("t3", autoAttach: false)]
        #expect(AutoAttachRun.pendingTargetIDs(targets, attachedTargetIDs: ["t2"], excluding: []) == ["t1"])
    }

    @Test("another user's mount of the target is in use elsewhere")
    func otherUsersMountIsInUseElsewhere() {
        let mounts = [mount("iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/0",
                            under: "/Users/other")]
        #expect(AutoAttachRun.isInUseElsewhere(record("t1"), mounts: mounts, home: home))
    }

    @Test("this user's own mount of the target is not in use elsewhere")
    func ownMountIsNotElsewhere() {
        let mounts = [mount("iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/0", under: home)]
        #expect(!AutoAttachRun.isInUseElsewhere(record("t1"), mounts: mounts, home: home))
    }

    @Test("a target nobody has mounted is not in use, whatever sessions the daemon holds")
    func unmountedTargetIsNotInUse() {
        // Measured 2026-10-22: fskitd refused an activate after the extension
        // had loaded the resource, and the extension held its daemon session
        // with nothing mounted — a session is not a user.
        #expect(!AutoAttachRun.isInUseElsewhere(record("t1"), mounts: [], home: home))
    }

    @Test("a home that merely starts with this user's home is someone else's")
    func homePrefixIsNotOwnHome() {
        let mounts = [mount("iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/0",
                            under: "/Users/herko2")]
        #expect(AutoAttachRun.isInUseElsewhere(record("t1"), mounts: mounts, home: home))
    }

    @Test("the target is named by its IQN and LUN, not by the portal it was reached through")
    func otherPortalSameTargetCounts() {
        let mounts = [mount("iscsi://10.0.0.5:3270/IQN.2026-08.me.herko:disk0/0",
                            under: "/Users/other")]
        #expect(AutoAttachRun.isInUseElsewhere(record("t1"), mounts: mounts, home: home))
    }

    @Test("an NVMe namespace mounted by another user counts")
    func nvmeNamespaceElsewhereCounts() {
        let nqn = "nqn.2011-06.com.truenas:uuid:75ca6aa3:name-testing"
        let target = TargetRecord(id: "n1", displayName: "n1", host: "192.168.20.1", port: 4420,
                                  targetIQN: nqn, lun: 1, autoAttach: true)
        let mounts = [mount("nvme://192.168.20.1:4420/\(nqn)/1", under: "/Users/other")]
        #expect(AutoAttachRun.isInUseElsewhere(target, mounts: mounts, home: home))
    }

    @Test("another LUN of the same target, or anything else mounted, does not count")
    func otherLUNOrOtherMountDoesNotCount() {
        let mounts = [mount("iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/1",
                            under: "/Users/other"),
                      MountTableEntry(from: "/dev/disk3s1", on: "/Volumes/Data"),
                      MountTableEntry(from: "map auto_home", on: "/System/Volumes/Data/home")]
        #expect(!AutoAttachRun.isInUseElsewhere(record("t1", lun: 0), mounts: mounts, home: home))
    }

    // MARK: - Another mount of the same unit, before any attach

    private let ownMountPoint = "/Users/herko/Library/Caches/me.herko.iSCSIInitiator/e7cf144d2c2ee621"

    @Test("this attach's own mount point is not another mount")
    func ownMountPointIsNotAnotherMount() {
        let mounts = [MountTableEntry(from: "iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/0",
                                      on: ownMountPoint)]
        #expect(AutoAttachRun.otherMount(ofTarget: "iqn.2026-08.me.herko:disk0", lun: 0,
                                         mounts: mounts, except: ownMountPoint) == nil)
    }

    /// The S-08 orphan: the record's address changed while attached, so its
    /// mount point moved and the old mount is still serving the same LUN.
    @Test("this user's mount of the unit under an old mount point is another mount")
    func ownOrphanIsAnotherMount() {
        let orphan = MountTableEntry(from: "iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/0",
                                     on: "/Users/herko/Library/Caches/me.herko.iSCSIInitiator/0123456789abcdef")
        #expect(AutoAttachRun.otherMount(ofTarget: "iqn.2026-08.me.herko:disk0", lun: 0,
                                         mounts: [orphan], except: ownMountPoint) == orphan)
    }

    @Test("another account's mount of the unit, through any portal and any case, is another mount")
    func otherAccountsMountIsAnotherMount() {
        let theirs = MountTableEntry(from: "iscsi://nas.local:3270/IQN.2026-08.me.herko:disk0/0",
                                     on: "/Users/other/Library/Caches/me.herko.iSCSIInitiator/e7cf144d2c2ee621")
        #expect(AutoAttachRun.otherMount(ofTarget: "iqn.2026-08.me.herko:disk0", lun: 0,
                                         mounts: [theirs], except: ownMountPoint) == theirs)
    }

    @Test("another unit of the same target, or anything else mounted, is not another mount")
    func otherUnitIsNotAnotherMount() {
        let mounts = [MountTableEntry(from: "iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/1",
                                      on: "/Users/other/x"),
                      MountTableEntry(from: "/dev/disk3s1", on: "/Volumes/Data")]
        #expect(AutoAttachRun.otherMount(ofTarget: "iqn.2026-08.me.herko:disk0", lun: 0,
                                         mounts: mounts, except: ownMountPoint) == nil)
    }

    @Test("a mount source reads back as its portal, name and unit")
    func mountSourceParses() {
        let iscsi = AutoAttachRun.mountedUnit("iscsi://192.168.20.1:3260/iqn.2026-08.me.herko:disk0/0")
        #expect(iscsi == AutoAttachRun.MountedUnit(portal: "192.168.20.1:3260",
                                                   name: "iqn.2026-08.me.herko:disk0", unit: 0))
        let nvme = AutoAttachRun.mountedUnit("nvme://[fd00::5]:4420/nqn.2011-06.com.truenas:uuid:1:disk/1?engine=diskimages2")
        #expect(nvme?.portal == "[fd00::5]:4420")
        #expect(nvme?.isNVMe == true && nvme?.unit == 1)
        #expect(AutoAttachRun.mountedUnit("/dev/disk3s1") == nil)
        #expect(AutoAttachRun.mountedUnit("map auto_home") == nil)
    }

    @Test("a target the user took over before the run began is not pending")
    func targetTakenOverBeforeRunIsNotPending() {
        let targets = [record("t1"), record("t2")]
        #expect(AutoAttachRun.pendingTargetIDs(targets, attachedTargetIDs: [],
                                               excluding: ["t1"]) == ["t2"])
    }

    @Test("cancelling every target ends the run with nothing to report")
    func cancellingEverythingEndsTheRun() {
        var run = AutoAttachRun(targetIDs: ["a", "b"])
        run.started("a", at: .zero)
        run.cancelAll()
        #expect(run.isOver(at: .seconds(1)))
        #expect(!run.canStart("b", at: .seconds(1)))
        #expect(run.failures.isEmpty)
    }
}
