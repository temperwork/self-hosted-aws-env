# What to give the studio and your workers.

output "environment" {
  description = "The studio's Add environment form (Settings → Environments). Add the external id yourself."
  value = {
    queue_url       = aws_sqs_queue.runs.url
    judge_queue_url = aws_sqs_queue.judges.url
    train_queue_url = aws_sqs_queue.trainings.url
    data_root       = "s3://${local.bucket}/${var.prefix}"
    region          = local.region
    credentials     = { kind = "role", role_arn = aws_iam_role.studio.arn }
  }
}

output "worker_env" {
  description = "The pod service's environment. Add STUDIO_CONNECTION_ID (the id you gave the environment), STUDIO_URL and STUDIO_ENROLL_TOKEN (the environment's card: Make an enrollment token)."
  value = {
    STUDIO_CONTROL_URI     = "s3://${local.bucket}/${local.control}"
    STUDIO_QUEUE_URL       = aws_sqs_queue.runs.url
    STUDIO_TRAIN_QUEUE_URL = aws_sqs_queue.trainings.url
    AWS_REGION             = local.region
  }
}

output "bucket" {
  description = "The data bucket."
  value       = local.bucket
}

output "control_uri" {
  description = "The control prefix the studio and your workers share."
  value       = "s3://${local.bucket}/${local.control}"
}

output "browser_access" {
  description = "Where the studio's signed links to your data work."
  value       = var.browser_access
}

output "studio_role_arn" {
  description = "The role the studio assumes in your account."
  value       = aws_iam_role.studio.arn
}

output "worker_role_arn" {
  description = "The workers' role: STUDIO_AWS_ROLE_ARN for a worker outside AWS (with worker_assumers)."
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

output "judge_worker_args" {
  description = "The judge worker's command line. Replace <id> with the environment's id."
  value       = "temperwork-worker judge-worker --control s3://${local.bucket}/${local.control} --connection <id> --queue-url ${aws_sqs_queue.judges.url}"
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
