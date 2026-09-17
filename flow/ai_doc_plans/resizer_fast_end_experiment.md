# Diagnosing the fast-end resizer gap

## Context

`dont_use_x1` (resizer library with x1 cells removed) outperforms the default
ORFS configuration at the fast end of the delay distribution:

- Q1 (fastest 40 variants by base) Spearman ρ: 0.10 → 0.14
- Top-10 fastest in base → median rank in ORFS: 80 → 15

Both configurations had `RUN_PLACE_REPAIR_TIMING=1` enabled, so the
difference is purely the cell library exposed to the resizer.

This suggests the resizer's gate-sizing policy is leaving delay on the table
on critical paths when x1 cells are available — the placement is keeping
(or downsizing back to) x1 where xN would be strictly better for delay at
acceptable area cost.

Two phases of the resizer (`flow/scripts/resize.tcl`) can produce this:

1. **`repair_design_helper`** — sizes for `max_cap` / `max_slew` / `max_fanout`.
   Conservative: upsizes until the violation clears, not to the size that
   minimizes delay.
2. **`repair_timing_helper`** — `SizeUpMove` walks the library one cell at
   a time toward stronger sizes and stops when slack is met. A cell that
   hits slack=0 at x2 stays at x2 even when x4 would yield +Δslack with
   negligible area delta.

## Experiment

Run two additional variants and compare Q1 ρ + top-10 fastest median rank
against `dont_use_x1`:

| Variant | Config                                      | Diagnoses                |
| ------- | ------------------------------------------- | ------------------------ |
| (a)     | x1 allowed; `EARLY_SIZING_CAP_RATIO=0.5..0.9` sweep | `repair_design` policy |
| (b)     | x1 allowed; extra post-`repair_timing` pass restricted to `SizeUpMove`     | `repair_timing` policy |

`EARLY_SIZING_CAP_RATIO` is already plumbed through `resize.tcl:14-16`
via `set_opt_config -set_early_sizing_cap_ratio`.

## Decision matrix

- If **(a) ≈ dont_use_x1** at the fast end → the gap is in `repair_design`'s
  starting sizing. Push there.
- If **(b) closes the gap** → the gap is in `repair_timing`'s `SizeUpMove`
  walk stopping at first feasible size.
- If **neither** closes the gap → the issue is upstream of the resizer
  (synthesis topology), and no resizer tuning will recover it.

## Upstream fix targets

Source lives in `tools/OpenROAD/src/rsz/`.

- **`SizeUpMove`**: sample multiple sizes on the stage curve and pick
  min-delay, not first-passing.
- **`repair_design`**: optional `-min_delay_sizing` mode on critical paths,
  size for min delay rather than just feasibility.
- `SLEW_MARGIN` is an existing indirect lever — tighter slew targets push
  `repair_design` toward stronger drivers on critical nets.

## Suggested upstream issue framing

> Removing x1 from `DONT_USE_CELLS` improves fast-end Spearman ρ vs Genus
> reference from 0.10 → 0.14 and moves top-10 fastest median rank from
> 80 → 15. This suggests resizer size-up policy is suboptimal on critical
> paths when small cells are available. Diagnostic experiments (a)/(b)
> above isolate whether `repair_design` or `repair_timing` is responsible.
