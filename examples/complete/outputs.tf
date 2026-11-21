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

output "subnet_ids" {
  description = "Launch workers in these subnets."
  value       = module.network.subnet_ids
}

output "security_group_id" {
  description = "The VPC's default security group, for workers."
  value       = module.network.default_security_group_id
}

output "browser_endpoint" {
  description = "With vpn: optional browser endpoint for the Add environment form."
  value       = module.network.browser_endpoint
}

output "vpn_client_config" {
  description = "With vpn: the OpenVPN / AWS VPN Client profile (holds a private key). terraform output -raw vpn_client_config > studio.ovpn"
  value       = module.network.vpn_client_config
  sensitive   = true
}
