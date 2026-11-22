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
  description = "The data bucket."
  value       = module.temperwork.bucket
}

output "control_bucket" {
  description = "The control bucket: temperwork's records."
  value       = module.temperwork.control_bucket
}

output "worker_instance_profile" {
  description = "Launch EC2 workers with this instance profile."
  value       = module.temperwork.worker_instance_profile
}

output "worker_role_arn" {
  value = module.temperwork.worker_role_arn
}

output "ec2_user_data_path" {
  description = "The EC2 user data script for workers."
  value       = module.temperwork.ec2_user_data_path
}

output "subnet_ids" {
  description = "Launch workers in these subnets."
  value       = aws_subnet.public[*].id
}

output "security_group_id" {
  description = "The VPC's default security group, for workers."
  value       = aws_vpc.this.default_security_group_id
}

output "browser_endpoint" {
  description = "With vpn: optional browser endpoint for the Add environment form (with private DNS the bucket's own name works over the VPN)."
  value       = var.vpn ? "https://bucket.${local.interface_dns}" : ""
}

output "vpn_client_config" {
  description = "With vpn: the OpenVPN / AWS VPN Client profile (holds a private key). terraform output -raw vpn_client_config > temperwork.ovpn"
  sensitive   = true
  value = var.vpn ? join("\n", [
    "client",
    "dev tun",
    "proto udp",
    "remote ${local.vpn_host} 443",
    "remote-random-hostname",
    "resolv-retry infinite",
    "nobind",
    "remote-cert-tls server",
    "cipher AES-256-GCM",
    "verb 3",
    "reneg-sec 0",
    "<ca>", trimspace(tls_self_signed_cert.ca[0].cert_pem), "</ca>",
    "<cert>", trimspace(tls_locally_signed_cert.client[0].cert_pem), "</cert>",
    "<key>", trimspace(tls_private_key.client[0].private_key_pem), "</key>",
    "",
  ]) : ""
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
