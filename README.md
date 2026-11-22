# temperwork self-hosted AWS environment

Terraform for running [temperwork](https://temperwork.com) workloads in **your own AWS account**.

temperwork is split in two. The **control plane** is temperwork itself, at temperwork.com: it plans runs, queues them and tracks them. The **data plane** is in your AWS account: your workers do the work, and your data stays in your data bucket. The control plane never holds your data and can't write to it. It signs links to your files, and those links work only from inside your network.

This repository is a Terraform module, [`modules/temperwork`](modules/temperwork), that you add to your existing AWS setup. It creates the queues, two buckets (one for your data, a separate one for the control plane's records), the IAM role the control plane assumes, and an IAM role for your workers. [`examples/complete`](examples/complete) also builds a VPC around it, for an account that has none.

```
          temperwork.com: the control plane
                       │  assumes temperwork-studio-<name>  (with your external id)
                       │  ├─ sqs:SendMessage            → your queues
                       │  ├─ s3 read/write              → <name>-control/.studio/ only
                       │  └─ signs GET links            → <name>-data, usable only through your VPC endpoint
                       ▼
 ┌──────────── your AWS account: the data plane ──────────────────────┐
 │  SQS FIFO: <name>-runs, -trainings, -judges, -model-*              │
 │  S3: <name>-data      datasets, outputs, LoRAs (control plane:     │
 │                       no writes, no reads from outside your VPC)   │
 │  S3: <name>-control   the control plane's records (.studio/)       │
 │  IAM: <name>-tw-worker  ← your EC2 / ECS / EKS workers             │
 └────────────────────────────────────────────────────────────────────┘
        ▲
        └── your people's browsers open files through your S3 VPC endpoint
```

## Contents

| Path | What it is |
|---|---|
| [`modules/temperwork`](modules/temperwork) | **The module.** Queues, data bucket (or your existing one), control bucket, the control-plane role, bucket policies, worker role and instance profile, plus [`ec2-user-data.sh`](modules/temperwork/ec2-user-data.sh) for running workers on EC2. |
| [`examples/existing-network`](examples/existing-network) | The module alone, for an account that already has a VPC with an S3 endpoint. It can also use a bucket you already have. |
| [`examples/complete`](examples/complete) | The module plus everything it needs in an empty account: a VPC, S3 endpoints and, optionally, an AWS Client VPN. |
| [`docs/`](docs) | [How access works](docs/security-model.md), [browser access options](docs/browser-access.md), [running workers](docs/workers.md). |

## Prerequisites

- An AWS account, and credentials that can create IAM roles, S3 buckets and SQS queues (and VPC resources if you use `examples/complete`).
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer, or OpenTofu 1.6 or newer.
- A temperwork account. Open **Settings → Environments → Add environment** in temperwork. The form shows two values you'll need:
  - the **role ARN**: the control plane's own role, which your account will trust
  - a random **external id**

  Leave the form open. You'll finish it after `terraform apply`.

## Quick start

### 1. Choose an example

- **Already have a VPC with an S3 endpoint?** Use `examples/existing-network`, or add the module to your own Terraform (see [Using the module](#using-the-module)).
- **No network for this yet?** Use `examples/complete`. It creates a VPC whose S3 endpoint is the only way to read your data.

### 2. Configure

```bash
git clone https://github.com/temperwork/self-hosted-aws-env.git
cd self-hosted-aws-env/examples/complete     # or examples/existing-network
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. At a minimum, set:

```hcl
name            = "acme"                              # names the buckets (acme-data, acme-control), queues and roles
region          = "us-west-2"
temperwork_role_arn = "arn:aws:iam::...:role/..."         # from the Add environment form
external_id     = "..."                               # from the Add environment form
```

`terraform.tfvars` is git-ignored. Keep the external id out of version control.

Before you go further, check how people's browsers will reach your files. See [Browser access](#browser-access).

### 3. Apply

```bash
terraform init
```

```bash
terraform plan
```

```bash
terraform apply
```

Store the state somewhere durable. Each example's `main.tf` has a commented-out S3 backend block you can enable.

### 4. Finish adding the environment in temperwork

```bash
terraform output environment
```

Copy the values into the Add environment form:

| Form field | Output |
|---|---|
| Region | `environment.region` |
| Runs queue URL | `environment.queue_url` |
| Judges queue URL | `environment.judge_queue_url` |
| Trainings queue URL | `environment.train_queue_url` |
| Data root | `environment.data_root` |
| Control URI | `environment.control_uri` |
| Role ARN | `environment.credentials.role_arn` |
| External id | the same value you put in `terraform.tfvars` |

Save the form, then click **Test** on the environment's card. Test checks each queue and writes and reads back a file in the control bucket.

### 5. Start workers

On the environment's card, choose **⋯ → Make an enrollment token**. Then start workers with the role this repository created. [docs/workers.md](docs/workers.md) covers EC2 (with [`ec2-user-data.sh`](modules/temperwork/ec2-user-data.sh)), ECS, EKS and GPUs outside AWS.

```bash
terraform output worker_env
```

```bash
terraform output judge_worker_args
```

## Browser access

When someone opens a file in temperwork, their browser downloads it directly from your data bucket using a link temperwork signed. Those links work only through your **S3 VPC endpoint** (`vpc_endpoint_id` / `vpc_endpoint_ids`), so your people open files on your VPN or inside your VPC.

The data bucket also needs a CORS rule for temperwork's origin (`temperwork_origins`, default `https://temperwork.com`). The module adds it.

[docs/browser-access.md](docs/browser-access.md) covers the details, including the optional Client VPN in `examples/complete`.

## What gets created

`modules/temperwork`:

| Resource | Name | Purpose |
|---|---|---|
| SQS FIFO queue | `<name>-runs.fifo` | Runs, for the pod service |
| SQS FIFO queue | `<name>-trainings.fifo` | Trainings, for trainer pods |
| SQS FIFO queue | `<name>-judges.fifo` | Judge runs, for judge workers |
| SQS FIFO queue | `<name>-model-<model>.fifo` | One per entry in `judge_models`: grading work for the model pods you host |
| S3 bucket | `<name>-data` (or `bucket`) | Your datasets, and what your workers write: outputs (`<prefix>datasets/`) and LoRAs (`<prefix>loras/`) |
| S3 bucket policy | on the data bucket | Denies the control-plane role any read that doesn't come through your VPC endpoint |
| S3 CORS rule | on the data bucket | Lets temperwork's page `GET` from the bucket |
| S3 bucket | `<name>-control` (or `control_bucket`) | **Separate from your data.** temperwork's records, shared with your workers (`.studio/`) |
| IAM role | `temperwork-studio-<name>` | The control-plane role: assumed by temperwork with your external id |
| IAM role + instance profile | `<name>-tw-worker` | Attached to your workers |

All queues are encrypted at rest with SQS-managed keys.

`examples/complete` adds a VPC, public subnets, an internet gateway, an S3 gateway endpoint and, with `vpn = true`, an S3 interface endpoint and an AWS Client VPN endpoint.

### Cost

The environment itself costs almost nothing while it's idle: SQS, S3 and IAM are billed by use. The S3 gateway endpoint is free. With `vpn = true`, the Client VPN and the interface endpoint are billed by the hour. In us-west-2 that is about $0.10/h per subnet association, $0.05/h per connection and $0.01/h for the interface endpoint, so turn the VPN off when no one needs it. GPU instances are billed by AWS as usual. Workers shut down when their queue is empty.

## Security model

In short:

- The control-plane role can **send** messages to your queues.
- It can **read and write only the control bucket** (`<name>-control/.studio/`), a bucket separate from your data that holds run records, pipelines, worker heartbeats and dataset manifests.
- It has `s3:GetObject` on the data bucket only so the read links it signs for your browsers work. It can't use that to download your data: the bucket policy denies it any request that doesn't come through your VPC endpoint, so only a browser inside your network can open the links ([why](docs/security-model.md#why-the-control-plane-has-s3getobject-on-your-data)). It can't write there at all.
- The control-plane role can be assumed only by the control plane's own role, and only with your external id.
- Your workers use their own role. They call temperwork.com only to hold a lease for their certificate. Your data stays in your account.
- Judge workers' LLM steps call Claude through **Bedrock in your account**, so images never leave it.

To revoke access, delete the environment in temperwork and its workers stop within one lease. Or run `terraform destroy`, or delete the `temperwork-studio-<name>` role.

[docs/security-model.md](docs/security-model.md) lists every permission.

## Using the module

```hcl
module "temperwork" {
  source = "github.com/temperwork/self-hosted-aws-env//modules/temperwork?ref=v0.1.0"

  name            = "acme"
  temperwork_role_arn = var.temperwork_role_arn
  external_id     = var.external_id

  vpc_endpoint_id = aws_vpc_endpoint.s3.id
}
```

The module has no `provider` block. It uses your `aws` provider and its region. Pin `ref` to a release tag.

### Inputs

| Name | Default | Description |
|---|---|---|
| `name` | (required) | Names the queues, buckets and roles. 3–42 lowercase letters, digits or hyphens. |
| `temperwork_role_arn` | (required) | The control plane's own role, from the Add environment form. |
| `external_id` | (required) | The external id from the Add environment form (at least 16 characters). |
| `bucket` | `""` | An existing data bucket. Empty creates `<name>-data`. |
| `control_bucket` | `""` | An existing, empty bucket for temperwork's records. Must differ from `bucket`. Empty creates `<name>-control`. |
| `bucket_policy_source_documents` | `[]` | With an existing bucket: its current policy JSON, so its statements are kept. The module writes the bucket's whole policy. |
| `prefix` | `"temperwork/"` | Where in the data bucket workers write outputs and LoRAs. |
| `temperwork_origins` | `["https://temperwork.com"]` | Origins allowed by the data bucket's CORS rule. |
| `vpc_endpoint_id`, `vpc_endpoint_ids` | (one required) | Your S3 VPC endpoints: the only way temperwork's links to your data work. |
| `worker_principals` | EC2, ECS tasks | Services that can assume the worker role. Add `pods.eks.amazonaws.com` for EKS. |
| `worker_assumers` | `[]` | IAM principals that can assume the worker role (workers outside AWS). |
| `judge_models` | `[]` | Self-hosted judge models. Each gets a queue. |
| `enroll_token_parameter` | `""` | An SSM parameter holding the enrollment token. The worker role can then read it. |
| `allow_bedrock_model_subscription` | `true` | Lets workers subscribe the account to Anthropic models on first use. |

### Outputs

`environment`, `worker_env`, `bucket`, `control_bucket`, `control_uri`, `control_plane_role_arn`, `worker_role_arn`, `worker_role_name`, `worker_instance_profile`, `ec2_user_data_path`, `judge_worker_args`, `judge_worker_env`, `judge_model_env`. Each output's description is in [`outputs.tf`](modules/temperwork/outputs.tf).

## Updating and removing

- **Update:** pull a newer release, then run `terraform plan` and `terraform apply`. Read the release notes first.
- **Remove:** delete the environment in temperwork, then run `terraform destroy`. Buckets this module created must be emptied before they can be destroyed. A bucket you passed in with `bucket` or `control_bucket` is never deleted, but the policy and CORS rule the module put on it are removed.

## Development

```bash
terraform fmt -check -recursive
```

```bash
cd modules/temperwork && terraform init -backend=false && terraform test
```

The tests use a mocked AWS provider, so no account is needed. CI runs format, validate and tests on every pull request ([`.github/workflows/terraform.yml`](.github/workflows/terraform.yml)).

## Support

Questions go to your temperwork contact or a GitHub issue. Report security problems privately as described in [SECURITY.md](SECURITY.md), not in a public issue.
