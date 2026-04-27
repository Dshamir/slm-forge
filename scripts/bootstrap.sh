#!/usr/bin/env bash
# slm-forge/scripts/bootstrap.sh
#
# Runs ON the EC2 training instance (not on the forge operator host).
# Uploaded via SSM by forge-bootstrap.
#
# Goals:
#   1. Create /workspace, ensure writable.
#   2. Install Python 3.11 + venv (DLAMI has 3.10; we add 3.11 via apt).
#   3. pip install torch + transformers + peft + accelerate + bitsandbytes
#      + datasets + safetensors + huggingface_hub (+ unsloth if supported).
#   4. Build llama.cpp from source (/workspace/llama.cpp).
#   5. Write /workspace/.forge-bootstrap-complete on success.
#      Write /workspace/.forge-bootstrap-failed on hard failure.
#
# Idempotent: skip heavyweight install steps if already-present markers exist.
# Stdout/stderr go to /var/log/forge-bootstrap.log via the caller's redirect.

set -euo pipefail

WORKSPACE="/workspace"
SENTINEL_OK="${WORKSPACE}/.forge-bootstrap-complete"
SENTINEL_FAIL="${WORKSPACE}/.forge-bootstrap-failed"
VENV="${WORKSPACE}/.venv"
LLAMA_DIR="${WORKSPACE}/llama.cpp"

# On any error, write the failure sentinel so forge-bootstrap's polling
# detects the failure within 20 s.
trap 'echo "[bootstrap] FATAL at line $LINENO"; touch "$SENTINEL_FAIL"; exit 1' ERR

log() { echo "[bootstrap $(date -u +%H:%M:%S)] $*"; }

# Fast mode skips llama.cpp build + unsloth install. Useful for smoke
# tests. Set FORGE_BOOTSTRAP_FAST=1 in the SSM-exec call.
FAST="${FORGE_BOOTSTRAP_FAST:-0}"

# Minimal mode also skips the full torch+transformers pip stack. Used by
# the M3 lifecycle smoke when the test instance is CPU-only (t3.micro)
# and there's no point installing GPU wheels. Sentinel still written.
MINIMAL="${FORGE_BOOTSTRAP_MINIMAL:-0}"

# ---- 1. Workspace ------------------------------------------------------

log "Step 1/5: Workspace setup"
sudo mkdir -p "$WORKSPACE"
sudo chown -R "$(whoami):$(whoami)" "$WORKSPACE"
# DLAMI expands root volume automatically via cloud-init → growpart. Verify.
df -h "$WORKSPACE"

# Idempotent short-circuit: if sentinel present and we're re-running
# (e.g., forge-bootstrap re-invocation after transient SSM blip), skip
# the heavy steps.
if [[ -f "$SENTINEL_OK" ]]; then
  log "Sentinel $SENTINEL_OK already present — bootstrap complete, exiting."
  exit 0
fi

# ---- 2. Python 3.11 ----------------------------------------------------

log "Step 2/5: Python 3.11 + system deps"
export DEBIAN_FRONTEND=noninteractive

# Avoid needrestart prompts during apt
sudo sed -i 's/#\$nrconf{kernelhints}.*/\$nrconf{kernelhints} = -1;/' /etc/needrestart/needrestart.conf 2>/dev/null || true

# apt retries: DLAMI occasionally has initial apt-daily lock contention
for attempt in 1 2 3; do
  if sudo apt-get update -qq; then
    break
  fi
  log "apt-get update failed (attempt $attempt) — retrying in 30s"
  sleep 30
done

sudo apt-get install -y -qq \
  python3.11 python3.11-venv python3.11-dev python3-pip \
  build-essential cmake git curl jq ca-certificates \
  libssl-dev libffi-dev

python3.11 --version

# ---- 3. Python venv + ML stack ----------------------------------------

if [[ "$MINIMAL" == "1" ]]; then
  log "Step 3/5: MINIMAL mode — venv only, skipping torch/transformers/etc."
  if [[ ! -d "$VENV" ]]; then
    python3.11 -m venv "$VENV"
  fi
  # shellcheck source=/dev/null
  source "$VENV/bin/activate"
  pip install --quiet --upgrade pip wheel setuptools
  python - <<'PY'
import sys
print(f"python={sys.version.split()[0]}  venv=ok  cuda=skipped(MINIMAL=1)")
PY
else
  log "Step 3/5: Python venv + PyTorch + transformers + peft + accelerate"
  if [[ ! -d "$VENV" ]]; then
    python3.11 -m venv "$VENV"
  fi

  # shellcheck source=/dev/null
  source "$VENV/bin/activate"
  pip install --quiet --upgrade pip wheel setuptools

  # Install torch matching the CUDA version on the AMI. The DLAMI 2026-04
  # ships CUDA 12.4; use cu124 wheels.
  log "Installing torch (cu124 wheels)..."
  pip install --quiet --extra-index-url https://download.pytorch.org/whl/cu124 \
    "torch>=2.4,<3" \
    "torchaudio>=2.4,<3"

  log "Installing transformers + peft + accelerate + bitsandbytes + datasets + huggingface_hub + safetensors..."
  # Version note (M4 v1 + v2 lessons 2026-04-23):
  #   transformers 4.44+ calls Accelerator.unwrap_model(keep_torch_compile=...)
  #   which was added in accelerate 1.1.0. First pip pass resolved to
  #   0.34 → crashed. Second pass (>=1.0,<1.2) resolved to 1.0.0 → same
  #   crash (the kwarg is 1.1.0+, not 1.0+). Floor is now 1.1.1 with
  #   no upper bound so pip picks the newest compat version.
  pip install --quiet \
    "transformers>=4.46,<5" \
    "datasets>=2.20,<3" \
    "accelerate>=1.1.1" \
    "peft>=0.13,<1" \
    "bitsandbytes>=0.43,<1" \
    "safetensors>=0.4,<1" \
    "huggingface_hub>=0.26,<1" \
    "sentencepiece>=0.2,<1" \
    "tokenizers>=0.20,<1" \
    "pyyaml>=6,<7" \
    "protobuf>=4,<6"

  # Record exact installed versions so debugging future version-pin
  # drift is one grep away.
  log "pip freeze (key ML packages):"
  pip freeze | grep -iE "^(torch|transformers|accelerate|peft|datasets|huggingface[-_]hub|tokenizers|safetensors|bitsandbytes|pyyaml)==" | sort | sed 's/^/  /'

  if [[ "$FAST" != "1" ]]; then
    log "Installing unsloth (skipped when FORGE_BOOTSTRAP_FAST=1)..."
    # unsloth is fussy about CUDA/torch combinations; if install fails,
    # record the reason but don't fail the whole bootstrap. forge-train can
    # fall back to stock HF Trainer per D-008.
    pip install --quiet "unsloth[cu124-torch240]" 2>/var/log/forge-bootstrap-unsloth-install.log || \
      log "WARN: unsloth install failed — will fall back to HF Trainer (D-008 path 2)"
  fi

  # Quick GPU sanity check
  log "GPU sanity check: torch.cuda.is_available()"
  python - <<'PY'
import torch
print(f"torch={torch.__version__}  cuda_available={torch.cuda.is_available()}  device_count={torch.cuda.device_count()}")
if torch.cuda.is_available():
    print(f"device_0_name={torch.cuda.get_device_name(0)}")
PY
fi

# ---- 4. llama.cpp ------------------------------------------------------

if [[ "$MINIMAL" == "1" ]]; then
  log "Step 4/5: llama.cpp build — SKIPPED (MINIMAL mode)"
elif [[ "$FAST" == "1" ]]; then
  log "Step 4/5: llama.cpp build — SKIPPED (FAST mode)"
else
  log "Step 4/5: llama.cpp build"
  if [[ ! -d "$LLAMA_DIR" ]]; then
    git clone --quiet --depth 1 https://github.com/ggml-org/llama.cpp.git "$LLAMA_DIR"
  fi
  pushd "$LLAMA_DIR" >/dev/null
  # Build with CUDA support (offloads quantize/convert)
  cmake -B build -DGGML_CUDA=ON -DBUILD_SHARED_LIBS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=ON -Wno-dev >/dev/null
  cmake --build build --config Release --target llama-quantize llama-cli llama-server -j "$(nproc)" >/dev/null
  popd >/dev/null
  "$LLAMA_DIR/build/bin/llama-quantize" --version 2>&1 | head -3 || true
fi

# ---- 5. AWS CLI (required by forge-train log-sync + forge-quantize) ---

log "Step 5/5: aws-cli v2 check"
if ! command -v aws >/dev/null 2>&1; then
  curl -sS "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  (cd /tmp && unzip -q -o awscliv2.zip && sudo ./aws/install --update)
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi
aws --version

# ---- Success sentinel --------------------------------------------------

touch "$SENTINEL_OK"
rm -f "$SENTINEL_FAIL"
log "DONE — sentinel $SENTINEL_OK written."
