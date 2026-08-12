//
//  iSCSIDext.cpp
//  Implementation of the virtual iSCSI SCSI HBA dext.
//
//  Working skeleton wired to the DriverKit SCSI controller contract
//  (SCSIControllerDriverKit, DriverKit 27). The data path is structured
//  around the single-segment framework limitation documented in
//  docs/architecture.md: until Apple ships the "software backend" opt-in
//  (FB23814092), UserProcessParallelTask can only move one physical segment
//  (~4 KiB) per task. TODOs mark where the shared-ring bridge to iscsid plugs
//  in — that plumbing lives in the paired iSCSIUserClient.
//

#include <os/log.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>
#include <DriverKit/IODispatchQueue.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOKitKeys.h>
#include <DriverKit/IOReturn.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/OSAction.h>
#include <DriverKit/OSDictionary.h>
#include <DriverKit/OSNumber.h>
#include <SCSIControllerDriverKit/IOUserSCSIParallelInterfaceController.h>

#include "iSCSIDext.h"
#include "iSCSIUserClientShared.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "iSCSIDext: " fmt, ##__VA_ARGS__)

// ---------------------------------------------------------------------------
// Bring-up scaffolding. With this set, the HBA presents ONE target backed by an
// in-dext RAM buffer instead of a real iSCSI LUN. Its only purpose is to prove
// the kernel-side SCSI contract (target publication → probe → task submission →
// completion → /dev/disk) independently of the daemon. Set to 0 once
// UserProcessParallelTask is bridged to iscsid over the shared ring.
// ---------------------------------------------------------------------------
// 0 = real path: READ/WRITE/SYNC CACHE are forwarded to iscsid over the shared
// arena. 1 = bring-up scaffolding backed by an in-dext RAM buffer.
#define ISCSI_DEXT_SCRATCH_DISK 0

enum {
    kScratchBlockSize = 512,
    kScratchBlocks    = 131072,               // 64 MiB — enough to format APFS
};
#define kScratchBytes ((uint64_t)kScratchBlockSize * kScratchBlocks)

// The single target we publish. Must be <= UserReportHighestSupportedDeviceID
// and must not collide with the initiator's own ID.
enum { kVirtualTargetID = 0, kInitiatorID = 7, kHighestTargetID = 7 };

// Reported LUN geometry: fixed in scaffolding mode, daemon-supplied otherwise.
#if ISCSI_DEXT_SCRATCH_DISK
#define kLUNBlockSize  ((uint32_t)kScratchBlockSize)
#define kLUNBlockCount ((uint64_t)kScratchBlocks)
#else
#define kLUNBlockSize  (ivars->lunBlockSize)
#define kLUNBlockCount (ivars->lunBlockCount)
#endif

// One outstanding SCSI task handed to the daemon. The task's data buffer is
// only obtainable inside UserProcessParallelTask, so we retain the descriptor
// here and copy into it when the daemon answers.
struct ParkedTask
{
    bool       inUse;
    bool       fetched;      // already handed to the daemon
    uint64_t   taskTag;
    OSAction * completion;
    IOBufferMemoryDescriptor * dataMD;
    uint8_t *  dataPtr;
    uint64_t   dataLen;
    uint32_t   direction;
    uint64_t   targetID;
    uint64_t   controllerTaskID;
    uint32_t   transferLength;
    uint32_t   cdbLength;
    uint8_t    cdb[16];
    uint64_t   parkTick;     // watchdog tick when this slot was filled
};

// Watchdog cadence. Tasks are failed once they have been parked for roughly
// kWatchdogTimeoutTicks * kWatchdogIntervalMs. Ticks avoid needing a clock.
enum {
    kWatchdogIntervalMs   = 2000,
    kWatchdogTimeoutTicks = 8,   // ~16 seconds
};

struct iSCSIDext_IVars
{
    bool controllerStarted;
    uint64_t highestTargetID; // one virtual target (0) for now
    uint32_t nextTaskID;      // monotonic id handed out by UserMapHBAData
    bool targetPublished;
    IOBufferMemoryDescriptor * scratchMD;
    uint8_t * scratch;
    // Dedicated queue for publishing the target. It must NOT be the default
    // queue: UserCreateTargetForID calls UserInitializeTargetForID back into
    // the dext, and that callback is serviced on the default queue — so if the
    // publish runs there, it blocks waiting for the queue it is occupying.
    IODispatchQueue * publishQueue;

    // --- daemon bridge ---
    IOBufferMemoryDescriptor * arenaMD; // shared payload arena (mapped by daemon)
    uint8_t * arena;
    bool lunPublished;
    uint32_t lunBlockSize;
    uint64_t lunBlockCount;
    ParkedTask tasks[kISCSIRequestSlotCount];
    uint64_t nextTaskTag;
    bool watchdogStarted;
    bool watchdogRun;
    uint64_t watchdogTick;
};

// Helper: set an OSNumber into the constraints dictionary.
static bool
SetConstraint(OSDictionary * dict, const char * key, uint64_t value, uint32_t bits = 64)
{
    OSNumber * num = OSNumber::withNumber(value, bits);
    if (num == nullptr) return false;
    bool ok = dict->setObject(key, num);
    OSSafeReleaseNULL(num);
    return ok;
}

bool iSCSIDext::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(iSCSIDext_IVars, 1);
    if (ivars == nullptr) return false;
    ivars->highestTargetID = kHighestTargetID;
    return true;
}

void iSCSIDext::free()
{
    if (ivars != nullptr) {
        OSSafeReleaseNULL(ivars->scratchMD);
        OSSafeReleaseNULL(ivars->publishQueue);
        ivars->scratch = nullptr;
    }
    IOSafeDeleteNULL(ivars, iSCSIDext_IVars, 1);
    super::free();
}

kern_return_t
IMPL(iSCSIDext, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        Log("super Start failed: 0x%x", ret);
        return ret;
    }
    Log("Start: virtual iSCSI HBA coming up");
    // RegisterService publishes us when matched on IOUserResources (no
    // hardware provider), letting the daemon open the user client.
    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        Log("RegisterService failed: 0x%x", ret);
    }
    return ret;
}

kern_return_t
IMPL(iSCSIDext, Stop)
{
    Log("Stop");
    if (ivars != nullptr) {
        ivars->watchdogRun = false;          // let the loop exit
        AbortAllParkedTasks("controller stopping");
    }
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(iSCSIDext, NewUserClient)
{
    (void)type;
    // Instantiates the class named by the personality's UserClientProperties
    // dict (IOUserClass = iSCSIUserClient) with this controller as provider.
    IOService * client = nullptr;
    kern_return_t ret = Create(this, "UserClientProperties", &client);
    if (ret != kIOReturnSuccess || client == nullptr) {
        Log("NewUserClient: Create failed 0x%x", ret);
        return ret == kIOReturnSuccess ? kIOReturnError : ret;
    }
    IOUserClient * uc = OSDynamicCast(IOUserClient, client);
    if (uc == nullptr) {
        Log("NewUserClient: created object is not an IOUserClient");
        client->release();
        return kIOReturnError;
    }
    *userClient = uc;
    Log("NewUserClient: handed out iSCSIUserClient");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserInitializeController)
{
    Log("UserInitializeController");
    ivars->controllerStarted = false;
    ivars->nextTaskID = 1;

    // The framework REQUIRES that we report HBA constraints before this method
    // returns — UserReportHBAConstraints() is a method we CALL (not a callback
    // we override), and all seven keys below are mandatory. Omitting the call
    // makes Start() fail; omitting a key panics the system.
    OSDictionary * constraints = OSDictionary::withCapacity(8);
    if (constraints == nullptr) {
        Log("UserInitializeController: could not allocate constraints dict");
        return kIOReturnNoMemory;
    }

    // Software controller: the framework's DMA path rejects multi-segment
    // buffers before we ever see them (FB23814092), so advertise a single
    // segment and let IOBreaker split larger requests. maxTransferSize must be
    // >= segmentCount * segmentByteCount.
    bool ok = true;
    ok &= SetConstraint(constraints, kIOMaximumSegmentCountReadKey, 1, 32);
    ok &= SetConstraint(constraints, kIOMaximumSegmentCountWriteKey, 1, 32);
    ok &= SetConstraint(constraints, kIOMaximumSegmentByteCountReadKey, kISCSIMaxSegmentByteCount, 32);
    ok &= SetConstraint(constraints, kIOMaximumSegmentByteCountWriteKey, kISCSIMaxSegmentByteCount, 32);
    ok &= SetConstraint(constraints, kIOMinimumSegmentAlignmentByteCountKey, 1, 32);
    ok &= SetConstraint(constraints, kIOMaximumSegmentAddressableBitCountKey, 64, 32);
    ok &= SetConstraint(constraints, kIOMinimumHBADataAlignmentMaskKey, 1, 64);
    if (!ok) {
        Log("UserInitializeController: failed to populate constraints");
        OSSafeReleaseNULL(constraints);
        return kIOReturnNoMemory;
    }

    kern_return_t ret = UserReportHBAConstraints(constraints);
    OSSafeReleaseNULL(constraints);
    if (ret != kIOReturnSuccess) {
        Log("UserReportHBAConstraints failed: 0x%x", ret);
        return ret;
    }
    Log("UserInitializeController: constraints reported");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserDoesHBASupportMultiPathing)
{
    *result = false; // single connection/session for now (no MC/S)
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserDoesHBASupportSCSIParallelFeature)
{
    // Pure SPI features (sync/wide/DT negotiation) are meaningless for an
    // iSCSI transport: nothing to negotiate on a virtual bus.
    (void)theValue;
    *result = false;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserGetDMASpecification)
{
    // Must agree with the constraints reported in UserInitializeController:
    // maxTransferSize >= maxSegmentCount * maxSegmentByteCount. We advertise a
    // single segment, so the two are equal.
    *maxTransferSize = kISCSIMaxSegmentByteCount;
    *alignment       = 1;   // byte-aligned; no hardware DMA engine behind us
    *numAddressBits  = 64;  // full 64-bit addressing (software controller)
    *segmentType     = kDMAOutputSegmentHost64;
    Log("UserGetDMASpecification -> maxTransfer=%llu align=%u bits=%u",
        *maxTransferSize, *alignment, *numAddressBits);
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserMapBundledParallelTaskCommandAndResponseBuffers)
{
    // Opt out of the bundled/shared-buffer path: returning failure here is the
    // documented way to tell the framework to keep using UserProcessParallelTask
    // and UserCompleteParallelTask. Our own shared ring to iscsid lives behind
    // the user client instead.
    // NB: DriverKit's trimmed IOReturn.h has no kIOReturnFailure; kIOReturnError
    // is the general-error code the framework treats as "not mapped".
    Log("UserMapBundledParallelTaskCommandAndResponseBuffers: declining bundled mode");
    return kIOReturnError;
}

void
IMPL(iSCSIDext, UserProcessBundledParallelTasks)
{
    // Unreachable while we decline bundled mode above, but the base declares it
    // pure-virtual so it must exist.
    Log("UserProcessBundledParallelTasks: unexpected (bundled mode declined)");
}

kern_return_t
IMPL(iSCSIDext, UserMapHBAData)
{
    // Called for every SCSIParallelTask created in the kernel. We keep no
    // per-task DMA state (the daemon owns the buffers); just hand out a
    // unique id the kernel uses to identify the task.
    *uniqueTaskID = ivars->nextTaskID++;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserStartController)
{
    Log("UserStartController");
    ivars->controllerStarted = true;

    // Start the watchdog before any task can be parked.
    if (!ivars->watchdogStarted) {
        if (ivars->publishQueue == nullptr) {
            kern_return_t qret = IODispatchQueue::Create(
                "iSCSIWatchdogQueue", 0, 0, &ivars->publishQueue);
            if (qret != kIOReturnSuccess) {
                Log("watchdog queue Create failed: 0x%x", qret);
            }
        }
        if (ivars->publishQueue != nullptr) {
            ivars->watchdogStarted = true;
            ivars->watchdogRun = true;
            ivars->publishQueue->DispatchAsync(^{ WatchdogLoop(); });
        }
    }

#if ISCSI_DEXT_SCRATCH_DISK
    // Back the bring-up target with a RAM buffer.
    if (ivars->scratch == nullptr) {
        kern_return_t ret = IOBufferMemoryDescriptor::Create(
            kIOMemoryDirectionInOut, kScratchBytes, 8, &ivars->scratchMD);
        if (ret != kIOReturnSuccess || ivars->scratchMD == nullptr) {
            Log("scratch buffer Create failed: 0x%x", ret);
            return ret == kIOReturnSuccess ? kIOReturnNoMemory : ret;
        }
        IOAddressSegment seg = {};
        ret = ivars->scratchMD->GetAddressRange(&seg);
        if (ret != kIOReturnSuccess) {
            Log("scratch GetAddressRange failed: 0x%x", ret);
            return ret;
        }
        ivars->scratch = reinterpret_cast<uint8_t *>(seg.address);
        Log("scratch disk ready: %llu bytes (%u-byte blocks)",
            kScratchBytes, (unsigned)kScratchBlockSize);
    }

    // No explicit target publication: UserDoesHBAPerformDeviceManagement()
    // returns false, so the family scans the bus and discovers target 0 by
    // INQUIRY. PublishVirtualTarget() is kept for the eventual daemon-driven
    // path but is deliberately NOT called here (see its deadlock note).
#endif
    return kIOReturnSuccess;
}

// Declared in the .iig, so it must always be defined (it lands in the vtable)
// even though nothing calls it while the family does the bus scan.
void
iSCSIDext::PublishVirtualTarget()
{
    if (ivars->targetPublished) return;

    // Give the framework time to finish bringing the controller up before
    // asking it to create a target. Calling immediately after
    // UserStartController returns blocks forever inside UserCreateTargetForID
    // (the target object is created but never registered, and
    // UserInitializeTargetForID is never called back). Safe to sleep here: this
    // runs on our own private queue, not the queue that services callbacks.
    IOSleep(5000);

    Log("PublishVirtualTarget: calling UserCreateTargetForID(%u)", kVirtualTargetID);

    OSDictionary * targetDict = OSDictionary::withCapacity(1);
    if (targetDict == nullptr) {
        Log("PublishVirtualTarget: no memory for target dict");
        return;
    }
    kern_return_t ret = UserCreateTargetForID(kVirtualTargetID, targetDict);
    OSSafeReleaseNULL(targetDict);
    if (ret != kIOReturnSuccess) {
        Log("UserCreateTargetForID(%u) failed: 0x%x", kVirtualTargetID, ret);
        return;
    }
    ivars->targetPublished = true;
    Log("published virtual target %u", kVirtualTargetID);
}

kern_return_t
IMPL(iSCSIDext, UserInitializeTargetForID)
{
    Log("UserInitializeTargetForID %llu", targetID);
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserReportInitiatorIdentifier)
{
    *id = kInitiatorID; // our initiator ID on the virtual bus
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserReportHighestSupportedDeviceID)
{
    // MUST be the real max target ID or targets > 0 never probe.
    *id = ivars->highestTargetID;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserReportMaximumTaskCount)
{
    // DTS guidance: make this high and rely on bundled tasks; sized by ring.
    *count = kISCSIRequestSlotCount;
    Log("UserReportMaximumTaskCount -> %u", *count);
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserReportHBAHighestLogicalUnitNumber)
{
    *value = 0; // single LUN per target for now
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserDoesHBAPerformDeviceManagement)
{
    // FALSE on purpose: let the SCSI family scan the bus and create targets
    // itself (it INQUIRYs each ID through UserProcessParallelTask). Returning
    // true makes target creation OUR job via UserCreateTargetForID — which
    // reliably hangs for this virtual controller: the target object is created
    // but never registered, UserInitializeTargetForID is never called back, and
    // the call never returns (verified both immediately after
    // UserStartController and 5s later, so it is not a start-timing issue).
    *result = false;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserDoesHBAPerformAutoSense)
{
    *result = true; // daemon returns sense inline in the completion slot
    return kIOReturnSuccess;
}

// --- SCSI helpers, used by both the daemon path and the scaffolding. ---

static inline void PutBE32(uint8_t * p, uint32_t v)
{
    p[0] = (uint8_t)(v >> 24); p[1] = (uint8_t)(v >> 16);
    p[2] = (uint8_t)(v >> 8);  p[3] = (uint8_t)v;
}

static inline void PutBE64(uint8_t * p, uint64_t v)
{
    PutBE32(p, (uint32_t)(v >> 32));
    PutBE32(p + 4, (uint32_t)v);
}

static inline uint32_t GetBE32(const uint8_t * p)
{
    return ((uint32_t)p[0] << 24) | ((uint32_t)p[1] << 16) |
           ((uint32_t)p[2] << 8) | (uint32_t)p[3];
}

static inline uint64_t GetBE64(const uint8_t * p)
{
    return ((uint64_t)GetBE32(p) << 32) | (uint64_t)GetBE32(p + 4);
}

// Fills fixed-format sense data (SPC): response code 0x70.
static uint8_t
MakeSense(uint8_t * sense, uint8_t key, uint8_t asc, uint8_t ascq)
{
    for (int i = 0; i < 18; i++) sense[i] = 0;
    sense[0] = 0x70;      // current error, fixed format
    sense[2] = key;
    sense[7] = 10;        // additional sense length
    sense[12] = asc;
    sense[13] = ascq;
    return 18;
}

// --- Daemon bridge (LOCALONLY; called by iSCSIUserClient in-process). ------

IOBufferMemoryDescriptor *
iSCSIDext::CopyPayloadArena()
{
    if (ivars->arenaMD == nullptr) {
        kern_return_t ret = IOBufferMemoryDescriptor::Create(
            kIOMemoryDirectionInOut, kISCSIDataRegionBytes, 8, &ivars->arenaMD);
        if (ret != kIOReturnSuccess || ivars->arenaMD == nullptr) {
            Log("arena Create failed: 0x%x", ret);
            return nullptr;
        }
        IOAddressSegment seg = {};
        if (ivars->arenaMD->GetAddressRange(&seg) == kIOReturnSuccess) {
            ivars->arena = reinterpret_cast<uint8_t *>(seg.address);
        }
        Log("payload arena ready: %u bytes", (unsigned)kISCSIDataRegionBytes);
    }
    ivars->arenaMD->retain();
    return ivars->arenaMD;
}

void
iSCSIDext::SetLUNGeometry(uint32_t blockSize, uint64_t blockCount)
{
    ivars->lunBlockSize  = blockSize;
    ivars->lunBlockCount = blockCount;
    bool becameReady = (blockSize != 0 && blockCount != 0) && !ivars->lunPublished;
    ivars->lunPublished  = (blockSize != 0 && blockCount != 0);
    Log("LUN geometry: %u x %llu (ready=%d)", blockSize, blockCount,
        ivars->lunPublished ? 1 : 0);

    // The SCSI family probes the bus once, right after the controller starts.
    // If the daemon connects after that (the normal case — it has to log in to
    // the target first), the LUN was NOT READY at probe time and nothing ever
    // re-examines it, so no /dev/disk is created. Telling the family the media
    // parameters changed makes it re-read capacity and attach.
    //
    // Dispatched off this queue on purpose: this runs from the user client's
    // ExternalMethod, and calling back into the framework inline is what
    // deadlocked UserCreateTargetForID.
    if (becameReady && ivars->publishQueue != nullptr) {
        ivars->publishQueue->DispatchAsync(^{
            kern_return_t r = UserCallMediaParametersHaveChanged();
            Log("media parameters changed -> 0x%x", r);
        });
    }
}

bool
iSCSIDext::FetchPendingTask(uint64_t * taskTag, uint32_t * slotIndex,
                            uint32_t * targetID, uint32_t * lun,
                            uint32_t * direction, uint32_t * transferLength,
                            uint64_t * cdbLow, uint64_t * cdbHigh,
                            uint32_t * cdbLength)
{
    for (uint32_t i = 0; i < kISCSIRequestSlotCount; i++) {
        ParkedTask * t = &ivars->tasks[i];
        if (!t->inUse || t->fetched) continue;
        t->fetched = true;
        *taskTag        = t->taskTag;
        *slotIndex      = i;
        *targetID       = (uint32_t)t->targetID;
        *lun            = 0;
        *direction      = t->direction;
        *transferLength = t->transferLength;
        uint64_t lo = 0, hi = 0;
        for (int b = 0; b < 8; b++) {
            lo |= (uint64_t)t->cdb[b] << (8 * b);
            hi |= (uint64_t)t->cdb[b + 8] << (8 * b);
        }
        *cdbLow    = lo;
        *cdbHigh   = hi;
        *cdbLength = t->cdbLength;
        return true;
    }
    return false;
}

// Completes one parked slot with a delivery failure. Caller owns slot validity.
void
iSCSIDext::FailParkedSlot(uint32_t index)
{
    ParkedTask * t = &ivars->tasks[index];
    // Claim the slot atomically: the daemon's completion, the watchdog and the
    // TMF paths can all race for it, and completing twice would finish an
    // unrelated recycled task.
    bool expected = true;
    if (!__atomic_compare_exchange_n(&t->inUse, &expected, false, false,
                                     __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST)) {
        return;
    }

    SCSIUserParallelResponse resp = {};
    resp.version = kScsiUserParallelTaskResponseCurrentVersion1;
    resp.fTargetID = t->targetID;
    resp.fControllerTaskIdentifier = t->controllerTaskID;
    // Delivery failure (rather than CHECK CONDITION) tells the stack the
    // command never reached the device, so it can retry or fail the I/O
    // promptly instead of interpreting stale sense data.
    resp.fServiceResponse  = kSCSIServiceResponse_SERVICE_DELIVERY_OR_TARGET_FAILURE;
    resp.fCompletionStatus = kSCSITaskStatus_DeliveryFailure;
    resp.fBytesTransferred = 0;

    OSAction * completion = t->completion;
    OSSafeReleaseNULL(t->dataMD);
    t->fetched = false; t->completion = nullptr;
    t->dataPtr = nullptr; t->dataLen = 0;

    if (completion != nullptr) {
        ParallelTaskCompletion(completion, resp);
        completion->release();
    }
}

void
iSCSIDext::WatchdogLoop()
{
    Log("watchdog: running (interval %ums, timeout ~%us)",
        (unsigned)kWatchdogIntervalMs,
        (unsigned)(kWatchdogIntervalMs * kWatchdogTimeoutTicks / 1000));
    while (ivars != nullptr && ivars->watchdogRun) {
        IOSleep(kWatchdogIntervalMs);
        if (ivars == nullptr || !ivars->watchdogRun) break;
        ivars->watchdogTick++;
        uint32_t timedOut = 0;
        for (uint32_t i = 0; i < kISCSIRequestSlotCount; i++) {
            ParkedTask * t = &ivars->tasks[i];
            if (!t->inUse) continue;
            if (ivars->watchdogTick - t->parkTick >= kWatchdogTimeoutTicks) {
                FailParkedSlot(i);
                timedOut++;
            }
        }
        if (timedOut != 0) {
            Log("watchdog: failed %u task(s) the daemon never answered", timedOut);
        }
    }
    Log("watchdog: stopped");
}

void
iSCSIDext::AbortAllParkedTasks(const char * reason)
{
    uint32_t n = 0;
    for (uint32_t i = 0; i < kISCSIRequestSlotCount; i++) {
        if (ivars->tasks[i].inUse) { FailParkedSlot(i); n++; }
    }
    if (n != 0) Log("aborted %u parked task(s): %s", n, reason);
}

uint32_t
iSCSIDext::AbortParkedTasksFor(uint64_t targetID, uint64_t lun)
{
    (void)lun; // single LUN per target for now
    uint32_t n = 0;
    for (uint32_t i = 0; i < kISCSIRequestSlotCount; i++) {
        if (ivars->tasks[i].inUse && ivars->tasks[i].targetID == targetID) {
            FailParkedSlot(i);
            n++;
        }
    }
    return n;
}

void
iSCSIDext::CompleteTaskFromDaemonEx(uint64_t taskTag, uint32_t scsiStatus,
                                    uint32_t dataLength, uint32_t senseLength)
{
    for (uint32_t i = 0; i < kISCSIRequestSlotCount; i++) {
        ParkedTask * t = &ivars->tasks[i];
        if (!t->inUse || t->taskTag != taskTag) continue;

        SCSIUserParallelResponse resp = {};
        resp.version = kScsiUserParallelTaskResponseCurrentVersion1;
        resp.fTargetID = t->targetID;
        resp.fControllerTaskIdentifier = t->controllerTaskID;
        resp.fServiceResponse  = kSCSIServiceResponse_TASK_COMPLETE;
        resp.fCompletionStatus = (scsiStatus == 0) ? kSCSITaskStatus_GOOD
                                                   : kSCSITaskStatus_CHECK_CONDITION;

        const uint8_t * slot = ivars->arena
            ? ivars->arena + ((uint64_t)i * kISCSISlotPayloadBytes) : nullptr;

        if (scsiStatus != 0 && senseLength > 0 && slot != nullptr) {
            uint32_t n = senseLength > kMaxSenseBufferSize ? kMaxSenseBufferSize : senseLength;
            if (n > 255) n = 255; // fSenseLength is a uint8_t
            memcpy(resp.fSenseBuffer, slot, n);
            resp.fSenseLength = (uint8_t)n;
        } else if (t->direction == kISCSIDirectionRead && dataLength > 0 &&
                   slot != nullptr && t->dataPtr != nullptr) {
            uint64_t n = dataLength;
            if (n > t->dataLen) n = t->dataLen;
            if (n > kISCSISlotPayloadBytes) n = kISCSISlotPayloadBytes;
            memcpy(t->dataPtr, slot, (size_t)n);
            resp.fBytesTransferred = n;
        } else if (scsiStatus == 0) {
            resp.fBytesTransferred = dataLength;
        }

        OSAction * completion = t->completion;
        OSSafeReleaseNULL(t->dataMD);
        t->inUse = false; t->fetched = false; t->completion = nullptr;
        t->dataPtr = nullptr; t->dataLen = 0;

        if (completion != nullptr) {
            ParallelTaskCompletion(completion, resp);
            completion->release();
        }
        return;
    }
    Log("CompleteTaskFromDaemon: unknown tag %llu", taskTag);
}

kern_return_t
IMPL(iSCSIDext, UserProcessParallelTask)
{
    SCSIUserParallelResponse resp = {};
    // MANDATORY: if this version does not match, the kernel returns WITHOUT
    // completing the I/O — the task just hangs, with no error reported.
    resp.version                = kScsiUserParallelTaskResponseCurrentVersion1;
    resp.fTargetID              = parallelRequest.fTargetID;
    resp.fControllerTaskIdentifier = parallelRequest.fControllerTaskIdentifier;
    resp.fServiceResponse       = kSCSIServiceResponse_TASK_COMPLETE;
    resp.fCompletionStatus      = kSCSITaskStatus_GOOD;
    resp.fBytesTransferred      = 0;
    resp.fSenseLength           = 0;

    const uint8_t * cdb = parallelRequest.fCommandDescriptorBlock;
    const uint8_t   op  = cdb[0];
    bool deferred = false; // true => daemon owns the completion now

    // fBufferIOVMAddr is a DMA/IOVM address — NOT dereferenceable from the
    // dext. Touching it faults instantly (EXC_BAD_ACCESS, byte write
    // Translation fault, and the dext dies mid-INQUIRY). UserGetDataBuffer is
    // the documented way to get a CPU-accessible mapping. It is only valid
    // inside UserProcessParallelTask, so fetch it here and release below.
    IOBufferMemoryDescriptor * dataMD = nullptr;
    uint8_t * buf   = nullptr;
    uint64_t  avail = parallelRequest.fRequestedTransferCount;
    if (avail > 0) {
        kern_return_t bret = UserGetDataBuffer(
            parallelRequest.fTargetID,
            parallelRequest.fControllerTaskIdentifier,
            &dataMD);
        if (bret == kIOReturnSuccess && dataMD != nullptr) {
            IOAddressSegment seg = {};
            if (dataMD->GetAddressRange(&seg) == kIOReturnSuccess && seg.address != 0) {
                buf = reinterpret_cast<uint8_t *>(seg.address);
                if (seg.length < avail) avail = seg.length;
            }
        } else {
            Log("UserGetDataBuffer failed: 0x%x", bret);
        }
    }
    Log("task: target=%llu op=0x%02x len=%llu buf=%s",
        parallelRequest.fTargetID, op, avail, buf ? "ok" : "none");
    // Only LUN 0 exists on this target.
    const bool lunZero = (parallelRequest.fLogicalUnitBytes[1] == 0);

    if (parallelRequest.fTargetID != kVirtualTargetID) {
        // The family scans every ID up to UserReportHighestSupportedDeviceID;
        // everything except our one virtual target must report "not present"
        // or the scan stalls waiting on us.
        resp.fServiceResponse  = kSCSIServiceResponse_SERVICE_DELIVERY_OR_TARGET_FAILURE;
        resp.fCompletionStatus = kSCSITaskStatus_DeviceNotPresent;
    } else if (!lunZero) {
        resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
        resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x05, 0x25, 0x00); // LUN not supported
    } else switch (op) {
    case 0x1B: // START STOP UNIT
        break;

    case 0x00: // TEST UNIT READY
#if !ISCSI_DEXT_SCRATCH_DISK
        // Until the daemon publishes LUN geometry there is no medium behind
        // us. Reporting "becoming ready" makes the SCSI stack keep polling
        // (it retries every ~3s) instead of giving up on the device.
        if (!ivars->lunPublished) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x02, 0x04, 0x01);
        }
#endif
        break;

    case 0x35: // SYNCHRONIZE CACHE (10)
    case 0x91: // SYNCHRONIZE CACHE (16)
#if ISCSI_DEXT_SCRATCH_DISK
        break; // RAM buffer is always coherent
#else
        if (!ivars->lunPublished) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x02, 0x04, 0x01);
            break;
        }
        deferred = ParkTaskForDaemon(parallelRequest, completion,
                                     kISCSIDirectionNone, 0, dataMD, buf, avail);
        if (!deferred) {
            resp.fCompletionStatus = kSCSITaskStatus_TASK_SET_FULL;
        }
        break;
#endif

    case 0x12: { // INQUIRY
        uint8_t inq[36] = {};
        if (cdb[1] & 0x01) { // EVPD
            // Only the mandatory page 0x00 (supported pages).
            if (cdb[2] == 0x00) {
                inq[0] = 0x00; inq[1] = 0x00; inq[3] = 0x01; inq[4] = 0x00;
                uint64_t n = avail < 5 ? avail : 5;
                if (buf && n) memcpy(buf, inq, (size_t)n);
                resp.fBytesTransferred = n;
            } else {
                resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
                resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x05, 0x24, 0x00);
            }
            break;
        }
        inq[0] = 0x00;  // direct-access block device
        inq[1] = 0x00;  // not removable
        inq[2] = 0x05;  // SPC-3
        inq[3] = 0x02;  // response data format
        inq[4] = 31;    // additional length
        memcpy(&inq[8],  "HERKO   ", 8);
        memcpy(&inq[16], "iSCSI Virtual   ", 16);
        memcpy(&inq[32], "0001", 4);
        uint64_t n = avail < sizeof(inq) ? avail : sizeof(inq);
        if (buf && n) memcpy(buf, inq, (size_t)n);
        resp.fBytesTransferred = n;
        break;
    }

    case 0x25: { // READ CAPACITY (10)
#if !ISCSI_DEXT_SCRATCH_DISK
        if (!ivars->lunPublished) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x02, 0x04, 0x01);
            break;
        }
#endif
        uint8_t cap[8] = {};
        uint64_t lastLBA = kLUNBlockCount - 1;
        PutBE32(&cap[0], lastLBA > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)lastLBA);
        PutBE32(&cap[4], kLUNBlockSize);
        uint64_t n = avail < sizeof(cap) ? avail : sizeof(cap);
        if (buf && n) memcpy(buf, cap, (size_t)n);
        resp.fBytesTransferred = n;
        break;
    }

    case 0x9E: { // SERVICE ACTION IN (16) — READ CAPACITY (16) is action 0x10
        if ((cdb[1] & 0x1F) != 0x10) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x05, 0x20, 0x00);
            break;
        }
#if !ISCSI_DEXT_SCRATCH_DISK
        if (!ivars->lunPublished) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x02, 0x04, 0x01);
            break;
        }
#endif
        uint8_t cap[32] = {};
        PutBE64(&cap[0], (uint64_t)kLUNBlockCount - 1);
        PutBE32(&cap[8], kLUNBlockSize);
        uint64_t n = avail < sizeof(cap) ? avail : sizeof(cap);
        if (buf && n) memcpy(buf, cap, (size_t)n);
        resp.fBytesTransferred = n;
        break;
    }

    case 0x28:   // READ (10)
    case 0x88:   // READ (16)
    case 0x2A:   // WRITE (10)
    case 0x8A: { // WRITE (16)
        const bool isWrite = (op == 0x2A || op == 0x8A);
        const bool is16    = (op == 0x88 || op == 0x8A);
        uint64_t lba    = is16 ? GetBE64(&cdb[2]) : (uint64_t)GetBE32(&cdb[2]);
        uint32_t blocks = is16 ? GetBE32(&cdb[10])
                               : (uint32_t)((cdb[7] << 8) | cdb[8]);
#if ISCSI_DEXT_SCRATCH_DISK
        uint64_t offset = lba * kLUNBlockSize;
        uint64_t length = (uint64_t)blocks * kLUNBlockSize;

        if (lba >= kLUNBlockCount || offset + length > kScratchBytes) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x05, 0x21, 0x00); // LBA out of range
            break;
        }
        if (length > avail) length = avail; // honour the mapped segment
        if (buf && length && ivars->scratch) {
            if (isWrite) memcpy(ivars->scratch + offset, buf, (size_t)length);
            else         memcpy(buf, ivars->scratch + offset, (size_t)length);
        }
        resp.fBytesTransferred = length;
#else
        if (!ivars->lunPublished) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x02, 0x04, 0x01);
            break;
        }
        if (lba >= kLUNBlockCount) {
            resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
            resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x05, 0x21, 0x00);
            break;
        }
        uint64_t length = (uint64_t)blocks * kLUNBlockSize;
        if (length > avail) length = avail;
        deferred = ParkTaskForDaemon(
            parallelRequest, completion,
            isWrite ? kISCSIDirectionWrite : kISCSIDirectionRead,
            (uint32_t)length, dataMD, buf, avail);
        if (!deferred) {
            // No free slot: tell the initiator to retry rather than fail the I/O.
            resp.fCompletionStatus = kSCSITaskStatus_TASK_SET_FULL;
        }
#endif
        break;
    }

    case 0x1A:   // MODE SENSE (6)
    case 0x5A: { // MODE SENSE (10)
        uint8_t mode[8] = {};
        uint64_t n;
        if (op == 0x1A) { mode[0] = 3; n = 4; }   // mode data length, no block descriptors
        else            { mode[1] = 6; n = 8; }
        if (n > avail) n = avail;
        if (buf && n) memcpy(buf, mode, (size_t)n);
        resp.fBytesTransferred = n;
        break;
    }

    case 0x03: { // REQUEST SENSE — no deferred errors to report
        uint8_t sense[18];
        uint8_t len = MakeSense(sense, 0x00, 0x00, 0x00);
        uint64_t n = avail < len ? avail : len;
        if (buf && n) memcpy(buf, sense, (size_t)n);
        resp.fBytesTransferred = n;
        break;
    }

    default:
        Log("unsupported CDB op 0x%02x", op);
        resp.fCompletionStatus = kSCSITaskStatus_CHECK_CONDITION;
        resp.fSenseLength = MakeSense(resp.fSenseBuffer, 0x05, 0x20, 0x00); // invalid opcode
        break;
    }
    if (deferred) {
        // The daemon owns this task now: it holds the retained data buffer and
        // the completion, and will finish it via CompleteTaskFromDaemonEx().
        *response = kSCSIServiceResponse_Request_In_Process;
        return kIOReturnSuccess;
    }

    OSSafeReleaseNULL(dataMD);

    // Completion is delivered through the OSAction; tell the framework the
    // request itself was accepted.
    ParallelTaskCompletion(completion, resp);
    *response = kSCSIServiceResponse_Request_In_Process;
    return kIOReturnSuccess;
}

// Parks a task for the daemon. For a write the payload is copied into the
// shared arena now, while the task's data buffer is still obtainable; for a
// read the buffer descriptor is retained so the daemon's reply can be copied
// back later. Returns false if no slot is free.
bool
iSCSIDext::ParkTaskForDaemon(SCSIUserParallelTask parallelRequest,
                             OSAction * completion,
                             uint32_t direction,
                             uint32_t transferLength,
                             IOBufferMemoryDescriptor * dataMD,
                             uint8_t * dataPtr,
                             uint64_t dataLen)
{
    if (ivars->arena == nullptr) {
        Log("ParkTaskForDaemon: no arena (daemon never connected)");
        return false;
    }
    for (uint32_t i = 0; i < kISCSIRequestSlotCount; i++) {
        ParkedTask * t = &ivars->tasks[i];
        if (t->inUse) continue;

        uint8_t * slot = ivars->arena + ((uint64_t)i * kISCSISlotPayloadBytes);
        if (direction == kISCSIDirectionWrite && dataPtr != nullptr && transferLength > 0) {
            uint64_t n = transferLength;
            if (n > dataLen) n = dataLen;
            if (n > kISCSISlotPayloadBytes) n = kISCSISlotPayloadBytes;
            memcpy(slot, dataPtr, (size_t)n);
        }

        t->inUse            = true;
        t->fetched          = false;
        t->parkTick         = ivars->watchdogTick;
        t->taskTag          = ++ivars->nextTaskTag;
        t->completion       = completion;
        if (completion != nullptr) completion->retain();
        t->dataMD           = dataMD;   // ownership transfers to the slot
        t->dataPtr          = dataPtr;
        t->dataLen          = dataLen;
        t->direction        = direction;
        t->targetID         = parallelRequest.fTargetID;
        t->controllerTaskID = parallelRequest.fControllerTaskIdentifier;
        t->transferLength   = transferLength;
        t->cdbLength        = parallelRequest.fCommandSize;
        memcpy(t->cdb, parallelRequest.fCommandDescriptorBlock, 16);
        return true;
    }
    return false;
}

kern_return_t
IMPL(iSCSIDext, UserAbortTaskRequest)
{
    // Actually cancel the parked work rather than claiming success and leaving
    // it outstanding — a lying TMF is how a "hung disk" turns permanent.
    uint32_t n = AbortParkedTasksFor(theT, theL);
    Log("UserAbortTaskRequest t=%llu l=%llu q=%llu -> aborted %u", theT, theL, theQ, n);
    *response = kSCSIServiceResponse_FUNCTION_COMPLETE;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserAbortTaskSetRequest)
{
    { uint32_t n = AbortParkedTasksFor(theT, theL);
      Log("UserAbortTaskSetRequest t=%llu l=%llu -> aborted %u", theT, theL, n); }
    *response = kSCSIServiceResponse_FUNCTION_COMPLETE; // TODO: forward ABORT TASK SET to daemon
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserClearACARequest)
{
    Log("UserClearACARequest t=%llu l=%llu", theT, theL);
    *response = 0; // TODO: forward CLEAR ACA to daemon
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserClearTaskSetRequest)
{
    { uint32_t n = AbortParkedTasksFor(theT, theL);
      Log("UserClearTaskSetRequest t=%llu l=%llu -> aborted %u", theT, theL, n); }
    *response = kSCSIServiceResponse_FUNCTION_COMPLETE; // TODO: forward CLEAR TASK SET to daemon
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserLogicalUnitResetRequest)
{
    uint32_t n = AbortParkedTasksFor(theT, theL);
    Log("UserLogicalUnitResetRequest t=%llu l=%llu -> aborted %u", theT, theL, n);
    *response = kSCSIServiceResponse_FUNCTION_COMPLETE;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserTargetResetRequest)
{
    uint32_t n = AbortParkedTasksFor(theT, ~0ull);
    Log("UserTargetResetRequest t=%llu -> aborted %u", theT, n);
    *response = kSCSIServiceResponse_FUNCTION_COMPLETE;
    return kIOReturnSuccess;
}

void
iSCSIDext::CompleteTaskFromDaemon(uint64_t taskTag, uint32_t scsiStatus, uint32_t dataLength)
{
    // TODO: look up the parked ParallelTaskCompletion OSAction by taskTag,
    // populate SCSIUserParallelResponse (version CurrentVersion1), and fire it.
    Log("CompleteTaskFromDaemon tag=%llu status=%u len=%u", taskTag, scsiStatus, dataLength);
}
