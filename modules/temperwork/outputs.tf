# What to give temperwork and your workers.

locals {
  # What each entry's pods take on top of worker_env.
  entry_out = { for k, e in local.entries : k => {
    queue_id  = local.queue_ids[k]
    queue_url = aws_sqs_queue.workers[k].url
    queue_arn = aws_sqs_queue.workers[k].arn
    env = merge(
      { STUDIO_POD_MODEL = e.model, STUDIO_POD_RUNS = e.work == "judging" ? "grading" : e.work },
      e.work == "training" ? {
        STUDIO_TRAIN_QUEUE_URL = aws_sqs_queue.workers[k].url
        STUDIO_TRAIN_QUEUE_ID  = local.temperwork_queue_ids[k]
        } : e.work == "inference" ? {
        STUDIO_QUEUE_URL       = aws_sqs_queue.workers[k].url
        STUDIO_QUEUE_ID        = local.temperwork_queue_ids[k]
        STUDIO_MODEL_QUEUE_URL = aws_sqs_queue.workers[k].url
      } : { STUDIO_MODEL_QUEUE_URL = aws_sqs_queue.workers[k].url },
    )
    ec2_autoscaling_group = contains(keys(local.fleets), k) ? aws_autoscaling_group.ec2_workers[k].name : ""
  } }
}

output "environment" {
  description = "temperwork's Add environment form (Settings → Environments): paste `terraform output -json environment` into it, then add the external id. temperwork uses only the queues listed here (as conn:<id>:<queue id>): each has its id, the work and model it's for, and its URL."
  value = {
    id = local.environment_id
    queues = concat(
      [for k, e in local.entries : {
        id    = local.queue_ids[k]
        work  = e.work
        model = e.model
        url   = aws_sqs_queue.workers[k].url
      }],
      [{ id = "judges", work = "judges", model = "", url = aws_sqs_queue.judges.url }],
    )
    data_root   = "s3://${local.bucket}/${var.prefix}"
    control_uri = local.control_uri
    region      = local.region
    credentials = { kind = "role", role_arn = aws_iam_role.temperwork.arn }
  }
}

output "worker_env" {
  description = "What every worker needs, wherever it runs. Add STUDIO_ENROLL_TOKEN (the environment's card: Make an enrollment token) for its first start, and its own settings from workers or judge_worker."
  value = {
    STUDIO_URL           = var.temperwork_url
    STUDIO_CONNECTION_ID = local.environment_id
    STUDIO_CONTROL_URI   = local.control_uri
    STUDIO_LORA_URI      = local.lora_uri
    AWS_REGION           = local.region
  }
}

output "workers" {
  description = "Each workers entry: its queue, the settings its pods take on top of worker_env (env), and its Auto Scaling group if the module runs it on EC2."
  value       = { for k in keys(var.workers) : k => local.entry_out[k] }
}

output "judge_worker" {
  description = "The judge worker's settings on top of worker_env (env: the judges queue and the judge models' queues), its Auto Scaling group if the module runs it, and each self-hosted judge model like a workers entry (models)."
  value = {
    env = {
      STUDIO_JUDGE_QUEUE_URL = aws_sqs_queue.judges.url
      STUDIO_QUEUES          = local.judge_queues
    }
    ec2_autoscaling_group = contains(keys(local.fleets), "judges") ? aws_autoscaling_group.ec2_workers["judges"].name : ""
    models                = { for k in keys(var.judge_worker.models) : k => local.entry_out[k] }
  }
}

output "judge_worker_args" {
  description = "The judge worker's command line, as an alternative to its environment."
  value       = "temperwork-worker judge-worker --control ${local.control_uri} --connection ${local.environment_id} --queue-url ${aws_sqs_queue.judges.url}"
}

output "worker_policy_json" {
  description = "The workers' IAM policy (queues, both buckets, Bedrock, the enrollment token). Attach it to the role or user of workers you run another way (ECS, Kubernetes, outside AWS)."
  value       = data.aws_iam_policy_document.worker.json
}

output "queues" {
  description = "Every queue's URL and ARN, by its id: model:<model>, training:<model>, judges."
  value = merge(
    { for k in keys(local.entries) : local.queue_ids[k] => { url = aws_sqs_queue.workers[k].url, arn = aws_sqs_queue.workers[k].arn } },
    { judges = { url = aws_sqs_queue.judges.url, arn = aws_sqs_queue.judges.arn } },
  )
}

output "ec2_autoscaling_groups" {
  description = "The Auto Scaling groups the module runs, by key (workers and judge_worker.models), and judges for the judge worker."
  value       = { for k, g in aws_autoscaling_group.ec2_workers : k => g.name }
}

output "bucket" {
  description = "The data bucket."
  value       = local.bucket
}

output "data_bucket_arn" {
  description = "The data bucket's ARN."
  value       = local.bucket_arn
}

output "control_bucket" {
  description = "The control bucket: temperwork's records, shared with your workers."
  value       = local.control
}

output "control_bucket_arn" {
  description = "The control bucket's ARN."
  value       = local.control_arn
}

output "control_uri" {
  description = "Where in the control bucket the records go (STUDIO_CONTROL_URI)."
  value       = local.control_uri
}

output "control_plane_role_arn" {
  description = "The control-plane role: what temperwork assumes in your account."
  value       = aws_iam_role.temperwork.arn
}

output "worker_role_arn" {
  description = "The workers' role (EC2)."
  value       = aws_iam_role.worker.arn
}

output "worker_role_name" {
  description = "The workers' role's name, to attach more policies to."
  value       = aws_iam_role.worker.name
}

output "worker_instance_profile" {
  description = "The workers' instance profile, for EC2."
  value       = aws_iam_instance_profile.worker.name
}

output "ec2_user_data_path" {
  description = "The EC2 user data script the module's instances run; fill in its settings block to launch instances yourself."
  value       = "${path.module}/ec2-user-data.sh"
}
