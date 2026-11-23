# Running workers

Workers are temperwork's compiled worker, `temperwork-worker`, packaged in container images. They run in your account with the role this repository creates. They take work from your queues, read inputs from your data bucket, write outputs back to it, update run records in the control bucket, and call temperwork.com only to hold a lease for their certificate.

## Images

temperwork publishes the worker images on the GitHub Container Registry, public, so pulling them needs no sign-in. Each is named after the model it serves (the `model` field beside it); `qwen-vl` serves several judge models, one per instance:

| Image | Model | Work |
|---|---|---|
| `ghcr.io/temperwork/qwen-image-edit-2511` | `qwen-image-edit-2511` | `inference` |
| `ghcr.io/temperwork/qwen-image-edit-2511-trainer` | `qwen-image-edit-2511` | `training` |
| `ghcr.io/temperwork/ltx-2.5` | `ltx-2.5` | `inference` |
| `ghcr.io/temperwork/ltx-2.5-trainer` | `ltx-2.5` | `training` |
| `ghcr.io/temperwork/qwen-vl` | `qwen3-vl-8b`, `qwen2-audio-7b`, `qwen3.5-9b`, `qwopus-9b` | judge models (`judge_worker.models`) |
| `ghcr.io/temperwork/judge-worker` | | the judge worker (`judge_worker.image`) |

Use their `customer-prod-latest` tags, or a `customer-prod-sha-<commit>` tag to pin one build: those images trust only temperwork.com's certificate root. The workers' subnets must reach `ghcr.io` and `pkg-containers.githubusercontent.com` (where it serves the layers). If many instances pull from behind one NAT address and GitHub throttles them, log the instances in to `ghcr.io` with any GitHub account's token that can read packages.

The images contain only temperwork's worker, the model's runtime and their dependencies; model weights download when a worker starts, under their authors' licenses. Each image carries its license and the third-party notices in `/usr/share/doc/temperwork/`.

## Workers, models and queues

Each worker image serves **one model** and does **one kind of work**, on that model's own queue:

| | What it does | Its queue's id |
|---|---|---|
| `workers` entry, `work = "inference"` | Runs pipeline steps on the model | `model:<model>` |
| `workers` entry, `work = "training"` | Trains LoRAs for the model | `training:<model>` |
| `judge_worker.models` entry | A judge model you host, judging the files of LLM judge steps | `model:<model>` |
| `judge_worker` | The judge worker: runs judges, and hands LLM steps to your judge models | `judges` |

temperwork sends work only to the queues your environment lists (the `environment` output), so it never sends work for a model you don't run.

```hcl
workers = {
  edit    = { model = "qwen-image-edit-2511", work = "inference", image = "ghcr.io/temperwork/qwen-image-edit-2511:customer-prod-latest", instances = 1 }
  trainer = { model = "qwen-image-edit-2511", work = "training", image = "ghcr.io/temperwork/qwen-image-edit-2511-trainer:customer-prod-latest" }
}
judge_worker = {
  image     = "ghcr.io/temperwork/judge-worker:customer-prod-latest"
  instances = 1
  models    = { vl = { model = "qwen3-vl-8b", image = "ghcr.io/temperwork/qwen-vl:customer-prod-latest" } }
}
```

The key of each entry (`edit`, `trainer`, `vl`) names its queue, `<name>-<key>.fifo`, and its EC2 resources, `<name>-tw-<key>`. Keys are 1 to 20 lowercase letters, digits or hyphens, and are shared between `workers` and `judge_worker.models`, so they must differ.

| Field | Default | |
|---|---|---|
| `model` | (required) | The model, as temperwork names it |
| `work` | (required) | `workers` only: `inference` or `training` |
| `image` | `""` | The worker image (required with `instances`) |
| `instances` | `0` | Always-on EC2 instances running it. 0: run it your own way |
| `instance_type` | `g6e.xlarge` | One pod per GPU |
| `volume_size` | `200` | GB. Models take 40 to 70 GB unless the instance has local NVMe |
| `ami_id` | latest Deep Learning Base GPU AMI (Amazon Linux 2023) | Needs Docker and the NVIDIA container toolkit |

`judge_worker` itself takes `image`, `instances` (default 0), `instance_type` (default `m7i.large`: it needs no GPU), `volume_size` (30) and `ami_id` (default: the latest Amazon Linux 2023). Without a judge model of its own, an LLM step on that model calls the model's API.

## The enrollment token

On the environment's card in temperwork, choose **⋯ → Make an enrollment token**. A worker uses it once, on its first start, to get its certificate. Store it in SSM Parameter Store, not in user data:

```bash
aws ssm put-parameter --name /temperwork/enroll-token --type SecureString --value '<token>'
```

Then set `enroll_token_parameter = "/temperwork/enroll-token"`, so the workers' role can read it.

## Three ways to run them

| | What runs | When to use |
|---|---|---|
| [**`instances` in the module**](#ec2-workers-from-the-module) | Always-on EC2 instances the module keeps running | The simplest setup: set a number and apply |
| [**Your own EC2 instances**](#your-own-ec2-instances) | Instances you launch with the module's user data script; each powers off when its queue is empty | You want to pay only while there's work, or scale your own way |
| [**Anything else**](#running-workers-another-way) | The images on ECS, Kubernetes, GPUs outside AWS... | You already run containers somewhere |

You can mix them: each entry decides for itself.

## EC2 workers from the module

Give an entry, a judge model or `judge_worker` `instances` > 0, set `enroll_token_parameter` and `ec2_subnet_ids` (`examples/complete` fills those in), and apply. For each, the module keeps that many instances running in an Auto Scaling group, each with one pod per GPU serving the entry's model on its queue. The workers stay up waiting for work, so **you pay for the instances while they run**, whether or not there's work. Set `instances = 0` to stop them.

| Input | Default | |
|---|---|---|
| `ec2_subnet_ids` | (required) | Must reach temperwork.com, the image registry, Hugging Face and S3 |
| `ec2_security_group_ids` | `[]` | Empty: one with no inbound and all outbound |
| `environment_id` | `name` | The id you gave the environment in temperwork |

An image in ECR gets pull access automatically. Changing an entry updates its launch template; running instances keep the old one until they're replaced.

## Your own EC2 instances

[`modules/temperwork/ec2-user-data.sh`](../modules/temperwork/ec2-user-data.sh) (`terraform output ec2_user_data_path`) is the same script the module uses. Fill in the settings block at its top from `terraform output worker_env` and the entry's settings in `terraform output workers`, then launch a GPU instance on the **AWS Deep Learning Base GPU AMI (Amazon Linux 2023)**:

```bash
aws ec2 run-instances \
  --image-id <dlami-id> --instance-type g6e.xlarge \
  --iam-instance-profile Name=$(terraform output -raw worker_instance_profile) \
  --subnet-id <subnet> --security-group-ids <sg> \
  --metadata-options HttpTokens=required,HttpPutResponseHopLimit=2 \
  --instance-initiated-shutdown-behavior terminate \
  --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=200}' \
  --user-data file://$(terraform output -raw ec2_user_data_path)
```

- `HttpPutResponseHopLimit=2` lets the containers reach the instance profile's credentials.
- Each worker leaves once its queue has been empty for `IDLE_S` (default 600 s), and then the instance powers off. With `terminate`, it's gone, so you pay only while there's work.
- Start instances when work waits, based on queue depth (`ApproximateNumberOfMessagesVisible`): by hand, or with your own scaling. temperwork doesn't start workers in your account.

To pull from a copy in your own ECR instead, set `REGISTRY_LOGIN='ecr'` in the script and attach `AmazonEC2ContainerRegistryReadOnly` to `terraform output worker_role_name`.

## Running workers another way

The images aren't tied to EC2. Leave an entry's `instances` at 0 and run its image however you like. Whatever runs it, a worker only needs to reach:

- **Its queue**: it takes work from it.
- **The control bucket**: it reads the run records the control plane wrote and updates them.
- **The data bucket**: it reads inputs and writes outputs.
- **temperwork.com**: it enrolls, then holds a lease for its certificate.

The control plane only ever talks to the queues and the control bucket, so it doesn't matter to temperwork where your workers run. The module's outputs have everything a worker needs:

| Output | |
|---|---|
| `worker_env` | What every worker needs (add `STUDIO_ENROLL_TOKEN`) |
| `workers` | Each entry's queue, and its pods' settings (`env`: the model, the kind of work, the queue's URL and id) |
| `judge_worker` | The judge worker's settings (`env`: the judges queue and the judge models' queues), and each judge model like a `workers` entry (`models`) |
| `worker_policy_json` | The workers' IAM policy. Attach it to the role or user your workers run as (the `<name>-tw-worker` role trusts only EC2) |
| `queues` | Each queue's URL and ARN, by id |
| `data_bucket_arn`, `control_bucket_arn` | The buckets |

## Troubleshooting

| Symptom | Check |
|---|---|
| Worker exits right away | Its log. Common causes: an expired or used enrollment token, or no route to temperwork.com |
| Runs stay queued | A worker is running for **that** queue, and holds a lease (its card on the Environments page lists enrolled workers) |
| `AccessDenied` on S3 from a worker | The worker is using the `<name>-tw-worker` role. On EC2, the metadata hop limit is 2 |
| LLM judge steps fail | The Anthropic models are enabled in Bedrock (Model access) in your region, and in the regions of the US or global inference profiles you use. Workers can't enable them |
| Files don't load in temperwork | See [browser-access.md](browser-access.md) |
