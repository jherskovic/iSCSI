#!/usr/sbin/dtrace -s
/*
 * wedge-loop.d — confirm the zero-progress split loop in IOBlockStorageDriver.
 *
 * Evidence so far (26.6.2): during a wedge, kernel_task re-enters
 * deblockRequest/breakUpRequest ~300/s (35,380 entries against 70
 * IOMedia::reads in one window; healthy ratio is 1:1), no command ever
 * reaches the dext, and the victim read sits in buf_biowait forever.  On
 * 26.6.1 the matching signature was breakUpRequestCompletion with actual=0
 * failing as kIOReturnIOError.  Both fit one mechanism: IOBreaker computes a
 * zero-byte break against our advertised constraints, so each iteration makes
 * no progress.
 *
 * This watches, per 5s tick:
 *   - the distribution of IOBreaker::getBreakSize RETURN values (a spike at 0
 *     during the wedge is the smoking gun)
 *   - deblock/breakUp/execute/complete entry rates
 *   - the byteStart argument of deblockRequest/breakUpRequest (arg1 for a
 *     member function), to see whether the loop is stuck at one offset
 */

#pragma D option quiet
#pragma D option bufsize=32m
#pragma D option aggsize=64m
#pragma D option switchrate=1sec

dtrace:::BEGIN { printf("TRACE-ALIVE wedge-loop\n"); }

fbt:com.apple.iokit.IOStorageFamily:_ZN9IOBreaker12getBreakSizeEyyyyyyyP18IOMemoryDescriptory:return
{
	@brk = quantize(arg1);
}

fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14deblockRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14breakUpRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver14executeRequestEyP18IOMemoryDescriptorP19IOStorageAttributesP19IOStorageCompletionPNS_7ContextE:entry
{
	@rate[probefunc] = count();
	@off[probefunc] = quantize(arg1);
}

fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver24breakUpRequestCompletionEPvS0_iy:entry,
fbt:com.apple.iokit.IOStorageFamily:_ZN20IOBlockStorageDriver24deblockRequestCompletionEPvS0_iy:entry
{
	@cmpl[probefunc, (int)arg2] = count();
	@actual[probefunc] = quantize(arg3);
}

tick-5sec
{
	printf("\nMARK ===== TICK =====\n");
	printf("MARK rates:\n");
	printa("RATE %s %@d\n", @rate);
	clear(@rate);
	printf("MARK getBreakSize return distribution:\n");
	printa(@brk);
	clear(@brk);
	printf("MARK completion (func, status) counts:\n");
	printa("CMPL %s 0x%x %@d\n", @cmpl);
	clear(@cmpl);
	printf("MARK completion actual-bytes distribution:\n");
	printa(@actual);
	clear(@actual);
	printf("MARK ===== END =====\n");
}
