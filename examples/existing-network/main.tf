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

  judge_models           = var.judge_models
  enroll_token_parameter = var.enroll_token_parameter

  ec2_workers            = var.ec2_workers
  environment_id         = var.environment_id
  worker_image           = var.worker_image
  worker_queue           = var.worker_queue
  judge_worker_image     = var.judge_worker_image
  ec2_instance_type      = var.ec2_instance_type
  ec2_subnet_ids         = var.ec2_subnet_ids
  ec2_security_group_ids = var.ec2_security_group_ids
}
