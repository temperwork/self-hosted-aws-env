# The temperwork module in an account that already has its network: you
# bring your own S3 VPC endpoint, and optionally your own data bucket.

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
  source              = "../../modules/temperwork"
  name                = var.name
  temperwork_role_arn = var.temperwork_role_arn
  external_id         = var.external_id
  temperwork_origins  = var.temperwork_origins

  bucket                         = var.bucket
  control_bucket                 = var.control_bucket
  bucket_policy_source_documents = var.existing_bucket_policy_file != "" ? [file(var.existing_bucket_policy_file)] : []
  prefix                         = var.prefix

  vpc_endpoint_ids = var.vpc_endpoint_ids

  worker_principals      = var.worker_principals
  worker_assumers        = var.worker_assumers
  judge_models           = var.judge_models
  enroll_token_parameter = var.enroll_token_parameter
}
