# With vpn = true: the way in for your people's browsers outside AWS. An S3
# interface endpoint with private DNS (the bucket's name resolves to it
# inside the VPC and over the VPN) and an AWS Client VPN endpoint (mutual
# TLS, split tunnel: only the VPC's range goes through it). Both bill by the
# hour, so turn vpn off when no one needs it.
#
# The VPN's certificates here are made by Terraform (a CA, a server and one
# client certificate, kept in the state): fine to try it, but for real use
# issue client certificates per person from a CA you keep outside the state,
# or use SAML / IAM Identity Center authentication.

resource "aws_security_group" "endpoint" {
  count       = var.vpn ? 1 : 0
  name        = "${var.name}-s3-endpoint"
  description = "HTTPS to the S3 interface endpoint from the VPC (VPN clients arrive from the VPC's range)"
  vpc_id      = aws_vpc.this.id
  ingress {
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.cidr]
  }
}

resource "aws_vpc_endpoint" "s3_interface" {
  count               = var.vpn ? 1 : 0
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [aws_subnet.public[0].id] # one zone: it bills per zone
  security_group_ids  = [aws_security_group.endpoint[0].id]
  private_dns_enabled = true
  # Every lookup in the VPC (the VPN's clients use its resolver) gets the
  # interface endpoint's addresses, not only lookups through an inbound
  # Route 53 Resolver endpoint: the gateway endpoint then carries nothing
  # resolved by name.
  dns_options {
    private_dns_only_for_inbound_resolver_endpoint = false
  }
  depends_on = [aws_vpc_endpoint.s3_gateway]
  tags       = { Name = "${var.name}-s3-interface" }
}

resource "tls_private_key" "ca" {
  count     = var.vpn ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "ca" {
  count                 = var.vpn ? 1 : 0
  private_key_pem       = tls_private_key.ca[0].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 24 * 365
  allowed_uses          = ["cert_signing", "crl_signing"]
  subject {
    common_name  = "${var.name} VPN CA"
    organization = var.name
  }
}

resource "tls_private_key" "server" {
  count     = var.vpn ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "server" {
  count           = var.vpn ? 1 : 0
  private_key_pem = tls_private_key.server[0].private_key_pem
  dns_names       = ["server.${var.name}.vpn"]
  subject {
    common_name = "server.${var.name}.vpn"
  }
}

resource "tls_locally_signed_cert" "server" {
  count                 = var.vpn ? 1 : 0
  cert_request_pem      = tls_cert_request.server[0].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca[0].private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca[0].cert_pem
  validity_period_hours = 24 * 365
  allowed_uses          = ["digital_signature", "key_encipherment", "server_auth"]
}

resource "tls_private_key" "client" {
  count     = var.vpn ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "client" {
  count           = var.vpn ? 1 : 0
  private_key_pem = tls_private_key.client[0].private_key_pem
  dns_names       = ["client.${var.name}.vpn"]
  subject {
    common_name = "client.${var.name}.vpn"
  }
}

resource "tls_locally_signed_cert" "client" {
  count                 = var.vpn ? 1 : 0
  cert_request_pem      = tls_cert_request.client[0].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca[0].private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca[0].cert_pem
  validity_period_hours = 24 * 365
  allowed_uses          = ["digital_signature", "key_encipherment", "client_auth"]
}

# Imported, not issued by ACM Private CA (which costs ~$400 a month).
resource "aws_acm_certificate" "server" {
  count             = var.vpn ? 1 : 0
  private_key       = tls_private_key.server[0].private_key_pem
  certificate_body  = tls_locally_signed_cert.server[0].cert_pem
  certificate_chain = tls_self_signed_cert.ca[0].cert_pem
  tags              = { Name = "${var.name}-vpn-server" }
}

resource "aws_acm_certificate" "client_ca" {
  count             = var.vpn ? 1 : 0
  private_key       = tls_private_key.client[0].private_key_pem
  certificate_body  = tls_locally_signed_cert.client[0].cert_pem
  certificate_chain = tls_self_signed_cert.ca[0].cert_pem
  tags              = { Name = "${var.name}-vpn-clients" }
}

resource "aws_security_group" "vpn" {
  count       = var.vpn ? 1 : 0
  name        = "${var.name}-client-vpn"
  description = "The Client VPN's network interfaces: out to the VPC"
  vpc_id      = aws_vpc.this.id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.cidr]
  }
}

resource "aws_ec2_client_vpn_endpoint" "this" {
  count                  = var.vpn ? 1 : 0
  description            = "${var.name}: browsers to the S3 interface endpoint"
  server_certificate_arn = aws_acm_certificate.server[0].arn
  client_cidr_block      = var.vpn_client_cidr
  split_tunnel           = true                    # only the VPC's range: the studio and sign-in stay on the client's own internet
  dns_servers            = [cidrhost(var.cidr, 2)] # the VPC's resolver: the bucket's name resolves to the interface endpoint
  vpc_id                 = aws_vpc.this.id
  security_group_ids     = [aws_security_group.vpn[0].id]
  transport_protocol     = "udp"
  session_timeout_hours  = 8
  authentication_options {
    type                       = "certificate-authentication"
    root_certificate_chain_arn = aws_acm_certificate.client_ca[0].arn
  }
  connection_log_options {
    enabled = false
  }
  tags = { Name = "${var.name}-client-vpn" }
}

resource "aws_ec2_client_vpn_network_association" "this" {
  count                  = var.vpn ? 1 : 0
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this[0].id
  subnet_id              = aws_subnet.public[0].id # one association: they bill per subnet
}

resource "aws_ec2_client_vpn_authorization_rule" "vpc" {
  count                  = var.vpn ? 1 : 0
  client_vpn_endpoint_id = aws_ec2_client_vpn_endpoint.this[0].id
  target_network_cidr    = var.cidr
  authorize_all_groups   = true
}

locals {
  # The endpoint's own DNS name, for the Add environment form's browser endpoint (the
  # links are then signed for it, and resolve without private DNS).
  interface_dns = var.vpn ? trimprefix(aws_vpc_endpoint.s3_interface[0].dns_entry[0].dns_name, "*.") : ""
  vpn_host      = var.vpn ? trimprefix(aws_ec2_client_vpn_endpoint.this[0].dns_name, "*.") : ""
}
