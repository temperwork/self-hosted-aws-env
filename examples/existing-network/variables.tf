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

variable "ec2_workers" {
  description = "How many always-on EC2 GPU instances run workers. 0: none."
  type        = number
  default     = 0
}

variable "environment_id" {
  description = "The id you gave the environment in temperwork. Empty: name."
  type        = string
  default     = ""
}

variable "worker_image" {
  description = "With ec2_workers: the worker image (a customer-prod-latest tag)."
  type        = string
  default     = ""
}

variable "worker_queue" {
  description = "With ec2_workers: runs (inference images) or trainings (trainer images)."
  type        = string
  default     = "runs"
}

variable "judge_worker_image" {
  description = "With ec2_workers: also run a judge worker on each instance from this image. Empty: none."
  type        = string
  default     = ""
}

variable "ec2_instance_type" {
  description = "With ec2_workers: the GPU instance type."
  type        = string
  default     = "g6e.xlarge"
}

variable "ec2_subnet_ids" {
  description = "With ec2_workers: the subnets the instances go in (reaching temperwork.com, the registry, Hugging Face and S3)."
  type        = list(string)
  default     = []
}

variable "ec2_security_group_ids" {
  description = "With ec2_workers: their security groups. Empty: one allowing no inbound, all outbound."
  type        = list(string)
  default     = []
}
