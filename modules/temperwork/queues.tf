# The queues temperwork sends work to and your workers take it from.
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
# temperwork never sends to it.
resource "aws_sqs_queue" "models" {
  for_each                   = toset(var.judge_models)
  name                       = "${var.name}-model-${replace(each.key, ".", "-")}.fifo"
  fifo_queue                 = true
  visibility_timeout_seconds = 300
  message_retention_seconds  = 86400
  sqs_managed_sse_enabled    = true
}
