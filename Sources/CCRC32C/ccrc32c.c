#include "include/ccrc32c.h"

#include <string.h>

/*
 * The digest is computed over every byte that crosses the wire, in both
 * directions, so it sits directly in the throughput path. The byte-at-a-time
 * table loop this replaces also ran through a generic Swift Sequence, which
 * defeats any contiguous fast path.
 *
 * Apple silicon and every x86-64 Mac with SSE4.2 have a CRC32C instruction, so
 * the common case is a hardware path; the table remains for correctness
 * elsewhere and is exercised by the same golden vectors.
 */

#if defined(__aarch64__)
#define ISCSI_CRC32C_HW 1
#elif defined(__x86_64__) && defined(__SSE4_2__)
#define ISCSI_CRC32C_HW 1
#include <nmmintrin.h>
#else
#define ISCSI_CRC32C_HW 0
#endif

#if !ISCSI_CRC32C_HW
/* Slice-by-8 tables, built once on first use. Still far better than
 * byte-at-a-time, and only reached on hardware without the instruction. */
static uint32_t g_table[8][256];
static int g_table_ready = 0;

static void build_table(void) {
    for (unsigned i = 0; i < 256; i++) {
        uint32_t crc = i;
        for (int k = 0; k < 8; k++)
            crc = (crc & 1) ? (crc >> 1) ^ 0x82F63B78u : (crc >> 1);
        g_table[0][i] = crc;
    }
    for (unsigned i = 0; i < 256; i++) {
        uint32_t crc = g_table[0][i];
        for (int j = 1; j < 8; j++) {
            crc = g_table[0][crc & 0xFF] ^ (crc >> 8);
            g_table[j][i] = crc;
        }
    }
    g_table_ready = 1;
}
#endif

uint32_t iscsi_crc32c(uint32_t crc, const void *data, size_t len) {
    const uint8_t *p = (const uint8_t *)data;

#if ISCSI_CRC32C_HW
    /* Chew 8 bytes per instruction, then finish the tail a byte at a time.
     * memcpy rather than a cast: the callers hand us arbitrary slices of
     * network buffers, which are not guaranteed to be 8-byte aligned, and a
     * misaligned 64-bit load is undefined behaviour even where it happens to
     * work. The compiler turns this into a single load. */
    while (len >= 8) {
        uint64_t chunk;
        memcpy(&chunk, p, 8);
#if defined(__aarch64__)
        crc = __builtin_arm_crc32cd(crc, chunk);
#else
        crc = (uint32_t)_mm_crc32_u64(crc, chunk);
#endif
        p += 8;
        len -= 8;
    }
    while (len--) {
#if defined(__aarch64__)
        crc = __builtin_arm_crc32cb(crc, *p++);
#else
        crc = (uint32_t)_mm_crc32_u8(crc, *p++);
#endif
    }
#else
    if (!g_table_ready) build_table();
    while (len >= 8) {
        uint32_t lo;
        uint32_t hi;
        memcpy(&lo, p, 4);
        memcpy(&hi, p + 4, 4);
        lo ^= crc;
        crc = g_table[7][lo & 0xFF] ^ g_table[6][(lo >> 8) & 0xFF] ^
              g_table[5][(lo >> 16) & 0xFF] ^ g_table[4][(lo >> 24) & 0xFF] ^
              g_table[3][hi & 0xFF] ^ g_table[2][(hi >> 8) & 0xFF] ^
              g_table[1][(hi >> 16) & 0xFF] ^ g_table[0][(hi >> 24) & 0xFF];
        p += 8;
        len -= 8;
    }
    while (len--) crc = g_table[0][(crc ^ *p++) & 0xFF] ^ (crc >> 8);
#endif

    return crc;
}
