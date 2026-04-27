---
name: forge-publish
description: Final publishing step — flips both the HF model repo and HF Space from private to public via the HF API. Runs ONLY after forge-card-validator and forge-smoketest have passed. Verifies the flip succeeded by re-reading each repo's settings.
---

# forge-publish

## When this fires

**Phase position: PUBLISH** — between SMOKETEST and TEARDOWN. Fires only if both CARD_VALIDATOR and SMOKETEST returned PASS. This is the public visibility switch.

## What it does

1. Reads `state.json` or v1 manifest to resolve `hf_repo` + `hf_space`
2. Strips URLs to `<namespace>/<name>` form
3. Calls `PUT https://huggingface.co/api/{models,spaces}/<id>/settings` with `{"private": false}` for both
4. Verifies by re-reading each repo's API record — `.private` must be `false`
5. Emits `publish-report.json`

## Inputs
- Reads `slm-forge/.runs/<run-id>/state.json` (v2 path) or v1 manifest
- Needs `HF_TOKEN` from `/tmp/forge-creds.env`

## Outputs
- Writes `slm-forge/.runs/<run-id>/publish-report.json`:
  ```json
  {"status":"pass","hf_repo_public":"https://...","hf_space_public":"https://...","flipped_at":"..."}
  ```
- On fail (API rejected OR repo still private after flip): exit 1, dispatcher writes `failure-report.md`

## Failure modes

| Failure | Cause | Recovery |
|---|---|---|
| Token lacks `repo:write` scope | HF token was fineGrained without public-flip | Rotate token, re-run PUBLISH manually |
| One of the two flipped but not the other | API rate limit or partial failure | Re-run PUBLISH (idempotent) |

## Usage
```bash
bash slm-forge/skills/forge-publish/run.sh <run-id>
```
