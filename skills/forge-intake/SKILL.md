---
name: forge-intake
description: Collects model requirements (goal, domain, corpus_ref, target_use, license preference, language, constraints) interactively or from an --auto-spec JSON file. Validates against D-005 (300M parameter ceiling for the v1 size class) before letting the run proceed. Entry point for the legacy v1 pipeline; v2 runs use forge-analyze + forge-plan instead.
---

# forge-intake

## When this fires

**Phase position: INTAKE** — entry point for the legacy v1 manifest-driven
flow. Precedes `forge-architect`. Skipped on v2 runs (`forge-analyze`
populates `analysis.json` directly from the input).

## What it does

1. If `manifest.spec` is already populated, exit 0 (already intaken)
2. With `--auto-spec <path>`, read the JSON and validate required keys
3. Without auto-spec, ask the operator interactively for: goal, domain,
   corpus_ref, target_use, license_preference, language, constraints
4. Hard-validate `constraints.max_params <= 300_000_000` (D-005 ceiling)
5. Write `manifest.spec` and advance state to `ARCHITECT`

## Inputs
- `$1` = forge-id (required)
- `--auto-spec <path>` = JSON file with the spec fields (optional)
- stdin (interactive mode when --auto-spec absent)

## Outputs
- `manifest.spec.{goal, domain, corpus_ref, target_use, license_preference, language, constraints}`
- `manifest.state.current_phase = ARCHITECT`

## Idempotency
If `manifest.spec` is non-empty, exits 0 without re-prompting.

## Failure modes

| Exit | Reason |
|---|---|
| 0  | spec populated (success or already-done) |
| 1  | missing required spec field OR `max_params > 300_000_000` (D-005 violation) |
| 64 | no forge-id provided |

## External resources
- stdin (interactive) or filesystem (`--auto-spec` JSON)
- Local manifest only — no AWS / HF / Anthropic calls

## Cost class
**free** — pure local I/O.

## Depends on
None — entry point.
