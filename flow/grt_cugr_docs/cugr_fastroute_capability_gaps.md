# CUGR vs FastRoute — Capability Discrepancies

The CUGR global router (`grt::CUGR`, `tools/OpenROAD/src/grt/src/cugr/`) is an opt-in
alternative to FastRoute, selected with `-use_cugr` (ORFS: `GLOBAL_ROUTE_USE_CUGR=1`).
The incremental-routing effort brought CUGR to parity on the core routing and
incremental-restore flow. This document lists the *remaining* capability gaps, found by
auditing every `use_cugr_` branch in `src/grt/src/GlobalRouter.cpp` and the FastRoute-only
APIs the CUGR path cannot reach. Line numbers are indicative and may drift.

## At parity (no gap)

- **Full global route** — `globalRoute` → `initCUGR` / `cugr_->route` (GlobalRouter.cpp:492).
- **Incremental routing** — `updateDirtyRoutes` dispatches to `updateDirtyRoutesCugr`
  (GlobalRouter.cpp:6555); restore-from-guides, NDR costs, and demand-verify all present.
- **Timing-repair callback** — the resizer drives `startIncremental` / `endIncremental` →
  `updateDirtyRoutes`, which routes through the CUGR path.
- **Diode antenna repair** — the diode flow in `repairAntennas` is engine-agnostic
  (operates on `routes_`).
- **Net merge (`mergeNets`)** — CUGR-aware: `cugr_->hasAvailableResources`,
  `cugr_->mergeNet`, `cugr_->getNdrCosts` (GlobalRouter.cpp:5725-5820).
- **Layer + global capacity adjustments** — `set_global_routing_layer_adjustment` and the
  global `-adjustment` reach CUGR. `computeUserLayerAdjustments` stamps per-layer values
  that `GridGraph` reads via `design->getLayer(i).getAdjustment()` (GridGraph.cpp:279).

## Discrepancies

| # | Capability | CUGR status | Mechanism / location |
|---|------------|-------------|----------------------|
| 1 | Antenna repair — jumper insertion | Missing (diodes only) | `jumperInsertion` needs FastRoute edge resources; guarded by **GRT-310** (GlobalRouter.cpp:619) and the in-loop `!use_cugr_` gate (:720) |
| 2 | Antenna repair from detailed routes | Missing | rebuild-from-detailed-routes is FastRoute-only (`initFastRoute` + `updateNetResources`); CUGR early-outs with **GRT-311** (:632) |
| 3 | Region adjustments (`add_global_routing_region_adjustment`) | Silently ignored | `computeRegionAdjustments` only calls `fastroute_->addAdjustment`/`getEdgeCapacity` (:2143); CUGR's `GridGraph` reads layer adjustments but not region ones |
| 4 | Capacity knobs (infinite capacity, perturbation, `setCapacities`) | Silently ignored | `setCapacities` / `infinite_capacity_` operate on FastRoute edges only (:926-987); CUGR builds its own grid |
| 5 | Congestion report / RUDY / GUI heatmap | Partial | `reportCongestion` and `getCapacityReductionData` are FastRoute-only (:6099, :1916 → `Rudy.cpp:104`); CUGR prints its own summary (GRT-0130) but the heatmap/RUDY data is not populated from CUGR |

### 1. Jumper insertion
FastRoute inserts jumpers before falling back to diodes; CUGR skips straight to diodes.
`jumperInsertion` relies on FastRoute edge resources (`hasAvailableResources` /
`getEdgeCapacity`), which CUGR does not populate. Impact: designs needing jumper-based
antenna fixes get diode-only repair with CUGR (more diode area, possibly residual
violations).

### 2. Antenna repair from detailed routes
Rebuilding router state from existing detailed routes (`!initialized_ ||
haveDetailedRoutes()`) is FastRoute-only. Impact: `repair_antennas` after DRT, or in a
fresh session with only detailed routes, is unavailable with CUGR — it requires global
routes from the current session.

### 3. Region adjustments
Region-based capacity derating is applied only to FastRoute edges. CUGR ignores it, with
no warning. This is a silent-correctness gap and the cheapest to close: apply the derate
to `GridGraph` capacity the same way layer adjustments already are (GridGraph.cpp:279).

### 4. Capacity manipulation knobs
`set_global_routing_capacities`, infinite capacity, and capacity perturbation have no
effect under CUGR (silently ignored).

### 5. Congestion reporting / visualization
`reportResources` is at parity (both engines). The detailed per-layer `reportCongestion`
and the `getCapacityReductionData` feed for RUDY / the GUI congestion heatmap are
FastRoute-only, so congestion visualization and the detailed report differ (or are
stale/empty) under CUGR.

## Minor (both engines, not a CUGR-vs-FastRoute gap)
`Total congestion` is `(int) total_overflow` (CUGR.cpp:1238), so sub-1.0 overflow prints
as 0 while `Min resource` shows the exact negative value — the source of the
"negative min resource with 0 congestion" observation.

## Needs verification (not confirmed)
`read_guides` / `read_segments` load `routes_` without initializing the CUGR grid; a
CUGR-based parasitics/incremental flow driven from externally read guides is untested.

## Suggested remediation order (if closing gaps)
1. **Region adjustments (#3)** — apply the derate to `GridGraph`; smallest change, removes
   a silent correctness gap.
2. **Silent-ignore warnings (#3/#4)** — warn when region adjustments / capacity knobs are
   set under `-use_cugr` so users are not surprised.
3. **RUDY / heatmap data (#5)** — implement `getCapacityReductionData` from `GridGraph`.
4. **Jumper insertion (#1)** — add a CUGR-backed edge-resource query path for
   `jumperInsertion` (extends the resource API already used by `mergeNets`).
5. **Antenna repair from detailed routes (#2)** — rebuild CUGR grid usage from detailed
   routes, analogous to the FastRoute `updateNetResources` repopulation.
