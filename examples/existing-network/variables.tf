variable "name" {
  description = "A short name for the environment (e.g. acme-studio): names the queues, bucket and roles."
  type        = string
}

variable "region" {
  description = "The AWS region for everything."
  type        = string
  default     = "us-west-2"
}

variable "studio_role_arn" {
  description = "The studio's role, from the studio's Add environment form."
  type        = string
}

variable "external_id" {
  description = "The external id from the studio's Add environment form."
  type        = string
  sensitive   = true
}

variable "studio_origins" {
  description = "The studio page's origin, for the bucket's CORS rule."
  type        = list(string)
  default     = ["https://temperwork.com"]
}

variable "bucket" {
  description = "An existing bucket, or empty to make <name>-data. An existing bucket's policy is replaced: see existing_bucket_policy_file."
  type        = string
  default     = ""
}

variable "control_bucket" {
  description = "An existing, empty bucket for the studio's records (not your data's bucket), or empty to make <name>-control."
  type        = string
  default     = ""
}

variable "existing_bucket_policy_file" {
  description = "With an existing bucket that has a policy: a file holding that policy's JSON, so its statements are kept (the module writes the whole policy)."
  type        = string
  default     = ""
}

variable "prefix" {
  description = "Where in the data bucket your workers write outputs and LoRAs."
  type        = string
  default     = "studio/"
}

variable "vpc_endpoint_ids" {
  description = "Your S3 VPC endpoint ids (an interface endpoint your VPN reaches, a gateway endpoint for in-VPC browsers, or both). Required."
  type        = list(string)
  default     = []
}

variable "worker_principals" {
  description = "AWS services that may assume the workers' role."
  type        = list(string)
  default     = ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com"]
}

variable "worker_assumers" {
  description = "IAM users or roles that may assume the workers' role (workers outside AWS)."
  type        = list(string)
  default     = []
}

variable "judge_models" {
  description = "Judge models you host yourselves."
  type        = list(string)
  default     = []
}

variable "enroll_token_parameter" {
  description = "The SSM parameter holding the workers' enrollment token, or empty."
  type        = string
  default     = ""
}

variable "tags" {
  description = "Tags on everything this makes."
  type        = map(string)
  default     = {}
}
