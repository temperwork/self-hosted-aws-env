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
| **Data bucket** | `<name>-data`, or your own `bucket` | Your datasets, anywhere in the bucket. Run outputs under `<prefix>datasets/`. Trained LoRAs under `<prefix>loras/`. Your workers write all of these. | **Read only**, and only through links it signs that work from your network. **Never write.** |
| **Control bucket** | `<name>-control`, or your own `control_bucket` | Records only, under `.studio/`: execution records, pipeline snapshots, worker heartbeats, dataset manifests (file lists and metadata, no file contents) | Read and write `.studio/` |

The control bucket is the only S3 location the studio can write. Its bucket policy refuses any request that doesn't use TLS. The module won't accept the same bucket for both.

## The studio's role: `temperwork-studio-<name>`

**Who can assume it.** Only the studio role ARN you pass as `studio_role_arn`, and only with your `external_id` (`sts:ExternalId`). Sessions last at most one hour. The hosted studio assumes only roles whose names start with `temperwork-studio`.

**What it can do:**

| Permission | On | Why |
|---|---|---|
| `sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:PurgeQueue` | `arn:aws:sqs:<region>:<account>:<name>-runs.fifo`<br>`arn:aws:sqs:<region>:<account>:<name>-trainings.fifo`<br>`arn:aws:sqs:<region>:<account>:<name>-judges.fifo` | Queue work, show queue depth, and clear a queue from the studio |
| `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::<name>-control/.studio/*`<br>(for example `.studio/executions/<id>.json`, `.studio/workers/<id>.json`, ...) | Write run records and read results |
| `s3:ListBucket` | `arn:aws:s3:::<name>-control`, only with `s3:prefix` = `.studio/*` | List the records |
| `s3:GetObject` | `arn:aws:s3:::<name>-data/*`<br>(for example `arn:aws:s3:::<name>-data/faces/0001.jpg`, `arn:aws:s3:::<name>-data/<prefix>datasets/<output>/...`, ...) | So the file links it signs for your browsers work. **The data bucket policy denies this outside your network** |
| `s3:ListBucket` | `arn:aws:s3:::<name>-data` | So the listing links it signs for your browsers work. **The data bucket policy denies this outside your network** |

It **cannot**:

- receive or delete queue messages
- send to the judge models' queues (`arn:aws:sqs:<region>:<account>:<name>-model-*.fifo`)
- write, delete or change anything in the data bucket
- touch anything else in your account

## The data bucket's policy

The module writes these **Deny** statements for the studio's role on `arn:aws:s3:::<name>-data` and `arn:aws:s3:::<name>-data/*`:

| Statement | Denies | When |
|---|---|---|
| `StudioReadsOnlyFromYourNetwork` | `s3:GetObject`, `s3:ListBucket` | The request doesn't come from your network (see below). Not added with `browser_access = open` |
| `StudioNeverWrites` | `s3:PutObject`, `s3:DeleteObject`, `s3:DeleteObjectVersion`, `s3:PutObjectAcl`, `s3:PutBucketPolicy`, `s3:DeleteBucketPolicy`, `s3:PutBucketCORS` | Always, whatever IAM policies are attached to the role later |

"Your network" means:

- **vpce**: the request came through one of your listed VPC endpoints (`aws:SourceVpce` in `vpc_endpoint_ids`, for example `vpce-0123456789abcdef0`, ...). Requests from the internet carry no `aws:SourceVpce`, so they are denied.
- **ip**: the request came from one of your `browser_cidrs` (`aws:SourceIp`, for example `203.0.113.0/24`, ...). A request through *any* VPC endpoint carries no source IP, so it is denied as well. That includes an endpoint in temperwork's own VPC.

A presigned URL carries the signer's identity. When your browser uses a link the studio signed, AWS evaluates the request as the studio's role, coming from your browser's network. The studio can therefore create a working link, but if the studio's servers tried to fetch the file themselves, the request would come from outside your network and be denied.

With `browser_access = open`, only `StudioNeverWrites` is added, and the studio's role can read your data from anywhere. Use `open` only for non-sensitive test data.

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
