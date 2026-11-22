# The control-plane role: what temperwork assumes in your account (with your
# external id). It may send to the queues, use the control bucket and sign
# links to the data; data_bucket.tf's policy keeps those links inside your
# network.

data "aws_iam_policy_document" "temperwork_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.temperwork_role_arn]
    }
    condition {
      test     = "StringEquals"
      variable = "sts:ExternalId"
      values   = [var.external_id]
    }
  }
}

resource "aws_iam_role" "temperwork" {
  # The control plane may assume only roles named temperwork-cp*.
  name                 = "temperwork-cp-${var.name}"
  assume_role_policy   = data.aws_iam_policy_document.temperwork_trust.json
  max_session_duration = 3600

  lifecycle {
    precondition {
      condition     = var.test_mode.access != "off" || length(local.endpoints) > 0
      error_message = "vpc_endpoint_id (or vpc_endpoint_ids) is required: your S3 VPC endpoint, the only way temperwork's links to your data work."
    }
    precondition {
      condition     = var.test_mode.access != "ip" || length(var.test_mode.cidrs) > 0
      error_message = "test_mode.access = ip needs test_mode.cidrs."
    }
    precondition {
      condition     = var.control_bucket == "" || var.control_bucket != var.bucket
      error_message = "control_bucket must be a different bucket from bucket: temperwork may write the control bucket, never your data's."
    }
  }
}

data "aws_iam_policy_document" "temperwork" {
  statement {
    sid       = "Queues"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes", "sqs:PurgeQueue"]
    resources = concat(local.sent_by_temperwork, [aws_sqs_queue.judges.arn])
  }
  # The grading queues: only your judge workers send to them, but temperwork
  # shows how much work waits there.
  dynamic "statement" {
    for_each = length(local.grading) > 0 ? [1] : []
    content {
      sid       = "SeeGradingQueues"
      actions   = ["sqs:GetQueueAttributes"]
      resources = [for q in local.grading : q.arn]
    }
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
  # limited to your VPC endpoints by the data bucket's policy below.
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

resource "aws_iam_role_policy" "temperwork" {
  name   = "temperwork"
  role   = aws_iam_role.temperwork.id
  policy = data.aws_iam_policy_document.temperwork.json
}
