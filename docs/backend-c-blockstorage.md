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

## BLOCKER FOUND: the data buffer is unreachable from a virtual dext

`DoAsyncReadWrite` hands the dext a bare address:

```c
 * @param       dmaAddr DMA address of the data buffer
uint64_t dmaAddr,
```

DriverKit provides **no way to turn a DMA address into memory a dext can read
or write**. The whole of `IOMemoryDescriptor`'s creation surface is
`CreateMapping`, `CreateWithMemoryDescriptors` and `GetAddressRange` — every one
of which needs a descriptor you already hold. There is no
"create-from-address" call.

The contrast inside this very class is the giveaway: `DoAsyncUnmap` receives an
`IOMemoryDescriptor *buffer`, which a dext *can* map, while `DoAsyncReadWrite`
receives only `dmaAddr`. That asymmetry is deliberate — this API is written for
a dext driving **DMA-capable hardware**. The dext programs its controller with
that address and the hardware moves the bytes; the dext never touches them.

A virtual device backed by a network has no hardware to program, and so cannot
service the transfer at all.

**This is why `SCSIControllerDriverKit` is the family a software HBA has to
use.** It explicitly hands the driver the payload — `UserGetDataBuffer` — which
is precisely what makes our existing virtual HBA possible, and precisely what
`IOUserBlockStorageDevice` withholds.

Using the documented API as documented, there is no way for the dext to reach
the payload. The only conceivable escape would be an undocumented mapping path,
and **this project does not use undocumented features** — so the question is
settled rather than merely open.

## Verdict: not viable, and not worth building

Backend C is **rejected for a network-backed device**. The reason is
architectural rather than incidental: the API is shaped for hardware DMA, and
the one thing a software device must have — access to the bytes — is exactly
what it does not provide.

Two supporting observations, neither of which is the deciding factor but both
of which point the same way:

- No shipping dext on macOS 26.6 uses `IOUserBlockStorageDevice`
  (`/System/Library/DriverExtensions` has none), so there is no worked example.
- There is no `com.apple.developer.driverkit.family.block-storage` entitlement
  among the family entitlements Xcode knows about (audio, hid.device,
  hid.eventservice, midi, networking, scsicontroller, serial).

**What this settles positively:** the `.img` in Backend A is not an accident or
a workaround that better API design would remove. On macOS, a userspace,
network-backed block device has exactly two routes — a SCSI controller dext
(`UserGetDataBuffer` gives it the payload) or DiskImages over a file. Backend A
takes the second; Backend B takes the first and is blocked by the APFS wedge.
There is no third door.

So the `.img` stays, and it is worth remembering what it actually is: a live
1:1 view of the LUN, not stored data. The cost is one indirection layer, not a
copy.
