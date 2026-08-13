//
//  iSCSIUserClientShared.h
//  Shared wire contract between the iscsid daemon (user space) and the
//  iSCSIDext DriverKit extension. Included by both the C++ dext and, via a
//  bridging header, the Swift daemon.
//
//  This defines the IOUserClient method selectors and the shared-memory ring
//  layout. Keep it dependency-free (plain C) so both sides can include it.
//

#ifndef iSCSIUserClientShared_h
#define iSCSIUserClientShared_h

#include <stdint.h>

// External method selectors on the dext's IOUserClient.
//
// Control travels as SCALARS (max 16 per call, so everything below fits inline
// and we never need out-of-line struct descriptors); bulk payload travels
// through the shared data arena mapped once via CopyClientMemoryForType. That
// keeps the DriverKit surface small — scalar methods plus one memory mapping.
enum {
    // in: blockSize, blockCount. Publishes LUN geometry; until this arrives the
    // dext answers TEST UNIT READY / READ CAPACITY with NOT READY.
    kISCSIUserClientPublishLUN     = 0,
    kISCSIUserClientUnpublishLUN   = 1, // no args
    // Maps the shared data arena (memory type for CopyClientMemoryForType).
    kISCSIUserClientSetRingBuffer  = 2,
    // out: see ISCSIFetchScalar order below. Returns taskTag == 0 when idle.
    kISCSIUserClientFetchTask      = 3,
    // in: taskTag, scsiStatus, dataLength, senseLength
    kISCSIUserClientCompleteTask   = 4,
    kISCSIUserClientTeardownNub    = 5, // reboot-free upgrade: drop the nub
    // out: see ISCSIStatsScalar order below. Reads the dext's task counters
    // directly, with no dependence on os_log.
    //
    // Diagnosing the post-mount wedge needs these counters at the moment the
    // device stops serving I/O, and the log cannot deliver them then: the
    // watchdog's heartbeat stops, `log show` itself hangs, and a forced
    // power-off loses the whole window because logd never flushed it. Bare ssh
    // keeps working during a wedge, so a scalar read is the one channel that
    // still answers "did we complete everything we were handed?".
    kISCSIUserClientGetStats       = 6,
    kISCSIUserClientMethodCount
};

// Scalar output order for kISCSIUserClientGetStats. Mirrors the watchdog's
// stats line, plus the live/zombie slot census it computes on the fly.
enum {
    kISCSIStatsParked        = 0,
    kISCSIStatsParkFull      = 1,
    kISCSIStatsFetched       = 2,
    kISCSIStatsCompleted     = 3,
    kISCSIStatsWatchdogFail  = 4,
    kISCSIStatsAborted       = 5,
    kISCSIStatsZombieLate    = 6,
    kISCSIStatsZombieExpired = 7,
    kISCSIStatsInflight      = 8, // slots currently Parked or Fetched
    kISCSIStatsZombies       = 9,
    kISCSIStatsWatchdogTick  = 10, // proves the watchdog thread is still running
    kISCSIStatsScalarCount   = 11
};

// Scalar output order for kISCSIUserClientFetchTask.
enum {
    kISCSIFetchTaskTag        = 0, // 0 => no task pending
    kISCSIFetchSlotIndex      = 1, // payload lives at slotIndex * kISCSISlotPayloadBytes
    kISCSIFetchTargetID       = 2,
    kISCSIFetchLUN            = 3,
    kISCSIFetchDirection      = 4, // 0 none, 1 device→initiator (read), 2 write
    kISCSIFetchTransferLength = 5,
    kISCSIFetchCDBLow         = 6, // CDB bytes 0-7, little-endian packed
    kISCSIFetchCDBHigh        = 7, // CDB bytes 8-15
    kISCSIFetchCDBLength      = 8,
    kISCSIFetchScalarCount    = 9
};

// Scalar input order for kISCSIUserClientCompleteTask. For a read the daemon
// first writes dataLength bytes into the arena at slotIndex*kISCSISlotPayloadBytes;
// on error it writes senseLength sense bytes at that same offset instead.
enum {
    kISCSICompleteTaskTag     = 0,
    kISCSICompleteSCSIStatus  = 1, // SAM status byte (0 = GOOD)
    kISCSICompleteDataLength  = 2,
    kISCSICompleteSenseLength = 3,
    kISCSICompleteScalarCount = 4
};

// Transfer directions used in the fetch scalars.
enum {
    kISCSIDirectionNone  = 0,
    kISCSIDirectionRead  = 1,
    kISCSIDirectionWrite = 2
};

// One entry in the request ring: a SCSI task the kernel handed us that must be
// serviced by the daemon (forwarded to the target over iSCSI).
typedef struct {
    uint64_t taskTag;       // dext-assigned, unique while outstanding
    uint64_t lun;
    uint32_t targetID;
    uint32_t direction;     // 0 none, 1 read (device→initiator), 2 write
    uint32_t transferLength;
    uint32_t cdbLength;
    uint8_t  cdb[16];
    uint64_t bufferOffset;  // offset into the shared data region
} ISCSIRequestSlot;

// One entry in the completion ring: the daemon's answer.
typedef struct {
    uint64_t taskTag;
    uint32_t scsiStatus;    // SAM status byte
    uint32_t dataLength;    // bytes placed in the data region (reads)
    uint32_t senseLength;
    uint8_t  sense[96];
} ISCSICompletionSlot;

// Ring geometry. Chosen large per DTS guidance; the single-segment framework
// limitation (see docs/architecture.md) still caps per-task size in practice.
enum {
    kISCSIRequestSlotCount    = 256,
    kISCSICompletionSlotCount = 256,
    kISCSIDataRegionBytes     = 16u * 1024u * 1024u, // 16 MiB payload arena
    kISCSISlotPayloadBytes    = 65536,               // per-slot data window
    // Reported to the SCSI family via UserReportHBAConstraints(). We advertise
    // a single segment of this size; IOBreaker splits larger requests. Keep it
    // <= kISCSISlotPayloadBytes so a task always fits one ring slot.
    kISCSIMaxSegmentByteCount = 65536,
};

// Shared-memory header at the front of the mapped region. The daemon and dext
// coordinate through the head/tail indices with acquire/release semantics.
typedef struct {
    _Atomic uint32_t requestHead;      // dext writes, daemon reads
    _Atomic uint32_t requestTail;      // daemon writes back after consuming
    _Atomic uint32_t completionHead;   // daemon writes
    _Atomic uint32_t completionTail;   // dext reads
    uint32_t abiVersion;
    uint32_t _reserved[11];
} ISCSIRingHeader;

#define kISCSIUserClientABIVersion 1u

// Async notification types delivered daemon→dext are handled via
// IODataQueueDispatchSource; the ring above carries the bulk data.

#endif /* iSCSIUserClientShared_h */
