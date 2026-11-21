# How access works

This page lists everything the environment lets the studio do in your account, and everything it lets your workers do. All of it is in [`modules/environment/main.tf`](../modules/environment/main.tf).

## Terms

- **Control prefix**: `<prefix>.studio/` in your bucket (by default `studio/.studio/`). The studio and your workers share records here: execution records, the pipelines they run, worker heartbeats and dataset manifests.
- **Data**: everything else in the bucket. That means your datasets wherever you keep them, plus the studio's outputs under `<prefix>datasets/`.

## The studio's role: `temperwork-studio-<name>`

**Who can assume it.** Only the studio role ARN you pass as `studio_role_arn`, and only with your `external_id` (`sts:ExternalId`). Sessions last at most one hour. The hosted studio assumes only roles whose names start with `temperwork-studio`.

**What it can do:**

| Permission | On | Why |
|---|---|---|
| `sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:PurgeQueue` | the runs, trainings and judges queues | Queue work, show queue depth, and clear a queue from the studio |
| `s3:GetObject`, `s3:PutObject` | the control prefix | Write run records and read results |
| `s3:ListBucket` | the bucket | List the control prefix. The bucket policy limits listing anything else to your network |
| `s3:GetObject` | the whole bucket | So that the links it signs for your browsers work. The bucket policy limits this to your network |

It **cannot** receive or delete queue messages, write outside the control prefix, or touch the judge models' queues.

## The bucket policy

With `browser_access = vpce` or `ip`, the bucket gets two **Deny** statements for the studio's role:

1. `s3:GetObject` on anything outside the control prefix, unless the request comes from your network.
2. `s3:ListBucket` with a prefix outside the control prefix, unless the request comes from your network.

"Your network" means:

- **vpce**: the request came through one of your listed VPC endpoints (`aws:SourceVpce`). Requests from the internet carry no `aws:SourceVpce`, so they are denied.
- **ip**: the request came from one of your `browser_cidrs` (`aws:SourceIp`). A request through *any* VPC endpoint carries no source IP, so it is denied as well. That includes an endpoint in temperwork's own VPC.

A presigned URL carries the signer's identity. When your browser uses a link the studio signed, AWS evaluates the request as the studio's role, coming from your browser's network. The studio can therefore create a working link, but if the studio's servers tried to fetch the file themselves, the request would come from outside your network and be denied.

With `browser_access = open` there is no bucket policy, and the studio's role can read your data from anywhere. Use `open` only for non-sensitive test data.

## The workers' role: `<name>-studio-worker`

**Who can assume it.** The services in `worker_principals` (by default EC2 and ECS tasks; add `pods.eks.amazonaws.com` for EKS Pod Identity), plus any IAM principals in `worker_assumers`, for workers outside AWS.

**What it can do:**

| Permission | On | Why |
|---|---|---|
| `sqs:ReceiveMessage`, `DeleteMessage`, `ChangeMessageVisibility`, `GetQueueAttributes` | all of the environment's queues | Take work |
| `sqs:SendMessage` | the judge models' queues (if any) | Judge workers hand grading work to your model pods |
| `s3:GetObject`, `s3:PutObject`, `s3:ListBucket` | the bucket | Read inputs and write outputs |
| `bedrock:InvokeModel` | Anthropic foundation models and inference profiles | LLM judge steps, run in your account |
| `bedrock-mantle:CreateInference` | `*` | The Bedrock Messages API |
| `bedrock:ListFoundationModels`, `ListInferenceProfiles` | `*` | Report which models the account has when a call fails |
| `aws-marketplace:ViewSubscriptions`, `Subscribe` | `*` | Bedrock enables a model on its first call. Turn off with `allow_bedrock_model_subscription = false` if you enable models yourself |
| `ssm:GetParameter` | `enroll_token_parameter` (if set) | Read the enrollment token at boot |

## What crosses to temperwork

- The studio writes records to and reads records from the control prefix, and sends messages to your queues.
- Workers call `https://temperwork.com` to enroll once, with the enrollment token, and then to renew a short **lease** for their certificate. A worker without a valid lease takes no work. Revoking a certificate, or deleting the environment in the studio, stops its workers within one lease.
- Your data (datasets, outputs, model weights you train) is never fetched by temperwork's servers. The studio's page in your people's browsers fetches it directly from your bucket, inside your network.

## Revoking access

Any one of these is enough:

- Delete the environment in the studio (Settings → Environments). This revokes its workers' certificates.
- Delete or change the trust policy of the `temperwork-studio-<name>` role, or rotate the external id.
- Run `terraform destroy`.
