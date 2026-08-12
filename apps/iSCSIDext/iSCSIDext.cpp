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
#define ISCSI_DEXT_SCRATCH_DISK 1

enum {
    kScratchBlockSize = 512,
    kScratchBlocks    = 131072,               // 64 MiB — enough to format APFS
};
#define kScratchBytes ((uint64_t)kScratchBlockSize * kScratchBlocks)

// The single target we publish. Must be <= UserReportHighestSupportedDeviceID
// and must not collide with the initiator's own ID.
enum { kVirtualTargetID = 0, kInitiatorID = 7, kHighestTargetID = 7 };

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
    return Stop(provider, SUPERDISPATCH);
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

#if ISCSI_DEXT_SCRATCH_DISK
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
#endif

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

#if ISCSI_DEXT_SCRATCH_DISK
// --- Bring-up only: minimal SCSI target emulation over the RAM buffer. ---

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
#endif // ISCSI_DEXT_SCRATCH_DISK

kern_return_t
IMPL(iSCSIDext, UserProcessParallelTask)
{
    // TODO(daemon-bridge): once ISCSI_DEXT_SCRATCH_DISK is 0, translate
    // parallelRequest into an ISCSIRequestSlot (CDB, direction, transfer
    // length, buffer offset), publish it on the request ring, retain
    // `completion` and park it keyed by fControllerTaskIdentifier. The daemon
    // posts an ISCSICompletionSlot and CompleteTaskFromDaemon() finishes it.
    // The response-filling code below is reused verbatim for that path.

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

#if ISCSI_DEXT_SCRATCH_DISK
    const uint8_t * cdb = parallelRequest.fCommandDescriptorBlock;
    const uint8_t   op  = cdb[0];

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
    case 0x00: // TEST UNIT READY
    case 0x35: // SYNCHRONIZE CACHE (10) — RAM buffer is always coherent
    case 0x91: // SYNCHRONIZE CACHE (16)
    case 0x1B: // START STOP UNIT
        break;

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
        uint8_t cap[8] = {};
        uint64_t lastLBA = kScratchBlocks - 1;
        PutBE32(&cap[0], lastLBA > 0xFFFFFFFFull ? 0xFFFFFFFFu : (uint32_t)lastLBA);
        PutBE32(&cap[4], kScratchBlockSize);
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
        uint8_t cap[32] = {};
        PutBE64(&cap[0], (uint64_t)kScratchBlocks - 1);
        PutBE32(&cap[8], kScratchBlockSize);
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
        uint64_t offset = lba * kScratchBlockSize;
        uint64_t length = (uint64_t)blocks * kScratchBlockSize;

        if (lba >= kScratchBlocks || offset + length > kScratchBytes) {
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
    OSSafeReleaseNULL(dataMD);
#endif // ISCSI_DEXT_SCRATCH_DISK

    // Completion is delivered through the OSAction; tell the framework the
    // request itself was accepted.
    ParallelTaskCompletion(completion, resp);
    *response = kSCSIServiceResponse_Request_In_Process;
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserAbortTaskRequest)
{
    Log("UserAbortTaskRequest t=%llu l=%llu q=%llu", theT, theL, theQ);
    *response = 0; // TODO: forward ABORT TASK to daemon (→ iSCSI TMF)
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserAbortTaskSetRequest)
{
    Log("UserAbortTaskSetRequest t=%llu l=%llu", theT, theL);
    *response = 0; // TODO: forward ABORT TASK SET to daemon
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
    Log("UserClearTaskSetRequest t=%llu l=%llu", theT, theL);
    *response = 0; // TODO: forward CLEAR TASK SET to daemon
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserLogicalUnitResetRequest)
{
    Log("UserLogicalUnitResetRequest t=%llu l=%llu", theT, theL);
    *response = 0; // TODO: forward LUN RESET to daemon
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserTargetResetRequest)
{
    Log("UserTargetResetRequest t=%llu", theT);
    *response = 0; // TODO: forward TARGET RESET to daemon
    return kIOReturnSuccess;
}

void
iSCSIDext::CompleteTaskFromDaemon(uint64_t taskTag, uint32_t scsiStatus, uint32_t dataLength)
{
    // TODO: look up the parked ParallelTaskCompletion OSAction by taskTag,
    // populate SCSIUserParallelResponse (version CurrentVersion1), and fire it.
    Log("CompleteTaskFromDaemon tag=%llu status=%u len=%u", taskTag, scsiStatus, dataLength);
}
