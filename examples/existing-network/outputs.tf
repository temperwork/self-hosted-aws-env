output "environment" {
  description = "Paste into the studio's Add environment form (with your external id)."
  value       = module.environment.environment
}

output "worker_env" {
  description = "The workers' environment variables."
  value       = module.environment.worker_env
}

output "judge_worker_args" {
  description = "The judge worker's command line."
  value       = module.environment.judge_worker_args
}

output "judge_worker_env" {
  description = "The judge worker's extra environment variables."
  value       = module.environment.judge_worker_env
}

output "bucket" {
  value = module.environment.bucket
}

output "worker_instance_profile" {
  description = "Launch EC2 workers with this instance profile."
  value       = module.environment.worker_instance_profile
}

output "worker_role_arn" {
  value = module.environment.worker_role_arn
}
