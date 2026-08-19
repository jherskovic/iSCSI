#!/usr/sbin/dtrace -s
/*
 * storage-errors.d — catch the exact function that manufactures a storage
 * error, anywhere in the block/SCSI stack.
 *
 * Motivating case: newfs_apfs on the dext's scratch disk fails with
 *   nx_format:308: failed to write superblock to block 0: 5 - Input/output error
 * while the dext receives every command and answers it cleanly, and a raw dd
 * write to the very same block 0 succeeds.  So the EIO is manufactured above
 * the driver, and the docs' note that this error "never reaches the driver"
 * says where NOT to look but not where it comes from.
 *
 * Two nets:
 *   1. Any IOReturn-shaped error (0xe0000000/8) returned by any function in
 *      the four storage kexts.  IOReturn errors are 0xe00002xx, so the mask is
 *      cheap and the volume is near zero until something actually fails.
 *   2. The completion routines, printed with their status arguments, so a
 *      failure that travels as a completion status rather than a return value
 *      is caught too.
 *
 * Runs unfiltered by execname on purpose: completions land on workloop
 * threads, not the caller's, so an execname predicate would hide exactly the
 * half that matters.
 */

#pragma D option quiet
#pragma D option bufsize=32m
#pragma D option switchrate=100ms
#pragma D option defaultargs

dtrace:::BEGIN { printf("TRACE-ALIVE storage-errors\n"); }

/* Net 1: any IOReturn error out of the storage stack. */
fbt:com.apple.iokit.IOStorageFamily::return,
fbt:com.apple.iokit.IOSCSIArchitectureModelFamily::return,
fbt:com.apple.iokit.IOSCSIBlockCommandsDevice::return,
fbt:com.apple.iokit.IOSCSIParallelFamily::return
/(arg1 & 0xff000000) == 0xe0000000/
{
	printf("ERR  [%s pid=%d] %s`%s -> 0x%x\n", execname, pid, probemod, probefunc, (int)arg1);
}

/* Net 2: completions, with the status they carry.  arg2 is the status for
 * both of these (void *, void *, int status, uint64 actual). */
fbt:com.apple.iokit.IOStorageFamily:_ZL21dkreadwritecompletionPvS_iy:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver24breakUpRequestCompletionEPvS0_iy:entry
/(int)arg2 != 0/
{
	printf("CMPL [%s pid=%d] %s status=0x%x actual=%d\n", execname, pid, probefunc, (int)arg2, (int)arg3);
}

/* The SCSI layer's verdict on every task: service response + task status. */
fbt:com.apple.iokit.IOSCSIArchitectureModelFamily:_ZN22IOSCSIProtocolServices16CommandCompletedEP8OSObject19SCSIServiceResponse14SCSITaskStatus:entry
{
	@svc[(int)arg1, (int)arg2] = count();
}

/* Deblocking and breaking are where a request that violates the HBA
 * constraints would be rejected rather than dispatched. */
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14deblockRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14breakUpRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry
/execname == $$1/
{
	@req[probefunc] = count();
}

tick-5sec
{
	printf("-- SCSI CommandCompleted (serviceResponse, taskStatus) counts --\n");
	printa("     svcResp=%d taskStatus=%d  %@d\n", @svc);
	printf("-- %s request shaping counts --\n", $$1);
	printa("     %s %@d\n", @req);
	printf("-- end tick --\n");
}
