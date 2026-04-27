# CONFIGURATION

SLM-Forge reads all secrets and tenant-specific values from environment variables. Below is the full list of env vars + the placeholder strings you'll see in the source code that map to them.

## Required env vars

| Env var | Required for | Maps to placeholder | Notes |
|---|---|---|---|
| `ANTHROPIC_API_KEY` | synth, plan-fit, smoketest | — | Get one from [console.anthropic.com](https://console.anthropic.com). Models used: Haiku 4.5, Sonnet 4.6. |
| `HF_TOKEN` | register, publish | — | `Settings → Access Tokens → New token`, role `write`. |
| `AWS_ACCESS_KEY_ID` | provision, bootstrap, train, monitor | — | IAM user with EC2 + S3 + KMS perms. Per-resource scoping in `scripts/setup-aws.sh`. |
| `AWS_SECRET_ACCESS_KEY` | as above | — | |
| `AWS_DEFAULT_REGION` | as above | — | Default: `ca-central-1`. v2 target: `us-east-1`. |
| `FORGE_BUCKET` | all S3 ops | `<YOUR_S3_BUCKET>` | Your CAS S3 bucket name. Must exist + be KMS-encrypted. |
| `FORGE_KMS_ALIAS` | s3 encrypt/decrypt | — | KMS key alias guarding FORGE_BUCKET, e.g. `alias/your-cas-key`. |
| `FORGE_AWS_ACCOUNT_ID` | preflight, ARN construction | `<YOUR_AWS_ACCOUNT_ID>` | 12-digit account ID. |
| `FORGE_PREFIX` | s3 path prefix | — | Default: `forge`. Subdir under FORGE_BUCKET where all run state lives. |

## Optional env vars

| Env var | Default | Effect |
|---|---|---|
| `FORGE_AWS_PROFILE` | — | If set, overrides default AWS profile. Maps to placeholder `<YOUR_IAM_USER>`. |
| `FORGE_DISABLE_OCR` | unset | Set to `1` to skip the OCR plugin (useful when figures contain little useful text). |
| `FORGE_VIDEO_MIN_DURATION_SEC` | `120` | MP4 plugin skips clips shorter than this (whitelist filter). Set to `0` to disable. |
| `FORGE_VIDEO_REQUIRE_AUDIO` | `1` | MP4 plugin skips clips with no audio stream. Set to `0` to disable. |
| `FORGE_CALIBRATION_STEPS` | `100` | Train calibration burst length. Set to `0` to disable. |
| `FORGE_CALIBRATION_MAX_SEC_PER_STEP` | `27` | Train aborts if measured sec/step exceeds this during calibration. |
| `FORGE_REGISTER_NAMESPACE` | (HF whoami) | Override HuggingFace publish namespace. |
| `FORGE_REGISTER_NAME_PREFIX` | (empty) | Prefix appended to model name. |
| `FORGE_REGISTER_SKIP_SPACE` | unset | Set to `1` to skip Space creation. |
| `FORGE_REGISTER_PUBLIC` | unset | Set to `1` to create a PUBLIC repo (default is private — operator flips manually after card review). |

## Placeholder reference

Source code in this repo has been sanitized: tenant-specific identifiers are replaced with placeholders. Where you see one, the corresponding env var fills it in:

| Placeholder in code | Replace with | Env var |
|---|---|---|
| `<YOUR_S3_BUCKET>` | your CAS bucket name | `FORGE_BUCKET` |
| `<YOUR_AWS_ACCOUNT_ID>` | your 12-digit AWS account ID | `FORGE_AWS_ACCOUNT_ID` |
| `<YOUR_IAM_USER>` | your IAM user / profile | `FORGE_AWS_PROFILE` (or AWS default) |
| `<YOUR_PROJECT_TAG>` | the EC2 tag scope value | (hardcode in `lib/compute_aws.sh` if you want resource-tag-scoped IAM) |
| `<PROJECT_HOME>` | path to project root on your workstation | (no env var; path-leak placeholder for any docs that referenced an absolute path) |

For full IAM policy + KMS + S3 setup, read `scripts/setup-aws.sh` before running it.

## Quick start

```bash
cp .env.example .env
$EDITOR .env  # fill in your values
set -a && source .env && set +a
```

Then run preflight to verify everything's wired:

```bash
bash scripts/preflight.sh
```

Preflight fails fast if any required credential or AWS resource is missing.
