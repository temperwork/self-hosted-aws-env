# A temperwork environment in your AWS account: what temperwork (the control
# plane) and your workers (the data plane) share, and nothing more. See the
# README and docs/security-model.md for the whole picture.
#
#   data_bucket.tf     your datasets and what your workers write; its policy
#                      lets temperwork read only through your VPC endpoints
#   control_bucket.tf  the records temperwork shares with your workers: the
#                      only S3 temperwork writes
#   queues.tf          the SQS FIFO queues temperwork sends work to
#   control_plane.tf   the role temperwork assumes in your account
#   workers.tf         the workers' permissions, role and instance profile
#   ec2_workers.tf     optional always-on EC2 workers (ec2_workers > 0)

data "aws_region" "current" {}
data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  region    = data.aws_region.current.region
  partition = data.aws_partition.current.partition
  endpoints = compact(distinct(concat([var.vpc_endpoint_id], var.vpc_endpoint_ids)))

  bucket         = var.bucket != "" ? var.bucket : aws_s3_bucket.data[0].bucket
  bucket_arn     = "arn:${local.partition}:s3:::${local.bucket}"
  control        = var.control_bucket != "" ? var.control_bucket : aws_s3_bucket.control[0].bucket
  control_arn    = "arn:${local.partition}:s3:::${local.control}"
  control_prefix = ".studio/" # the workers expect the control URI to end in .studio/
  control_uri    = "s3://${local.control}/${local.control_prefix}"
  lora_uri       = "s3://${local.bucket}/${var.prefix}loras/"
  environment_id = var.environment_id != "" ? var.environment_id : var.name
}
