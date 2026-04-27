#!/usr/bin/env bash
# slm-forge/lib/compute_aws.sh
#
# AWS ComputeTarget implementation. Pinned to ca-central-1. Reads
# FORGE_AWS_* (preferred) or AWS_* (less safe; resolves to <YOUR_IAM_USER>).
#
# All operations follow the contract in
# slm-forge-brief/architecture/COMPUTE_TARGET.md:
#   provision, bootstrap, exec, exec_nohup, fetch_logs, upload, download,
#   ps, cost_to_date, teardown, reattach.
#
# This is the M1 skeleton — provision + exec + teardown have minimal
# logic. The exec/exec_nohup loops, log-sync side process, and Cost
# Explorer reconciliation arrive in M3 and M4.

set -euo pipefail

FORGE_REGION="${FORGE_REGION:-ca-central-1}"
FORGE_DEFAULT_AMI="${FORGE_DEFAULT_AMI:-ami-0cd334baef71e080e}"  # AWS DLAMI Ubuntu 22.04 (2026-04-21)
FORGE_INSTANCE_PROFILE="${FORGE_INSTANCE_PROFILE:-SLMForgeInstanceRole}"
FORGE_DEFAULT_EBS_GB="${FORGE_DEFAULT_EBS_GB:-200}"
FORGE_BUCKET="${FORGE_BUCKET:-<YOUR_S3_BUCKET>}"
FORGE_PREFIX="${FORGE_PREFIX:-forge}"

# AWS shim — same pattern as manifest.sh
_compute_aws_cli() {
  local key_id="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local key_secret="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  if [[ -z "$key_id" || -z "$key_secret" ]]; then
    echo "compute_aws: FORGE_AWS_ACCESS_KEY_ID + FORGE_AWS_SECRET_ACCESS_KEY required" >&2
    return 64
  fi
  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="$key_id" \
    AWS_SECRET_ACCESS_KEY="$key_secret" \
    AWS_DEFAULT_REGION="$FORGE_REGION" \
      aws "$@"
  else
    docker run --rm -i \
      -e AWS_ACCESS_KEY_ID="$key_id" \
      -e AWS_SECRET_ACCESS_KEY="$key_secret" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      amazon/aws-cli:latest "$@"
  fi
}

# ---- provision ---------------------------------------------------------

# compute_aws_provision <spec-json>
# Spec JSON fields (all optional, defaults documented):
#   instance_type   default g5.xlarge
#   ami_id          default FORGE_DEFAULT_AMI (AWS DLAMI Ubuntu 22.04)
#   ebs_gb          default FORGE_DEFAULT_EBS_GB (200)
#   forge_id        (required for tagging)
#   subnet_id       auto-discovered first default subnet if omitted
#   security_group  auto-discovered default SG if omitted
#
# Side effect: launches one EC2 instance. Polls until running+ok and SSM
# agent registered. Returns a JSON object:
#   { instance_id, ec2_launch_time, instance_type, ami_id, subnet_id,
#     security_group_ids, cost_per_hour_usd }
compute_aws_provision() {
  local spec="$1"
  local instance_type ami_id ebs_gb forge_id subnet_id sg_id
  instance_type=$(echo "$spec" | jq -r '.instance_type // "g5.xlarge"')
  ami_id=$(echo "$spec" | jq -r ".ami_id // \"$FORGE_DEFAULT_AMI\"")
  ebs_gb=$(echo "$spec" | jq -r ".ebs_gb // $FORGE_DEFAULT_EBS_GB")
  forge_id=$(echo "$spec" | jq -r '.forge_id // ""')
  if [[ -z "$forge_id" || "$forge_id" == "null" ]]; then
    echo "compute_aws_provision: spec.forge_id is required for tagging" >&2
    return 64
  fi
  subnet_id=$(echo "$spec" | jq -r '.subnet_id // ""')
  sg_id=$(echo "$spec" | jq -r '.security_group // ""')

  # Env override wins over auto-discovery. FORGE_SUBNET_ID lets operators
  # pin to a specific AZ when capacity is scarce (e.g. g5.xlarge 1a → 1b).
  if [[ -z "$subnet_id" || "$subnet_id" == "null" ]]; then
    subnet_id="${FORGE_SUBNET_ID:-}"
  fi

  # Auto-discover default VPC subnet + SG when unset.
  if [[ -z "$subnet_id" || "$subnet_id" == "null" ]]; then
    subnet_id=$(_compute_aws_cli ec2 describe-subnets \
      --filters "Name=default-for-az,Values=true" \
      --query 'Subnets[0].SubnetId' --output text 2>/dev/null)
    if [[ -z "$subnet_id" || "$subnet_id" == "None" ]]; then
      echo "compute_aws_provision: no default subnet in region $FORGE_REGION" >&2
      return 1
    fi
  fi

  if [[ -z "$sg_id" || "$sg_id" == "null" ]]; then
    # Look up default SG for the subnet's VPC.
    local vpc_id
    vpc_id=$(_compute_aws_cli ec2 describe-subnets \
      --subnet-ids "$subnet_id" \
      --query 'Subnets[0].VpcId' --output text)
    sg_id=$(_compute_aws_cli ec2 describe-security-groups \
      --filters "Name=vpc-id,Values=$vpc_id" "Name=group-name,Values=default" \
      --query 'SecurityGroups[0].GroupId' --output text)
    if [[ -z "$sg_id" || "$sg_id" == "None" ]]; then
      echo "compute_aws_provision: no default SG in VPC $vpc_id" >&2
      return 1
    fi
  fi

  # Assemble tag spec. IAM policy RunForgeInstances + ManageForgeEbsVolumes
  # requires aws:RequestTag/Project=slm-forge at create time.
  local tag_spec_instance tag_spec_volume
  tag_spec_instance="ResourceType=instance,Tags=[{Key=Project,Value=slm-forge},{Key=forge-id,Value=${forge_id}},{Key=ManagedBy,Value=slm-forge},{Key=Name,Value=slm-forge-${forge_id}}]"
  tag_spec_volume="ResourceType=volume,Tags=[{Key=Project,Value=slm-forge},{Key=forge-id,Value=${forge_id}},{Key=ManagedBy,Value=slm-forge}]"

  # Block device mapping: DLAMI has a default root volume. We replace it
  # with a larger gp3 volume so there's room for Python packages + models.
  local block_device
  block_device="[{\"DeviceName\":\"/dev/sda1\",\"Ebs\":{\"VolumeSize\":${ebs_gb},\"VolumeType\":\"gp3\",\"DeleteOnTermination\":true}}]"

  # User-data script: just writes forge-id to /etc/forge-id so the box
  # self-identifies. Minimal by design — heavy work is in forge-bootstrap.
  local user_data
  user_data=$(printf '#!/bin/bash\necho "%s" > /etc/forge-id\n' "$forge_id" | base64 -w0)

  # Auto-AZ retry: collect all default subnets in the region. If the
  # operator-supplied or first-default subnet is rejected with
  # InsufficientInstanceCapacity, we iterate through the rest.
  # Can be disabled with FORGE_AZ_RETRY=0.
  local -a subnet_candidates
  subnet_candidates=("$subnet_id")
  if [[ "${FORGE_AZ_RETRY:-1}" == "1" ]]; then
    local other_subnets
    other_subnets=$(_compute_aws_cli ec2 describe-subnets \
      --filters "Name=default-for-az,Values=true" \
      --query 'Subnets[].SubnetId' --output text 2>/dev/null | tr '\t' '\n')
    while IFS= read -r s; do
      [[ -z "$s" || "$s" == "$subnet_id" ]] && continue
      subnet_candidates+=("$s")
    done <<< "$other_subnets"
  fi

  local launch_json=""
  local try_subnet=""
  local last_err=""
  for try_subnet in "${subnet_candidates[@]}"; do
    echo "[provision] trying subnet $try_subnet..." >&2
    local attempt
    attempt=$(_compute_aws_cli ec2 run-instances \
      --image-id "$ami_id" \
      --instance-type "$instance_type" \
      --subnet-id "$try_subnet" \
      --security-group-ids "$sg_id" \
      --iam-instance-profile "Name=$FORGE_INSTANCE_PROFILE" \
      --block-device-mappings "$block_device" \
      --tag-specifications "$tag_spec_instance" "$tag_spec_volume" \
      --user-data "$user_data" \
      --metadata-options "HttpTokens=required,HttpPutResponseHopLimit=2" \
      --count 1 \
      --query 'Instances[0]' --output json 2>&1) || {
        last_err="$attempt"
        if [[ "$last_err" == *"InsufficientInstanceCapacity"* ]]; then
          echo "[provision]   InsufficientInstanceCapacity in $try_subnet — trying next AZ" >&2
          continue
        fi
        # Any other error: fail immediately, don't iterate further
        echo "compute_aws_provision: run-instances failed with non-capacity error:" >&2
        echo "$last_err" >&2
        return 1
      }
    # If we got here with valid JSON, success
    if [[ -n "$attempt" && "$attempt" != "null" ]]; then
      launch_json="$attempt"
      subnet_id="$try_subnet"
      break
    fi
  done

  if [[ -z "$launch_json" ]]; then
    echo "compute_aws_provision: all ${#subnet_candidates[@]} subnet(s) rejected with InsufficientInstanceCapacity" >&2
    echo "last error: $last_err" >&2
    return 1
  fi

  local instance_id launch_time
  instance_id=$(echo "$launch_json" | jq -r '.InstanceId')
  launch_time=$(echo "$launch_json" | jq -r '.LaunchTime')

  if [[ -z "$instance_id" || "$instance_id" == "null" ]]; then
    echo "compute_aws_provision: no InstanceId in response" >&2
    echo "$launch_json" >&2
    return 1
  fi

  echo "[provision] launched $instance_id — waiting for running state..." >&2
  # Wait up to 2 min for the instance to reach 'running'. We do NOT wait
  # for the 'ok' system+instance status checks (DLAMI sometimes takes
  # 5-7 min there) — SSM Online below is the real "ready" signal.
  local deadline=$(( SECONDS + 120 ))
  local inst_state="pending"
  while (( SECONDS < deadline )); do
    inst_state=$(_compute_aws_cli ec2 describe-instances \
      --instance-ids "$instance_id" \
      --query 'Reservations[0].Instances[0].State.Name' \
      --output text 2>/dev/null || echo "pending")
    case "$inst_state" in
      running) break ;;
      terminated|shutting-down)
        echo "compute_aws_provision: instance entered state $inst_state unexpectedly" >&2
        return 1
        ;;
    esac
    sleep 5
  done

  if [[ "$inst_state" != "running" ]]; then
    echo "compute_aws_provision: timed out waiting for state=running (last=$inst_state)" >&2
    return 1
  fi

  echo "[provision] $instance_id running — waiting for SSM agent (this is the gating signal)..." >&2
  # Wait up to 5 min for SSM agent. DLAMI bake takes ~3-5 min before SSM
  # registers — that's the real bottleneck.
  deadline=$(( SECONDS + 300 ))
  local ssm_ping="Unknown"
  while (( SECONDS < deadline )); do
    ssm_ping=$(_compute_aws_cli ssm describe-instance-information \
      --filters "Key=InstanceIds,Values=$instance_id" \
      --query 'InstanceInformationList[0].PingStatus' \
      --output text 2>/dev/null || echo "None")
    [[ "$ssm_ping" == "Online" ]] && break
    sleep 15
  done

  if [[ "$ssm_ping" != "Online" ]]; then
    echo "compute_aws_provision: SSM agent never registered (last=$ssm_ping)" >&2
    # Do NOT terminate from here — let the caller decide. They have the
    # instance_id from the SDK call below this function (when we update
    # the manifest) — but we abort before that. Print the id so it can
    # be cleaned up out-of-band.
    echo "compute_aws_provision: ORPHAN instance still running: $instance_id" >&2
    return 1
  fi

  echo "[provision] $instance_id SSM online ✓" >&2

  # Return a summary JSON.
  jq -n \
    --arg iid "$instance_id" \
    --arg it "$instance_type" \
    --arg ami "$ami_id" \
    --arg sub "$subnet_id" \
    --arg sg "$sg_id" \
    --arg lt "$launch_time" \
    '{
      instance_id: $iid,
      instance_type: $it,
      ami_id: $ami,
      subnet_id: $sub,
      security_group_ids: [$sg],
      ec2_launch_time: $lt,
      ssm_status: "Online"
    }'
}

# ---- exec --------------------------------------------------------------

# compute_aws_exec <instance-id> <cmd>
# Runs command via SSM Run Command, blocks until completion.
compute_aws_exec() {
  local instance_id="$1"; shift
  local cmd="$*"
  local command_id

  command_id=$(_compute_aws_cli ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"$cmd\"]" \
    --query 'Command.CommandId' --output text)

  # Poll until terminal status
  local status
  for _ in $(seq 1 60); do
    sleep 2
    status=$(_compute_aws_cli ssm get-command-invocation \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")
    case "$status" in
      Success) break ;;
      Failed|Cancelled|TimedOut) break ;;
      *) ;;
    esac
  done

  _compute_aws_cli ssm get-command-invocation \
    --command-id "$command_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text

  if [[ "$status" != "Success" ]]; then
    _compute_aws_cli ssm get-command-invocation \
      --command-id "$command_id" --instance-id "$instance_id" \
      --query 'StandardErrorContent' --output text >&2
    return 1
  fi
}

# ---- exec_nohup --------------------------------------------------------

# compute_aws_exec_nohup <instance-id> <cmd> <log-path>
# Launches a detached command, returns the PID. M4 fills in.
compute_aws_exec_nohup() {
  echo "compute_aws_exec_nohup: not implemented — M4 milestone" >&2
  return 78
}

# ---- ps / liveness -----------------------------------------------------

# compute_aws_ps <instance-id> <pid>
# Returns 0 if PID alive, 1 otherwise. M4 fills in fully.
compute_aws_ps() {
  local instance_id="$1"
  local pid="$2"
  compute_aws_exec "$instance_id" "kill -0 $pid 2>/dev/null && echo alive || echo dead"
}

# ---- file transfer -----------------------------------------------------

# compute_aws_upload <forge-id> <instance-id> <local-path> <remote-path>
# Path: local → S3 (under forge/<id>/bootstrap/) → SSM aws s3 cp → instance.
compute_aws_upload() {
  local forge_id="$1" instance_id="$2" local_path="$3" remote_path="$4"
  if [[ ! -f "$local_path" ]]; then
    echo "compute_aws_upload: not a file: $local_path" >&2
    return 1
  fi
  # Upload to S3 staging prefix
  local base_name s3_key mount_dir
  base_name=$(basename "$local_path")
  s3_key="${FORGE_PREFIX}/${forge_id}/bootstrap/${base_name}"
  mount_dir=$(cd "$(dirname "$local_path")" && pwd)
  _forge_aws_mount "$mount_dir" s3api put-object \
    --bucket "$FORGE_BUCKET" \
    --key "$s3_key" \
    --body "/work/$base_name" \
    --tagging "Project=slm-forge&forge-id=${forge_id}&phase=BOOTSTRAP" >/dev/null

  # SSM: pull from S3 to the target path on the instance
  local remote_dir
  remote_dir=$(dirname "$remote_path")
  local fetch_cmd
  fetch_cmd="mkdir -p '${remote_dir}' && aws s3 cp 's3://${FORGE_BUCKET}/${s3_key}' '${remote_path}' --region ${FORGE_REGION} && chmod +x '${remote_path}' 2>/dev/null || true"
  compute_aws_exec "$instance_id" "$fetch_cmd" >/dev/null
}

# compute_aws_download <forge-id> <instance-id> <remote-path> <local-path>
# Inverse of upload: SSM uploads remote file to S3, then we pull it locally.
compute_aws_download() {
  local forge_id="$1" instance_id="$2" remote_path="$3" local_path="$4"
  local base_name s3_key mount_dir
  base_name=$(basename "$remote_path")
  s3_key="${FORGE_PREFIX}/${forge_id}/bootstrap/dl-${base_name}"

  # Remote: upload to S3
  local push_cmd
  push_cmd="aws s3 cp '${remote_path}' 's3://${FORGE_BUCKET}/${s3_key}' --region ${FORGE_REGION}"
  compute_aws_exec "$instance_id" "$push_cmd" >/dev/null

  # Local: pull from S3
  mkdir -p "$(dirname "$local_path")"
  mount_dir=$(cd "$(dirname "$local_path")" && pwd)
  _forge_aws_mount "$mount_dir" s3api get-object \
    --bucket "$FORGE_BUCKET" \
    --key "$s3_key" \
    "/work/$(basename "$local_path")" >/dev/null
}

# _forge_aws_mount: mounted-volume variant for commands that need file I/O.
# Matches the pattern in lib/manifest.sh.
_forge_aws_mount() {
  local mount_dir="$1"; shift
  local key_id="${FORGE_AWS_ACCESS_KEY_ID:-${AWS_ACCESS_KEY_ID:-}}"
  local key_secret="${FORGE_AWS_SECRET_ACCESS_KEY:-${AWS_SECRET_ACCESS_KEY:-}}"
  if command -v aws >/dev/null 2>&1; then
    AWS_ACCESS_KEY_ID="$key_id" \
    AWS_SECRET_ACCESS_KEY="$key_secret" \
    AWS_DEFAULT_REGION="$FORGE_REGION" \
      aws "$@"
  else
    docker run --rm --user "$(id -u):$(id -g)" \
      -e AWS_ACCESS_KEY_ID="$key_id" \
      -e AWS_SECRET_ACCESS_KEY="$key_secret" \
      -e AWS_DEFAULT_REGION="$FORGE_REGION" \
      -v "$(cd "$mount_dir" && pwd):/work" \
      amazon/aws-cli:latest "$@"
  fi
}

compute_aws_fetch_logs() {
  echo "compute_aws_fetch_logs: not implemented — M4 milestone" >&2
  return 78
}

# ---- cost --------------------------------------------------------------

# compute_aws_cost_to_date <forge-id>
# Fast estimate path: queries instance launch time + rate. M3 fills in
# proper Cost Explorer reconciliation.
compute_aws_cost_to_date() {
  local forge_id="$1"
  local local_path="${FORGE_WORK:-${HOME}/.slm-forge}/manifests/${forge_id}.json"
  if [[ ! -f "$local_path" ]]; then
    echo "compute_aws_cost_to_date: no local manifest for $forge_id" >&2
    return 1
  fi
  local rate launch_time now elapsed_h cost
  rate=$(jq -r '.compute_target.cost_per_hour_usd // 0' "$local_path")
  launch_time=$(jq -r '.compute_target.ec2_launch_time // empty' "$local_path")
  if [[ -z "$launch_time" || "$rate" == "0" ]]; then
    echo "0.00"
    return 0
  fi
  now=$(date -u +%s)
  local launch_epoch
  launch_epoch=$(date -u -d "$launch_time" +%s 2>/dev/null || date -j -f "%Y-%m-%dT%H:%M:%SZ" "$launch_time" +%s 2>/dev/null)
  elapsed_h=$(awk -v a="$now" -v b="$launch_epoch" 'BEGIN{printf "%.6f", (a-b)/3600}')
  cost=$(awk -v r="$rate" -v h="$elapsed_h" 'BEGIN{printf "%.4f", r*h}')
  echo "$cost"
}

# ---- teardown ----------------------------------------------------------

# compute_aws_teardown <instance-id> [terminate|stop]
# Default: stop (preserves EBS for resume). Terminate deletes EBS.
compute_aws_teardown() {
  local instance_id="$1"
  local mode="${2:-stop}"
  case "$mode" in
    stop)
      _compute_aws_cli ec2 stop-instances --instance-ids "$instance_id" >/dev/null
      ;;
    terminate)
      _compute_aws_cli ec2 terminate-instances --instance-ids "$instance_id" >/dev/null
      ;;
    *)
      echo "compute_aws_teardown: unknown mode '$mode' (expected stop|terminate)" >&2
      return 64
      ;;
  esac
}

# ---- reattach ----------------------------------------------------------

# compute_aws_reattach <instance-id>
# Returns 0 if instance is reachable via SSM. M4 fills in restart-if-stopped.
compute_aws_reattach() {
  local instance_id="$1"
  _compute_aws_cli ssm describe-instance-information \
    --filters "Key=InstanceIds,Values=$instance_id" \
    --query 'InstanceInformationList[0].PingStatus' --output text 2>/dev/null \
    | grep -q Online
}

# ---- bootstrap ---------------------------------------------------------

# compute_aws_bootstrap <forge-id> <instance-id> <local-script-path> [timeout-sec]
# Uploads the script via S3 + SSM, runs it SYNCHRONOUSLY via SSM with an
# extended poll. Output goes to /var/log/forge-bootstrap.log on the
# instance AND back through SSM's StandardOutputContent. Final log is
# pushed to S3 regardless of outcome. Returns 0 on success.
#
# Why synchronous: SSM Run Command's nohup/disown pattern is fragile —
# AWS-RunShellScript document on Ubuntu uses dash, which doesn't support
# `disown`. The detached process gets cleaned up when the SSM-spawned
# shell exits and bootstrap silently never starts. Synchronous SSM with
# a long timeout is simpler and surfaces failures inline.
compute_aws_bootstrap() {
  local forge_id="$1" instance_id="$2" script_path="$3" timeout_sec="${4:-1800}"
  if [[ ! -f "$script_path" ]]; then
    echo "compute_aws_bootstrap: script not found: $script_path" >&2
    return 1
  fi

  local remote_path="/tmp/forge-bootstrap.sh"

  echo "[bootstrap] uploading script → $instance_id:$remote_path" >&2
  compute_aws_upload "$forge_id" "$instance_id" "$script_path" "$remote_path"

  # Pass through smoke env vars (FAST, MINIMAL).
  local env_prefix=""
  [[ -n "${FORGE_BOOTSTRAP_FAST:-}" ]]    && env_prefix+="FORGE_BOOTSTRAP_FAST=${FORGE_BOOTSTRAP_FAST} "
  [[ -n "${FORGE_BOOTSTRAP_MINIMAL:-}" ]] && env_prefix+="FORGE_BOOTSTRAP_MINIMAL=${FORGE_BOOTSTRAP_MINIMAL} "

  echo "[bootstrap] executing synchronously (timeout ${timeout_sec}s; tail to /var/log/forge-bootstrap.log)..." >&2

  # Send command with extended SSM execution timeout. We don't poll
  # compute_aws_exec (which caps at 2 min); instead use send-command +
  # custom poll loop directly.
  local cmd_id
  local exec_cmd
  exec_cmd="env ${env_prefix} bash ${remote_path} 2>&1 | tee /var/log/forge-bootstrap.log"

  cmd_id=$(_compute_aws_cli ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --timeout-seconds "$timeout_sec" \
    --parameters "commands=[\"$exec_cmd\"],executionTimeout=[\"$timeout_sec\"]" \
    --query 'Command.CommandId' --output text)

  if [[ -z "$cmd_id" || "$cmd_id" == "None" ]]; then
    echo "[bootstrap] SSM send-command returned no CommandId" >&2
    return 1
  fi
  echo "[bootstrap] SSM CommandId: $cmd_id" >&2

  # Poll get-command-invocation. SSM terminal states: Success, Failed,
  # Cancelled, TimedOut. Non-terminal: Pending, InProgress, Delayed.
  local deadline=$(( SECONDS + timeout_sec + 60 ))
  local status="Pending"
  local last_log=0
  while (( SECONDS < deadline )); do
    sleep 15
    status=$(_compute_aws_cli ssm get-command-invocation \
      --command-id "$cmd_id" --instance-id "$instance_id" \
      --query 'Status' --output text 2>/dev/null || echo "Pending")

    # Periodic progress: every minute, print elapsed
    if (( SECONDS - last_log >= 60 )); then
      echo "[bootstrap]  ${SECONDS}s elapsed, status=${status}" >&2
      last_log=$SECONDS
    fi

    case "$status" in
      Success|Failed|Cancelled|TimedOut) break ;;
    esac
  done

  echo "[bootstrap] terminal status: $status (after ${SECONDS}s)" >&2

  # Push final log from instance to S3 regardless (best-effort).
  _compute_aws_cli ssm send-command \
    --instance-ids "$instance_id" \
    --document-name "AWS-RunShellScript" \
    --parameters "commands=[\"aws s3 cp /var/log/forge-bootstrap.log s3://${FORGE_BUCKET}/${FORGE_PREFIX}/${forge_id}/logs/bootstrap.log --region ${FORGE_REGION} 2>&1 || true\"]" \
    --query 'Command.CommandId' --output text >/dev/null 2>&1 || true

  if [[ "$status" == "Success" ]]; then
    return 0
  fi

  # On non-success, fetch the last KB of stdout/stderr to surface the cause
  echo "[bootstrap] last 40 lines of SSM stdout:" >&2
  _compute_aws_cli ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance_id" \
    --query 'StandardOutputContent' --output text 2>/dev/null \
    | tail -40 >&2 || true

  echo "[bootstrap] SSM stderr (if any):" >&2
  _compute_aws_cli ssm get-command-invocation \
    --command-id "$cmd_id" --instance-id "$instance_id" \
    --query 'StandardErrorContent' --output text 2>/dev/null \
    | tail -20 >&2 || true

  return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  cmd="${1:-help}"
  shift || true
  fn="compute_aws_${cmd}"
  if declare -F "$fn" >/dev/null 2>&1; then
    "$fn" "$@"
  else
    echo "Unknown compute_aws op: $cmd" >&2
    echo "Available: provision, bootstrap, exec, exec_nohup, ps, upload, download, fetch_logs, cost_to_date, teardown, reattach" >&2
    exit 64
  fi
fi
