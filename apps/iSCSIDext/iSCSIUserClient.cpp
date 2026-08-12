//
//  iSCSIUserClient.cpp
//  Skeleton user client: owns the shared IOBufferMemoryDescriptor ring and
//  routes daemon calls to the controller. See iSCSIUserClientShared.h for the
//  selector and ring definitions.
//

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOUserClient.h>
#include <DriverKit/IOBufferMemoryDescriptor.h>

#include "iSCSIUserClient.h"
#include "iSCSIDext.h"
#include "iSCSIUserClientShared.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "iSCSIUserClient: " fmt, ##__VA_ARGS__)

struct iSCSIUserClient_IVars
{
    iSCSIDext * controller; // our provider; owns the arena and the task table
};

bool iSCSIUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(iSCSIUserClient_IVars, 1);
    return ivars != nullptr;
}

void iSCSIUserClient::free()
{
    IOSafeDeleteNULL(ivars, iSCSIUserClient_IVars, 1);
    super::free();
}

kern_return_t
IMPL(iSCSIUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    // The controller owns the payload arena and the outstanding-task table; we
    // are just the daemon's doorway to it. Both objects live in this dext
    // process, so these are plain in-process calls (LOCALONLY).
    ivars->controller = OSDynamicCast(iSCSIDext, provider);
    if (ivars->controller == nullptr) {
        Log("Start: provider is not iSCSIDext");
        return kIOReturnNoDevice;
    }
    Log("Start: daemon connected");
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIUserClient, Stop)
{
    Log("Stop: daemon disconnected");
    // The daemon is the only thing that can complete parked tasks. If it goes
    // away (crash, Ctrl-C, kill) they must be failed here — otherwise the SCSI
    // stack waits on them forever and every mount on this device wedges, along
    // with anything that enumerates mounted volumes.
    if (ivars->controller != nullptr) {
        ivars->controller->AbortAllParkedTasks("daemon disconnected");
        ivars->controller->SetLUNGeometry(0, 0); // back to NOT READY
    }
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(iSCSIUserClient, CopyClientMemoryForType)
{
    if (type == kISCSIUserClientSetRingBuffer && ivars->controller != nullptr) {
        IOBufferMemoryDescriptor * arena = ivars->controller->CopyPayloadArena();
        if (arena == nullptr) return kIOReturnNoMemory;
        *memory = arena; // already retained for the caller
        return kIOReturnSuccess;
    }
    return super::CopyClientMemoryForType(type, options, memory, SUPERDISPATCH);
}

// ExternalMethod is the dispatch entry point; iig keeps it in the class but
// generates no trampoline, so implement it as a plain C++ override.
kern_return_t
iSCSIUserClient::ExternalMethod(
    uint64_t selector,
    IOUserClientMethodArguments * arguments,
    const IOUserClientMethodDispatch * dispatch,
    OSObject * target,
    void * reference)
{
    if (ivars->controller == nullptr) {
        return super::ExternalMethod(selector, arguments, dispatch, target, reference);
    }

    switch (selector) {
        case kISCSIUserClientPublishLUN: {
            if (arguments->scalarInputCount < 2) return kIOReturnBadArgument;
            ivars->controller->SetLUNGeometry(
                (uint32_t)arguments->scalarInput[0], arguments->scalarInput[1]);
            return kIOReturnSuccess;
        }
        case kISCSIUserClientUnpublishLUN:
            ivars->controller->SetLUNGeometry(0, 0);
            return kIOReturnSuccess;

        case kISCSIUserClientFetchTask: {
            if (arguments->scalarOutputCount < kISCSIFetchScalarCount) {
                return kIOReturnBadArgument;
            }
            uint64_t tag = 0, cdbLow = 0, cdbHigh = 0;
            uint32_t slot = 0, tgt = 0, lun = 0, dir = 0, len = 0, cdbLen = 0;
            if (!ivars->controller->FetchPendingTask(&tag, &slot, &tgt, &lun,
                                                     &dir, &len, &cdbLow,
                                                     &cdbHigh, &cdbLen)) {
                tag = 0; // idle
            }
            arguments->scalarOutput[kISCSIFetchTaskTag]        = tag;
            arguments->scalarOutput[kISCSIFetchSlotIndex]      = slot;
            arguments->scalarOutput[kISCSIFetchTargetID]       = tgt;
            arguments->scalarOutput[kISCSIFetchLUN]            = lun;
            arguments->scalarOutput[kISCSIFetchDirection]      = dir;
            arguments->scalarOutput[kISCSIFetchTransferLength] = len;
            arguments->scalarOutput[kISCSIFetchCDBLow]         = cdbLow;
            arguments->scalarOutput[kISCSIFetchCDBHigh]        = cdbHigh;
            arguments->scalarOutput[kISCSIFetchCDBLength]      = cdbLen;
            arguments->scalarOutputCount = kISCSIFetchScalarCount;
            return kIOReturnSuccess;
        }

        case kISCSIUserClientCompleteTask: {
            if (arguments->scalarInputCount < kISCSICompleteScalarCount) {
                return kIOReturnBadArgument;
            }
            ivars->controller->CompleteTaskFromDaemonEx(
                arguments->scalarInput[kISCSICompleteTaskTag],
                (uint32_t)arguments->scalarInput[kISCSICompleteSCSIStatus],
                (uint32_t)arguments->scalarInput[kISCSICompleteDataLength],
                (uint32_t)arguments->scalarInput[kISCSICompleteSenseLength]);
            return kIOReturnSuccess;
        }
        case kISCSIUserClientTeardownNub:
            // Reboot-free upgrade path: drop the IOUserResources nub so the
            // system re-matches a replacement dext without a reboot.
            Log("TeardownNub");
            return kIOReturnSuccess;
        default:
            return super::ExternalMethod(selector, arguments, dispatch, target, reference);
    }
}
