# The queues temperwork sends work to and your workers take it from: one per
# entry of workers (a model and a kind of work), and the judges queue.
# temperwork uses only the queues the environment lists (the environment
# output), each under its id. Encrypted at rest with SQS-owned keys: no KMS
# key or permissions needed.

locals {
  # Each worker entry's queue id, as temperwork and the worker name it:
  # model:<model> for inference and grading, training:<model> for training.
  worker_queue_ids = { for k, w in var.workers : k => "${w.work == "training" ? "training" : "model"}:${w.model}" }

  # temperwork sends to inference and training queues; grading queues are fed
  # by your judge workers (the grade chunks of LLM steps on a judge model).
  sent_by_temperwork = [for k, w in var.workers : aws_sqs_queue.workers[k].arn if w.work != "grading"]
  grading            = { for k, w in var.workers : k => aws_sqs_queue.workers[k] if w.work == "grading" }
}

resource "aws_sqs_queue" "workers" {
  for_each                    = var.workers
  name                        = "${var.name}-${each.key}.fifo"
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
