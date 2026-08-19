#!/usr/sbin/dtrace -s
/*
 * wedge-zero.d — catch every zero-byte IOBreaker::getBreakSize verdict with
 * its full argument set and caller stack.
 *
 * Signature (from the mangled name):
 *   IOBreaker::getBreakSize(unsigned long long withMaximumBlockCountRead,
 *       u64 withMaximumBlockCountWrite, u64 withMaximumByteCountRead,
 *       u64 withMaximumByteCountWrite, u64 withMaximumSegmentCountRead,
 *       u64 withMaximumSegmentCountWrite, u64 withMaximumSegmentByteCount,
 *       IOMemoryDescriptor *buffer, u64 withRequestStart)
 *   -- static member, so arg0..arg8 are exactly these.
 *
 * The zero case is the swallow candidate: on 26.6.1 a zero-progress
 * sub-request completed with kIOReturnIOError actual=0 (newfs EIO); on
 * 26.6.2 the request appears to be neither executed nor completed, and its
 * caller waits in buf_biowait forever.  The constraint set in the printout
 * attributes the device: ours advertises segment count 1 / segment byte
 * count 65536; the virtio boot disk differs.
 */

#pragma D option quiet
#pragma D option bufsize=32m
#pragma D option switchrate=1sec

dtrace:::BEGIN { printf("TRACE-ALIVE wedge-zero\n"); }

fbt:com.apple.iokit.IOStorageFamily:_ZN9IOBreaker12getBreakSizeEyyyyyyyP18IOMemoryDescriptory:entry
{
	self->a0 = arg0; self->a1 = arg1; self->a2 = arg2; self->a3 = arg3;
	self->a4 = arg4; self->a5 = arg5; self->a6 = arg6; self->a7 = arg7;
	self->a8 = arg8;
	self->inbrk = 1;
}

fbt:com.apple.iokit.IOStorageFamily:_ZN9IOBreaker12getBreakSizeEyyyyyyyP18IOMemoryDescriptory:return
/self->inbrk && arg1 == 0/
{
	printf("ZERO %Y exec=%s maxBlkR=%llu maxBlkW=%llu maxByteR=%llu maxByteW=%llu maxSegR=%llu maxSegW=%llu maxSegByte=%llu md=%p reqStart=%llu\n",
	    walltimestamp, execname,
	    (unsigned long long)self->a0, (unsigned long long)self->a1,
	    (unsigned long long)self->a2, (unsigned long long)self->a3,
	    (unsigned long long)self->a4, (unsigned long long)self->a5,
	    (unsigned long long)self->a6, (void *)self->a7,
	    (unsigned long long)self->a8);
	stack(16);
}

fbt:com.apple.iokit.IOStorageFamily:_ZN9IOBreaker12getBreakSizeEyyyyyyyP18IOMemoryDescriptory:return
/self->inbrk/
{
	@sizes[execname] = quantize(arg1);
	self->inbrk = 0;
}

tick-10sec
{
	printf("MARK tick\n");
}

dtrace:::END
{
	printf("===== break sizes by exec =====\n");
	printa(@sizes);
}
