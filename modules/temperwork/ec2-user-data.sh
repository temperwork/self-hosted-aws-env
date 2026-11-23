#!/bin/bash
# EC2 user data that runs a temperwork environment's workers on one instance.
# See docs/workers.md. `terraform output` of the temperwork module fills in the
# settings block below.
#
# On a GPU instance (the AWS Deep Learning Base GPU AMI, Amazon Linux 2023:
# docker and the NVIDIA container toolkit) it runs the pod service, one
# container per GPU, from a worker image serving one model (POD_MODEL) and
# one kind of work (POD_RUNS: inference, training, or grading for a judge
# model), on that
# model's queue. With JUDGE_QUEUE_URL set it also runs a judge worker, which
# needs no GPU: from JUDGE_IMAGE (the judge worker image, with temperwork's
# automation judges built in), else from IMAGE (no automation steps). With
# only JUDGE_QUEUE_URL (a CPU instance) it runs the judge worker alone.
#
# Launch it:
#   - with the module's worker instance profile (<name>-tw-worker),
#     created with enroll_token_parameter set to TOKEN_PARAM below
#   - in a subnet that reaches temperwork.com (workers call home for a
#     lease), the image registry, Hugging Face (models download at boot) and S3
#   - with --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2
#     (the containers use the instance profile)
#   - with --instance-initiated-shutdown-behavior terminate: each container
#     leaves once its queue is empty, and then the instance powers off
#
# The enrollment token (the environment's card on temperwork's Environments
# page: Make an enrollment token) is read from SSM Parameter Store, never
# written here. A worker keeps its certificate on the instance's disk, so one
# enrollment serves its restarts.
set -euxo pipefail

# --- your settings: the module's outputs (worker_env, workers, judge_worker). Each
# can also come from the environment (set, even to empty, it wins): the module's
# EC2 workers set them that way ---
IMAGE="${IMAGE-ghcr.io/temperwork/qwen-image:customer-prod-latest}"   # a worker image (docs/workers.md, "Images")
REGISTRY_LOGIN="${REGISTRY_LOGIN-none}"          # ecr: log in to IMAGE's ECR registry with the profile; none: a public registry
STUDIO_URL="${STUDIO_URL-https://temperwork.com}"
STUDIO_CONNECTION_ID="${STUDIO_CONNECTION_ID-<the id you gave the environment>}"
STUDIO_CONTROL_URI="${STUDIO_CONTROL_URI-<worker_env STUDIO_CONTROL_URI>}"   # in the control bucket
STUDIO_LORA_URI="${STUDIO_LORA_URI-<worker_env STUDIO_LORA_URI>}"         # in the data bucket
AWS_REGION="${AWS_REGION-us-west-2}"
POD_MODEL="${POD_MODEL-}"                 # the model the image serves (env STUDIO_POD_MODEL in workers.<key>)
POD_RUNS="${POD_RUNS-}"                   # inference, training, or grading for a judge model (env STUDIO_POD_RUNS); empty: the image decides
QUEUE_URL="${QUEUE_URL-}"                 # inference: the model's queue (workers.<key>.queue_url)
QUEUE_ID="${QUEUE_ID-}"                   # inference: its id, model:<model> (workers.<key>.queue_id)
TRAIN_QUEUE_URL="${TRAIN_QUEUE_URL-}"     # training: the model's trainings queue
TRAIN_QUEUE_ID="${TRAIN_QUEUE_ID-}"       # training: its id, training:<model>
MODEL_QUEUE_URL="${MODEL_QUEUE_URL-}"     # inference, or a judge model's grading, on the model's own queue
MODEL_QUEUE_ID="${MODEL_QUEUE_ID-}"       # a judge model: its queue's id, conn:<id>:model:<model>
JUDGE_QUEUE_URL="${JUDGE_QUEUE_URL-}"             # also run a judge worker here: judge_worker_args' --queue-url
JUDGE_QUEUES="${JUDGE_QUEUES-}"           # the judge worker's self-hosted judge models' queues (judge_worker.env STUDIO_QUEUES)
JUDGE_IMAGE="${JUDGE_IMAGE-}"                 # the judge worker image (ghcr.io/temperwork/judge-worker:customer-prod-latest); empty: IMAGE's worker, without automation judges
TOKEN_PARAM="${TOKEN_PARAM-/temperwork/enroll-token}"   # the SSM parameter (SecureString) holding the enrollment token
ROOT_SHA256="${ROOT_SHA256-}"                 # only for an image not pinned to temperwork.com's root (the customer images are): that root's fingerprint
IDLE_S="${IDLE_S-600}"                     # a worker leaves after its queue has been empty this long (0: never; always-on workers)
MAX_MINUTES="${MAX_MINUTES-0}"                  # power off after this long whatever happens (0: never)
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
pods=0; { [ -n "$QUEUE_URL" ] || [ -n "$TRAIN_QUEUE_URL" ] || [ -n "$MODEL_QUEUE_URL" ]; } && pods=1
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
export STUDIO_ENROLL_TOKEN STUDIO_URL STUDIO_CONNECTION_ID STUDIO_CONTROL_URI STUDIO_LORA_URI AWS_REGION
set -x
TOKEN=$(curl -sfX PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' || true)
ITYPE=$(curl -sf -H "X-aws-ec2-metadata-token: $TOKEN" http://169.254.169.254/latest/meta-data/instance-type || true)

common=(-d --stop-timeout 100 -e STUDIO_ENROLL_TOKEN -e STUDIO_URL
        -e STUDIO_CONNECTION_ID -e STUDIO_CONTROL_URI -e STUDIO_LORA_URI -e AWS_REGION)
[ -n "$ROOT_SHA256" ] && common+=(-e STUDIO_ROOT_SHA256="$ROOT_SHA256")
# IDLE_S=0: the workers stay, waiting for work (an Auto Scaling group keeps them).
if [ "$IDLE_S" -gt 0 ]; then
  idle_pod=(-e STUDIO_POD_IDLE_S="$IDLE_S"); idle_judge=(-e STUDIO_JUDGE_IDLE_S="$IDLE_S")
else
  idle_pod=(-e STUDIO_POD_STAY=1); idle_judge=()
fi
names=()
pod() {   # name, docker args for its device...
  local name=$1; shift
  docker rm -f "$name" 2>/dev/null || true
  # --ipc=host: a training's data loader outgrows docker's 64 MB /dev/shm.
  docker run "${common[@]}" --restart on-failure --name "$name" --hostname "$name" "$@" --ipc=host \
    -v "$WS:/workspace" -e STUDIO_QUEUE_URL="$QUEUE_URL" -e STUDIO_TRAIN_QUEUE_URL="$TRAIN_QUEUE_URL" \
    -e STUDIO_MODEL_QUEUE_URL="$MODEL_QUEUE_URL" -e STUDIO_MODEL_QUEUE_ID="$MODEL_QUEUE_ID" -e STUDIO_QUEUE_ID="$QUEUE_ID" -e STUDIO_TRAIN_QUEUE_ID="$TRAIN_QUEUE_ID" \
    -e STUDIO_POD_MODEL="$POD_MODEL" -e STUDIO_POD_RUNS="$POD_RUNS" \
    "${idle_pod[@]}" -e STUDIO_POD_DRAIN_S=90 -e STUDIO_POD_INSTANCE_TYPE="$ITYPE" \
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
  judge=(-v "$WS/judge:/state" -e STUDIO_JUDGE_STATE=/state -e STUDIO_JUDGE_QUEUE_URL="$JUDGE_QUEUE_URL" -e STUDIO_QUEUES="$JUDGE_QUEUES"
         "${idle_judge[@]}")
  if [ -n "$JUDGE_IMAGE" ]; then
    chown 65532:65532 "$WS/judge"
    docker run "${common[@]}" --name judge --hostname judge "${judge[@]}" "$JUDGE_IMAGE"
  else
    docker run "${common[@]}" --name judge --hostname judge --entrypoint /opt/qwen/temperwork-worker \
      "${judge[@]}" "$IMAGE" judge-worker
  fi
  names+=(judge)
fi
[ "${#names[@]}" -gt 0 ] || { echo "[workers] nothing to run: set QUEUE_URL, TRAIN_QUEUE_URL, MODEL_QUEUE_URL or JUDGE_QUEUE_URL"; exit 1; }

# Every worker has left (no work on its queue, or its certificate revoked): the instance goes too.
for n in "${names[@]}"; do docker wait "$n" || true; done
shutdown -h now
