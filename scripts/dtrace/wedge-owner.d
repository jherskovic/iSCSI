#!/usr/sbin/dtrace -s
/*
 * wedge-owner.d — name the lock the wedge victim parks on, and find the
 * thread that owns it.
 *
 * Why this shape: the victim (a uniquely-named copy of ls, $1) blocks with
 * ZERO storage-family entries and ZERO sched:::sleep stacks — a turnstile
 * park on a mutex, invisible to wait-queue instrumentation.  So:
 *
 *  1. When the victim enters lck_mtx_lock / lck_rw_* we print the lock
 *     address AND its first word, which on arm64 carries the owner thread
 *     pointer in its high bits.
 *  2. Every thread's last off-CPU stack is recorded keyed by the raw
 *     curthread pointer, so the owner pointer from (1) can be looked up in
 *     (2) to see where the OWNER itself is parked.
 *
 * Keyed by curthread pointer, not tid: the owner word gives us a pointer,
 * and matching pointer-to-pointer needs no struct knowledge on a kernel
 * with no CTF.
 *
 * $1 = victim execname.  Run with -c 'sleep N'; results print at END.
 */

#pragma D option quiet
#pragma D option bufsize=64m
#pragma D option aggsize=128m
#pragma D option dynvarsize=64m
#pragma D option switchrate=1sec
#pragma D option defaultargs

dtrace:::BEGIN { printf("TRACE-ALIVE wedge-owner victim=%s\n", $$1); }

/* NOTE: lck_mtx_lock has no fbt probe on this kernel (inlined fast
 * path); the victim's park site comes from its off-CPU stack instead. */

/* the victim's syscall entries, to see how far it gets */
syscall:::entry
/execname == $$1/
{
	printf("VICTIM-SYSCALL %s\n", probefunc);
}

/* (2) last off-CPU stack per thread.  max(timestamp) picks the most recent
 * park for each (thread, stack) pair; at read time the newest timestamp per
 * thread is its current park site. */
sched:::off-cpu
{
	@pstk[(uint64_t)curthread, execname, stack(20)] = max(timestamp);
}

dtrace:::END
{
	printf("\n===== PARKED-STACKS (thread, exec, stack, last-park-ns) =====\n");
	printa("THREAD %p %s %k TS %@d\n", @pstk);
}
