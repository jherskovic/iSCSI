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
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserServer.h>
#include <DriverKit/OSAction.h>
#include <SCSIControllerDriverKit/IOUserSCSIParallelInterfaceController.h>

#include "iSCSIDext.h"
#include "iSCSIUserClientShared.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "iSCSIDext: " fmt, ##__VA_ARGS__)

struct iSCSIDext_IVars
{
    bool controllerStarted;
    uint64_t highestTargetID; // one virtual target (0) for now
};

bool iSCSIDext::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(iSCSIDext_IVars, 1);
    if (ivars == nullptr) return false;
    ivars->highestTargetID = 0;
    return true;
}

void iSCSIDext::free()
{
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
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserStartController)
{
    Log("UserStartController");
    ivars->controllerStarted = true;
    return kIOReturnSuccess;
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
    *id = 7; // our initiator ID on the virtual bus
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
    *result = true; // software controller manages its own targets/LUNs
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserDoesHBAPerformAutoSense)
{
    *result = true; // daemon returns sense inline in the completion slot
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIDext, UserProcessParallelTask)
{
    // Enqueue the task for the daemon and defer completion.
    //
    // TODO(daemon-bridge): translate parallelRequest into an ISCSIRequestSlot
    // (CDB, direction, transfer length, buffer offset), publish on the request
    // ring, retain `completion`, and park it keyed by task tag. When the
    // daemon posts a completion (via the user client), fill a
    // SCSIUserParallelResponse with fResponseVersion =
    // kScsiUserParallelTaskResponseCurrentVersion1 and invoke the completion
    // OSAction (ParallelTaskCompletion). Returning success here means "task
    // accepted; completion will arrive asynchronously".
    (void)parallelRequest;
    (void)completion;
    *response = 0;
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
