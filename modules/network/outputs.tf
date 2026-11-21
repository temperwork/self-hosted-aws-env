output "vpc_id" {
  value = aws_vpc.this.id
}

output "subnet_ids" {
  value = aws_subnet.public[*].id
}

output "default_security_group_id" {
  value = aws_vpc.this.default_security_group_id
}

output "s3_endpoint_ids" {
  description = "The environment module's vpc_endpoint_ids: the gateway, and the interface endpoint with vpn"
  value       = compact([aws_vpc_endpoint.s3_gateway.id, var.vpn ? aws_vpc_endpoint.s3_interface[0].id : ""])
}

output "browser_endpoint" {
  description = "With vpn: the Add environment form's browser endpoint for the interface endpoint (optional: with private DNS the bucket's own name works over the VPN)"
  value       = var.vpn ? "https://bucket.${local.interface_dns}" : ""
}

output "vpn_endpoint_id" {
  value = var.vpn ? aws_ec2_client_vpn_endpoint.this[0].id : ""
}

output "vpn_client_config" {
  description = "With vpn: the client's configuration (AWS VPN Client or OpenVPN), its key included"
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
