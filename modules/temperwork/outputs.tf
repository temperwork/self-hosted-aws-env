# What to give temperwork and your workers.

output "environment" {
  description = "temperwork's Add environment form (Settings → Environments). Add the external id yourself. temperwork uses only the queues listed here: each has the id temperwork sends that work under, what it's for, and its URL."
  value = {
    queues = concat(
      [for k, w in var.workers : {
        id    = local.worker_queue_ids[k]
        work  = w.work
        model = w.model
        url   = aws_sqs_queue.workers[k].url
      }],
      [{ id = "judges", work = "judging", model = "", url = aws_sqs_queue.judges.url }],
    )
    data_root   = "s3://${local.bucket}/${var.prefix}"
    control_uri = local.control_uri
    region      = local.region
    credentials = { kind = "role", role_arn = aws_iam_role.temperwork.arn }
  }
}

output "worker_env" {
  description = "What every worker needs, wherever it runs. Add STUDIO_ENROLL_TOKEN (the environment's card: Make an enrollment token) for its first start, and the queue settings in workers (pods) or judge_worker_env (the judge worker)."
  value = {
    STUDIO_URL           = var.temperwork_url
    STUDIO_CONNECTION_ID = local.environment_id
    STUDIO_CONTROL_URI   = local.control_uri
    STUDIO_LORA_URI      = local.lora_uri
    AWS_REGION           = local.region
  }
}

output "workers" {
  description = "Each workers entry: its queue, and the settings its pods take on top of worker_env (whether the module runs them on EC2 or you run them yourself)."
  value = { for k, w in var.workers : k => {
    queue_id  = local.worker_queue_ids[k]
    queue_url = aws_sqs_queue.workers[k].url
    queue_arn = aws_sqs_queue.workers[k].arn
    env = merge(
      { STUDIO_POD_MODEL = w.model, STUDIO_POD_RUNS = w.work },
      w.work == "training" ? {
        STUDIO_TRAIN_QUEUE_URL = aws_sqs_queue.workers[k].url
        STUDIO_TRAIN_QUEUE_ID  = local.worker_queue_ids[k]
        } : w.work == "inference" ? {
        STUDIO_QUEUE_URL       = aws_sqs_queue.workers[k].url
        STUDIO_QUEUE_ID        = local.worker_queue_ids[k]
        STUDIO_MODEL_QUEUE_URL = aws_sqs_queue.workers[k].url
      } : { STUDIO_MODEL_QUEUE_URL = aws_sqs_queue.workers[k].url },
    )
    ec2_autoscaling_group = contains(keys(local.fleets), k) ? aws_autoscaling_group.ec2_workers[k].name : ""
  } }
}

output "judge_worker_env" {
  description = "The judge worker's settings on top of worker_env: the judges queue, and the self-hosted judge models' grading queues."
  value = {
    STUDIO_JUDGE_QUEUE_URL = aws_sqs_queue.judges.url
    STUDIO_QUEUES          = local.judge_queues
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
    { for k, w in var.workers : local.worker_queue_ids[k] => { url = aws_sqs_queue.workers[k].url, arn = aws_sqs_queue.workers[k].arn } },
    { judges = { url = aws_sqs_queue.judges.url, arn = aws_sqs_queue.judges.arn } },
  )
}

output "ec2_autoscaling_groups" {
  description = "The Auto Scaling groups the module runs, by workers key (and judges for the judge worker)."
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
