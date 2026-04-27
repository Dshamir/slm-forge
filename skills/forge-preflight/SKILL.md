---
name: forge-preflight
description: Single-shot environment readiness check. Runs FIRST in every forge invocation, before plan generation. Hard-fails with a structured "what to fix" report if any required credential, tool, quota, or service is missing. The whole forge is gated on this passing — there's no point planning a forge if the environment can't execute it.
---

# forge-preflight

## When this fires

**Phase position: PREFLIGHT (-2)** — before ANALYZE and PLAN. The first thing
`/slm-forge` does. If it fails, the operator sees a fix list and the forge
never advances.

## What it checks

| # | Check | Pass criterion |
|---|---|---|
| 1 | Host tools | docker, jq, curl, git, python3 all on PATH |
| 2 | AWS forge creds | FORGE_AWS_ACCESS_KEY_ID + secret resolve from vault or env; sts get-caller-identity returns user `intellident-forge-provisioner` |
| 3 | S3 bucket reachable | `aws s3 ls s3://<YOUR_S3_BUCKET>/forge/` succeeds |
| 4 | HF token | resolves from vault or env; whoami returns namespace; has `repo:create` scope |
| 5 | Anthropic API key | resolves from `aiProviders` collection; `messages.create` with 5-token max succeeds |
| 6 | G+VT vCPU quota | sufficient headroom for the planned instance type; surfaces stop-instance-id if dental-prod is consuming the quota |
| 7 | AZ availability | g5.xlarge offered in at least one AZ in ca-central-1 |
| 8 | Disk headroom | ≥ 5 GB free in /tmp (for staging) and ≥ 20 GB in working dir (for HF cache) |

## Output

On PASS:
```json
{
  "status": "pass",
  "next_phase": "ANALYZE",
  "resolved_creds": {
    "aws_user": "intellident-forge-provisioner",
    "hf_namespace": "Nexless",
    "anthropic_key_id": "sk-ant-api03-Av...",  // truncated, never full key
    "s3_bucket": "<YOUR_S3_BUCKET>",
    "s3_prefix": "forge/"
  },
  "available_quota": {
    "g_vt_vcpu_total": 8,
    "g_vt_vcpu_in_use": 0,
    "g_vt_vcpu_available": 8,
    "blocking_instances": []  // or [{"id":"i-04b...", "name":"dental-prod", "type":"g4dn.2xlarge", "vcpus":8}]
  }
}
```

On FAIL:
```json
{
  "status": "fail",
  "blockers": [
    {"check":"hf_token_scope","detail":"token has no repo:create scope","fix":"regenerate token at https://huggingface.co/settings/tokens with write+create scope"},
    {"check":"g_vt_vcpu_quota","detail":"0 vCPUs available; dental-prod (g4dn.2xlarge=8 vCPU) is consuming the quota","fix":"`aws ec2 stop-instances --instance-ids i-04b483e8b944738d6` OR request quota increase"}
  ]
}
```

## Inputs
- (none — environmental check; doesn't read manifest)
- Optional env: `FORGE_REGION` (default `ca-central-1`)

## Outputs
- Stdout: status JSON
- Side effect: caches resolved creds to `/tmp/forge-creds.env` (mode 600) for reuse by downstream skills

## Failure modes

All hard-failing — no recoverable. The forge cannot proceed without:
- AWS creds (provision will fail)
- HF token (register will fail)
- Anthropic key (synth + plan-fit will fail)
- vCPU quota (provision will fail)

## Usage
```bash
bash slm-forge/skills/forge-preflight/run.sh
# Prints JSON to stdout. Exit 0 on pass, 1 on fail.
```
