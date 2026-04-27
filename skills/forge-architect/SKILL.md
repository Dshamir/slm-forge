---
name: forge-architect
description: Selects base model + training regime + tokenizer strategy + chat template from config/whitelist.json by filtering on license preference and parameter ceiling. Writes manifest.plan with rationale. Bridges from v2 plan.json when invoked under the v2-bridged dispatch path.
---

# forge-architect

## When this fires

**Phase position: ARCHITECT** — after `forge-intake`, before `forge-estimate`.
On v2-bridged runs, reads `plan.json` (already produced by `forge-plan`)
and copies the architectural fields into the legacy manifest.

## What it does

1. Load `config/whitelist.json` (the whitelisted base models)
2. Filter by `manifest.spec.license_preference` and the v1 size ceiling
3. Score remaining candidates by domain fit + tokenizer coverage + size
4. Pick the best base model + regime (lora-sft / qlora-sft / full-sft)
5. Pick the chat template + tokenizer strategy that go with that base
6. Write `manifest.plan.*` with a `rationale` string + `selected_at`
7. Advance state to `ESTIMATE`

## Inputs
- `$1` = forge-id (legacy) or `v2-<run-id>` (v2 bridge)
- `manifest.spec` (license_preference, language, constraints)
- `config/whitelist.json` (base model whitelist)
- `plan.json` if the run was bridged from v2 (overrides whitelist scoring)

## Outputs
- `manifest.plan.{base_model, regime, target_params, framework, chat_template, tokenizer_strategy, rationale, selected_at}`
- `manifest.state.current_phase = ESTIMATE`

## Idempotency
If `manifest.plan` is already populated, exits 0 (no-op).

## Failure modes

| Exit | Reason |
|---|---|
| 0  | plan written or already-set |
| 1  | `spec.license_preference` incompatible with every whitelisted model |
| 64 | no forge-id provided |

## External resources
- Local disk only — reads `config/whitelist.json`, writes manifest

## Cost class
**free** — deterministic config selection, no API calls.

## Depends on
- `forge-intake` (populated `manifest.spec`)
- `forge-plan` (when v2-bridged — supplies plan.json)
