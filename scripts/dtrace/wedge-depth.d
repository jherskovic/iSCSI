#!/usr/sbin/dtrace -s
/*
 * wedge-depth.d — how deep does the swallowed read get?
 *
 * Established so far (26.6.2): after mount_apfs returns, the next APFS
 * btree-node read blocks forever in buf_biowait, and the dext never receives
 * a command for it.  So the read dies somewhere between buf_bread's strategy
 * call and the SCSI dispatch.  This ladder has a rung at each layer:
 *
 *   nx_buf_bread        (apfs)             the read being issued
 *   buf_strategy        (mach_kernel)      buf layer -> device vnode
 *   spec_strategy       (mach_kernel)      specfs -> the dk driver
 *   dkreadwrite         (IOStorageFamily)  BSD dk layer -> IOMedia
 *   IOMedia::read
 *   IOBlockStorageDriver::prepareRequest / deblockRequest / breakUpRequest
 *                       / executeRequest
 *   IOBlockStorageDevice::doAsyncReadWrite (IOSCSIBlockCommandsDevice)
 *
 * Keyed by execname: buf_bread issues the strategy call in the caller's
 * thread before parking in buf_biowait, so the victim's own name carries the
 * whole chain.  After the wedge stands, the victim's deepest rung with a
 * positive balance names the layer that swallowed the read.
 *
 * Balances carry per-call phantom offsets (missing fbt returns), so the
 * verdict is comparative: rungs above the swallow point go +1 and STAY; the
 * healthy-run profile of the same rungs is the control.
 */

#pragma D option quiet
#pragma D option bufsize=32m
#pragma D option aggsize=64m
#pragma D option switchrate=1sec

dtrace:::BEGIN { printf("TRACE-ALIVE wedge-depth\n"); }

fbt:com.apple.filesystems.apfs:nx_buf_bread:entry,
fbt:mach_kernel:buf_strategy:entry,
fbt:mach_kernel:spec_strategy:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZL11dkreadwritePv9dkrtype_t:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN7IOMedia4readEP9IOServiceyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletion:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14prepareRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletion:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14deblockRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14breakUpRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14executeRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry
{
	@bal[execname, probefunc] = sum(1);
}

fbt:com.apple.filesystems.apfs:nx_buf_bread:return,
fbt:mach_kernel:buf_strategy:return,
fbt:mach_kernel:spec_strategy:return,
fbt:com.apple.iokit.IOStorageFamily:_ZL11dkreadwritePv9dkrtype_t:return,
fbt:com.apple.iokit.IOStorageFamily:_ZN7IOMedia4readEP9IOServiceyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletion:return,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14prepareRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletion:return,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14deblockRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:return,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14breakUpRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:return,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14executeRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:return
{
	@bal[execname, probefunc] = sum(-1);
}

/* buf_biowait entries that never return ARE the victims — print who. */
fbt:mach_kernel:buf_biowait:entry  { @wait[execname] = sum(1); }
fbt:mach_kernel:buf_biowait:return { @wait[execname] = sum(-1); }

tick-5sec
{
	printf("\nMARK ===== TICK =====\n");
	printf("MARK -- ladder balance (exec func bal) --\n");
	printa("BAL %s %s %@d\n", @bal);
	printf("MARK -- buf_biowait balance per exec --\n");
	printa("WAIT %s %@d\n", @wait);
	printf("MARK ===== END =====\n");
}
