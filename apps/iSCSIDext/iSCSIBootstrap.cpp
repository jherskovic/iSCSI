//
//  iSCSIBootstrap.cpp
//  See iSCSIBootstrap.iig. The marker property `iSCSIVirtualHBA` is declared
//  in this personality's Info.plist dict, so it is already present on this
//  service's registry entry — we only need to RegisterService() so the
//  controller personality can match us as its provider.
//

#include <os/log.h>
#include <DriverKit/IOLib.h>
#include <DriverKit/IOService.h>

#include "iSCSIBootstrap.h"

#define Log(fmt, ...) os_log(OS_LOG_DEFAULT, "iSCSIBootstrap: " fmt, ##__VA_ARGS__)

bool iSCSIBootstrap::init()
{
    return super::init();
}

void iSCSIBootstrap::free()
{
    super::free();
}

kern_return_t
IMPL(iSCSIBootstrap, Start)
{
    kern_return_t ret = Start(provider, SUPERDISPATCH);
    if (ret != kIOReturnSuccess) {
        Log("super Start failed: 0x%x", ret);
        return ret;
    }
    Log("Start: publishing virtual SCSI HBA nub");
    // Makes this object matchable as a provider by the controller personality.
    ret = RegisterService();
    if (ret != kIOReturnSuccess) {
        Log("RegisterService failed: 0x%x", ret);
    }
    return kIOReturnSuccess;
}

kern_return_t
IMPL(iSCSIBootstrap, Stop)
{
    Log("Stop");
    return Stop(provider, SUPERDISPATCH);
}
