output "environment" {
  description = "Paste into temperwork's Add environment form (with your external id)."
  value       = module.temperwork.environment
}

output "worker_env" {
  description = "The workers' environment variables."
  value       = module.temperwork.worker_env
}

output "judge_worker_args" {
  description = "The judge worker's command line."
  value       = module.temperwork.judge_worker_args
}

output "judge_worker_env" {
  description = "The judge worker's extra environment variables."
  value       = module.temperwork.judge_worker_env
}

output "bucket" {
  value = module.temperwork.bucket
}

output "worker_instance_profile" {
  description = "Launch EC2 workers with this instance profile."
  value       = module.temperwork.worker_instance_profile
}

output "worker_role_arn" {
  value = module.temperwork.worker_role_arn
}

output "control_bucket" {
  description = "The control bucket: temperwork's records."
  value       = module.temperwork.control_bucket
}

output "ec2_user_data_path" {
  description = "The EC2 user data script for workers."
  value       = module.temperwork.ec2_user_data_path
}

output "worker_policy_json" {
  description = "The workers' IAM policy, for workers you run another way."
  value       = module.temperwork.worker_policy_json
}

output "queues" {
  description = "Every queue's URL and ARN."
  value       = module.temperwork.queues
}

output "ec2_autoscaling_group" {
  description = "With ec2_workers: the Auto Scaling group running them."
  value       = module.temperwork.ec2_autoscaling_group
}
