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
enum {
    // Scalar methods (no struct payload).
    kISCSIUserClientPublishLUN     = 0, // args: targetID, lun, blockSize, blockCount
    kISCSIUserClientUnpublishLUN   = 1, // args: targetID, lun
    kISCSIUserClientSetRingBuffer  = 2, // maps the shared ring (struct output)
    kISCSIUserClientCompleteTask   = 3, // args: slotIndex, scsiStatus, dataLength
    kISCSIUserClientTeardownNub    = 4, // reboot-free upgrade: drop the nub
    kISCSIUserClientMethodCount
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
