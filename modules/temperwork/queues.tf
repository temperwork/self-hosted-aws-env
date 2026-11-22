# The queues temperwork sends work to and your workers take it from: one per
# workers entry (a model and a kind of work) and per self-hosted judge model
# (judge_worker.models), and the judges queue.
# temperwork uses only the queues the environment lists (the environment
# output), each under its id. Encrypted at rest with SQS-owned keys: no KMS
# key or permissions needed.

locals {
  # Every model the workers serve, one queue each: workers' entries (inference
  # or training) and the self-hosted judge models (judging).
  entries = merge(
    var.workers,
    { for k, m in var.judge_worker.models : k => merge(m, { work = "judging" }) },
  )

  # Each entry's queue id, as temperwork and the worker name it:
  # model:<model> for inference and judging, training:<model> for training.
  queue_ids = { for k, e in local.entries : k => "${e.work == "training" ? "training" : "model"}:${e.model}" }

  # The same queue as temperwork names it across environments,
  # conn:<environment id>:<its id>: what the pods tell temperwork they serve.
  temperwork_queue_ids = { for k, id in local.queue_ids : k => "conn:${local.environment_id}:${id}" }

  # temperwork sends to inference and training queues; judging queues are fed
  # by your judge worker (the files of LLM steps on a self-hosted judge model).
  sent_by_temperwork = [for k, e in local.entries : aws_sqs_queue.workers[k].arn if e.work != "judging"]
  judging            = { for k, e in local.entries : k => aws_sqs_queue.workers[k] if e.work == "judging" }
}

resource "aws_sqs_queue" "workers" {
  for_each                    = local.entries
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

  # Checks across workers and judge_worker.models, whose keys share one namespace.
  lifecycle {
    precondition {
      condition     = length(setintersection(keys(var.workers), keys(var.judge_worker.models))) == 0
      error_message = "workers and judge_worker.models share a key: each key names a queue, so they must differ."
    }
    precondition {
      condition     = alltrue([for k in keys(local.entries) : can(regex("^[a-z0-9][a-z0-9-]{0,19}$", k)) && k != "judges"])
      error_message = "workers and judge_worker.models: keys are 1 to 20 lowercase letters, digits or hyphens, and not \"judges\"."
    }
    precondition {
      condition     = length(distinct(values(local.queue_ids))) == length(local.queue_ids)
      error_message = "workers and judge_worker.models: one entry per model and kind of work (each has its own queue)."
    }
    precondition {
      condition     = alltrue([for e in local.entries : e.instances >= 0 && floor(e.instances) == e.instances && (e.instances == 0 || e.image != "")])
      error_message = "workers and judge_worker.models: instances is a whole number, 0 or more, and needs image."
    }
  }
}
