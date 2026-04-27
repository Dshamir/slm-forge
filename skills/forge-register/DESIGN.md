# forge-register — DESIGN.md

> **Status:** M5-prep design doc. Implementation lives in `run.sh`
> when M5 unblocks.

## Phase

`REGISTER → TEARDOWN`. The publication step. Produces the three consumer
surfaces per D-010 (HuggingFace model repo + HF Space + Ollama Modelfile)
and a standalone release/README.md for sharing.

## Inputs read from manifest

- `manifest.artifacts.{final_weights_s3, quantized_s3, eval_reports_s3}`
- `manifest.spec.{goal, domain, target_use, license_preference, language}`
- `manifest.plan.{base_model, training_regime, training_framework, chat_template, target_params}`
- `manifest.training_runtime.started_at` → for duration calc
- `manifest.compute_target.instance_type` (historical, for model card)
- `manifest.cost_tracking.cost_to_date_usd` (historical)
- `HF_TOKEN` from env (seeded from `/admin/credentials`)

## Outputs written to manifest

- `manifest.artifacts.hf_repo`   = `https://huggingface.co/Nexless/<forge-model-name>`
- `manifest.artifacts.hf_space`  = `https://huggingface.co/spaces/Nexless/<forge-model-name>-demo`
- `manifest.artifacts.model_card_s3` = `s3://forge/<id>/release/README.md`
- `s3://forge/<id>/release/README.md` — standalone share-this doc
- `s3://forge/<id>/release/model-card.md` — HF-format model card
- `s3://forge/<id>/release/hf-repo-url.txt` — pointer
- `s3://forge/<id>/release/Modelfile` — Ollama Modelfile
- `s3://forge/<id>/release/app.py` — Gradio app for HF Space
- Phase advance: `REGISTER → TEARDOWN`

## forge-model-name generation

From `spec.goal` + `spec.domain`, generate a kebab-case name:
```
{domain-slug}-slm-{target_params_M}m-{YYYYMMDD}
```
Example: `dental-patient-education-slm-200m-20260424`.
User can override via `spec.release_name` (future field).

## Procedure

### Phase 0: preflight (verify HF token scope)

The token we stored in /admin/credentials at M0 is "fineGrained" — specific
scopes chosen at token-generation time. For forge-register we need:
- `repo:write` on model repos
- `repo:create` on model repos  
- `repo:write` on space repos
- `repo:create` on space repos

Test via a no-op API call:
```
curl -sS -H "Authorization: Bearer $HF_TOKEN" \
  https://huggingface.co/api/whoami-v2 | jq '.auth.accessToken.role'
```
If `role` is `write` or `admin`: good. If `read`-only or fineGrained without
the required scopes: fail fast with `recoverable: true, recovery_hint: regenerate token with write+create scopes`.

**Defer-to-real-call check:** even with "write" role, try a dry-run repo
existence check on our target name. If it exists, we'll update; if not,
we'll create. Either path needs the right scope.

### Phase 1: generate release assets locally

All file generation happens locally (on the forge-operator host, not on
EC2). Keeps EC2 idle during what is essentially IO + HTTP work.

1. **Pull** final weights + GGUFs + eval reports from S3 to a temp dir.

2. **Generate model card** (`release/model-card.md`) from
   `templates/model-card.md.tmpl` + manifest values. Vendor-neutral per
   D-018: the final line says "Forged with the SLM-Forge skill tree",
   NOT "NEXLESS" or "SIF" or "MGMO".

3. **Generate release README** (`release/README.md`) from
   `templates/release-readme.md.tmpl`. This is the one-pager Daniel
   shares.

4. **Generate Ollama Modelfile** (`release/Modelfile`) from
   `templates/ollama-modelfile.tmpl` + `plan.chat_template`. The template
   library has one variant per chat template (chatml, llama-3, qwen2,
   phi-3).

5. **Generate Space `app.py`** (`release/app.py`) from
   `templates/space-app.py.tmpl` with `{forge_model_name, system_prompt,
   example_prompts}` interpolated. `system_prompt` derived from
   `spec.goal`; `example_prompts` from domain-specific prompt set (same
   routing table as forge-eval).

6. **Generate Space `requirements.txt`** — static list pinned to the
   versions that work with llama-cpp-python + Gradio 4.

### Phase 2: HF model repo create + upload

Use the `huggingface_hub` Python SDK via `lib/hf.sh` (already in M1).

1. **Create repo.** `hf_create_repo <namespace>/<forge-model-name> model private` (default private; user can toggle after reviewing).

2. **Upload weights + GGUFs + card in one shot.**
   ```
   hf_upload_folder /tmp/release/hf-repo <namespace>/<forge-model-name> "" model
   ```
   Layout of `/tmp/release/hf-repo`:
   ```
   /tmp/release/hf-repo/
     README.md                 # model card
     config.json
     tokenizer.json            # + tokenizer_config.json, special_tokens_map.json
     model.safetensors
     generation_config.json
     LICENSE
     Modelfile                 # Ollama
     gguf/
       model-Q4_K_M.gguf
       model-Q8_0.gguf
     eval/
       domain-bench-report.md
       comparison-vs-baseline.md
       samples.md
   ```

3. **Record** repo URL in manifest.

### Phase 3: HF Space create + upload

1. **Create space.** `hf_create_space <namespace>/<forge-model-name>-demo gradio private`.

2. **Upload `app.py` + `requirements.txt` + README.md.**
   ```
   /tmp/release/hf-space/
     app.py
     requirements.txt
     README.md         # brief pointer to the model card
   ```

3. **Wait for space to build** (polling the Space's `/api/spaces/<ns>/<name>/runtime` endpoint until `stage = RUNNING` or `stage = BUILD_ERROR`, max 10 min).

4. **Record** space URL in manifest.

### Phase 4: Release artifacts to S3

Sync `/tmp/release/` to `s3://forge/<id>/release/` so the user has a
durable local copy independent of HF.

### Phase 5: Exit summary

```
FORGE RELEASED

Model:       https://huggingface.co/Nexless/dental-patient-education-slm-200m-20260424
Browser:     https://huggingface.co/spaces/Nexless/dental-patient-education-slm-200m-20260424-demo
LM Studio:   search "Nexless/dental-patient-education-slm-200m-20260424" in the app
Ollama:      curl https://huggingface.co/.../Modelfile -o Modelfile && ollama create ... -f Modelfile

Duration:    <spec.phase_history total>
Cost:        $<cost_tracking.cost_to_date_usd>
```

Return `{"status":"completed","next_phase":"TEARDOWN","forge_id":"…","hf_repo":"…","hf_space":"…"}`.

## Visibility default: private

Default to **private** repo+space. User flips to public via the HF web UI
after reviewing model card + sample generations. Rationale: vendor-neutral
output policy (D-018) requires a manual review that no internal branding
leaked; auto-public would risk that.

For the symposium demo: Daniel flips to public 1 day before, tests on a
clean browser, confirms the Space works. Manual step, explicitly
documented in the symposium-day checklist.

## Failure modes (return contract)

| Failure | recoverable | recovery_hint |
|---|---|---|
| HF_TOKEN missing or invalid | true | `seed HF_TOKEN in /admin/credentials; verify with huggingface-cli whoami` |
| Token lacks repo:write / repo:create scope | true | `regenerate token at https://huggingface.co/settings/tokens with Write + Create scopes on repos+spaces` |
| Upload interrupted | true | `re-run forge-register; hf upload_folder resumes cleanly` |
| Space build fails (app.py error) | true | `pull Space build logs via HF API; fix template; re-run forge-register --force-space-rebuild` |
| Model repo name collision | true | `append -v2 to name or change spec.release_name` |
| Quota exceeded on HF (free tier limits) | false | `upgrade HF account; no workaround` |

## Idempotency

Check `manifest.artifacts.hf_repo` before starting. If set AND HF repo
still exists AND file count matches expected: short-circuit. Re-running
explicitly requires `--force`.

## Deliberate non-goals (per D-018)

- **No NEXLESS / SIF / MGMO mentions** in model card, README, Modelfile, or Space.
- **No internal ticket IDs or project tags** in any published artifact.
- **No telemetry hooks** phoning home.

The forge is SIF-native infrastructure; the forged artifact is vendor-
neutral. `forge-register` is the enforcement point — all outputs are
grep-tested for forbidden strings before upload.

## Key references

- `slm-forge-brief/skills/SKILL_SPECS.md § forge-register`
- `slm-forge-brief/DEMO_REQUIREMENTS.md` (templates + symposium checklist)
- `slm-forge-brief/DECISIONS.md § D-010` (three-surface triad)
- `slm-forge-brief/DECISIONS.md § D-013` (HF namespace = Nexless)
- `slm-forge-brief/DECISIONS.md § D-018` (no branding in output)
