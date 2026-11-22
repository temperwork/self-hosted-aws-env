# Running workers

Workers are temperwork's compiled worker, `temperwork-worker`, packaged in container images. They run in your account with the role this repository creates. They take work from your queues, read inputs from your data bucket, write outputs back to it, update run records in the control bucket, and call temperwork.com only to hold a lease for their certificate.

## Images

The worker images are on [GitHub Container Registry](https://github.com/tonymeng?tab=packages&repo_name=gallery). Use their `customer-prod-latest` tags: those images trust only temperwork.com's certificate root.

## Settings

Each worker needs these environment variables:

```bash
terraform output worker_env
```

| Variable | Value |
|---|---|
| `STUDIO_CONNECTION_ID` | The id you gave the environment in temperwork |
| `STUDIO_CONTROL_URI` | `worker_env.STUDIO_CONTROL_URI`: the control bucket's `.studio/` |
| `STUDIO_LORA_URI` | `worker_env.STUDIO_LORA_URI`: the data bucket's `<prefix>loras/`, where trainings put LoRAs |
| `STUDIO_QUEUE_URL` | `worker_env.STUDIO_QUEUE_URL` (runs) |
| `STUDIO_TRAIN_QUEUE_URL` | `worker_env.STUDIO_TRAIN_QUEUE_URL` (trainer pods) |
| `AWS_REGION` | `worker_env.AWS_REGION` |
| `STUDIO_URL` | `https://temperwork.com` |
| `STUDIO_ENROLL_TOKEN` | The token from the environment's card: **⋯ → Make an enrollment token**. Used only on first start |

A judge worker takes `STUDIO_JUDGE_QUEUE_URL` (or the flags in `terraform output judge_worker_args`). If you host judge models, it also takes `STUDIO_QUEUES` from `terraform output judge_worker_env`.

Workers on EC2 need **no access keys**: the SDK picks up the role from the instance profile.

A pod serves one base model. Give a runs queue only pods of one model. A worker leaves when its queue has been empty for a while (`STUDIO_POD_IDLE_S`, `STUDIO_JUDGE_IDLE_S`), or when its certificate is revoked.

### Keeping the enrollment token secret

Store the token in a secret store, not in the user data. The EC2 script reads it from SSM Parameter Store:

```bash
aws ssm put-parameter --name /temperwork/enroll-token --type SecureString --value '<token>'
```

Set `enroll_token_parameter = "/temperwork/enroll-token"` in Terraform so the worker role can read it.

## EC2

[`modules/temperwork/ec2-user-data.sh`](../modules/temperwork/ec2-user-data.sh) (also `terraform output ec2_user_data_path`) is the whole setup. It runs one pod container per GPU and, optionally, a judge worker beside them. It shuts the instance down when every worker has left.

1. Fill in the settings block at the top of the script from `terraform output`.
2. Launch a GPU instance on the **AWS Deep Learning Base GPU AMI (Amazon Linux 2023)**:

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
- `terminate` means the instance is gone once its workers leave, so you pay only while there is work.
- The models are about 40–70 GB. The script uses the instance's local NVMe disk if it has one. Otherwise, give the root volume enough space.

To run several instances against the same queue, put the same user data in a launch template and use an Auto Scaling group.

If you keep the images in your own ECR, set `REGISTRY_LOGIN='ecr'` in the script and give the worker role pull access:

```hcl
resource "aws_iam_role_policy_attachment" "ecr" {
  role       = module.temperwork.worker_role_name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}
```

## Running workers another way

This repository sets up workers on **EC2**. The worker images aren't tied to it: you can run them however you like, for example on ECS, Kubernetes or GPUs outside AWS.

Whatever runs them, a worker only needs to reach the same things:

- **The queues**: it takes work from them (`STUDIO_QUEUE_URL`, `STUDIO_TRAIN_QUEUE_URL`, `STUDIO_JUDGE_QUEUE_URL`).
- **The control bucket**: it reads the run records the control plane wrote and updates them (`STUDIO_CONTROL_URI`).
- **The data bucket**: it reads inputs and writes outputs.
- **temperwork.com**: it enrolls, then holds a lease for its certificate.

The control plane only ever talks to the queues and the control bucket, so it doesn't matter to temperwork where your workers run. The `<name>-tw-worker` role trusts only EC2, so elsewhere give your workers credentials of your own with the same permissions, and the settings above.

## Scaling

temperwork doesn't start workers in your account. Start them with your own scaling, based on queue depth (`ApproximateNumberOfMessagesVisible` on the queues): an Auto Scaling group with the user data in its launch template, or by hand. Workers leave on their own once their queue is empty.

## Troubleshooting

| Symptom | Check |
|---|---|
| Worker exits right away | Its log. Common causes: an expired or used enrollment token, or no route to temperwork.com |
| Runs stay queued | A worker is running for **that** queue, and holds a lease (its card on the Environments page lists enrolled workers) |
| `AccessDenied` on S3 from a worker | The worker is using the `<name>-tw-worker` role. On EC2, the metadata hop limit is 2 |
| LLM judge steps fail | The Anthropic models are enabled in Bedrock (Model access) in your region, and in the regions of the US or global inference profiles you use. Workers can't enable them |
| Files don't load in temperwork | See [browser-access.md](browser-access.md) |
