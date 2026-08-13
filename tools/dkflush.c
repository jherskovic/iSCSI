/*
 * dkflush — ask a block device to flush, directly, with no filesystem in the way.
 *
 * The APFS blocker (docs/architecture.md → "OPEN: APFS hangs") rests on one
 * claim: the kernel never sends SYNCHRONIZE CACHE to our DriverKit-backed LUN.
 * Every observation of that so far came from watching a *filesystem* (newfs_apfs,
 * mount) and inferring what it asked for. This tool removes the inference: it
 * opens the raw device and issues the flush ioctls itself, so "no SYNCHRONIZE
 * CACHE on the wire" becomes a statement about the storage stack alone.
 *
 *   cc -O2 -o dkflush tools/dkflush.c
 *   ./dkflush /dev/rdisk5           # read-only probe: features + flush
 *   ./dkflush /dev/rdisk5 --write   # also write before/after the flush
 *
 * --write is destructive: it scribbles on the first block of the device.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <sys/time.h>
#include <unistd.h>

/* Older SDKs are missing some of these; the ioctl numbers are stable. */
#ifndef DK_FEATURE_BARRIER
#define DK_FEATURE_BARRIER      0x00000002
#endif
#ifndef DK_FEATURE_PRIORITY
#define DK_FEATURE_PRIORITY     0x00000004
#endif
#ifndef DK_FEATURE_UNMAP
#define DK_FEATURE_UNMAP        0x00000010
#endif
#ifndef DK_FEATURE_QUEUEDFLUSH
#define DK_FEATURE_QUEUEDFLUSH  0x00000020
#endif

static double now_us(void)
{
    struct timeval tv;
    gettimeofday(&tv, NULL);
    return (double)tv.tv_sec * 1e6 + (double)tv.tv_usec;
}

/* Run one ioctl, print how long it took and how it ended. */
static void timed(const char * what, int fd, unsigned long req, void * arg)
{
    double t0 = now_us();
    int rc = ioctl(fd, req, arg);
    double dt = now_us() - t0;
    if (rc == 0) printf("  %-34s ok        %9.0f us\n", what, dt);
    else         printf("  %-34s FAIL %-3d  %9.0f us  (%s)\n", what, errno, dt, strerror(errno));
}

int main(int argc, char ** argv)
{
    if (argc < 2) { fprintf(stderr, "usage: dkflush /dev/rdiskN [--write]\n"); return 2; }
    const char * dev = argv[1];
    int do_write = (argc > 2 && strcmp(argv[2], "--write") == 0);

    int fd = open(dev, do_write ? O_RDWR : O_RDONLY);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", dev, strerror(errno)); return 1; }
    printf("device: %s (%s)\n", dev, do_write ? "read-write" : "read-only");

    uint32_t features = 0, bs = 0;
    uint64_t bc = 0;
    if (ioctl(fd, DKIOCGETFEATURES, &features) < 0) printf("  DKIOCGETFEATURES failed: %s\n", strerror(errno));
    ioctl(fd, DKIOCGETBLOCKSIZE, &bs);
    ioctl(fd, DKIOCGETBLOCKCOUNT, &bc);
    printf("  features = 0x%08x  [%s%s%s%s]\n", features,
           (features & DK_FEATURE_BARRIER)     ? "barrier "     : "",
           (features & DK_FEATURE_PRIORITY)    ? "priority "    : "",
           (features & DK_FEATURE_UNMAP)       ? "unmap "       : "",
           (features & DK_FEATURE_QUEUEDFLUSH) ? "queuedflush " : "");
    printf("  geometry = %llu blocks x %u bytes\n", (unsigned long long)bc, bs);

    /* Dirty the device first: a flush with nothing outstanding is a weaker
     * test, since the stack is free to elide it as trivially satisfied. */
    if (do_write && bs) {
        void * buf = NULL;
        if (posix_memalign(&buf, 4096, bs) == 0) {
            memset(buf, 0xA5, bs);
            double t0 = now_us();
            ssize_t w = pwrite(fd, buf, bs, 0);
            printf("  %-34s %s  %9.0f us\n", "pwrite block 0 (pre-flush)",
                   w == (ssize_t)bs ? "ok       " : "FAIL     ", now_us() - t0);
            if (w != (ssize_t)bs) printf("      -> %s\n", strerror(errno));
            free(buf);
        }
    }

    printf("flush:\n");
    timed("DKIOCSYNCHRONIZECACHE (legacy)", fd, DKIOCSYNCHRONIZECACHE, NULL);

    dk_synchronize_t sync;
    memset(&sync, 0, sizeof(sync));
    timed("DKIOCSYNCHRONIZE (whole device)", fd, DKIOCSYNCHRONIZE, &sync);

    memset(&sync, 0, sizeof(sync));
    sync.options = DK_SYNCHRONIZE_OPTION_BARRIER;
    timed("DKIOCSYNCHRONIZE (barrier)", fd, DKIOCSYNCHRONIZE, &sync);

    /* The WCE=1 symptom was a write EIO'ing in ~24 us right after a flush.
     * Repeat that shape here, away from newfs_apfs. */
    if (do_write && bs) {
        void * buf = NULL;
        if (posix_memalign(&buf, 4096, bs) == 0) {
            memset(buf, 0x5A, bs);
            double t0 = now_us();
            ssize_t w = pwrite(fd, buf, bs, 0);
            printf("  %-34s %s  %9.0f us\n", "pwrite block 0 (post-flush)",
                   w == (ssize_t)bs ? "ok       " : "FAIL     ", now_us() - t0);
            if (w != (ssize_t)bs) printf("      -> %s\n", strerror(errno));
            free(buf);
        }
    }

    close(fd);
    return 0;
}
