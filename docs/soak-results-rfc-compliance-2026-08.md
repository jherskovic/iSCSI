# Protocol soak after the RFC 7143 compliance fixes — 2026-08-25

90 minutes against the scratch LUN (`iqn.me.herko.planet-express:iscsi-driver-testing`,
40 GiB, 4096-byte blocks, TrueNAS SCALE/SCST at 192.168.20.1), driven at the
protocol layer through `iscsictl` — no daemon, no FSKit, no filesystem. The
question was whether the new receive-side strictness (sequential DataSN/R2TSN,
contiguous Data-In offsets, GOOD-completion byte accounting, MaxBurst-on-R2T,
renegotiation detection, login echo validation) ever fires against a
conforming target under sustained load, and whether data integrity holds.

## Workload

- Three workers of full login → negotiate → patterned WRITE(16) →
  SYNCHRONIZE CACHE → READ(16) → byte-compare → logout cycles at random LBAs
  in disjoint ranges; sizes 1/2/8/15/16/17/128/256/512 blocks (4 KiB–2 MiB),
  straddling FirstBurstLength (16 blocks) and MaxBurstLength (256 blocks).
  A SendTargets discovery every 20 iterations.
- One `read-bench` worker: 512 MiB sequential reads at queue depth 4, one
  long-lived `ISCSISession` per pass — interleaved concurrent Data-In.

## Results

- 14,244 write/verify cycles (~5.7 GiB written and byte-compared), evenly
  spread across all nine sizes. **Zero mismatches, zero CHECK CONDITIONs.**
- 3,463 bench passes (~1.7 TiB read at QD4). Zero protocol errors.
- 713 discoveries; ~19k logins total. **None of the new strictness ever
  fired** — SCST is conforming, and the checks are silent on a conforming
  peer.
- 281 failures (1.5%), all one class: **connect-phase timeouts** (10 s
  deadline in `NetworkTransport.connect`; a few surfaced as TCP ETIMEDOUT or
  as bench recovery exhausting its bounded attempts). Bursty, 0.6–2.4% per
  10-minute interval, no cumulative growth — consistent with the NAS pausing
  its accept path during ZFS txg commits under sync-heavy load. Every
  affected operation failed cleanly and the next proceeded; no hangs, no
  cascade.

## What the trial runs caught

`iscsictl verify` had guessed blockSize=512 whenever READ CAPACITY was
answered by the fresh-nexus UNIT ATTENTION (which is always), so against this
4Kn LUN every CDB described 8× the data actually carried: block-aligned sizes
degenerated into short I/O with overflow residuals, odd sizes drew CHECK
CONDITION. Fixed the same day (UA absorbed with retry, shared
`ISCSIBlockDevice.geometry` parser, no fallback guess) — earlier verify runs
against 4Kn targets were degenerate and should not be cited.
