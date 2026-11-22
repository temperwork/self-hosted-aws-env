# Everything the temperwork module needs, in an account that has none of it
# yet: a VPC with an S3 endpoint (network.tf), optionally a Client VPN for
# browsers outside AWS (vpn.tf), and the module itself. See README.md.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
    tls = { source = "hashicorp/tls", version = ">= 4.0" }
  }

  # Keep the state somewhere durable and shared, e.g.:
  # backend "s3" {
  #   bucket       = "my-terraform-state"
  #   key          = "temperwork/terraform.tfstate"
  #   region       = "us-west-2"
  #   use_lockfile = true
  # }
}

provider "aws" {
  region = var.region
  default_tags {
    tags = var.tags
  }
}

module "temperwork" {
  source          = "../../modules/temperwork"
  name            = var.name
  studio_role_arn = var.studio_role_arn
  external_id     = var.external_id
  studio_origins  = var.studio_origins

  # The studio's links to your data work only through this VPC's S3
  # endpoints: from instances in the VPC and, with vpn = true, from
  # browsers on the VPN.
  vpc_endpoint_ids = compact([
    aws_vpc_endpoint.s3_gateway.id,
    var.vpn ? aws_vpc_endpoint.s3_interface[0].id : "",
  ])

  judge_models           = var.judge_models
  enroll_token_parameter = var.enroll_token_parameter
}
