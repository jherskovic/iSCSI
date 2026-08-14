# Backend C: `IOUserBlockStorageDevice` — a block device with no disk image

Answering "can we do this without a `.img`?"

## What the `.img` actually is today

Backend A's `lun0.img` is **not** a stored image. It is a *view*: a file whose
bytes map 1:1 onto the LUN, served live by the FSKit extension. There is no
second copy and no container format — every read and write passes straight
through to iSCSI.

What it does cost is a layer. The chain is:

```
APFS -> /dev/diskN -> DiskImages -> lun0.img -> FSKit extension -> XPC -> iscsid -> TCP
```

DiskImages is there for exactly one reason: on macOS, a userspace process cannot
create a `/dev/disk` node. Only real hardware, a DriverKit storage dext, or
DiskImages can. FSKit publishes *filesystems*, not block devices, so Backend A
borrows DiskImages to turn a file back into a block device.

## The alternative exists: `BlockStorageDeviceDriverKit`

The DriverKit SDK ships
`System/Library/Frameworks/BlockStorageDeviceDriverKit.framework`, whose
`IOUserBlockStorageDevice` publishes a block device **directly** from a dext:

```c
kern_return_t DoAsyncReadWrite(bool isRead, uint32_t requestID, uint64_t dmaAddr,
                               uint64_t size, uint64_t lba, uint64_t numOfBlocks,
                               IOUserStorageOptions options);
kern_return_t DoAsyncSynchronize(uint32_t requestID, uint64_t lba, uint64_t numOfBlocks);
kern_return_t DoAsyncUnmap(uint32_t requestID, IOMemoryDescriptor *buffer, uint32_t numOfRanges);
kern_return_t GetDeviceParams(struct DeviceParams *);
void CompleteIO(uint32_t requestID, uint64_t bytesTransferred, kern_return_t status);
```

with

```c
#define kIOUserStorageOptionForceUnitAccess 0x0001

struct DeviceParams {
    uint64_t numOfBlocks;   uint32_t blockSize;   uint32_t maxIOSize;
    uint32_t numOfOutstandingIOs;  uint32_t maxNumOfUnmapRegions;
    uint32_t minSegmentAlignment;  uint8_t numOfAddressBits;
    bool isUnmapSupported;  bool isFUASupported;
};
```

### Why this is strictly better than both current backends

| property | Backend A (FSKit + hdiutil) | Backend B (SCSI dext) | Backend C |
|---|---|---|---|
| `.img` / DiskImages layer | required | none | **none** |
| barrier signal | **none at all** — `synchronize` is never called | SCSI flush, but elided when RMB=1 | **`DoAsyncSynchronize` + per-write FUA flag** |
| I/O interface | byte ranges through a filesystem | full SCSI CDB emulation | **LBA + block count, no CDBs** |
| queue depth control | none | `UserReportMaximumTaskCount` | `numOfOutstandingIOs` |
| alignment | must be re-derived (see `BlockAligner`) | SCSI-native | `minSegmentAlignment` declared |
| affected by the APFS wedge | no | **yes** | unknown — different family |

The two decisive points:

1. **It restores barriers.** Backend A's central limitation is structural: FSKit
   never signals a flush, so durability has to be bought with blanket
   write-through. `IOUserBlockStorageDevice` hands us `DoAsyncSynchronize` *and*
   a per-write FUA bit, so the kernel tells us exactly when a barrier is meant,
   and write-through can be dropped in favour of honouring real ones. That is a
   throughput win and a correctness win simultaneously.
2. **It is a different family from the wedge.** The documented wedge lives in
   `IOUserSCSIParallelInterfaceController` / `IOSCSIParallelFamily`
   (`feedback-virtual-scsi-wedge.md`). This is `IOBlockStorageDevice`-side and
   involves no SCSI emulation at all, so it may sidestep the bug entirely — but
   that is a hypothesis, not a result.

It also removes a lot of code: no INQUIRY/READ CAPACITY/MODE SENSE/UNMAP
emulation, no VPD pages, no sense data — the dext would translate
`DoAsyncReadWrite` to `iscsid` block I/O almost directly.

## What is not yet known

- **Whether it loads.** Both frameworks ship in the same DriverKit SDK with the
  same targets and no visible availability gating, but that is not proof the
  kernel side is present on macOS 26.6. `strings` on the kernel collections
  proves nothing here: the same probe finds no
  `IOUserSCSIParallelInterfaceController` either, and that one demonstrably
  works. The only real test is building a dext against it and loading it.
- **Which entitlement it needs.** Probably a `com.apple.developer.driverkit.*`
  family entitlement, quite possibly one requiring Apple approval, as the
  transport-family ones do.
- **Whether the APFS wedge follows it.** `scripts/vm-scratch-apfs.sh` has a
  ready-made discriminating probe: serve a RAM buffer from the dext and run the
  positional two-access test. If it survives, Backend C is the answer for the
  whole project.

## Recommendation

Worth a spike, and cheap to falsify: a minimal `IOUserBlockStorageDevice` dext
serving a RAM buffer, loaded on the SIP-off VM, with the existing positional
probe run against it. That answers "does it load" and "does the wedge follow"
in one experiment, before any iSCSI wiring.

Backend A works today and is measured; this does not displace it. But if
Backend C loads and does not wedge, it is a better destination than either
current path — fewer layers, real barriers, and no disk image.
