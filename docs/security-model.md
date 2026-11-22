# How access works

temperwork is split in two:

- **The control plane** is temperwork itself, at temperwork.com. It plans runs, queues them and tracks them.
- **The data plane** is in your AWS account: your workers, your queues and your data. The work runs here and the data stays here.

This page lists everything the temperwork module lets the control plane do in your account, and everything it lets your workers do. All of it is in [`modules/temperwork`](../modules/temperwork): [`control_plane.tf`](../modules/temperwork/control_plane.tf) (the role temperwork assumes), [`data_bucket.tf`](../modules/temperwork/data_bucket.tf) (the data bucket and its policy) and [`workers.tf`](../modules/temperwork/workers.tf) (the workers' role).

In the resource names below:

- `<name>` is the module's `name`.
- `<region>` and `<account>` are your AWS region and account id.
- `<prefix>` is `prefix` (default `temperwork/`).
- `...` means "and more of the same kind".

## Two buckets

The module keeps the control plane's records apart from your data. **These are two separate buckets:**

| Bucket | Default name | What's in it | The control plane can |
|---|---|---|---|
| **Data bucket** | `<name>-data`, or your own `bucket` | Your datasets, anywhere in the bucket. Run outputs under `<prefix>datasets/`. Trained LoRAs under `<prefix>loras/`. Your workers write all of these. | **Read only**, and only through links it signs that work through your VPC endpoints. **Never write.** |
| **Control bucket** | `<name>-control`, or your own `control_bucket` | Records only, under `.studio/`: execution records, pipeline snapshots, worker heartbeats, dataset manifests (file lists and metadata, no file contents) | Read and write `.studio/` |

The control bucket is the only S3 location the control plane can write. The module won't accept the same bucket for both.

## The control-plane role: `temperwork-cp-<name>`

This is the role in your account that the control plane assumes.

**Who can assume it.** Only the control plane's own role, the ARN you pass as `temperwork_role_arn`, and only with your `external_id` (`sts:ExternalId`). Sessions last at most one hour. The name must start with `temperwork-cp`, because that's the only kind of role the control plane is allowed to assume.

**What it can do:**

| Permission | On | Why |
|---|---|---|
| `sqs:SendMessage`, `sqs:GetQueueAttributes`, `sqs:PurgeQueue` | The queue of each `workers` entry doing inference or training, for example `arn:aws:sqs:<region>:<account>:<name>-edit.fifo`, ...<br>`arn:aws:sqs:<region>:<account>:<name>-judges.fifo` | Queue work, show queue depth, and clear a queue |
| `sqs:GetQueueAttributes` | The queue of each self-hosted judge model (`judge_worker.models`), for example `arn:aws:sqs:<region>:<account>:<name>-vl.fifo`, ... | Show how much judging work waits for your judge model pods. Only your judge worker sends to these queues |
| `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::<name>-control/.studio/*`<br>(for example `.studio/executions/<id>.json`, `.studio/workers/<id>.json`, ...) | Write run records and read results |
| `s3:ListBucket` | `arn:aws:s3:::<name>-control`, only with `s3:prefix` = `.studio/*` | List the records |
| `s3:GetObject` | `arn:aws:s3:::<name>-data/*`<br>(for example `arn:aws:s3:::<name>-data/faces/0001.jpg`, `arn:aws:s3:::<name>-data/<prefix>datasets/<output>/...`, ...) | So the file links it signs for your browsers work. **The control plane can't use it to download your data**: see [Why the control plane has `s3:GetObject` on your data](#why-the-control-plane-has-s3getobject-on-your-data) |
| `s3:ListBucket` | `arn:aws:s3:::<name>-data` | So the folder-listing links it signs for your browsers work. Limited the same way as `s3:GetObject` |

It **cannot**:

- receive or delete queue messages. It doesn't need to: to cancel a queued run, the control plane marks the run stopped in the control bucket, and the worker that receives its message drops it. A running judge run is stopped with a `stop` message on its queue
- send to the judge models' queues. Only your judge worker does
- download or list your data from temperwork's servers, or from anywhere else outside your VPC ([`TemperworkReadsOnlyFromYourNetwork`](../modules/temperwork/data_bucket.tf#L41-L55))
- write, delete or change anything in the data bucket: its IAM policy grants no write there, and S3 denies anything not granted
- touch anything else in your account

The role's whole IAM policy is the [`temperwork` policy document](../modules/temperwork/control_plane.tf#L43-L86).

## Why the control plane has `s3:GetObject` on your data

temperwork's page shows your images and folder listings, but your data never passes through the control plane. The control plane gives your people's browsers **presigned URLs**, and each browser downloads the file directly from your bucket.

- **Signing a URL doesn't touch S3.** A presigned URL is the request, signed locally with the control-plane role's credentials. Making one sends nothing to S3, so the control plane doesn't download anything when it signs.
- **The URL is checked when it's used, as the role that signed it.** When a browser opens the link, S3 checks the request as the control-plane role. So the role needs `s3:GetObject` ([`SignDataLinks`](../modules/temperwork/control_plane.tf#L74-L80)), or the link would be refused.
- **The bucket policy decides where the control-plane role can read from at all, not just where links work.** S3 checks the data bucket's policy on every request made as the control-plane role, against the network the request comes from. [`TemperworkReadsOnlyFromYourNetwork`](../modules/temperwork/data_bucket.tf#L41-L55) denies the role `s3:GetObject` and `s3:ListBucket` unless the request arrives through one of your S3 VPC endpoints (`vpc_endpoint_ids`). That covers a presigned link, and it equally covers temperwork's servers calling `GetObject` directly with the role's credentials: those calls can't come through your VPC endpoint, so they are denied even though the role has `s3:GetObject`. The test for "outside your network" is the [`outside` local](../modules/temperwork/data_bucket.tf#L27-L35).

So:

| Request | Result |
|---|---|
| A browser on your VPN or in your VPC opens a link the control plane signed | Allowed: the control-plane role, through your VPC endpoint |
| temperwork's servers open a link they signed, or call `GetObject` with the role directly | **Denied**: the control-plane role, not through your VPC endpoint |
| Someone who got hold of a link opens it outside your VPC or VPN | **Denied**, and the link expires anyway |

The control-plane role can only do what its IAM policy, in your account, allows, and only your admins can change that policy or the bucket's. Nothing in the role's policy writes to the data bucket or changes its policy.

## The data bucket's policy

The [data bucket's policy](../modules/temperwork/data_bucket.tf#L38-L64) has one **Deny** statement for the control-plane role on `arn:aws:s3:::<name>-data` and `arn:aws:s3:::<name>-data/*`:

| Statement | Denies | When |
|---|---|---|
| [`TemperworkReadsOnlyFromYourNetwork`](../modules/temperwork/data_bucket.tf#L41-L55) | `s3:GetObject`, `s3:ListBucket` | The request doesn't come through one of your S3 VPC endpoints |

Only traffic inside your VPC, or on a VPN into it, can come through your endpoint. A request from the internet, including from temperwork's servers, carries no `aws:SourceVpce` (or a different one), so it is denied.

## The workers' role: `<name>-tw-worker`

Your workers are the data plane's compute. This is the role they run with.

**Who can assume it.** Only EC2 (`ec2.amazonaws.com`), through the `<name>-tw-worker` instance profile you launch your workers with.

**What it can do:**

| Permission | On | Why |
|---|---|---|
| `sqs:ReceiveMessage`, `sqs:DeleteMessage`, `sqs:ChangeMessageVisibility`, `sqs:GetQueueAttributes` | Every `workers` entry's and judge model's queue, for example `arn:aws:sqs:<region>:<account>:<name>-edit.fifo`, ...<br>`arn:aws:sqs:<region>:<account>:<name>-judges.fifo` | Take work |
| `sqs:SendMessage` | The judge models' queues, for example `arn:aws:sqs:<region>:<account>:<name>-vl.fifo`, ... (only with `judge_worker.models`) | The judge worker hands the files of LLM steps to your judge model pods |
| `s3:GetObject`, `s3:PutObject` | `arn:aws:s3:::<name>-data/*` (for example `.../<prefix>datasets/<output>/0001.png`, `.../<prefix>loras/<name>_1000.safetensors`, ...)<br>`arn:aws:s3:::<name>-control/*` (for example `.../.studio/executions/<id>.json`, ...) | Read inputs, write outputs and LoRAs, and update run records |
| `s3:ListBucket` | `arn:aws:s3:::<name>-data`<br>`arn:aws:s3:::<name>-control` | List datasets and records |
| `bedrock:InvokeModel` | For each of `bedrock_models` (default `anthropic.claude-*`):<br>`arn:aws:bedrock:*::foundation-model/anthropic.claude-*` (for example `anthropic.claude-haiku-4-5-...`, ...)<br>`arn:aws:bedrock:::foundation-model/anthropic.claude-*` (what a global inference profile calls)<br>`arn:aws:bedrock:*:*:inference-profile/*anthropic.claude-*` (for example `us.anthropic.claude-haiku-4-5-...`, ...) | LLM judge steps, run in your account. None with `bedrock_models = []` |
| `bedrock-mantle:CreateInference` | `*` (the Bedrock Messages API takes no resource) | LLM judge steps through the Messages API. None with `bedrock_models = []` |
| `ssm:GetParameter` | `arn:aws:ssm:<region>:<account>:parameter/temperwork/enroll-token` (the value of `enroll_token_parameter`, only if set) | Read the enrollment token at boot |

With EC2 workers running an image in ECR, the role also gets `AmazonEC2ContainerRegistryReadOnly`, to pull it. The EC2 workers' instances use IMDSv2 only, and their security group (unless you give your own) allows no inbound traffic.

Workers **can't enable** Bedrock models: they have no AWS Marketplace access. An admin enables the Anthropic models in your account first (see the README's prerequisites). Until then, a judge's LLM steps fail with an error saying the model isn't enabled.

## What crosses between the planes

- The control plane writes records to, and reads records from, the **control bucket**, and sends messages to your queues.
- Workers call `https://temperwork.com` to enroll once, with the enrollment token, and then to renew a short **lease** for their certificate. A worker without a valid lease takes no work. Revoking a certificate, or deleting the environment in temperwork, stops its workers within one lease.
- Your data (datasets, outputs, LoRAs you train) stays in the **data bucket** and is never fetched by temperwork's servers. temperwork's page, running in your people's browsers, fetches it directly from your bucket, inside your network.

## Revoking access

Any one of these is enough:

- Delete the environment in temperwork (Settings → Environments). This revokes its workers' certificates.
- Delete or change the trust policy of the `temperwork-cp-<name>` role, or rotate the external id.
- Run `terraform destroy`.
