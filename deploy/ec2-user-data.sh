#!/bin/bash
# EC2 user data that runs a temperwork environment's workers on one instance.
# See docs/workers.md.
#
# On a GPU instance (the AWS Deep Learning Base GPU AMI, Amazon Linux 2023:
# docker and the NVIDIA container toolkit) it runs the pod service, one
# container per GPU, from a worker image (qwen-image for runs, lora-trainer
# for trainings). With JUDGE_QUEUE_URL set it also runs a judge worker beside
# them, which needs no GPU: from JUDGE_IMAGE (the judge worker image, with
# temperwork's automation judges built in), else from IMAGE (no automation
# steps). On a CPU instance with only JUDGE_QUEUE_URL it runs the judge worker
# alone.
#
# Launch it:
#   - with the environment module's instance profile (<name>-studio-worker),
#     created with enroll_token_parameter set to TOKEN_PARAM below
#   - in a subnet that reaches temperwork.com (workers call home for a
#     lease), the image registry, Hugging Face (models download at boot) and S3
#   - with --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2
#     (the containers use the instance profile)
#   - with --instance-initiated-shutdown-behavior terminate: each container
#     leaves once its queue is empty, and then the instance powers off
#
# The enrollment token (the environment's card on the studio's Environments
# page: Make an enrollment token) is read from SSM Parameter Store, never
# written here. A worker keeps its certificate on the instance's disk, so one
# enrollment serves its restarts.
set -euxo pipefail

# --- your settings: the environment's outputs (worker_env, judge_worker_args) ---
IMAGE='<registry>/qwen-image:customer-prod-latest'   # the worker image temperwork gives you access to
REGISTRY_LOGIN='none'          # ecr: log in to IMAGE's ECR registry with the profile; none: a public registry
STUDIO_URL='https://temperwork.com'
STUDIO_CONNECTION_ID='<the id you gave the environment>'
STUDIO_CONTROL_URI='<worker_env STUDIO_CONTROL_URI>'
AWS_REGION='us-west-2'
QUEUE_URL='<worker_env STUDIO_QUEUE_URL>'   # the pod service's runs queue ('' : none)
TRAIN_QUEUE_URL=''             # a trainer image's: worker_env STUDIO_TRAIN_QUEUE_URL
JUDGE_QUEUE_URL=''             # also run a judge worker here: judge_worker_args' --queue-url
JUDGE_IMAGE=''                 # the judge worker image (<registry>/judge-worker:customer-prod-latest); empty: IMAGE's worker, without automation judges
TOKEN_PARAM='/studio/enroll-token'   # the SSM parameter (SecureString) holding the enrollment token
ROOT_SHA256=''                 # only for an image not pinned to temperwork.com's root (the customer images are): that root's fingerprint
IDLE_S=600                     # a worker leaves after its queue has been empty this long
MAX_MINUTES=0                  # power off after this long whatever happens (0: never)
# --- end of settings ---

[ "$MAX_MINUTES" -gt 0 ] && shutdown -h "+$MAX_MINUTES"
trap 'echo "[workers] boot failed: shutting down"; shutdown -h now' ERR
gpu=0; command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && gpu=1
[ "$gpu" = 1 ] && { ( systemctl start nvidia-persistenced || nvidia-smi -pm 1 ) >/dev/null 2>&1 & }

# The instance's local NVMe disk (if it has one) for the models and docker: the
# root volume is too small for a pod's ~40 GB of models.
WS=/opt/workspace
dev=$(lsblk -dpno NAME,MODEL | awk '/Instance Storage/ {print $1; exit}')
if [ -n "$dev" ]; then
  at=$(findmnt -nro TARGET -S "$dev" || true)
  if [ -z "$at" ]; then
    mkfs.xfs -f -K "$dev" && mkdir -p /mnt/nvme && mount "$dev" /mnt/nvme && at=/mnt/nvme
  fi
  WS="$at/workspace"
  systemctl stop docker docker.socket containerd 2>/dev/null || true
  for d in docker containerd; do mkdir -p "$at/$d" "/var/lib/$d" && mount --bind "$at/$d" "/var/lib/$d"; done
fi
mkdir -p "$WS"

command -v docker >/dev/null || dnf install -y docker
systemctl enable --now docker
pods=0; { [ -n "$QUEUE_URL" ] || [ -n "$TRAIN_QUEUE_URL" ]; } && pods=1
images=()   # what this instance runs: the pods' image, and the judge worker's
{ [ "$pods" = 1 ] || { [ -n "$JUDGE_QUEUE_URL" ] && [ -z "$JUDGE_IMAGE" ]; }; } && images+=("$IMAGE")
[ -n "$JUDGE_QUEUE_URL" ] && [ -n "$JUDGE_IMAGE" ] && images+=("$JUDGE_IMAGE")
for image in "${images[@]}"; do
  if [ "$REGISTRY_LOGIN" = ecr ]; then   # the registry's own region, which may not be the instance's
    host=${image%%/*}; ecr_region=$(echo "$host" | sed -E 's/.*\.dkr\.ecr\.([a-z0-9-]+)\.amazonaws\.com$/\1/')
    aws ecr get-login-password --region "${ecr_region:-$AWS_REGION}" | docker login -u AWS --password-stdin "$host"
  fi
  docker pull "$image"
done

set +x
STUDIO_ENROLL_TOKEN=$(aws ssm get-parameter --region "$AWS_REGION" --name "$TOKEN_PARAM" --with-decryption \
  --query Parameter.Value --output text)
export STUDIO_ENROLL_TOKEN STUDIO_URL STUDIO_CONNECTION_ID STUDIO_CONTROL_URI AWS_REGION
set -x
TOKEN=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)
ITYPE=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type || true)

common=(-d --stop-timeout 100 -e STUDIO_ENROLL_TOKEN -e STUDIO_URL
        -e STUDIO_CONNECTION_ID -e STUDIO_CONTROL_URI -e AWS_REGION)
[ -n "$ROOT_SHA256" ] && common+=(-e STUDIO_ROOT_SHA256="$ROOT_SHA256")
names=()
pod() {   # name, docker args for its device...
  local name=$1; shift
  docker rm -f "$name" 2>/dev/null || true
  # --ipc=host: a training's data loader outgrows docker's 64 MB /dev/shm.
  docker run "${common[@]}" --restart on-failure --name "$name" --hostname "$name" "$@" --ipc=host \
    -v "$WS:/workspace" -e STUDIO_QUEUE_URL="$QUEUE_URL" -e STUDIO_TRAIN_QUEUE_URL="$TRAIN_QUEUE_URL" \
    -e STUDIO_POD_IDLE_S="$IDLE_S" -e STUDIO_POD_DRAIN_S=90 -e STUDIO_POD_INSTANCE_TYPE="$ITYPE" \
    -e STUDIO_POD_PLATFORM=ec2 "$IMAGE"
  names+=("$name")
}
if [ "$pods" = 1 ]; then
  if [ "$gpu" = 1 ]; then   # one pod per GPU
    for i in $(seq 0 $(( $(nvidia-smi -L | wc -l) - 1 ))); do pod "pod-$i" --gpus "device=$i"; done
  else                      # no GPU: one pod (an image that runs on CPU)
    pod pod-0
  fi
fi
if [ -n "$JUDGE_QUEUE_URL" ]; then
  # The judge worker. Not restarted: it leaves when its queue is empty or it
  # is revoked. JUDGE_IMAGE: its command is the judge worker and temperwork's
  # judges are built in, so automation steps run; it runs as uid 65532, which
  # owns its state. Without it: IMAGE's worker, which has no judges, so
  # automation steps fail.
  mkdir -p "$WS/judge"
  docker rm -f judge 2>/dev/null || true
  judge=(-v "$WS/judge:/state" -e STUDIO_JUDGE_STATE=/state -e STUDIO_JUDGE_QUEUE_URL="$JUDGE_QUEUE_URL"
         -e STUDIO_JUDGE_IDLE_S="$IDLE_S")
  if [ -n "$JUDGE_IMAGE" ]; then
    chown 65532:65532 "$WS/judge"
    docker run "${common[@]}" --name judge --hostname judge "${judge[@]}" "$JUDGE_IMAGE"
  else
    docker run "${common[@]}" --name judge --hostname judge --entrypoint /opt/qwen/temperwork-worker \
      "${judge[@]}" "$IMAGE" judge-worker
  fi
  names+=(judge)
fi
[ "${#names[@]}" -gt 0 ] || { echo "[workers] nothing to run: set QUEUE_URL, TRAIN_QUEUE_URL or JUDGE_QUEUE_URL"; exit 1; }

# Every worker has left (no work on its queue, or its certificate revoked): the instance goes too.
for n in "${names[@]}"; do docker wait "$n" || true; done
shutdown -h now
