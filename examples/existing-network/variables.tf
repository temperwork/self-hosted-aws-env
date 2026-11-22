variable "name" {
  description = "A short name for the environment (e.g. acme): names the queues, bucket and roles."
  type        = string
}

variable "region" {
  description = "The AWS region for everything."
  type        = string
  default     = "us-west-2"
}

variable "temperwork_role_arn" {
  description = "The temperwork control plane's own role, from temperwork's Add environment form."
  type        = string
}

variable "external_id" {
  description = "The external id from temperwork's Add environment form."
  type        = string
  sensitive   = true
}

variable "temperwork_origins" {
  description = "temperwork page's origin, for the bucket's CORS rule."
  type        = list(string)
  default     = ["https://temperwork.com"]
}

variable "bucket" {
  description = "An existing bucket, or empty to make <name>-data. An existing bucket's policy is replaced: see existing_bucket_policy_file."
  type        = string
  default     = ""
}

variable "control_bucket" {
  description = "An existing, empty bucket for temperwork's records (not your data's bucket), or empty to make <name>-control."
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
  default     = "temperwork/"
}

variable "vpc_endpoint_ids" {
  description = "Your S3 VPC endpoint ids (an interface endpoint your VPN reaches, a gateway endpoint for in-VPC browsers, or both). Required."
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

variable "environment_id" {
  description = "The id you gave the environment in temperwork. Empty: name."
  type        = string
  default     = ""
}

variable "ec2_subnet_ids" {
  description = "With EC2 instances: the subnets they go in (reaching temperwork.com, the registry, Hugging Face and S3)."
  type        = list(string)
  default     = []
}

variable "ec2_security_group_ids" {
  description = "With EC2 instances: their security groups. Empty: one allowing no inbound, all outbound."
  type        = list(string)
  default     = []
}

variable "workers" {
  description = "One entry per model and kind of work, each with its own queue and, with instances > 0, its own always-on EC2 instances. See docs/workers.md."
  type        = any
  default     = {}
}

variable "judge_worker" {
  description = "The judge worker: image, and instances to run it on EC2. See docs/workers.md."
  type        = any
  default     = {}
}

variable "bedrock_models" {
  description = "Bedrock model ids (wildcards allowed) the judge workers' LLM steps may call."
  type        = list(string)
  default     = ["anthropic.claude-*"]
}
