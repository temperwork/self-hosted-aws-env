# A temperwork environment in your AWS account: what the studio and your
# workers share, and nothing more. See the README for the whole picture.
#
#   - SQS FIFO queues: runs (the pod service), trainings (trainer pods) and
#     judges (judge workers), plus one per judge model you host
#   - a data bucket: your datasets anywhere in it, the studio's outputs under
#     <prefix>datasets/, and the records the studio shares with your workers
#     under <prefix>.studio/ (the control prefix)
#   - a role the studio assumes (with an external id), allowed only to send
#     to the queues, use the control prefix and sign links; and a bucket
#     policy that lets those links read your data only from your network,
#     so the studio can sign a link to a file but never fetch it itself
#   - a role for your workers (attach it to your instances, tasks or pods),
#     with Bedrock for judge workers' LLM steps

data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
  bucket    = var.bucket != "" ? var.bucket : aws_s3_bucket.data[0].bucket
  control   = "${var.prefix}.studio/"
  endpoints = compact(distinct(concat([var.vpc_endpoint_id], var.vpc_endpoint_ids)))

  # The bucket policy's test for "outside your network", by mode. A request
  # through a VPC endpoint carries aws:SourceVpce and no aws:SourceIp, and a
  # negated condition on a missing key is true: so in ip mode a request
  # through any VPC endpoint (one in another account's VPC included) is
  # denied too, and in vpce mode any request from the internet.
  outside = {
    vpce = { test = "StringNotEquals", variable = "aws:SourceVpce", values = local.endpoints }
    ip   = { test = "NotIpAddress", variable = "aws:SourceIp", values = var.browser_cidrs }
  }
  deny = local.outside[var.browser_access == "ip" ? "ip" : "vpce"]

  bucket_arn = "arn:${local.partition}:s3:::${local.bucket}"
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
      condition     = var.browser_access != "vpce" || length(local.endpoints) > 0
      error_message = "browser_access = vpce needs vpc_endpoint_id (your S3 endpoint), or choose ip (with browser_cidrs) or open."
    }
    precondition {
      condition     = var.browser_access != "ip" || length(var.browser_cidrs) > 0
      error_message = "browser_access = ip needs browser_cidrs: the public IP ranges your browsers reach S3 from."
    }
  }
}

data "aws_iam_policy_document" "studio" {
  statement {
    sid       = "Queue"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:PurgeQueue"]
    resources = [aws_sqs_queue.runs.arn, aws_sqs_queue.trainings.arn, aws_sqs_queue.judges.arn]
  }
  statement {
    sid       = "ControlPrefix"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.bucket_arn}/${local.control}*"]
  }
  statement {
    sid       = "ListControlPrefix"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
  }
  # The links it signs for your browsers act as this role: allowed here, and
  # limited to your network by the bucket policy below.
  statement {
    sid       = "SignLinks"
    actions   = ["s3:GetObject"]
    resources = ["${local.bucket_arn}/*"]
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

  statement {
    sid     = "DataOnlyFromYourNetwork"
    effect  = "Deny"
    actions = ["s3:GetObject"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.studio.arn]
    }
    not_resources = ["${local.bucket_arn}/${local.control}*"]
    condition {
      test     = local.deny.test
      variable = local.deny.variable
      values   = local.deny.values
    }
  }
  statement {
    sid     = "ListOnlyFromYourNetworkOutsideTheControlPrefix"
    effect  = "Deny"
    actions = ["s3:ListBucket"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.studio.arn]
    }
    resources = [local.bucket_arn]
    condition {
      test     = "StringNotLike"
      variable = "s3:prefix"
      values   = ["${local.control}*"]
    }
    condition {
      test     = local.deny.test
      variable = local.deny.variable
      values   = local.deny.values
    }
  }
}

# None with browser_access = open: the studio's role may then read the data.
# With an existing bucket this replaces its policy: pass the statements it
# already has in bucket_policy_source_documents to keep them.
resource "aws_s3_bucket_policy" "data" {
  count      = var.browser_access != "open" ? 1 : 0
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
    sid       = "Data"
    actions   = ["s3:GetObject", "s3:PutObject"]
    resources = ["${local.bucket_arn}/*"]
  }
  statement {
    sid       = "ListData"
    actions   = ["s3:ListBucket"]
    resources = [local.bucket_arn]
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
