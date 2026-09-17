# CUGR incremental non-determinism — characterization (2026-07-08)

**Status (2026-07-09): ROOT-CAUSED + FIXED.** The NUM_CORES=1 non-determinism was a
**single-pin-net parallel-array desync in `CUGR::updateNet`** (`gr_nets_` vs
`Design::nets_`). A new, transiently-single-pin buffer net hit the else-branch,
which appended to `Design::nets_` but `getNumPins()<2`-returned without growing
`gr_nets_` → permanent off-by-N desync → later nets stored at the wrong slot → a
reroute overwrites a different net's live `GRNet`, leaving a dangling `GRNet*`
whose *reused* memory read varies run-to-run (ASLR-sensitive, MALLOC_PERTURB_-immune).
Trigger CONFIRMED on jpeg (5 declines / 2 nets via SPDECLINE instrumentation).
An A/B counter (getNumPins()<2 at the dirty-net boundary) shows RSZ leaves
transiently-single-pin nets for BOTH routers — CUGR 5 (_35951_,_35952_),
FastRoute 3 (_35952_) — so it was a CUGR *handling* bug (FastRoute tolerates
single-pin dirty nets; CUGR desynced), NOT CUGR-specific net creation.
**Fix** (3 files under `src/grt/src/cugr/`): exclude single-pin nets from the
netlist in `Design::readNetlist` AND `Design::updateNet`; `Design::updateNet`
returns the admitted index (or -1) so `CUGR::updateNet` keys off it instead of
`getAllNets().back()`; `getITermsAccessPoints`/`getBTermsAccessPoints` made
tolerant (`.find`). **Verified:** the fix makes CUGR ROUTING deterministic — WL/via byte-identical
across all runs (WL 1728581 / via 200444, 1T & 8T). QoR cost (accepted): excluding
12 init single-pin nets reorders routing → WL +1.6%, EnTNS baseline ~−138.6/−141.9.

**CORRECTION / STILL OPEN (separate bug): repair EnTNS is NOT fully deterministic.**
det_test2 gave −138.6 ×8 at NUM_CORES=1 (one batch), but a later same-binary
NUM_CORES=1 run gave −141.9 with *identical* routing; at NUM_CORES>1 EnTNS varies
within a batch (−130.3..−155.0). So the repair-side (resizer/STA) non-determinism
persists — 1T across-batch and MT within-batch — exposed by CUGR's marginal timing.
This is the shared-path effect the old `_sta_mt` doc described (prematurely
dismissed); NOT addressed by the single-pin fix. Separate investigation.

--- original characterization (the reasoning trail; exact line now pinned above) ---

This supersedes `cugr_nondeterminism_sta_mt.md`, whose "multithreaded STA/resizer
FP-order" conclusion is **REFUTED as the NUM_CORES=1 cause** (it is real but MT-only).

## One-line conclusion
`sky130hd/jpeg` with CUGR (`GLOBAL_ROUTE_USE_CUGR=1`) gives a non-deterministic
`repair_timing` result run-to-run. The cause is a **single-threaded,
address/content-dependent computation inside CUGR's incremental reroute.** It is
NOT the resizer/STA/est, NOT multithreading, NOT a heap uninitialized read, NOT
core type / memory / system load. The resizer faithfully amplifies CUGR's
slightly-different parasitics via tie-sensitive TNS moves.

## The decisive control (proves CUGR-specific)
Same binary, same input (`results/sky130hd/jpeg/cugr/4_cts.odb`), same machine,
NUM_CORES=1, only the global router differs:

| Router | Runs | repair_timing EnTNS | Determinism |
|--------|------|---------------------|-------------|
| **FastRoute** (`GLOBAL_ROUTE_USE_CUGR=0`) | 4x baseline + 2x `OMP_NUM_THREADS=1` | **−89.8** every run (removed 1501 / resized 230) | bit-identical, OMP-insensitive |
| **CUGR** (`=1`) | ~20 runs | **−129.9 / −132.2 / −132.8** (~3-pt spread) | non-deterministic, ~1-in-5 flip |

FastRoute uses the exact same resizer/STA/est/repair_timing → that path is
deterministic. Only CUGR wobbles.

## Elimination table (all tested 2026-07-08, sky130hd/jpeg, do-5_1_grt, NUM_CORES=1)
| Hypothesis | Verdict | Evidence |
|---|---|---|
| Ungated thread pool / multithreading | ❌ | `/proc/PID/status` Threads=1 across the entire run (525 samples), incl. all of repair_timing. rsz `ThreadPool(threadCount()-1)=ThreadPool(0)`→inline; GRT `num_threads(1)`; STA `thread_count==1` sequential branches. |
| Resizer / STA / est code | ❌ | FastRoute identical ×6 on the same repair path. 5-agent code audit of rsz/sta/est found no wall-clock/RNG/reduction-order/uninit/FP-env mechanism. |
| Heap uninitialized read | ❌ | `MALLOC_PERTURB_` does not determine the result; two byte-identical invocations (`=1`) gave −132.2 and −132.8. |
| CPU core type (P vs E, i7-14700K hybrid) | ❌ | Pinned P-core == pinned E-core. |
| Memory pressure | ❌ | 32 GB RAM, ~950 MB/process, 6-way ≈ 6 GB. No swap. |
| External system load | ❌ | openroad pinned to a dedicated core: rest-idle == rest-saturated (both −132.8). |
| ASLR *ordering* of odb pointer maps | ❌ | `odb::PtrMap`/`PtrSet` use `ODBPtrLess`→`compare_by_id` (object-ID order, ASLR-immune). `setarch -R` ×3 == baseline. |
| CPU frequency / wall-clock decision | ❌ | repair loop is count-based (`SetupTnsPolicy.cc`: for-endpoint / while-pass). Pinned-idle (fast) and pinned-loaded (slow) both −132.8. |

## What remains (two live sub-hypotheses, both single-threaded + address/content dependent)
- **B1 — pointer VALUE / order used as data.** An address (or hash of one, or a
  pointer-order iteration not covered by odb's id-ordering) feeds a routing
  decision; ASLR varies it run-to-run. valgrind will NOT flag this (a pointer is a
  "defined" value). Fast grep found no obvious `reinterpret_cast`/`uintptr_t`/
  `hash<T*>` in CUGR, so if it's B1 it is subtle.
- **B2 — stack uninitialized read.** A local read before write in the
  incremental-specific path. `MALLOC_PERTURB_` only poisons the heap, not the
  stack; valgrind memcheck WOULD catch this and name the origin.

## Structures already audited and found determinism-safe
- `odb::PtrMap`/`PtrSet` — `compare_by_id` (src/odb/include/odb/PtrSetMap.h:12-24).
- CUGR `db_net_map_` (`unordered_map<dbNet*,GRNet*>`) & `Design::db_net_to_id_` — lookup-only, never iterated.
- MazeRoute `priority_queue<shared_ptr<Solution>>` — ties break by `vertex` (int), not pointer (MazeRoute.cpp:175-178).
- `GRNet` ctor initializes `slack_`/`is_critical_` (GRNet.cpp:23-24) despite no in-class initializer.
- Incremental net mgmt (`addDirtyNet`/`updateNet`/`removeNet`, `nets_to_route_`) — processing order = GlobalRouter's id-ordered dirty set.
- Resizer worker pool — `OptimizationPolicy::makeWorkerThreadPool` = `ThreadPool(0)` at NUM_CORES=1 (OptimizationPolicy.cc:519-526).

## Reproduce
```bash
cd flow
BIN=$PWD/../tools/OpenROAD/build/bin/openroad   # must be the CUGR-enabled build
V=repro
rm -rf results/sky130hd/jpeg/$V && mkdir -p results/sky130hd/jpeg/$V
cp -p results/sky130hd/jpeg/cugr/4_cts.odb results/sky130hd/jpeg/cugr/4_cts.sdc \
      results/sky130hd/jpeg/$V/
make DESIGN_CONFIG=./designs/sky130hd/jpeg/config.mk FLOW_VARIANT=$V \
     GLOBAL_ROUTE_USE_CUGR=1 NUM_CORES=1 OPENROAD_EXE="$BIN" do-5_1_grt
# metric: the `final` row of logs/sky130hd/jpeg/$V/5_1_grt.log repair_timing table.
# EnTNS = 10th |-separated column. Run ~5x; EnTNS scatters -129.9/-132.2/-132.8.
```
Notes: the run ends with a pre-existing `ANT-0008` error (grt-only run has no
detailed routing for the trailing antenna check) — harmless, occurs AFTER the
repair_timing metric is printed. `4_cts.odb`/`4_cts.sdc` are the fixed CTS output
(router-agnostic), valid for both CUGR and FastRoute.

## Recommended next step to pin the exact line
1. **Route-fingerprint bisect (works for B1 & B2, fast runs).** Add throwaway
   instrumentation where CUGR patches rerouted nets — GlobalRouter CUGR branch of
   `updateDirtyRoutes` using `cugr_->getReroutedNets()`, or inside
   `CUGR::route(incremental)` after `iterativeRRR` — to hash each rerouted net's
   `GRoute` and log `net_id -> hash`. Run 2x single-threaded, diff logs, find the
   FIRST divergent net, then inspect that net's reroute path (PatternRoute DAG /
   MazeRoute) for the address/content-dependent decision. (Prior MT-era bisect saw
   divergence at call 250 / net 42840 — redo single-threaded.)
2. **valgrind memcheck --track-origins=yes** on the do-5_1_grt step (via
   `OPENROAD_EXE` pointing at a valgrind wrapper). Definitive for B2 (stack/heap
   uninit USE) and names the origin. Slow (~2-4h). If clean → it's B1.

## Why the old "multithreaded STA/resizer FP-order" theory was wrong
That conclusion assumed NUM_CORES=1 made the process single-threaded and
deterministic. It measured ROUTE hashes (which ARE deterministic) but not repair
QoR. Under matched conditions the resizer/STA path is provably deterministic
(FastRoute ×6 identical), and the process is genuinely single-threaded at
NUM_CORES=1 — so multithreaded FP-order cannot be the cause. The variation source
is inside CUGR's incremental reroute; the resizer only amplifies it.

## Convergence note (separate issue)
CUGR's QoR gap vs FastRoute (~−130 vs −90) is a *convergence/layer-distribution*
problem (see the via-cost lever work), NOT the non-determinism. Poor convergence
merely AMPLIFIES the non-determinism (near-tied timing → resizer flips on tiny
parasitic diffs). Plateaus alone do not cause non-determinism — FastRoute plateaus
too and stays deterministic. Fixing convergence would shrink the spread but not
remove the root variation source.
