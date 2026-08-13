/*
 * ukopen.c — time an IOKit lookup + user-client open on a named service class.
 *
 *   ./ukopen IOHIDSystem
 *   ./ukopen iSCSIDext
 *
 * Why this exists: `iscsictl dext-stats` hangs while the iSCSI device is
 * wedged and returns in ~7s when healthy, which looked like proof that the
 * dext cannot service a request. It is not proof. Every inspection tool tried
 * so far — spindump, log show, ps, pgrep, sample — also hangs once the box is
 * wedged, and a control run showed `sample` hanging on an ordinary sleep
 * process just as readily as on the dext.
 *
 * So the question is whether IOKit itself still works during a wedge. Point
 * this at a service that has nothing to do with storage:
 *
 *   returns promptly -> IOKit is fine, and the dext's hang is specific to us
 *   hangs            -> IOKit is globally stuck and the dext's hang says
 *                       nothing about the dext
 *
 * A FAILED open is a perfectly good result: what matters is whether the call
 * returns at all, not whether it succeeds. Many services refuse to open
 * without entitlements, and that refusal still proves IOKit is live.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <mach/mach.h>
#include <IOKit/IOKitLib.h>
#include <sys/time.h>

static double now_ms(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return tv.tv_sec * 1000.0 + tv.tv_usec / 1000.0;
}

int main(int argc, char ** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: ukopen <IOServiceClassName>\n"); return 2; }
    const char * cls = argv[1];

    /* Unbuffered: if the process is killed mid-hang, whatever it managed to
       print must already have escaped. */
    setvbuf(stdout, NULL, _IONBF, 0);

    printf("%-18s looking up...\n", cls);
    double t0 = now_ms();

    /* Same fallback chain as DextBridge.findService: our dext's registry class
       is the SCSI family's kernel proxy (IOUserSCSIParallelInterfaceController),
       not "iSCSIDext", so a plain class match misses it. Unrelated services
       like IOHIDSystem match on the first try. */
    io_service_t svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                                   IOServiceMatching(cls));
    if (svc == IO_OBJECT_NULL) {
        svc = IOServiceGetMatchingService(kIOMainPortDefault,
                                          IOServiceNameMatching(cls));
    }
    if (svc == IO_OBJECT_NULL) {
        CFStringRef key = CFStringCreateWithCString(NULL, cls, kCFStringEncodingUTF8);
        CFStringRef userClassKey = CFSTR("IOUserClass");
        CFDictionaryRef inner = CFDictionaryCreate(NULL,
                                                   (const void **)&userClassKey,
                                                   (const void **)&key, 1,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        CFStringRef propKey = CFSTR("IOPropertyMatch");
        CFDictionaryRef match = CFDictionaryCreate(NULL,
                                                   (const void **)&propKey,
                                                   (const void **)&inner, 1,
                                                   &kCFTypeDictionaryKeyCallBacks,
                                                   &kCFTypeDictionaryValueCallBacks);
        svc = IOServiceGetMatchingService(kIOMainPortDefault, match);
        CFRelease(key);
        CFRelease(inner);
    }
    double t1 = now_ms();
    if (svc == IO_OBJECT_NULL) {
        printf("%-18s LOOKUP-NOTFOUND    %.0f ms\n", cls, t1 - t0);
        return 1;
    }
    printf("%-18s LOOKUP-OK          %.0f ms\n", cls, t1 - t0);

    printf("%-18s opening user client...\n", cls);
    io_connect_t conn = IO_OBJECT_NULL;
    double t2 = now_ms();
    kern_return_t kr = IOServiceOpen(svc, mach_task_self(), 0, &conn);
    double t3 = now_ms();

    /* Any return is a pass: the point is liveness, not access. */
    printf("%-18s OPEN-RETURNED kr=0x%x  %.0f ms\n", cls, kr, t3 - t2);

    if (kr == KERN_SUCCESS) IOServiceClose(conn);
    IOObjectRelease(svc);
    return 0;
}
