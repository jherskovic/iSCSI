/*
 * syncprobe — issue one kind of flush, from user space, and time it.
 *
 * Helper for scripts/vm-fskit-barrier-probe.sh, which asks whether any flush
 * a user can issue reaches the FSKit extension (docs/backend-a-fskit-notes.md,
 * "there is no barrier signal"). Each mode is one flush, so the extension's
 * log can be read against exactly one cause.
 *
 *   cc -O2 -arch arm64 -mmacosx-version-min=26.0 -o syncprobe tools/syncprobe.c
 *
 *   syncprobe write      <file> <bytes>   create <file>, write random bytes
 *   syncprobe fsync      <file> <bytes>   ... then fsync
 *   syncprobe fullfsync  <file> <bytes>   ... then fcntl(F_FULLFSYNC)
 *   syncprobe sync-only  <file>           open read-only, fsync, F_FULLFSYNC
 *   syncprobe devflush   <rawdev>         open read-only, DKIOCSYNCHRONIZECACHE,
 *                                         then DKIOCSYNCHRONIZE
 *
 * Nothing here writes to an existing file or to a device: sync-only and
 * devflush open read-only, which is what makes them safe on lun0.img and on
 * an attached LUN's /dev/rdiskN.
 */
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/disk.h>
#include <sys/ioctl.h>
#include <time.h>
#include <unistd.h>

static double now_ms(void)
{
    return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e6;
}

static int report(const char * what, int rc, double started)
{
    double took = now_ms() - started;
    if (rc == 0) printf("  %-28s ok    %9.2f ms\n", what, took);
    else         printf("  %-28s FAIL  %9.2f ms  (%s)\n", what, took, strerror(errno));
    return rc == 0 ? 0 : 1;
}

/* Create `path` and fill it with `bytes` of random data, so there is something
 * dirty for the flush that follows to push. Returns an open fd or -1. */
static int write_new(const char * path, long long bytes)
{
    int fd = open(path, O_RDWR | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return -1; }
    char buf[65536];
    double t0 = now_ms();
    for (long long left = bytes; left > 0; ) {
        size_t n = left < (long long)sizeof buf ? (size_t)left : sizeof buf;
        arc4random_buf(buf, n);
        ssize_t w = write(fd, buf, n);
        if (w < 0) { report("write", -1, t0); close(fd); return -1; }
        left -= w;
    }
    report("write", 0, t0);
    return fd;
}

int main(int argc, char ** argv)
{
    if (argc < 3) {
        fprintf(stderr, "usage: syncprobe write|fsync|fullfsync <file> <bytes>\n"
                        "       syncprobe sync-only <file>\n"
                        "       syncprobe devflush /dev/rdiskN\n");
        return 2;
    }
    const char * mode = argv[1];
    const char * path = argv[2];
    int failures = 0;

    if (!strcmp(mode, "write") || !strcmp(mode, "fsync") || !strcmp(mode, "fullfsync")) {
        if (argc < 4) { fprintf(stderr, "%s needs a byte count\n", mode); return 2; }
        int fd = write_new(path, atoll(argv[3]));
        if (fd < 0) return 1;
        double t0 = now_ms();
        if (!strcmp(mode, "fsync"))     failures += report("fsync", fsync(fd), t0);
        if (!strcmp(mode, "fullfsync")) failures += report("F_FULLFSYNC", fcntl(fd, F_FULLFSYNC) == -1 ? -1 : 0, t0);
        close(fd);
    } else if (!strcmp(mode, "sync-only")) {
        int fd = open(path, O_RDONLY);
        if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }
        double t0 = now_ms();
        failures += report("fsync (read-only fd)", fsync(fd), t0);
        t0 = now_ms();
        failures += report("F_FULLFSYNC (read-only fd)", fcntl(fd, F_FULLFSYNC) == -1 ? -1 : 0, t0);
        close(fd);
    } else if (!strcmp(mode, "devflush")) {
        int fd = open(path, O_RDONLY);
        if (fd < 0) { fprintf(stderr, "open %s: %s\n", path, strerror(errno)); return 1; }
        double t0 = now_ms();
        failures += report("DKIOCSYNCHRONIZECACHE", ioctl(fd, DKIOCSYNCHRONIZECACHE), t0);
        dk_synchronize_t sync;
        memset(&sync, 0, sizeof sync);
        t0 = now_ms();
        failures += report("DKIOCSYNCHRONIZE", ioctl(fd, DKIOCSYNCHRONIZE, &sync), t0);
        close(fd);
    } else {
        fprintf(stderr, "unknown mode %s\n", mode);
        return 2;
    }
    return failures ? 1 : 0;
}
