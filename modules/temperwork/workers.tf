# Your workers: the role and instance profile your EC2 workers run with.
# EC2 only: attach it to your instances with the instance profile below.

data "aws_iam_policy_document" "worker_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "worker" {
  name                 = "${var.name}-tw-worker"
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
  name   = "tw-worker"
  role   = aws_iam_role.worker.id
  policy = data.aws_iam_policy_document.worker.json
}

resource "aws_iam_instance_profile" "worker" {
  name = "${var.name}-tw-worker"
  role = aws_iam_role.worker.name
}
