# SYMPOSIUM HANDOFF — One-pager for demo day

> Keep this open on your second monitor during the Polytechnique symposium.
> Designed to be scannable in a panic. If something goes sideways, jump to
> "If the demo dies".

## T-24h pre-flight (the day before)

- [ ] `bash slm-forge/scripts/check-quota-status.sh` — G+VT vCPU ≥ 32
- [ ] `bash slm-forge/skills/forge-status/run.sh <demo-forge-id>` — phase=DONE, hf_repo + hf_space populated, cost recorded
- [ ] Open HF Space URL in a clean browser (incognito) — chat returns at least one response
- [ ] Upgrade HF Space hardware to **T4 small** ($0.60/hr) if budget allows. Schedule downgrade after the talk.
- [ ] Test `ollama create <name> -f <Modelfile>` on a laptop that has never seen the model
- [ ] Test LM Studio: search for `Nexless/<forge-model-name>`, confirm it appears + downloads
- [ ] Print this page or keep it on screen

## T-30min warm-up

- [ ] Open HF Space URL. Send a warmup prompt (e.g., "What is a dental crown?"). Confirm it doesn't cold-start mid-talk.
- [ ] Check HF Space runtime is "Running" (not "Sleeping" or "Build error")
- [ ] Pre-load the model in Ollama on the presenter laptop: `ollama run <name>` → type `/bye` to warm the cache
- [ ] Have `slm-forge/skills/forge-status/run.sh <demo-forge-id>` running in a terminal so live cost + phase are visible

## During the talk

Key URLs (have these in a visible tab / notecard):
- Model repo: `https://huggingface.co/Nexless/<forge-model-name>`
- Space demo: `https://huggingface.co/spaces/Nexless/<forge-model-name>-demo`
- Model card (direct): `https://huggingface.co/Nexless/<forge-model-name>/blob/main/README.md`

Commands you might run live:
```bash
# Show the forge in action (fresh run, tiny corpus, ~7 min total)
bash slm-forge/tests/smoke-test.sh --through BOOTSTRAP --then-teardown \
  FORGE_INSTANCE_TYPE_OVERRIDE=t3.xlarge FORGE_BOOTSTRAP_FAST=1

# Show the status of a completed forge
bash slm-forge/skills/forge-status/run.sh <demo-forge-id>

# Show the full manifest
cat ~/.slm-forge/manifests/<demo-forge-id>.json | jq .
```

Talking points (adapt as needed):
- "The forge is a 16-skill tree. No services, no k8s, no Docker Compose — just bash + jq + AWS primitives."
- "Everything is a pure function over `forge.state.json` in S3. If my laptop dies mid-training, I open a new Claude session and type `/slm-forge resume` — the forge picks up where it left off."
- "Cost is explicit at every phase. This model cost $X.XX to forge. [gesture to status readout]"
- "The output is vendor-neutral by design — the model card says nothing about NEXLESS or SIF. It's an Apache-2.0 Apache artifact that works with any llama.cpp-compatible runtime."

## If the demo dies

### HF Space returns 503 / shows "Building" / times out
1. Refresh once. Wait 30 sec.
2. If still broken, fall back to Ollama: open terminal, `ollama run <name>`, type a prompt live.
3. Optional: show the model card URL instead ("the model is here, here are the benchmarks, you can pull it yourself").

### Ollama not responding on presenter laptop
1. `ollama list` — confirm model is pulled
2. `ollama run <name> --verbose` — pipe a simple prompt, watch for error
3. Fall back to LM Studio (should have it pre-loaded)

### Internet drops entirely at the venue
1. LM Studio is fully offline once the GGUF is downloaded. Pre-download before the talk.
2. Have `llama.cpp` with the Q4_K_M GGUF on the laptop — `./llama-cli -m model.gguf -p "<prompt>"` works with no network.

### AWS blows up mid-live-demo (unlikely — nothing should be running during the talk)
1. `bash slm-forge/scripts/retention-sweep.sh` — list active forges
2. For each: `forge-teardown <id> --terminate` from another terminal
3. Don't attempt a live fix; pivot back to the pre-forged Space.

## Post-talk

- [ ] Downgrade HF Space back to CPU Basic (save the $0.60/hr)
- [ ] `bash slm-forge/scripts/retention-sweep.sh --apply` to clean up any smoke-test artifacts
- [ ] Thank-you tweet / post with the HF Space link
- [ ] Add the symposium date + link to the forge's `manifest.notes` for future reference

## Emergency contacts

- AWS support console: https://console.aws.amazon.com/support/home
- HF Hub status: https://status.huggingface.co
- Ollama docs: https://ollama.com/docs

## Don't panic

The forge has been smoke-tested end-to-end. The artifacts are durable
(S3 + HF). Even if a live-run fails, the pre-forged assets are a
perfectly good demo on their own. The talk is about the *skill tree*,
not live training.
