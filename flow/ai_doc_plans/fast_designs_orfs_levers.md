# ORFS levers for fast-design results vs Genus reference

Background: comparing ORFS results against a Genus reference (`base_results.csv`)
on 202 `add_f32_*` variants. Overall Spearman ρ on delay is reasonable, but
the **fast tail** of the distribution decorrelates: variants Genus says are
fastest get scattered across the ORFS ranking. The question driving this
discussion: what in ORFS can be tuned to better track the fast end?

## 1. Cell library restrictions (`DONT_USE_CELLS`)

**Initial suggestion.** Don't blanket-ban x1 cells. The resizer relies on
small cells to trade area on non-critical paths; removing them constrains
optimization elsewhere.

**User's point.** Empirically the opposite holds: `dont_use_x1` has the
**best** fast-end behavior of all runs in `csvs/`. The `repair_timing.csv`
run (x1 allowed) has worse global ρ and a far worse top-10 median rank
(80 vs 15 for dont_use_x1). Both runs had `RUN_PLACE_REPAIR_TIMING=1`,
so the only difference is the x1 ban — pointing at a resizer policy gap
when x1 is available.

**Resolution.** Suggestion withdrawn. The data points to a real resizer
issue: when x1 cells exist, the size-up walk in `repair_timing` and the
conservative behavior of `repair_design` leave delay on the table on
critical paths. See `resizer_fast_end_experiment.md` for the follow-up
diagnostic plan.

## 2. `RUN_PLACE_REPAIR_TIMING=1`

**Initial suggestion.** Enable pre-CTS setup repair using placement
parasitics so ORFS doesn't concede the fast tail by skipping
timing-driven optimization at placement.

**User's point.** Already enabled in every `csvs/` run, including
`dont_use_x1.csv`.

**Resolution.** Not a lever to flip — it's already on. Acknowledged my
earlier framing of "RUN_PLACE_REPAIR_TIMING hurts the fast tail" was
based on a mis-read of which runs had what enabled; the fast-tail
benefit of `dont_use_x1` over `repair_timing.csv` is attributable to
the x1 ban, not to repair_timing itself.

## 3. `SWAP_ARITH_OPERATORS` / wrapped arithmetic

**Initial suggestion.** For arithmetic-heavy designs like `add_f32_*`,
try `SWAP_ARITH_OPERATORS=1` and `SYNTH_WRAPPED_ADDERS` so the synthesis
flow explores adder/multiplier architectures.

**User's point.** Already tried (`hier_swap.csv`) with:
```
export SWAP_ARITH_OPERATORS = 1
export OPENROAD_HIERARCHICAL = 1
```
Ranking was worse than `dont_use_x1`, and **absolute delay was bad**.

**Resolution.** `SWAP_ARITH_OPERATORS` swaps to a single alternative
topology; if Genus is already picking the best topology per variant,
forcing one canonical alternative will lose on average. A better fit
is **`SYNTH_WRAPPED_OPERATORS=1`** — keeps multiple architectures alive
so downstream stages can pick rather than committing upfront.

## 4. Match SDC clock period

**Initial suggestion.** Ensure ORFS's target clock matches Genus's,
otherwise `repair_timing` exits early and absolute delays will diverge
even if rankings hold.

**User's point.** Both flows target 500 ps. Previously tried tightening
to 300 ps — not useful.

**Resolution.** Not a lever here. The fast-tail issue persists at the
matched target, so the gap isn't a "ORFS quit too early because the
clock was easy" problem.

## 5. `repair_timing` aggressiveness defaults

**Initial suggestion.** Push harder: negative `SETUP_SLACK_MARGIN`,
custom `SETUP_MOVE_SEQUENCE`, max `TNS_END_PERCENT`.

**User's point.** Defaults untouched — please review what's actually
running today.

**Resolution.** Defaults as observed in `flow/scripts/variables.yaml`
and platform configs:

| variable             | default | already aggressive? |
| -------------------- | ------- | ------------------- |
| `TNS_END_PERCENT`    | `100`   | yes — every endpoint, not just WNS |
| `SETUP_SLACK_MARGIN` | `0`     | no — untouched lever |
| `SETUP_MOVE_SEQUENCE`| unset → OR default `UnbufferMove,SizeUpMove,SwapPinsMove,BufferMove,CloneMove,SplitLoadMove` | no — starts with `UnbufferMove` |
| `PLACE_DENSITY`      | `nangate45=0.30`, `ihp-sg13g2=0.65` | platform-dependent |

Untouched levers worth trying:

- **`SETUP_SLACK_MARGIN=-50`** (or more negative): tells `repair_timing`
  to overfix past slack=0. Directly targets the fast tail because that's
  where there's actually slack room to keep pushing.
- **`SETUP_MOVE_SEQUENCE="SizeUpMove,SwapPinsMove,CloneMove,SplitLoadMove,BufferMove"`**:
  drop `UnbufferMove`. For fast designs the synthesis buffers are
  probably load-driven, not garbage to remove.

## 6. `PLACE_DENSITY`

**Initial suggestion.** Loosen `PLACE_DENSITY` so the resizer has slots
to upsize critical-path cells without legalization fighting back.

**User's point.** Concern: lower density → cells spread out → longer wires →
worse timing.

**Resolution.** The placer's **wirelength objective dominates**; density
is mostly a *legalization-headroom* parameter, not a *spacing* parameter.
Cells with strong nets still cluster — density just decides whether the
legalizer has slots to upsize/buffer or has to displace cells. The
spreading effect kicks in only at very low density (~0.2) on already-sparse
designs.

Practical implication:

- `nangate45` (default 0.30) — nothing to loosen further usefully.
- `ihp-sg13g2` (default 0.65) — room to try 0.55 if the fast tail is
  resize-limited.

## Bigger-picture conclusion

All four ORFS variants tested produce Q1 (fast end) ρ in the 0.10–0.14
range. That ceiling isn't a P&R problem — it's a **synthesis problem**.
Genus picks per-variant netlist topology informed by physical estimates;
Yosys+ABC map everything to a near-homogeneous netlist family, so the
variants don't differentiate at the fast tail by construction. The two
levers that can actually move that ceiling:

1. **`SYNTH_WRAPPED_OPERATORS=1`** (keep multiple architectures alive,
   pick post-synth).
2. **Per-variant ABC script tuning** (`&dch -f; &if -K 4 -W 250` style),
   or running multiple synthesis recipes and keeping the best — closer
   to what Genus is doing internally.

The lowest-effort next step that stays inside the resizer scope (and
exploits the fast-end insight from the `dont_use_x1` data): take the
`dont_use_x1` config and add `SETUP_SLACK_MARGIN=-50` and a
`SETUP_MOVE_SEQUENCE` that drops `UnbufferMove`. If fast-end ρ moves
from 0.14 toward 0.3+, you've found the lever. If not, the bottleneck
is locked in at synth and the fix has to go upstream.
