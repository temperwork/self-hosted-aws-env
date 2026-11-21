# temperwork self-hosted AWS environment

Terraform for running [temperwork](https://temperwork.com) workloads in **your own AWS account**.

The temperwork studio plans runs and tracks them. Your GPUs do the work, and your data stays in your bucket. The studio never holds your data. It signs links to your files, and those links work only from inside your network.

This repository creates the AWS side of that setup: the queues, the bucket, an IAM role the studio can assume, and an IAM role for your workers. If you need one, it can also create a VPC.

```
                temperwork.com (studio)
                       │  assumes temperwork-studio-<name>  (external id)
                       │  ├─ sqs:SendMessage            → your queues
                       │  ├─ s3 read/write              → <prefix>.studio/ only
                       │  └─ signs GET links            → usable only from your network
                       ▼
 ┌──────────────────── your AWS account ─────────────────────────┐
 │  SQS FIFO: <name>-runs, -trainings, -judges, -model-*         │
 │  S3: <name>-data   (datasets, outputs, <prefix>.studio/)      │
 │  IAM: <name>-studio-worker  ← your EC2 / ECS / EKS workers    │
 │  (optional) VPC + S3 endpoints + Client VPN                   │
 └───────────────────────────────────────────────────────────────┘
        ▲
        └── your people's browsers open files through your VPC endpoint / IP ranges
```

## Contents

| Path | What it is |
|---|---|
| [`modules/environment`](modules/environment) | The environment: queues, data bucket (or your existing one), studio role, bucket policy, worker role and instance profile. |
| [`modules/network`](modules/network) | An example network: VPC, public subnets, an S3 gateway endpoint and, optionally, an S3 interface endpoint and an AWS Client VPN for browsers outside AWS. |
| [`examples/complete`](examples/complete) | A new VPC with the environment in it. This is the quickest start. |
| [`examples/existing-network`](examples/existing-network) | The environment only, for an account that already has a VPC endpoint or office/VPN IP ranges. It can also use a bucket you already have. |
| [`deploy/ec2-user-data.sh`](deploy/ec2-user-data.sh) | EC2 user data that runs the workers on a GPU instance. |
| [`docs/`](docs) | [How access works](docs/security-model.md), [browser access options](docs/browser-access.md), [the example network and VPN](docs/network.md), [running workers](docs/workers.md). |

## Prerequisites

- An AWS account, and credentials that can create IAM roles, S3 buckets and SQS queues (and VPC resources if you use `examples/complete`).
- [Terraform](https://developer.hashicorp.com/terraform/install) 1.5 or newer, or OpenTofu 1.6 or newer.
- A temperwork account. Open **Settings → Environments → Add environment** in the studio. The form shows two values you'll need:
  - the **studio role ARN**: the temperwork role your account will trust
  - a random **external id**

  Leave the form open. You'll finish it after `terraform apply`.

## Quick start

### 1. Choose an example

- **No network for this yet?** Use `examples/complete`. It creates a VPC whose S3 endpoint is the only way to read your data.
- **Already have a VPC endpoint, or want to allow your office's IP addresses?** Use `examples/existing-network`.

You can also call the modules from your own Terraform. See [Using the modules directly](#using-the-modules-directly).

### 2. Configure

```bash
git clone https://github.com/temperwork/self-hosted-aws-env.git
cd self-hosted-aws-env/examples/complete     # or examples/existing-network
cp terraform.tfvars.example terraform.tfvars
```

Edit `terraform.tfvars`. At a minimum, set:

```hcl
name            = "acme-studio"                       # names the bucket (acme-studio-data), queues and roles
region          = "us-west-2"
studio_role_arn = "arn:aws:iam::...:role/..."         # from the Add environment form
external_id     = "..."                               # from the Add environment form
```

`terraform.tfvars` is git-ignored. Keep the external id out of version control.

Before you go further, decide how people's browsers will reach your files. See [Browser access](#browser-access).

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

### 4. Finish adding the environment in the studio

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
| Role ARN | `environment.credentials.role_arn` |
| External id | the same value you put in `terraform.tfvars` |

Save the form, then click **Test** on the environment's card. Test checks each queue and writes and reads back a file under the control prefix.

### 5. Start workers

On the environment's card, choose **⋯ → Make an enrollment token**. Then start workers with the role this repository created. [docs/workers.md](docs/workers.md) covers EC2 (with [`deploy/ec2-user-data.sh`](deploy/ec2-user-data.sh)), ECS, EKS and GPUs outside AWS.

```bash
terraform output worker_env
```

```bash
terraform output judge_worker_args
```

## Browser access

When someone opens a file in the studio, their browser downloads it directly from your bucket using a link the studio signed. `browser_access` decides where those links work.

| `browser_access` | Links work… | You provide |
|---|---|---|
| `vpce` (default) | only through your S3 VPC endpoints: on your VPN, or inside your VPC | `vpc_endpoint_id` / `vpc_endpoint_ids` |
| `ip` | only from your public IP ranges (an office, or your VPN's egress) | `browser_cidrs` |
| `open` | anywhere. The studio's role can then read your data itself. **Not recommended.** | nothing |

The bucket also needs a CORS rule for the studio's origin (`studio_origins`, default `https://temperwork.com`). The module adds it.

[docs/browser-access.md](docs/browser-access.md) covers the details, including the optional Client VPN in `modules/network`.

## What gets created

`modules/environment`:

| Resource | Name | Purpose |
|---|---|---|
| SQS FIFO queue | `<name>-runs.fifo` | Runs, for the pod service |
| SQS FIFO queue | `<name>-trainings.fifo` | Trainings, for trainer pods |
| SQS FIFO queue | `<name>-judges.fifo` | Judge runs, for judge workers |
| SQS FIFO queue | `<name>-model-<model>.fifo` | One per entry in `judge_models`: grading work for the model pods you host |
| S3 bucket | `<name>-data` (or `bucket`) | Your datasets, the studio's outputs (`<prefix>datasets/`) and shared records (`<prefix>.studio/`) |
| S3 bucket policy | | Denies the studio's role your data outside your network (not created with `open`) |
| S3 CORS rule | | Lets the studio's page `GET` from the bucket |
| IAM role | `temperwork-studio-<name>` | Assumed by the studio with your external id |
| IAM role + instance profile | `<name>-studio-worker` | Attached to your workers |

All queues are encrypted at rest with SQS-managed keys. A new bucket blocks all public access.

`modules/network` (optional): a VPC, public subnets, an internet gateway, an S3 gateway endpoint and, with `vpn = true`, an S3 interface endpoint and an AWS Client VPN endpoint.

### Cost

The environment itself costs almost nothing while it's idle: SQS, S3 and IAM are billed by use. The S3 gateway endpoint is free. With `vpn = true`, the Client VPN and the interface endpoint are billed by the hour. In us-west-2 that is about $0.10/h per subnet association, $0.05/h per connection and $0.01/h for the interface endpoint, so turn the VPN off when no one needs it. GPU instances are billed by AWS as usual. Workers shut down when their queue is empty.

## Security model

In short:

- The studio's role can **send** messages to your queues. It can **read and write only the control prefix** (`<prefix>.studio/`), which holds run records, pipelines, worker heartbeats and dataset manifests. It can **sign** links to the rest of the bucket.
- The bucket policy **denies** the studio's role any read outside the control prefix unless the request comes from your network. The studio can sign a link to a file but cannot fetch the file itself. Only a browser inside your network can.
- The studio's role can be assumed only by temperwork's studio role, and only with your external id.
- Your workers use their own role. They call temperwork.com only to hold a lease for their certificate. Your data stays in your account.
- Judge workers' LLM steps call Claude through **Bedrock in your account**, so images never leave it.

To revoke access, delete the environment in the studio and its workers stop within one lease. Or run `terraform destroy`, or delete the `temperwork-studio-<name>` role.

[docs/security-model.md](docs/security-model.md) lists every permission.

## Using the modules directly

```hcl
module "temperwork" {
  source = "github.com/temperwork/self-hosted-aws-env//modules/environment?ref=v0.1.0"

  name            = "acme-studio"
  studio_role_arn = var.studio_role_arn
  external_id     = var.external_id

  browser_access  = "vpce"
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
}
```

The modules have no `provider` block. They use your `aws` provider and its region. Pin `ref` to a release tag.

### `modules/environment` inputs

| Name | Default | Description |
|---|---|---|
| `name` | (required) | Names the queues, bucket and roles. 3–42 lowercase letters, digits or hyphens. |
| `studio_role_arn` | (required) | The studio's role, from the Add environment form. |
| `external_id` | (required) | The external id from the Add environment form (at least 16 characters). |
| `bucket` | `""` | An existing bucket. Empty creates `<name>-data`. |
| `bucket_policy_source_documents` | `[]` | With an existing bucket: its current policy JSON, so its statements are kept. The module writes the bucket's whole policy. |
| `prefix` | `"studio/"` | Where the studio's outputs and control prefix go in the bucket. |
| `studio_origins` | `["https://temperwork.com"]` | Origins allowed by the bucket's CORS rule. |
| `browser_access` | `"vpce"` | `vpce`, `ip` or `open`. |
| `vpc_endpoint_id`, `vpc_endpoint_ids` | `""`, `[]` | S3 VPC endpoints, for `vpce`. |
| `browser_cidrs` | `[]` | Public IP ranges, for `ip`. |
| `worker_principals` | EC2, ECS tasks | Services that can assume the worker role. Add `pods.eks.amazonaws.com` for EKS. |
| `worker_assumers` | `[]` | IAM principals that can assume the worker role (workers outside AWS). |
| `judge_models` | `[]` | Self-hosted judge models. Each gets a queue. |
| `enroll_token_parameter` | `""` | An SSM parameter holding the enrollment token. The worker role can then read it. |
| `allow_bedrock_model_subscription` | `true` | Lets workers subscribe the account to Anthropic models on first use. |

### `modules/environment` outputs

`environment`, `worker_env`, `bucket`, `control_uri`, `browser_access`, `studio_role_arn`, `worker_role_arn`, `worker_role_name`, `worker_instance_profile`, `judge_worker_args`, `judge_worker_env`, `judge_model_env`. Each output's description is in [`outputs.tf`](modules/environment/outputs.tf).

## Updating and removing

- **Update:** pull a newer release, then run `terraform plan` and `terraform apply`. Read the release notes first.
- **Remove:** delete the environment in the studio, then run `terraform destroy`. A bucket that this repository created must be emptied before it can be destroyed. A bucket you passed in with `bucket` is never deleted, but its policy and CORS rule are removed.

## Development

```bash
terraform fmt -check -recursive
```

```bash
cd modules/environment && terraform init -backend=false && terraform test
```

The tests use a mocked AWS provider, so no account is needed. CI runs format, validate and tests on every pull request ([`.github/workflows/terraform.yml`](.github/workflows/terraform.yml)).

## Support

Questions go to your temperwork contact or a GitHub issue. Report security problems privately as described in [SECURITY.md](SECURITY.md), not in a public issue.
