variable "name" {
  description = "A short name for the environment (e.g. acme): names the VPC, queues, bucket and roles."
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

variable "cidr" {
  description = "The VPC's address range. Must not overlap vpn_client_cidr."
  type        = string
  default     = "10.42.0.0/16"
}

variable "zone_names" {
  description = "Availability zones for the subnets (pick ones that offer your GPU type); empty: the region's first two."
  type        = list(string)
  default     = []
}

variable "vpn_client_cidr" {
  description = "Addresses the Client VPN gives its clients: a /22 or larger, outside cidr."
  type        = string
  default     = "10.200.0.0/22"
}

variable "vpn" {
  description = "Make an AWS Client VPN and an S3 interface endpoint so browsers outside AWS can open your files (billed by the hour)."
  type        = bool
  default     = false
}

variable "enroll_token_parameter" {
  description = "The SSM parameter holding the workers' enrollment token (e.g. /temperwork/enroll-token), or empty."
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
