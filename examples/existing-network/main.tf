# A temperwork environment in an account that already has its network: you
# bring your own S3 VPC endpoint (browser_access = vpce) or your browsers'
# public IP ranges (browser_access = ip), and optionally your own bucket.

terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0" }
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

  bucket                         = var.bucket
  control_bucket                 = var.control_bucket
  bucket_policy_source_documents = var.existing_bucket_policy_file != "" ? [file(var.existing_bucket_policy_file)] : []
  prefix                         = var.prefix

  browser_access   = var.browser_access
  vpc_endpoint_ids = var.vpc_endpoint_ids
  browser_cidrs    = var.browser_cidrs

  worker_principals      = var.worker_principals
  worker_assumers        = var.worker_assumers
  judge_models           = var.judge_models
  enroll_token_parameter = var.enroll_token_parameter
}
