# Local disk cache — design

0.7.0, feature 3 of 3. Approved in conversation 2026-10-02.

## Goal

An optional, per-target read cache on this Mac's own disk, so data that is
read again is served locally instead of over the network. Off by default;
when on, 1–16 GB in 1 GB steps (GiB internally: 1 GB here is 2^30 bytes).

What it is for, as the user chose it:

- **a long-running working set** — a VM or app running for hours that keeps
  re-reading more than the 32 MiB the in-memory chunk cache holds;
- **slow or remote links** — Wi-Fi, Tailscale, a WAN path, where every round
  trip is expensive.

What it is **not** for: making the *next* attach start warm. The cache lives
only while the target is attached and is discarded on detach.

## The decisions that shape everything

- **Session-scoped.** Nothing outlives the attach. This removes the whole
  stale-data problem: a ZFS snapshot rollback, a second initiator, a restore
  while detached — none of them can leave a local copy that disagrees with the
  LUN, and there is nothing to validate at attach time.
- **Per target.** The size is a `TargetRecord` setting like the flush interval
  and the interface pin. Two attached targets at 16 GB use up to 32 GB.
- **In the FSKit extension, under the existing RAM cache.** The extension
  already holds the only write-coherence protocol in the stack
  (`PrefetchChunkCache.willWrite` / `didWrite` / `writeFailed`, ordered by
  `DaemonStore.ioLock`, with a write-generation guard against racing miss
  fetches). A daemon-side tier would need a second one. Placement here also
  saves the XPC hop on a hit, and serves hits while the daemon is mid-recovery
  (`docs/open-questions.md` §8a).
- **Write-through, unchanged.** Writes still go to the target, FUA by default.
  The disk tier never holds the only copy of anything; a write only removes
  overlapping cached copies.
- **Encrypted with an ephemeral key.** AES-GCM, key held only in memory for the
  session.

## Expectations, stated plainly

- **A first VM boot stays cold.** `docs/queue-depth.md` measured that a VM
  boot's misses are scattered *first* touches; no cache can serve a first read.
- **The kernel's buffer cache sits above this whole stack** (APFS on
  `/dev/diskN` on the FSKit file). Buffered re-reads of hot data never reach the
  extension. The tier only sees what the buffer cache evicted or bypassed — which
  is exactly the working-set-beyond-RAM and slow-link traffic it is for.
- **No reuse measurement exists yet.** Reads are not traced today, so measuring
  reuse distance first would cost a notarized build — the same price as the
  0.7.0 RC. Instead the tier ships with its own counters (below), and the RC run
  decides whether the defaults hold.

## What "worked" means

The volume's summary line (`DaemonStore.summary`, logged at deactivate,
unmount and close) gains:

- `disk=<hits>/<lookups>` — RAM misses and speculative fetches served from the
  disk tier, out of those that consulted it;
- `diskSaved=<bytes>` — bytes served from disk instead of fetched;
- `spilled=<chunks>` — chunks written to the tier;
- `diskCorrupt=<count>` — chunks that failed authentication;
- `diskOff=<reason>` when the tier disabled itself.

At the RC (with the ramp and interface-pinning checks):

- `scripts/readahead-soak.py` against a volume with the cache on reports **zero
  mismatches** — the correctness bar, on hardware;
- a long VM session and a run over Tailscale show `diskSaved` > 0.

## Data path

Two tiers, both in the extension:

```
FSKit read ─► DaemonStore ─► PrefetchChunkCache (RAM, 32 MiB, 256 KiB chunks)
                                   │ miss / speculation
                                   ▼
                            fetch closures ─► DiskChunkTier (this design)
                                   │ not all chunks on disk
                                   ▼
                              daemon over XPC ─► network
```

### Lookups

`PrefetchChunkCache` already takes its fetches as closures from
`DaemonStore` (`fetchSync` for a miss, `fetchAsync` for speculation). The disk
tier is consulted inside those closures, so the RAM cache needs no knowledge of
it for reads.

- **A miss** fetches a span of one or more chunks (read-around). It is served
  from the disk tier **only if every chunk of the span is there**; otherwise the
  whole span goes to the daemon as today. A partial hit never costs an extra
  round trip.
- **A speculative fetch** is one chunk; it is served from the disk tier when the
  chunk is there, asynchronously, instead of from the daemon.
- A disk hit's bytes go into the RAM tier exactly as fetched bytes do — through
  the same generation guard.

### Admission — victim spill

Bytes enter the disk tier **only** when the RAM tier evicts a ready chunk that
was actually read: a demand-fetched chunk, or a speculative one with `used`
set. Unused speculation never reaches disk. Nothing enters the disk tier
directly from a fetch, so everything on disk has already passed the RAM tier's
generation guard.

`PrefetchChunkCache` gains an eviction hook — `onEvict(offset, data)` — called
for exactly those chunks. Spilling (encrypt + write) runs on a serial
background queue, never under the RAM cache's lock.

The tier is **inclusive**: a disk hit leaves the slot in place, so when the RAM
tier evicts the same unchanged chunk again, the spill finds it already on disk
and writes nothing.

### Eviction — segmented LRU

The ramp change means a clean stream reaches depth 32 in about two seconds,
and every chunk of a 100 GB copy is read once — so under plain LRU one big copy
flushes a 16 GB tier of hot VM data. Instead:

- **Probation** holds new spills. **Protected** holds chunks that were hit at
  least once while on disk, up to ~80% of slots.
- A disk hit moves a chunk to the protected head. Protected overflow demotes its
  LRU chunk to the probation head. Eviction takes the probation tail.

A sequential copy only ever churns probation; the re-referenced working set in
protected survives it.

## Coherence

The invariants, each with a test:

1. **Only the RAM tier writes to the disk tier.** (Admission above.)
2. **Every write invalidates overlapping disk entries at both edges** — in
   `DaemonStore.write`, alongside `cache.willWrite` (before the device write)
   and again alongside `cache.didWrite` / `cache.writeFailed` (after it). Both
   edges, because the RAM tier can evict a chunk *between* them, and that spill
   carries pre-write bytes.
3. **A pending spill can never land after an invalidation of its chunk.** When a
   spill is enqueued it records a per-chunk ticket under the tier's lock;
   invalidation removes the ticket; the queued job inserts only if its ticket is
   still current.
4. **Invalidation is synchronous** — the in-memory index entry is gone before
   `invalidate` returns, so no read after the write can find the old slot.

Concurrency: the tier's index is guarded by its own lock; file reads and the
queued spills use `pread`/`pwrite` on one descriptor, so the file I/O itself
runs outside the lock. A reader copies the slot number, nonce and length under
the lock, then reads without it. If the slot is evicted and reused for another
chunk meanwhile, authentication fails — the additional authenticated data names
the chunk the reader asked for. The reader then re-checks the index under the
lock: an entry that changed means a plain miss (nothing freed, nothing counted);
an entry that did not change means real corruption, so that slot is freed and
`diskCorrupt` counts it.

## A cache problem never fails a read

Stated as an invariant, with tests:

- A chunk that fails AES-GCM authentication is a **miss**: its slot is freed,
  `diskCorrupt` counts it, and the read goes to the network.
- Any I/O error from the cache file — `ENOSPC` above all, since the sparse file
  grows as it fills and other apps can fill the disk — **disables the tier**:
  index dropped, descriptor closed, one log line, `diskOff=<reason>`. Every
  later read goes to the network exactly as with the cache off.
- Creating the tier at attach is best effort too: if anything fails, the volume
  mounts with the tier off and says so in the log.

## Storage

- **One sparse file** in the extension's sandbox `Library/Caches`
  (`FileManager.urls(for: .cachesDirectory, in: .userDomainMask)` inside the
  sandbox), created with `O_CREAT | O_EXCL` under a random name, then
  **unlinked immediately**. Nothing outlives the process — not a detach, not a
  crash — so there is no leftover sweep and no ownership logic.
- **`F_NOCACHE`** on the descriptor: the tier sits *under* the buffer cache, and
  caching its file in the same buffer cache would spend RAM twice on one chunk.
- **Fixed slots.** Stride = chunk size + 4 KiB (the 16-byte GCM tag lives in the
  extra page, keeping chunk data page-aligned). Slot count =
  `budgetBytes / stride`, so the file never exceeds the budget. 16 GB of
  256 KiB chunks is ~64,500 slots; the index (chunk offset → slot, nonce,
  length, segment links) is a few MB of memory.
- **Encryption.** CryptoKit `AES.GCM`, a `SymmetricKey(size: .bits256)` made
  per tier and never written anywhere. Nonce = 4-byte slot index + 8-byte
  per-tier write counter, kept in the in-memory index (so a nonce never repeats
  under one key). The chunk's LUN offset and length are the additional
  authenticated data, so a slot mix-up fails authentication instead of
  returning another chunk's bytes. A crash leaves ciphertext under a key that no
  longer exists.
- **Free space at attach.** `statfs` on the caches directory; the effective
  budget is `min(configured, available − 10 GiB)`. Below 1 GiB the tier stays
  off (`diskOff=space`). The effective size is logged.

## Configuration and plumbing

- **`TargetRecord.localCacheGB: Int?`** — optional (a non-optional key would
  break every existing `targets.json`). nil or 0 is off; 1…16 is the size; any
  other value is off. Derived accessor `localCacheBytes: Int` (0 when off).
- **Daemon → extension**, by the `readaheadBudget` precedent:
  `XPCService.claim(_:readaheadBudget:)` also records the record's cache bytes
  for the handle, and a new XPC call `localCacheBytes(session:reply:)` returns
  them (scoped to the owning connection like `readaheadBudget`). The extension
  asks after login. An older daemon, or any error, means off — a mount must not
  fail for a cache.
- **Target editor.** A "Local cache" picker in its own section: Off, 1 GB … 16
  GB. Footer: "Kept on this Mac's disk, encrypted, only while the target is
  attached. Takes effect the next time it is attached."

## Code layout

- `Sources/iSCSIVolume/DiskChunkTier.swift` — the tier: file, slots, crypto,
  spill queue, tickets, invalidation, disable-on-error, stats. iSCSIVolume
  already does file I/O (`BackingStore`), so no layering rule bends.
- `Sources/iSCSIVolume/SegmentedLRU.swift` — the pure eviction index, unit-tested
  on its own.
- `Sources/iSCSIKit/Session/PrefetchChunkCache.swift` — gains the `onEvict` hook
  and nothing else.
- `Sources/iSCSIVolume/LUNStore.swift` (`DaemonStore`) — builds the tier, routes
  the fetch closures through it, invalidates at both write edges, extends the
  summary. The test initializer gains the RAM cache size and an injected tier,
  so tests can force evictions.
- `XPCModels.swift`, `XPCProtocol.swift`, `XPCService.swift` — the record key and
  the XPC call. `TargetsView.swift` — the picker.

## Testing

Unit:

- `SegmentedLRU`: admission to probation; promotion on hit; protected overflow
  demotes; eviction from probation; a scan of N new chunks evicts none of the
  protected set; capacity never exceeded.
- `DiskChunkTier` against a temp directory:
  - admit → lookup returns the bytes; invalidate → lookup misses;
  - **a pending spill cancelled by an invalidation never lands** (spill queue
    held paused in the test);
  - **a tampered slot is a miss**, freed and counted, not data;
  - **an injected write failure disables the tier**, and later lookups miss
    without touching the file;
  - **the cache file is gone from the directory** right after creation;
  - the file never exceeds the budget; re-spilling an unchanged chunk writes
    nothing.
- `TargetRecord`: a pre-0.7.0 record decodes with the cache off; out-of-range
  values are off; the key round-trips.

Integration (`DaemonStore` with the injected fake daemon, small RAM cache):

- a chunk re-read after RAM eviction makes **no daemon call**;
- write-then-read after eviction returns the **new** bytes;
- a write to a chunk held **only on disk** invalidates it;
- a write racing a pending spill — the later read returns the new bytes;
- after the tier disables itself, reads keep succeeding from the daemon;
- a speculative fetch is served from disk when the chunk is there.

XPC: the record's cache size reaches `localCacheBytes(session:)`; another
connection cannot read it; an unset record answers 0.

Hardware: at the RC, as under "What worked means".

## Out of scope

- Write-back caching. FUA and the flush policy are unchanged.
- Keeping the cache across detach, reboot or a new attach.
- A global, cross-target budget.
- Any metadata written to the LUN.
- Caching on the daemon side, or for `iscsictl`.
