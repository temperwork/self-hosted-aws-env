# A new VPC and a temperwork environment in it: the quickest way to start in
# an account that has no network for this yet. See the README.

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

module "network" {
  source     = "../../modules/network"
  name       = var.name
  cidr       = var.cidr
  zone_names = var.zone_names
  vpn        = var.vpn
}

module "environment" {
  source          = "../../modules/environment"
  name            = var.name
  studio_role_arn = var.studio_role_arn
  external_id     = var.external_id
  studio_origins  = var.studio_origins

  # Your data is readable through the VPC's S3 endpoints only: from
  # instances in the VPC and, with vpn = true, from browsers on the VPN.
  browser_access   = "vpce"
  vpc_endpoint_ids = module.network.s3_endpoint_ids

  judge_models           = var.judge_models
  enroll_token_parameter = var.enroll_token_parameter
}
