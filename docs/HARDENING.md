# HARDENING — M6 Failure Injection Test Plan

> **Status:** M6-prep. Execution waits until M4 + M5 smoke pass (full
> pipeline needs to be functional before we can inject faults into it).

## Why

Per BUILD_ORDER.md § Milestone 6: "The forge survives the symposium demo
and real-world use." The way to prove that is deliberate breakage. Each
failure class below has (a) a way to inject it, (b) the expected recovery
behavior, (c) an assertion we verify.

## Coverage matrix

| Fault class | Phase affected | Injection method | Expected behavior | Assertion |
|---|---|---|---|---|
| **Network blip** | SOURCE / BOOTSTRAP / forge-register upload | `sudo iptables -A OUTPUT -p tcp --dport 443 -j DROP` on the instance for 30 s | retry with backoff (3 attempts), then recoverable-fail with hint | manifest.errors has one entry with `recoverable=true`, next forge-* invocation succeeds after unblock |
| **AWS quota exhausted** | PROVISION | already tested at M3 (D-011a) | recoverable-fail, surface to user, no partial state written | manifest.compute_target is null, no EC2 to clean up |
| **SSM drop** | BOOTSTRAP / TRAIN / MONITOR | `sudo systemctl stop amazon-ssm-agent` on instance for 5 min | compute_aws_exec retries, times out, forge-monitor flags as failed recoverable | errors entry, forge-resume restores via re-SSM-restart path |
| **OOM on first batch** | TRAIN | set batch_size=256 in training config (deliberately too big for g5.xlarge) | train.py exits rc=10; forge-train 30-sec health probe catches it | manifest.errors with recoverable=true + "OOM, reduce batch" hint |
| **OOM mid-training** | MONITOR | same as above but at larger batch, or inject via `stress-ng --vm-bytes 24G` | train.py exits; forge-monitor detects dead PID + log Traceback | recoverable=true, forge-resume from last checkpoint |
| **Disk full (EBS)** | BOOTSTRAP / TRAIN | `dd if=/dev/zero of=/workspace/hog bs=1M count=200000` to fill EBS | pip install or checkpoint save fails with ENOSPC | recoverable=true, hint to forge-provision with larger ebs_gb |
| **Spot interruption** | TRAIN / MONITOR | deliberately launch as spot then send `aws ec2 send-spot-instance-interruption` (or simulate via stop-instances) | forge-monitor detects terminated PID + instance, returns failed recoverable | forge-resume re-provisions + restores checkpoint |
| **Instance terminated mid-training** (manual kill) | TRAIN / MONITOR | `aws ec2 terminate-instances` from another shell | forge-monitor sees missing instance next poll | forge-resume re-provisions, re-bootstraps, restores latest checkpoint |
| **Checkpoint write corrupt** | MONITOR / RESUME | write a truncated safetensors file in place of the real one, then trigger resume | forge-resume's integrity check catches; tries prior checkpoint | warning in notes, training resumes from checkpoint-1 |
| **HF rate-limit on upload** | REGISTER | simulate 429 with mitmproxy or synthetic throttle | retry with exponential backoff | no manifest corruption, final upload succeeds |
| **HF token expired / rotated mid-forge** | REGISTER | revoke token at HF while forge-register is running | forge-register fails with explicit "token invalid" hint | manifest.errors + recoverable=true, resume after token refresh |
| **Space build fails** (bad app.py) | REGISTER phase-3 | inject a syntax error into the template | forge-register pulls Space build logs, surfaces error | manifest has space_url but marked build_error=true; user fixes, re-runs |
| **Manifest version conflict** (optimistic concurrency) | any | two `manifest_patch` calls in parallel from two sessions | manifest_patch retries 3×, then fails with version-mismatch | forge operator told to pick one session to own; second aborts |
| **Stale local mirror** | any read | touch `$FORGE_WORK/manifests/<id>.json` older than S3 version | manifest_load always fetches fresh from S3 | no stale reads |
| **Budget cap breached mid-forge** | any cost-incurring phase | manually lower `spec.constraints.budget_cap_usd` below current `cost_to_date_usd` | next cost-gate check halts with explicit message | no further spend until user raises cap or aborts |

## Idempotency sweep

Separate exercise, not a fault: re-run every completed phase on a DONE
manifest; verify zero new S3 writes and no manifest mutations.

```bash
# For each phase skill in order:
for skill in forge-intake forge-architect forge-estimate forge-source \
             forge-curate forge-shape forge-provision forge-bootstrap \
             forge-train forge-monitor forge-eval forge-quantize \
             forge-register forge-teardown; do
  result=$(bash slm-forge/skills/$skill/run.sh "$FORGE_ID_DONE")
  # Assert: result.status=completed AND result.idempotent=true
  echo "$result" | jq -e '.status == "completed" and (.idempotent // false)'
done
```

Expected: every skill returns `idempotent: true`. Zero new S3 objects
created, zero mutations to manifest.

## Session-loss + resume sweep

Exercises forge-resume's 4-state matrix:

1. **State A (alive + SSM)**: start a forge, wait for TRAIN phase, kill
   Claude CLI, open new session, run `/slm-forge resume <id>` →
   assert forge-resume skips re-provision, re-attaches, training PID
   still alive, monitor resumes.

2. **State B (stopped + EBS intact)**: `forge-teardown --stop` during
   TRAIN, wait 5 min, run resume → assert `ec2 start-instances` fires,
   EBS remounts, training restarts from last checkpoint.

3. **State C (terminated + no snapshot)**: kill instance via `ec2
   terminate-instances`, run resume → assert new instance provisioned,
   new bootstrap runs, checkpoint restored from S3, training resumes
   from last synced step.

4. **State D (snapshot present)**: taking the snapshot path is deferred
   to M6+ (the EBS snapshot-before-terminate flag isn't wired yet —
   flagged as a deferral in M3's CHANGELOG).

## Budget gate sweep

Set `spec.constraints.budget_cap_usd = 0.50` on a forge. Advance through
PROVISION → BOOTSTRAP (projected cost > cap). Assert:
- forge-provision's cost-gate refuses to launch
- manifest.errors has entry
- no EC2 launched
- user raises cap → re-run succeeds

## End-to-end symposium rehearsal

Single-run smoke covering the full path a symposium attendee would see:

```bash
# Fresh Claude CLI session
/slm-forge

# Answer intake:
# goal: "make a tiny dental Q&A model for the talk demo"
# domain: "dental.patient-education"
# corpus_ref: "local:/path/to/docs.jsonl"
# target_use: "local-laptop"
# target_latency_ms: 300
# target_quality: "usable for demo"
# license: apache-2.0
# language: en
# max_params: 100000000
# budget_cap: 5
# max_wall: 1

# Approve at BUDGET_GATE

# (walk away; training runs ~20 min)

# Deliberately kill the Claude CLI mid-training

# Re-open Claude CLI:
/slm-forge

# Master detects current-forge pointer, asks to resume
# Answer yes
# forge-resume re-attaches (state A), monitor continues

# Training completes, EVAL runs
# QUALITY_GATE: review sample generations, approve

# QUANTIZE runs
# REGISTER creates HF repo + Space + Modelfile
# TEARDOWN terminates instance, reconciles cost

# Verify:
bash slm-forge/skills/forge-status/run.sh <forge-id>
# Assert: phase=DONE, all artifacts populated, cost_to_date < $5
# Open the HF Space URL in a browser, send a message, confirm response.
# Run `ollama create <name> -f /tmp/Modelfile && ollama run <name>` — confirm CLI inference works.
```

## Assertions summary

After M6 smoke passes, these must all be true:
- Every failure mode has been hit at least once with `recoverable=true|false` flagged correctly
- Every skill passes idempotency sweep
- Session-loss sweep states A, B, C all exercised
- Budget gate halts when breached
- Full end-to-end with deliberate session kill completes with a working HF Space URL + Ollama Modelfile

## References

- `slm-forge-brief/skills/SKILL_SPECS.md` — per-skill failure modes
- `slm-forge-brief/architecture/COMPUTE_TARGET.md` § Failure modes
- `slm-forge-brief/BUILD_ORDER.md` § Milestone 6
