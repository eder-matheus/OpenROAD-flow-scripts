# Plan: add `RUN_PLACE_REPAIR_TIMING` env-var guard

## Goal

Wrap the pre-CTS `repair_timing_helper` call in `flow/scripts/resize.tcl`
behind an opt-in environment variable named `RUN_PLACE_REPAIR_TIMING`.
Default behavior: **disabled** (existing pre-CTS repair_timing is *not*
run unless the user sets the variable). Designs that need it must
`export RUN_PLACE_REPAIR_TIMING = 1` in their `config.mk`.

## Why

This guards the placement-stage `repair_timing` call so designs can opt
out (or opt in, depending on default polarity) without editing the
flow script. ORFS already follows the same pattern for related flags
(e.g. `SKIP_CTS_REPAIR_TIMING`, `SWAP_ARITH_OPERATORS`).

## Files to modify

1. **`flow/scripts/resize.tcl`** — add the guard around the
   `repair_timing_helper` call **and** its immediate preceding
   `estimate_parasitics -placement` + `puts "Repair setup and hold violations..."`
   block. The relevant block sits between `repair_design_helper` and the
   `# hold violations are not repaired until after CTS` comment.

2. **`flow/scripts/variables.yaml`** — register the new variable as the
   single source of truth. This is consumed by downstream generators
   (see step 4). Place it near `SKIP_CTS_REPAIR_TIMING` for locality.

3. **`flow/scripts/variables.json`** — regenerate from yaml (do *not*
   hand-edit). This file is consumed by `defaults.py` (which emits
   Makefile `export VAR?=DEFAULT` lines) and `non_stage_variables.py`.

4. **`docs/user/FlowVariables.md`** — regenerate from yaml. Includes
   the variable in the alphabetical table and index.

## How

### 1. Guard pattern in `resize.tcl`

Use **`$::env(VAR)`** (Tcl boolean check), NOT
`env_var_exists_and_non_empty VAR`.

```tcl
if { $::env(RUN_PLACE_REPAIR_TIMING) } {
  # Repair timing using global route parasitics
  puts "Repair setup and hold violations..."
  log_cmd estimate_parasitics -placement

  repair_timing_helper
}
```

**Why this matters (critical to get right):** `flow/scripts/defaults.py`
walks `variables.json` and emits `export KEY?=DEFAULT` for every
variable that declares a `default`. So a variable with `default: 0`
will *always* be present in the environment with value `"0"`. The check
`env_var_exists_and_non_empty` returns true for `"0"` because `"0"` is
a non-empty string — so a guard using that helper would always fire,
defeating the default-off behavior.

The boolean form `$::env(RUN_PLACE_REPAIR_TIMING)` evaluates `"0"` as
false and `"1"` as true, which is what we want. Reference: this is the
same pattern used by `SKIP_CTS_REPAIR_TIMING` in
[flow/scripts/cts.tcl](../scripts/cts.tcl) (search for
`!$::env(SKIP_CTS_REPAIR_TIMING)`).

The contrasting pattern `env_var_exists_and_non_empty` is correct only
for variables that **have no default** in `variables.yaml` (the env
var is then absent until set in a `config.mk`), e.g.
`SWAP_ARITH_OPERATORS`.

### 2. `variables.yaml` entry

```yaml
RUN_PLACE_REPAIR_TIMING:
  description: >
    Run repair_timing during the placement (resize) stage using placement
    parasitics. Disabled by default; pre-CTS setup/hold repair is skipped
    unless this is set to 1.
  stages:
    - place
  default: 0
```

The `default: 0` is intentional — it both documents the default in the
generated docs and ensures the env var is exported so the Tcl
`$::env(...)` lookup doesn't error on an unset key.

### 3 & 4. Regenerate derived files

```sh
python3 flow/scripts/yaml_to_json.py
python3 flow/scripts/generate-variables-docs.py
```

These scripts read `flow/scripts/variables.yaml` and update
`flow/scripts/variables.json` and `docs/user/FlowVariables.md` respectively.
Do **not** hand-edit `variables.json` or `FlowVariables.md`.

`flow/scripts/variables.mk` is *not* a per-variable enumeration and does
not need updating.

## Verification

1. **Tree-wide grep** should find the new variable in exactly these files:
   - `flow/scripts/resize.tcl`
   - `flow/scripts/variables.yaml`
   - `flow/scripts/variables.json`
   - `docs/user/FlowVariables.md`

   ```sh
   grep -rn RUN_PLACE_REPAIR_TIMING flow/scripts docs/user
   ```

2. **Default-off smoke test.** Run a `make place` stage without
   exporting the variable; verify the `3_4_place_resized.log` does NOT
   contain `Repair setup and hold violations...` or
   `repair_timing -repair_tns`.

3. **Opt-in smoke test.** Run `make place RUN_PLACE_REPAIR_TIMING=1`;
   verify the same log DOES contain those lines.

## Common pitfalls (do NOT repeat these)

- Using `env_var_exists_and_non_empty RUN_PLACE_REPAIR_TIMING` with a
  declared `default: 0` — the guard will always fire because
  `defaults.py` auto-exports the env var with value `"0"`, which is a
  non-empty string. This was a real bug observed during initial
  implementation. Use `$::env(RUN_PLACE_REPAIR_TIMING)` instead.

- Hand-editing `variables.json` or `FlowVariables.md` instead of
  regenerating from `variables.yaml`. These files have explicit
  generators (`yaml_to_json.py`, `generate-variables-docs.py`) and the
  yaml is the single source of truth.

- Forgetting that this is **opt-in (default off)**. The original ORFS
  behavior was to *always* run pre-CTS repair_timing; this change
  inverts that default. Designs that previously relied on pre-CTS
  repair_timing will see a behavior change unless they set
  `RUN_PLACE_REPAIR_TIMING=1`.

## Polarity rationale (for the agent)

The original conversation considered both polarities:

- `SKIP_PLACE_REPAIR_TIMING` (opt-out, default keeps existing behavior).
- `RUN_PLACE_REPAIR_TIMING` (opt-in, mirrors `SWAP_ARITH_OPERATORS`
  pattern but inverts the default).

The user chose **opt-in (`RUN_PLACE_REPAIR_TIMING`)**. Implement that
polarity; do not change it without asking.
