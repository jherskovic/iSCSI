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
#include "iSCSIUserClientShared.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "iSCSIUserClient: " fmt, ##__VA_ARGS__)

struct iSCSIUserClient_IVars
{
    IOBufferMemoryDescriptor * ringBuffer; // header + request/completion rings + data arena
};

bool iSCSIUserClient::init()
{
    if (!super::init()) return false;
    ivars = IONewZero(iSCSIUserClient_IVars, 1);
    return ivars != nullptr;
}

void iSCSIUserClient::free()
{
    if (ivars) {
        OSSafeReleaseNULL(ivars->ringBuffer);
    }
    IOSafeDeleteNULL(ivars, iSCSIUserClient_IVars, 1);
    super::free();
}

kern_return_t
IMPL(iSCSIUserClient, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) return ret;

    // Allocate the shared ring: header + request slots + completion slots +
    // data arena, all in one mapped region.
    const uint64_t total =
        sizeof(ISCSIRingHeader) +
        sizeof(ISCSIRequestSlot) * kISCSIRequestSlotCount +
        sizeof(ISCSICompletionSlot) * kISCSICompletionSlotCount +
        kISCSIDataRegionBytes;

    ret = IOBufferMemoryDescriptor::Create(
        kIOMemoryDirectionInOut, total, 0, &ivars->ringBuffer);
    if (ret != kIOReturnSuccess) {
        Log("ring alloc failed: 0x%x", ret);
        return ret;
    }
    Log("Start: %llu-byte shared ring ready", total);
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIUserClient, Stop)
{
    Log("Stop");
    return Stop(provider, SUPERDISPATCH);
}

kern_return_t
IMPL(iSCSIUserClient, CopyClientMemoryForType)
{
    if (type == kISCSIUserClientSetRingBuffer && ivars->ringBuffer) {
        ivars->ringBuffer->retain();
        *memory = ivars->ringBuffer;
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
    switch (selector) {
        case kISCSIUserClientPublishLUN:
            // args->scalarInput[0..3] = targetID, lun, blockSize, blockCount
            // TODO: tell the controller to publish; trigger a bus rescan.
            Log("PublishLUN");
            return kIOReturnSuccess;
        case kISCSIUserClientUnpublishLUN:
            Log("UnpublishLUN");
            return kIOReturnSuccess;
        case kISCSIUserClientCompleteTask:
            // args->scalarInput[0..2] = slotIndex, scsiStatus, dataLength
            // TODO: forward to iSCSIDext::CompleteTaskFromDaemon.
            return kIOReturnSuccess;
        case kISCSIUserClientTeardownNub:
            // Reboot-free upgrade path: drop the IOUserResources nub so the
            // system re-matches a replacement dext without a reboot.
            Log("TeardownNub");
            return kIOReturnSuccess;
        default:
            return super::ExternalMethod(selector, arguments, dispatch, target, reference);
    }
}
