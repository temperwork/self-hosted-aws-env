# A temperwork environment in your AWS account: what the studio and your
# workers share, and nothing more. See the README for the whole picture.
#
#   - SQS FIFO queues: runs (the pod service), trainings (trainer pods) and
#     judges (judge workers), plus one per judge model you host
#   - a data bucket: your datasets anywhere in it, and what your workers
#     write (outputs under <prefix>datasets/, LoRAs under <prefix>loras/).
#     The studio can't write to it, and can read it only through links that
#     work from your network
#   - a separate control bucket: the records the studio shares with your
#     workers (execution records, pipeline snapshots, worker heartbeats,
#     dataset manifests). The only S3 the studio reads and writes
#   - a role the studio assumes (with an external id), allowed only to send
#     to the queues, use the control bucket and sign links to the data; and
#     a bucket policy on the data bucket that lets those links work only
#     from your network, so the studio can sign a link but never fetch it
#   - a role for your workers (attach it to your instances, tasks or pods),
#     with Bedrock for judge workers' LLM steps

data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
  endpoints = compact(distinct(concat([var.vpc_endpoint_id], var.vpc_endpoint_ids)))

  bucket         = var.bucket != "" ? var.bucket : aws_s3_bucket.data[0].bucket
  bucket_arn     = "arn:${local.partition}:s3:::${local.bucket}"
  control        = var.control_bucket != "" ? var.control_bucket : aws_s3_bucket.control[0].bucket
  control_arn    = "arn:${local.partition}:s3:::${local.control}"
  control_prefix = ".studio/" # the workers expect the control URI to end in .studio/
  control_uri    = "s3://${local.control}/${local.control_prefix}"

  # The data bucket policy's test for "outside your network": not through
  # one of your VPC endpoints. A request from the internet carries no
  # aws:SourceVpce, and a negated condition on a missing key is true, so it
  # is denied. (test_mode_access = ip tests the source IP instead.)
  outside = {
    vpce = { test = "StringNotEquals", variable = "aws:SourceVpce", values = local.endpoints }
    ip   = { test = "NotIpAddress", variable = "aws:SourceIp", values = var.test_mode_cidrs }
  }
  deny = local.outside[var.test_mode_access == "ip" ? "ip" : "vpce"]
}

# --- the data bucket -----------------------------------------------------------

resource "aws_s3_bucket" "data" {
  count  = var.bucket == "" ? 1 : 0
  bucket = "${var.name}-data"
}

resource "aws_s3_bucket_public_access_block" "data" {
  count                   = var.bucket == "" ? 1 : 0
  bucket                  = aws_s3_bucket.data[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The studio's page fetches listings and files with the links it signs: from
# the studio's origin, inside your network.
resource "aws_s3_bucket_cors_configuration" "data" {
  bucket = local.bucket
  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = var.studio_origins
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

# --- the control bucket ------------------------------------------------------------
# Only records: no datasets, outputs or models. The studio and your workers
# both read and write it; nothing else in your account needs to.

resource "aws_s3_bucket" "control" {
  count  = var.control_bucket == "" ? 1 : 0
  bucket = "${var.name}-control"
}

resource "aws_s3_bucket_public_access_block" "control" {
  count                   = var.control_bucket == "" ? 1 : 0
  bucket                  = aws_s3_bucket.control[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "control" {
  count  = var.control_bucket == "" ? 1 : 0
  bucket = aws_s3_bucket.control[0].id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

data "aws_iam_policy_document" "control" {
  statement {
    sid     = "TlsOnly"
    effect  = "Deny"
    actions = ["s3:*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
    resources = [local.control_arn, "${local.control_arn}/*"]
    condition {
      test     = "Bool"
      variable = "aws:SecureTransport"
      values   = ["false"]
    }
  }
}

resource "aws_s3_bucket_policy" "control" {
  count      = var.control_bucket == "" ? 1 : 0
  bucket     = aws_s3_bucket.control[0].id
  policy     = data.aws_iam_policy_document.control.json
  depends_on = [aws_s3_bucket_public_access_block.control]
}

# --- the queues ----------------------------------------------------------------
# Encrypted at rest with SQS-owned keys: no KMS key or permissions needed.

resource "aws_sqs_queue" "runs" {
  name                        = "${var.name}-runs.fifo"
  fifo_queue                  = true
  visibility_timeout_seconds  = 300
  message_retention_seconds   = 86400
  sqs_managed_sse_enabled     = true
  content_based_deduplication = false
}

resource "aws_sqs_queue" "trainings" {
  name                        = "${var.name}-trainings.fifo"
  fifo_queue                  = true
  visibility_timeout_seconds  = 300
  message_retention_seconds   = 86400
  sqs_managed_sse_enabled     = true
  content_based_deduplication = false
}

resource "aws_sqs_queue" "judges" {
  name                       = "${var.name}-judges.fifo"
  fifo_queue                 = true
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  sqs_managed_sse_enabled    = true
}

# A judge model's own queue: judge workers put an LLM step's files there in
# chunks, and that model's pods take them. Only your workers use it: the
# studio never sends to it.
resource "aws_sqs_queue" "models" {
  for_each                   = toset(var.judge_models)
  name                       = "${var.name}-model-${replace(each.key, ".", "-")}.fifo"
  fifo_queue                 = true
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  sqs_managed_sse_enabled    = true
}

# --- the studio's role in your account -------------------------------------------

data "aws_iam_policy_document" "studio_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.studio_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "studio" {
  # The hosted studio may assume only roles named temperwork-studio*.
  name                 = "temperwork-studio-${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.studio_trust.json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = var.test_mode_access != "off" || length(local.endpoints) > 0
      error_message = "vpc_endpoint_id (or vpc_endpoint_ids) is required: your S3 VPC endpoint, the only way the studio's links to your data work."
    }
    precondition {
      condition     = var.test_mode_access != "ip" || length(var.test_mode_cidrs) > 0
      error_message = "test_mode_access = ip needs test_mode_cidrs."
    }
    precondition {
      condition     = var.control_bucket == "" || var.control_bucket != var.bucket
      error_message = "control_bucket must be a different bucket from bucket: the studio may write the control bucket, never your data's."
    }
  }
}

data "aws_iam_policy_document" "studio" {
  statement {
    sid       = "Queues"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:PurgeQueue"]
    resources = [aws_sqs_queue.runs.arn, aws_sqs_queue.trainings.arn, aws_sqs_queue.judges.arn]
  }
  statement {
    sid       = "ControlRecords"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.control_arn}/${local.control_prefix}*"]
  }
  statement {
    sid       = "ListControlRecords"
    actions   = ["s3:ListBucket"]
    resources = [local.control_arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.control_prefix}*"]
    }
  }
  # The links it signs for your browsers act as this role: allowed here, and
  # limited to your network by the data bucket's policy below. Read only:
  # the studio never writes your data.
  statement {
    sid       = "SignDataLinks"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/*"]
  }
  statement {
    sid       = "SignListingLinks"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
}

resource "aws_iam_role_policy" "studio" {
  name   = "studio"
  role   = aws_iam_role.studio.id
  policy = data.aws_iam_policy_document.studio.json
}

# --- your data: read only inside your network --------------------------------------

data "aws_iam_policy_document" "bucket" {
  source_policy_documents = var.bucket_policy_source_documents

  # Left out only with test_mode_access = open.
  dynamic "statement" {
    for_each = var.test_mode_access != "open" ? [1] : []
    content {
      sid     = "StudioReadsOnlyFromYourNetwork"
      effect  = "Deny"
      actions = ["s3:GetObject", "s3:ListBucket"]
      principals {
        type        = "AWS"
        identifiers = [aws_iam_role.studio.arn]
      }
      resources = [local.bucket_arn, "${local.bucket_arn}/*"]
      condition {
        test     = local.deny.test
        variable = local.deny.variable
        values   = local.deny.values
      }
    }
  }
  # Belt and braces: whatever IAM policies are later attached to the studio's
  # role, it can't change your data.
  statement {
    sid    = "StudioNeverWrites"
    effect = "Deny"
    actions = [
      "s3:PutObject", "s3:DeleteObject", "s3:DeleteObjectVersion", "s3:PutObjectAcl",
      "s3:PutBucketPolicy", "s3:DeleteBucketPolicy", "s3:PutBucketCORS",
    ]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.studio.arn]
    }
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
  }
}

# With an existing bucket this replaces its policy: pass the statements it
# already has in bucket_policy_source_documents to keep them.
resource "aws_s3_bucket_policy" "data" {
  bucket     = local.bucket
  policy     = data.aws_iam_policy_document.bucket.json
  depends_on = [aws_s3_bucket_public_access_block.data]
}

# --- your workers ----------------------------------------------------------------------

data "aws_iam_policy_document" "worker_trust" {
  statement {
    actions = ["sts:AssumeRole", "sts:TagSession"]
    principals {
      type        = "Service"
      identifiers = var.worker_principals
    }
  }

  # Workers outside AWS: an IAM principal's keys, used only to assume this
  # role (STUDIO_AWS_ROLE_ARN in the pod service).
  dynamic "statement" {
    for_each = length(var.worker_assumers) > 0 ? [1] : []
    content {
      actions = ["sts:AssumeRole"]
      principals {
        type        = "AWS"
        identifiers = var.worker_assumers
      }
    }
  }
}

resource "aws_iam_role" "worker" {
  name                 = "${var.name}-studio-worker"
  assume_role_policy   = data.aws_iam_policy_document.worker_trust.json
  max_session_duration = 43200
}

data "aws_iam_policy_document" "worker" {
  statement {
    sid     = "Queues"
    actions = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:ChangeMessageVisibility", "sqs:GetQueueAttributes"]
    resources = concat([aws_sqs_queue.runs.arn, aws_sqs_queue.trainings.arn, aws_sqs_queue.judges.arn],
    [for q in aws_sqs_queue.models : q.arn])
  }
  # Judge workers put grading chunks on the judge models' queues.
  dynamic "statement" {
    for_each = length(var.judge_models) > 0 ? [1] : []
    content {
      sid       = "JudgeModelQueues"
      actions   = ["sqs:SendMessage"]
      resources = [for q in aws_sqs_queue.models : q.arn]
    }
  }
  # Judge workers' LLM steps call Claude in Bedrock, in this account: the
  # Messages API, then InvokeModel on the model or a US or global inference
  # profile (which may serve it from another region).
  statement {
    sid     = "LlmJudges"
    actions = ["bedrock:InvokeModel"]
    resources = [
      "arn:${local.partition}:bedrock:*::foundation-model/anthropic.*",
      "arn:${local.partition}:bedrock:::foundation-model/anthropic.*",
      "arn:${local.partition}:bedrock:*:*:inference-profile/*anthropic.*",
    ]
  }
  statement {
    sid       = "LlmJudgesMessages"
    actions   = ["bedrock-mantle:CreateInference"]
    resources = ["*"]
  }
  # So a run that reaches no model can say which ones the account has.
  statement {
    sid       = "ListModels"
    actions   = ["bedrock:ListFoundationModels", "bedrock:ListInferenceProfiles"]
    resources = ["*"]
  }
  # Bedrock enables a model for the account on its first call, by
  # subscribing to it on AWS Marketplace as the caller.
  dynamic "statement" {
    for_each = var.allow_bedrock_model_subscription ? [1] : []
    content {
      sid       = "EnableModels"
      actions   = ["aws-marketplace:ViewSubscriptions", "aws-marketplace:Subscribe"]
      resources = ["*"]
    }
  }
  statement {
    sid       = "Objects"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.bucket_arn}/*", "${local.control_arn}/*"]
  }
  statement {
    sid       = "List"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn, local.control_arn]
  }
  dynamic "statement" {
    for_each = var.enroll_token_parameter != "" ? [1] : []
    content {
      sid       = "EnrollToken"
      actions   = ["ssm:GetParameter"]
      resources = ["arn:${local.partition}:ssm:${local.region}:${data.aws_caller_identity.current.account_id}:parameter${var.enroll_token_parameter}"]
    }
  }
}

resource "aws_iam_role_policy" "worker" {
  name   = "studio-worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.name}-studio-worker"
  role = aws_iam_role.worker.name
}
