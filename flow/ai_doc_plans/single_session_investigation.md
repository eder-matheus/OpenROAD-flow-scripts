# Single-Session Flow Investigation

This document captures the full context of an investigation to make OpenROAD's
single-session flow (`floorplan_to_place.tcl` / `single_session.tcl`) produce
byte-identical results to the regular multi-step `make` flow. Feed this entire
document to Claude Code to resume the investigation.

## The Codebase

- Root: `/home/emrmonteiro/openroad/OpenROAD-flow-scripts`
- OpenROAD: `tools/OpenROAD/` (submodule)
- STA: `tools/OpenROAD/src/sta/` (sub-submodule)
- Flow scripts: `flow/scripts/`
- Makefile: `flow/Makefile`

## What We're Doing

The regular ORFS flow runs each stage (floorplan, placement, CTS, routing, etc.)
in a **separate OpenROAD process**. We want a **single-session** mode that runs
all stages in one process, producing identical results.

The single-session script is `flow/scripts/single_session.tcl`. It sets
`KEEP_VARS=1` and sources each stage script in sequence. The Makefile target is
`make single_session SINGLE_SESSION_STAGE=<stage>`.

## Root Causes Found

### 1. Missing `set_dont_use` in floorplan.tcl (FIXED - script change)

**Problem:** `floorplan.tcl` calls `repair_timing_helper` which invokes the
Resizer. The Resizer populates caches (`buffer_cells_`, `target_load_map_`,
`tgt_slews_`, `equiv_cells_made_`, etc.) during this call. These caches are
guarded by "already computed" flags that prevent recomputation.

In the multi-step flow, each stage starts fresh so caches are always computed
from scratch. In the single session, caches from floorplan persist into
`global_place.tcl`. The key issue: `global_place.tcl` calls `set_dont_use`
which changes which cells are available, but `set_dont_use` only clears
`buffer_cells_` — NOT `target_load_map_` or `tgt_slews_`. So those caches
were computed without dont_use filtering in floorplan, but used WITH dont_use
filtering in global_place.

**Fix:** Added `set_dont_use $::env(DONT_USE_CELLS)` to `floorplan.tcl` before
the `repair_timing_helper` / `remove_buffers` block. This ensures the Resizer
caches are populated with the same dont_use configuration from the start.

**File:** `flow/scripts/floorplan.tcl` (lines 143-145)

**Status:** This fix resolves the divergence for asap7/gcd, asap7/aes, and
nangate45/aes. But nangate45/gcd and gf180/aes still diverge.

### 2. Stale DRT frDesign in TritonRoute::main() (FIXED - C++ change)

**Problem:** `global_route.tcl` calls `pin_access` which invokes
`TritonRoute::pinAccess()`. This creates an internal `frDesign` object. Later,
`detail_route.tcl` calls `detailed_route` which invokes `TritonRoute::main()`.
In `main()`, `initDesign()` checks if `design_->getTopBlock() != nullptr` — if
true (single session), it takes an incremental `updateDesign()` path instead of
the full `readTechAndLibs()` + `readDesign()` path. This produces different
results.

**Fix:** Added `clearDesign()` before `initDesign()` in `TritonRoute::main()`.
This matches what `pinAccess()` already does (line 1086). In a fresh process
the design is already empty so this is a no-op.

**File:** `tools/OpenROAD/src/drt/src/TritonRoute.cpp` (line ~1007)

### 3. Remaining Resizer stale state (NEEDS FIX)

**Problem:** For some designs (nangate45/gcd, gf180/aes), the `set_dont_use`
fix alone is insufficient. The Resizer has additional cached state that persists
between stages:
- `target_load_map_` — guarded by null check, computed once
- `tgt_slews_` / `tgt_slew_corner_` — set during `findBufferTargetSlews()`
- `equiv_cells_made_` — bool flag preventing recomputation
- `buffer_fast_sizes_`, `cell_leakage_cache_`, `level_drvr_vertices_valid_`

These are all derived from liberty data (which doesn't change) but are
computed in a context that may differ between stages (different SDC, different
parasitics, different design state).

**Proposed fix (implemented but reverted for testing):** Add a
`postNetworkChange()` callback to `dbNetworkObserver` that the Resizer
implements to clear all caches. This gets triggered automatically when
`network_changed_non_sdc` is called.

The implementation involved:
- `dbNetwork.hh`: Add `virtual void postNetworkChange() {}` to observer
- `dbNetwork.hh`: Add `void notifyNetworkChange()` method
- `dbNetwork.cc`: Implement `notifyNetworkChange()` iterating observers
- `dbSta.hh`: Override `networkChangedNonSdc()` (requires making it virtual in STA)
- `Resizer.hh`: Override `postNetworkChange()`
- `Resizer.cc`: Implement `postNetworkChange()` clearing all caches

Alternative without STA changes: Add SWIG function
`network_changed_non_sdc_with_observers()` in `dbSta.i` that calls both
`Sta::sta()->networkChangedNonSdc()` and `getDbNetwork()->notifyNetworkChange()`.

Plus `load.tcl` changes to call the reset when `load_design` re-enters:
```tcl
if { $sdc_path ne "" && [file exists $sdc_path] } {
  sta::network_changed_non_sdc_with_observers  ;# or network_changed_non_sdc
  log_cmd read_sdc $sdc_path
  source_rc
}
```

**Status:** This was fully implemented and tested — it fixes ALL designs
including nangate45/gcd and gf180/aes. It was reverted to test whether
`set_dont_use` alone was sufficient (it wasn't for all designs).

### 4. ODB table serialization differences (NOT OUR FIX)

**Problem:** Even when design content is identical, the ODB binary files can
differ due to internal table layout (free lists, page allocation, unique name
counters). This causes `5_1_grt.odb` to always DIFFER in bytes even though
`5_2_route.odb` and `5_3_fillcell.odb` match perfectly.

**Status:** The user has a pending PR that fixes ODB table serialization to be
deterministic regardless of allocation history. Not part of this investigation.

## Current State of Changes

### Applied and kept:
- `flow/scripts/floorplan.tcl`: `set_dont_use` added (lines 143-145)
- `tools/OpenROAD/src/drt/src/TritonRoute.cpp`: `clearDesign()` in `main()`
- `flow/scripts/single_session.tcl`: New script for single-session flow
- `flow/Makefile`: New `single_session` target

### Previously implemented, tested working, currently reverted:
These changes together fixed ALL designs but were reverted during testing:

**dbSta (OpenROAD):**
- `dbNetwork.hh`: `postNetworkChange()` observer callback + `notifyNetworkChange()`
- `dbNetwork.cc`: `notifyNetworkChange()` implementation
- `dbSta.i`: `network_changed_non_sdc_with_observers()` SWIG function
  (alternative to making `networkChangedNonSdc` virtual in STA)

**RSZ (OpenROAD):**
- `Resizer.hh`: `postNetworkChange() override`
- `Resizer.cc`: `postNetworkChange()` clearing all caches:
  ```cpp
  void Resizer::postNetworkChange()
  {
    equiv_cells_made_ = false;
    target_load_map_.reset();
    buffer_cells_.clear();
    buffer_lowest_drive_ = nullptr;
    buffer_fast_sizes_.clear();
    tgt_slews_ = {0, 0};
    tgt_slew_corner_ = nullptr;
    swappable_cells_cache_.clear();
    cell_leakage_cache_.clear();
    level_drvr_vertices_valid_ = false;
  }
  ```
- `Resizer.cc`: `bufferInputs`/`bufferOutputs` sort ports by `PinPathNameLess`
- `Resizer.cc`: Port-name-based buffer base names (`"input_<port>"`)
- `Resizer.cc`: `resizeWorstSlackNets` breaks slack ties by net name

**EST (OpenROAD):**
- `EstimateParasitics.cpp`: Guard in `updateParasitics()` returning early when
  `sta_->graph() == nullptr`

**load.tcl:**
- `source_rc` helper proc (extracted from duplicated block)
- Single-session re-entry: `network_changed_non_sdc_with_observers` + re-read
  SDC + re-source setRC

### Other changes explored but NOT needed:
- `VertexIdLess` in STA `Graph.cc` — changed to use `pathNameLess` or
  `network->id()` instead of `graph->id()`. NOT the root cause and has
  performance concerns (string allocation on every std::set comparison).
  Reverted.
- Making `networkChangedNonSdc` virtual in STA — needed only if using the
  `dbSta` override approach. Can be avoided with the SWIG alternative.

## Test Results Matrix

With set_dont_use + clearDesign only:
| Design | Through place | Through CTS | Through GRT | Through DRT |
|---|---|---|---|---|
| asap7/gcd | MATCH | MATCH | DIFFER* | MATCH |
| asap7/aes | MATCH | MATCH | DIFFER* | MATCH |
| nangate45/aes | MATCH | MATCH | MATCH | MATCH |
| nangate45/gcd | DIFFER | DIFFER | DIFFER | DIFFER |
| gf180/aes | MATCH | DIFFER | DIFFER | DIFFER |

*5_1_grt DIFFER is cosmetic ODB table layout, DRT reconverges.

With full fix (set_dont_use + clearDesign + postNetworkChange + load.tcl reset):
| Design | All stages |
|---|---|
| asap7/gcd | MATCH (5_1_grt cosmetic) |
| asap7/aes | MATCH (5_1_grt cosmetic) |
| nangate45/aes | MATCH |
| nangate45/tinyRocket | MATCH (5_1_grt cosmetic) |
| gf180/riscv32i | MATCH |

## How to Verify

```bash
# Run both flows
make DESIGN_CONFIG=designs/<pdk>/<design>/config.mk FLOW_VARIANT=base <stage>
make DESIGN_CONFIG=designs/<pdk>/<design>/config.mk single_session SINGLE_SESSION_STAGE=<stage> FLOW_VARIANT=single_session

# Compare ODB files
for f in 3_3_place_gp 3_4_place_resized 3_5_place_dp 4_1_cts 5_1_grt 5_2_route 5_3_fillcell; do
  base="results/<pdk>/<design>/base/${f}.odb"
  ss="results/<pdk>/<design>/single_session/${f}.odb"
  b=$(sha1sum "$base" | cut -c1-40)
  s=$(sha1sum "$ss" | cut -c1-40)
  echo "$f: $([ "$b" = "$s" ] && echo MATCH || echo DIFFER)"
done
```

## Next Steps

1. Re-implement the `postNetworkChange` approach (or equivalent) to fix
   nangate45/gcd and gf180/aes
2. Decide whether to make `networkChangedNonSdc` virtual in STA or use the
   SWIG-only approach
3. Wait for ODB table serialization PR to fix the `5_1_grt.odb` cosmetic
   differences
4. Test on more designs/PDKs
