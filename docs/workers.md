# Running workers

Workers are temperwork's compiled worker, `temperwork-worker`, packaged in container images. They run in your account with the role this repository creates. They take work from your queues, read inputs from your data bucket, write outputs back to it, update run records in the control bucket, and call temperwork.com only to hold a lease for their certificate.

## Images

The worker images are on [GitHub Container Registry](https://github.com/tonymeng?tab=packages&repo_name=gallery). Use their `customer-prod-latest` tags: those images trust only temperwork.com's certificate root.

## Three ways to run them

| | What runs | When to use |
|---|---|---|
| [**`ec2_workers`**](#ec2-workers-from-the-module) | The module keeps that many always-on GPU instances (an Auto Scaling group) | The simplest setup: set a number and apply |
| [**Your own EC2 instances**](#your-own-ec2-instances) | Instances you launch with the module's user data script; each powers off when its queue is empty | You want to pay only while there's work, or scale your own way |
| [**Anything else**](#running-workers-another-way) | The images on ECS, Kubernetes, GPUs outside AWS... | You already run containers somewhere. Leave `ec2_workers` at 0 and use the module's outputs |

All three need the enrollment token in SSM first.

## The enrollment token

On the environment's card in temperwork, choose **⋯ → Make an enrollment token**. A worker uses it once, on its first start, to get its certificate. Store it in SSM Parameter Store, not in user data:

```bash
aws ssm put-parameter --name /temperwork/enroll-token --type SecureString --value '<token>'
```

Then set `enroll_token_parameter = "/temperwork/enroll-token"`, so the workers' role can read it.

## EC2 workers from the module

```hcl
ec2_workers            = 1
worker_image           = "<registry>/qwen-image:customer-prod-latest"
enroll_token_parameter = "/temperwork/enroll-token"
ec2_subnet_ids         = ["subnet-..."]   # examples/complete fills this in
```

Each instance runs one pod per GPU, taking work from `worker_queue` (`runs`, or `trainings` for a trainer image). With `judge_worker_image`, it also runs a judge worker on the judges queue. The workers stay up waiting for work, so **you pay for the instances while they run**, whether or not there's work. Set `ec2_workers = 0` to stop them.

| Input | Default | |
|---|---|---|
| `ec2_workers` | `0` | How many instances |
| `worker_image` | (required) | The pods' image |
| `worker_queue` | `runs` | `runs` or `trainings` |
| `judge_worker_image` | `""` | Also run a judge worker |
| `ec2_instance_type` | `g6e.xlarge` | One pod per GPU |
| `ec2_subnet_ids` | (required) | Must reach temperwork.com, the image registry, Hugging Face and S3 |
| `ec2_security_group_ids` | `[]` | Empty: one with no inbound and all outbound |
| `ec2_ami_id` | latest Deep Learning Base GPU AMI (Amazon Linux 2023) | Needs Docker and the NVIDIA container toolkit |
| `ec2_volume_size` | `200` | GB. Models take 40 to 70 GB unless the instance has local NVMe |
| `environment_id` | `name` | The id you gave the environment in temperwork |

An image in ECR gets pull access automatically. Changing these settings updates the launch template; running instances keep the old one until they're replaced.

## Your own EC2 instances

[`modules/temperwork/ec2-user-data.sh`](../modules/temperwork/ec2-user-data.sh) (`terraform output ec2_user_data_path`) is the same script the module uses. Fill in the settings block at its top from `terraform output`, then launch a GPU instance on the **AWS Deep Learning Base GPU AMI (Amazon Linux 2023)**:

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

For an image in your own ECR, set `REGISTRY_LOGIN='ecr'` in the script and attach `AmazonEC2ContainerRegistryReadOnly` to `terraform output worker_role_name`.

## Running workers another way

The images aren't tied to EC2. Leave `ec2_workers` at 0 and run them however you like. Whatever runs them, a worker only needs to reach:

- **The queues**: it takes work from them.
- **The control bucket**: it reads the run records the control plane wrote and updates them.
- **The data bucket**: it reads inputs and writes outputs.
- **temperwork.com**: it enrolls, then holds a lease for its certificate.

The control plane only ever talks to the queues and the control bucket, so it doesn't matter to temperwork where your workers run. The module's outputs have everything a worker needs:

| Output | |
|---|---|
| `worker_env` | Every worker's environment variables (add `STUDIO_ENROLL_TOKEN`). A pod takes `STUDIO_QUEUE_URL` or `STUDIO_TRAIN_QUEUE_URL`; a judge worker takes `STUDIO_JUDGE_QUEUE_URL` |
| `judge_worker_env` | A judge worker's queues for self-hosted judge models, and its Bedrock region |
| `worker_policy_json` | The workers' IAM policy. Attach it to the role or user your workers run as (the `<name>-tw-worker` role trusts only EC2) |
| `queues` | Each queue's URL and ARN |
| `data_bucket_arn`, `control_bucket_arn` | The buckets |

A pod serves one base model: give a queue only pods of one model.

## Troubleshooting

| Symptom | Check |
|---|---|
| Worker exits right away | Its log. Common causes: an expired or used enrollment token, or no route to temperwork.com |
| Runs stay queued | A worker is running for **that** queue, and holds a lease (its card on the Environments page lists enrolled workers) |
| `AccessDenied` on S3 from a worker | The worker is using the `<name>-tw-worker` role. On EC2, the metadata hop limit is 2 |
| LLM judge steps fail | The Anthropic models are enabled in Bedrock (Model access) in your region, and in the regions of the US or global inference profiles you use. Workers can't enable them |
| Files don't load in temperwork | See [browser-access.md](browser-access.md) |
