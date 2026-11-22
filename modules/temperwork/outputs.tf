# What to give temperwork and your workers.

output "environment" {
  description = "temperwork's Add environment form (Settings → Environments). Add the external id yourself."
  value = {
    queue_url       = aws_sqs_queue.runs.url
    judge_queue_url = aws_sqs_queue.judges.url
    train_queue_url = aws_sqs_queue.trainings.url
    data_root       = "s3://${local.bucket}/${var.prefix}"
    control_uri     = local.control_uri
    region          = local.region
    credentials     = { kind = "role", role_arn = aws_iam_role.temperwork.arn }
  }
}

output "worker_env" {
  description = "Every worker's environment, wherever it runs. Add STUDIO_ENROLL_TOKEN (the environment's card: Make an enrollment token) for its first start. A pod takes STUDIO_QUEUE_URL (inference) or STUDIO_TRAIN_QUEUE_URL (trainer images); a judge worker takes STUDIO_JUDGE_QUEUE_URL, and STUDIO_QUEUES from judge_worker_env."
  value = {
    STUDIO_URL             = var.temperwork_url
    STUDIO_CONNECTION_ID   = local.environment_id
    STUDIO_CONTROL_URI     = local.control_uri
    STUDIO_LORA_URI        = local.lora_uri
    STUDIO_QUEUE_URL       = aws_sqs_queue.runs.url
    STUDIO_TRAIN_QUEUE_URL = aws_sqs_queue.trainings.url
    STUDIO_JUDGE_QUEUE_URL = aws_sqs_queue.judges.url
    AWS_REGION             = local.region
  }
}

output "worker_policy_json" {
  description = "The workers' IAM policy (queues, both buckets, Bedrock, the enrollment token). Attach it to the role or user of workers you run another way (ECS, Kubernetes, outside AWS)."
  value       = data.aws_iam_policy_document.worker.json
}

output "queues" {
  description = "Every queue's URL and ARN: runs, trainings, judges, and model:<name> for each judge model."
  value = merge(
    {
      runs      = { url = aws_sqs_queue.runs.url, arn = aws_sqs_queue.runs.arn }
      trainings = { url = aws_sqs_queue.trainings.url, arn = aws_sqs_queue.trainings.arn }
      judges    = { url = aws_sqs_queue.judges.url, arn = aws_sqs_queue.judges.arn }
    },
    { for m, q in aws_sqs_queue.models : "model:${m}" => { url = q.url, arn = q.arn } },
  )
}

output "data_bucket_arn" {
  description = "The data bucket's ARN."
  value       = local.bucket_arn
}

output "control_bucket_arn" {
  description = "The control bucket's ARN."
  value       = local.control_arn
}

output "ec2_autoscaling_group" {
  description = "With ec2_workers: the Auto Scaling group running them."
  value       = local.ec2 ? aws_autoscaling_group.ec2_workers[0].name : ""
}

output "bucket" {
  description = "The data bucket."
  value       = local.bucket
}

output "control_bucket" {
  description = "The control bucket: temperwork's records, shared with your workers."
  value       = local.control
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
  description = "The workers' role's name, to attach more policies to (e.g. to pull images from your ECR)."
  value       = aws_iam_role.worker.name
}

output "worker_instance_profile" {
  description = "The workers' instance profile, for EC2."
  value       = aws_iam_instance_profile.worker.name
}

output "ec2_user_data_path" {
  description = "The EC2 user data script that runs workers (fill in its settings block)."
  value       = "${path.module}/ec2-user-data.sh"
}

output "judge_worker_args" {
  description = "The judge worker's command line."
  value       = "temperwork-worker judge-worker --control ${local.control_uri} --connection ${local.environment_id} --queue-url ${aws_sqs_queue.judges.url}"
}

output "judge_worker_env" {
  description = "A judge worker's environment besides its flags: the judge models' queues, and the Bedrock region."
  value = {
    STUDIO_QUEUES = jsonencode([for m, q in aws_sqs_queue.models : { id = "model:${m}", kind = "sqs", url = q.url }])
    AWS_REGION    = local.region
  }
}

output "judge_model_env" {
  description = "Each self-hosted judge model pod's queue (with STUDIO_POD_RUNS=grading and the worker_env settings)."
  value       = { for m, q in aws_sqs_queue.models : m => { STUDIO_MODEL_QUEUE_URL = q.url } }
}
