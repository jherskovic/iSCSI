#!/usr/sbin/dtrace -s
/*
 * storage-inflight.d — find where a blocked I/O parks inside the storage
 * stack, and which storage function it entered and never returned from.
 *
 * WHY THIS LAYER.  The wedge is BELOW APFS: during it a raw dd of
 * /dev/rdiskN and a raw flush ioctl hang too, so every previous dtrace run --
 * all of which traced com.apple.filesystems.apfs -- was pointed at the wrong
 * layer.  This traces what the raw-I/O result actually implicates:
 *
 *   IOStorageFamily                IOBlockStorageDriver, IOMedia, IOBreaker
 *   IOSCSIArchitectureModelFamily  the Type00 block device + SCSI task layer
 *   IOSCSIBlockCommandsDevice      READ/WRITE/SYNCHRONIZE CACHE construction
 *   IOSCSIParallelFamily           the HBA queue that dispatches to our dext
 *   mach_kernel IOUserServer*      the kernel side of every DriverKit RPC
 *
 * EVERYTHING IS FILTERED BY execname.  Two reasons, both learned the hard way:
 *   - Unfiltered, the boot disk buries the trace.  A 5s tick on an idle-ish
 *     box logged 133,869 IOMedia::read entries; our device contributes a
 *     handful.
 *   - fbt has no return probe for some tail-call/leaf functions, so unfiltered
 *     balances climb forever and mean nothing.  Restricted to one process's
 *     thread context, the submission path is synchronous and the balance is
 *     readable.
 * execname needs no copyinstr, which matters: copyinstr predicates are
 * unusable during this hang -- page-ins stall and every one faults, so the
 * probes you need go silent exactly when it matters.  Copy the trigger binary
 * to a unique name and pass that name as $1.
 *
 * $1 = execname of the trigger (e.g. wedgeprobe)
 * $2 = execname to watch as a second party; defaults to the dext, whose
 *      threads parking is the discriminator between "the dext is stuck" and
 *      "the family never dispatched to it".
 */

#pragma D option quiet
#pragma D option bufsize=32m
#pragma D option aggsize=32m
#pragma D option switchrate=1sec
#pragma D option dynvarsize=8m
#pragma D option defaultargs

dtrace:::BEGIN
{
	ticks = 0;
	printf("TRACE-ALIVE trigger=%s other=%s\n", $$1, $$2);
}

fbt:com.apple.iokit.IOStorageFamily::entry,
fbt:com.apple.iokit.IOSCSIArchitectureModelFamily::entry,
fbt:com.apple.iokit.IOSCSIBlockCommandsDevice::entry,
fbt:com.apple.iokit.IOSCSIParallelFamily::entry,
fbt:mach_kernel:*IOUserServer*:entry,
fbt:mach_kernel:*IOUserClient*:entry
/execname == $$1/
{
	@bal[probemod, probefunc] = sum(1);
	@calls[probefunc] = count();
	self->depth++;
	@last[probefunc] = max(timestamp);
}

fbt:com.apple.iokit.IOStorageFamily::return,
fbt:com.apple.iokit.IOSCSIArchitectureModelFamily::return,
fbt:com.apple.iokit.IOSCSIBlockCommandsDevice::return,
fbt:com.apple.iokit.IOSCSIParallelFamily::return,
fbt:mach_kernel:*IOUserServer*:return,
fbt:mach_kernel:*IOUserClient*:return
/execname == $$1/
{
	@bal[probemod, probefunc] = sum(-1);
	self->depth--;
}

/* Where the trigger actually parks.  This is the direct answer, and it needs
 * no symbolication of kernel.release.vmapple: kext frames print
 * module-qualified and C++ names demangle with c++filt on the host. */
sched:::sleep
/execname == $$1/
{
	@stk[stack(28)] = count();
}

/* The dext's own threads.  If its default dispatch queue is blocked, its
 * threads park here; if the family simply never dispatches, they do not. */
sched:::sleep
/execname == $$2/
{
	@ostk[stack(28)] = count();
}

tick-5sec
{
	ticks++;
	printf("\nMARK ===== TICK %d =====\n", ticks);
	printf("MARK -- trigger in-flight balance: module func balance --\n");
	printa("BAL %s %s %@d\n", @bal);
	printf("MARK -- trigger calls this tick (proves the trace is live) --\n");
	printa("HOT %s %@d\n", @calls);
	clear(@calls);
	printf("MARK -- trigger sleep stacks --\n");
	printa(@stk);
	printf("MARK -- %s sleep stacks --\n", $$2);
	printa(@ostk);
	printf("MARK ===== END TICK %d =====\n", ticks);
}
