# How access works

This page lists everything the temperwork module lets the studio do in your account, and everything it lets your workers do. All of it is in [`modules/temperwork/main.tf`](../modules/temperwork/main.tf).

In the resource names below:

- `<name>` is the module's `name`.
- `<region>` and `<account>` are your AWS region and account id.
- `<prefix>` is `prefix` (default `studio/`).
- `...` means "and more of the same kind".

## Two buckets

The module keeps the studio's records apart from your data. **These are two separate buckets:**

| Bucket | Default name | What's in it | The studio can |
|---|---|---|---|
| **Data bucket** | `<name>-data`, or your own `bucket` | Your datasets, anywhere in the bucket. Run outputs under `<prefix>datasets/`. Trained LoRAs under `<prefix>loras/`. Your workers write all of these. | **Read only**, and only through links it signs that work through your VPC endpoints. **Never write.** |
| **Control bucket** | `<name>-control`, or your own `control_bucket` | Records only, under `.studio/`: execution records, pipeline snapshots, worker heartbeats, dataset manifests (file lists and metadata, no file contents) | Read and write `.studio/` |

The control bucket is the only S3 location the studio can write. The module won't accept the same bucket for both.

## The studio's role: `temperwork-studio-<name>`

**Who can assume it.** Only the studio role ARN you pass as `studio_role_arn`, and only with your `external_id` (`sts:ExternalId`). Sessions last at most one hour. The hosted studio assumes only roles whose names start with `temperwork-studio`.

**What it can do:**

| Permission | On | Why |
|---|---|---|
| `sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:PurgeQueue` | `arn:aws:sqs:<region>:<account>:<name>-runs.fifo`<br>`arn:aws:sqs:<region>:<account>:<name>-trainings.fifo`<br>`arn:aws:sqs:<region>:<account>:<name>-judges.fifo` | Queue work, show queue depth, and clear a queue from the studio |
| `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::<name>-control/.studio/*`<br>(for example `.studio/executions/<id>.json`, `.studio/workers/<id>.json`, ...) | Write run records and read results |
| `s3:ListBucket` | `arn:aws:s3:::<name>-control`, only with `s3:prefix` = `.studio/*` | List the records |
| `s3:GetObject` | `arn:aws:s3:::<name>-data/*`<br>(for example `arn:aws:s3:::<name>-data/faces/0001.jpg`, `arn:aws:s3:::<name>-data/<prefix>datasets/<output>/...`, ...) | So the file links it signs for your browsers work. **Temperwork can't use it to download your data**: see [Why the studio has `s3:GetObject` on your data](#why-the-studio-has-s3getobject-on-your-data) |
| `s3:ListBucket` | `arn:aws:s3:::<name>-data` | So the folder-listing links it signs for your browsers work. Limited the same way as `s3:GetObject` |

It **cannot**:

- receive or delete queue messages
- send to the judge models' queues (`arn:aws:sqs:<region>:<account>:<name>-model-*.fifo`)
- download or list your data from its own servers, or from anywhere else outside your VPC ([`StudioReadsOnlyFromYourNetwork`](../modules/temperwork/main.tf#L202-L216))
- write, delete or change anything in the data bucket: its IAM policy grants no write there, and S3 denies anything not granted
- touch anything else in your account

The role's whole IAM policy is the [`studio` policy document](../modules/temperwork/main.tf#L156-L189).

## Why the studio has `s3:GetObject` on your data

The studio's page shows your images and folder listings, but your data never passes through temperwork. The studio gives your people's browsers **presigned URLs**, and each browser downloads the file directly from your bucket.

- **Signing a URL doesn't touch S3.** A presigned URL is the request, signed locally with the studio role's credentials. Making one sends nothing to S3, so the studio doesn't download anything when it signs.
- **The URL is checked when it's used, as the role that signed it.** When a browser opens the link, S3 checks the request as the studio's role. So the role needs `s3:GetObject` ([`SignDataLinks`](../modules/temperwork/main.tf#L177-L183)), or the link would be refused.
- **The bucket policy decides where the studio's role can read from at all, not just where links work.** S3 checks the data bucket's policy on every request made as the studio's role, against the network the request comes from. [`StudioReadsOnlyFromYourNetwork`](../modules/temperwork/main.tf#L202-L216) denies the role `s3:GetObject` and `s3:ListBucket` unless the request arrives through one of your S3 VPC endpoints (`vpc_endpoint_ids`). That covers a presigned link, and it equally covers temperwork's servers calling `GetObject` directly with the role's credentials: those calls can't come through your VPC endpoint, so they are denied even though the role has `s3:GetObject`. The test for "outside your network" is the [`outside` local](../modules/temperwork/main.tf#L37-L45).

So:

| Request | Result |
|---|---|
| A browser on your VPN or in your VPC opens a link the studio signed | Allowed: the studio's role, through your VPC endpoint |
| temperwork's servers open a link they signed, or call `GetObject` with the role directly | **Denied**: the studio's role, not through your VPC endpoint |
| Someone who got hold of a link opens it outside your VPC or VPN | **Denied**, and the link expires anyway |

The studio's role can only do what its IAM policy, in your account, allows, and only your admins can change that policy or the bucket's. Nothing in the role's policy writes to the data bucket or changes its policy.

## The data bucket's policy

The [data bucket's policy](../modules/temperwork/main.tf#L199-L225) has one **Deny** statement for the studio's role on `arn:aws:s3:::<name>-data` and `arn:aws:s3:::<name>-data/*`:

| Statement | Denies | When |
|---|---|---|
| [`StudioReadsOnlyFromYourNetwork`](../modules/temperwork/main.tf#L202-L216) | `s3:GetObject`, `s3:ListBucket` | The request doesn't come through one of your S3 VPC endpoints |

Only traffic inside your VPC, or on a VPN into it, can come through your endpoint. A request from the internet, including from temperwork's servers, carries no `aws:SourceVpce` (or a different one), so it is denied.

## The workers' role: `<name>-studio-worker`

**Who can assume it.**

- The services in `worker_principals`: by default `ec2.amazonaws.com` and `ecs-tasks.amazonaws.com`. Add `pods.eks.amazonaws.com` for EKS Pod Identity.
- Any IAM principals in `worker_assumers`, for workers outside AWS (for example `arn:aws:iam::<account>:user/gpu-host`, ...).

**What it can do:**

| Permission | On | Why |
|---|---|---|
| `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility`, `sqs:GetQueueAttributes` | `arn:aws:sqs:<region>:<account>:<name>-runs.fifo`<br>`arn:aws:sqs:<region>:<account>:<name>-trainings.fifo`<br>`arn:aws:sqs:<region>:<account>:<name>-judges.fifo`<br>`arn:aws:sqs:<region>:<account>:<name>-model-qwen3-vl-8b.fifo`, ... (one per `judge_models` entry) | Take work |
| `sqs:SendMessage` | `arn:aws:sqs:<region>:<account>:<name>-model-qwen3-vl-8b.fifo`, ... (only if `judge_models` is set) | Judge workers hand grading work to your model pods |
| `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::<name>-data/*` (for example `.../<prefix>datasets/<output>/0001.png`, `.../<prefix>loras/<name>_1000.safetensors`, ...)<br>`arn:aws:s3:::<name>-control/*` (for example `.../.studio/executions/<id>.json`, ...) | Read inputs, write outputs and LoRAs, and update run records |
| `s3:ListBucket` | `arn:aws:s3:::<name>-data`<br>`arn:aws:s3:::<name>-control` | List datasets and records |
| `bedrock:InvokeModel` | `arn:aws:bedrock:*::foundation-model/anthropic.*` (for example `anthropic.claude-haiku-4-5-...`, ...)<br>`arn:aws:bedrock:::foundation-model/anthropic.*`<br>`arn:aws:bedrock:*:*:inference-profile/*anthropic.*` (for example `us.anthropic.claude-haiku-4-5-...`, `global.anthropic....`, ...) | LLM judge steps, run in your account |
| `bedrock-mantle:CreateInference` | `*` (the Bedrock Messages API takes no resource) | LLM judge steps through the Messages API |
| `bedrock:ListFoundationModels`, `bedrock:ListInferenceProfiles` | `*` (list actions take no resource) | Report which models the account has when a call fails |
| `aws-marketplace:ViewSubscriptions`, `aws-marketplace:Subscribe` | `*` (Marketplace takes no resource) | Bedrock enables a model on its first call. Turn off with `allow_bedrock_model_subscription = false` if you enable models yourself |
| `ssm:GetParameter` | `arn:aws:ssm:<region>:<account>:parameter/studio/enroll-token` (the value of `enroll_token_parameter`, only if set) | Read the enrollment token at boot |

## What crosses to temperwork

- The studio writes records to, and reads records from, the **control bucket**, and sends messages to your queues.
- Workers call `https://temperwork.com` to enroll once, with the enrollment token, and then to renew a short **lease** for their certificate. A worker without a valid lease takes no work. Revoking a certificate, or deleting the environment in the studio, stops its workers within one lease.
- Your data (datasets, outputs, LoRAs you train) stays in the **data bucket** and is never fetched by temperwork's servers. The studio's page, running in your people's browsers, fetches it directly from your bucket, inside your network.

## Revoking access

Any one of these is enough:

- Delete the environment in the studio (Settings → Environments). This revokes its workers' certificates.
- Delete or change the trust policy of the `temperwork-studio-<name>` role, or rotate the external id.
- Run `terraform destroy`.
