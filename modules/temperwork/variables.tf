variable "name" {
  description = "A short name for the environment: it names the queues, the bucket (<name>-data) and the roles. Lowercase letters, digits and hyphens (e.g. acme-studio)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.name))
    error_message = "name: 3 to 42 lowercase letters, digits or hyphens, not starting or ending with a hyphen."
  }
}

variable "studio_role_arn" {
  description = "The temperwork studio's role, which your studio role trusts. Shown on the studio's Add environment form (Settings → Environments)."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.studio_role_arn))
    error_message = "studio_role_arn: an IAM role ARN (arn:aws:iam::<account>:role/<name>)."
  }
}

variable "external_id" {
  description = "The external id the studio sends when it assumes your role. The Add environment form suggests a random one; enter the same value in both places."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.external_id) >= 16
    error_message = "external_id: at least 16 characters. Use the random one the studio suggests."
  }
}

variable "bucket" {
  description = "An existing bucket for your data, or empty to make one named <name>-data. The studio can read it only through links that work from your network, and never write to it."
  type        = string
  default     = ""
}

variable "control_bucket" {
  description = "An existing, empty bucket for the studio's records (not your data's bucket), or empty to make one named <name>-control."
  type        = string
  default     = ""
}

variable "bucket_policy_source_documents" {
  description = "With an existing bucket: its current bucket policy (JSON), and any other statements to keep. The module writes the bucket's whole policy, so statements not listed here are removed."
  type        = list(string)
  default     = []
}

variable "prefix" {
  description = "Where in the data bucket your workers write outputs (<prefix>datasets/) and LoRAs (<prefix>loras/). Ends with a slash."
  type        = string
  default     = "studio/"
  validation {
    condition     = var.prefix == "" || endswith(var.prefix, "/")
    error_message = "prefix: empty, or ending with a slash (e.g. studio/)."
  }
}

variable "studio_origins" {
  description = "The studio page's origin, allowed by the bucket's CORS rule: the page opens your listings and files itself."
  type        = list(string)
  default     = ["https://temperwork.com"]
}

variable "browser_access" {
  description = <<-EOT
    Where the links the studio signs for your data work (they act as the studio's role):
      vpce: only through your S3 VPC endpoints (vpc_endpoint_id, vpc_endpoint_ids): on your VPN or in your VPC
      ip:   only from your public IP ranges (browser_cidrs): your office or VPN egress; no VPN needed
      open: from anywhere, and the studio's role can then read your data itself (not recommended)
  EOT
  type        = string
  default     = "vpce"
  validation {
    condition     = contains(["vpce", "ip", "open"], var.browser_access)
    error_message = "browser_access: vpce, ip or open."
  }
}

variable "vpc_endpoint_id" {
  description = "With browser_access = vpce: your S3 VPC endpoint (an interface endpoint for browsers on a VPN, or a gateway endpoint for browsers inside the VPC)."
  type        = string
  default     = ""
}

variable "vpc_endpoint_ids" {
  description = "More S3 VPC endpoints, beside vpc_endpoint_id (e.g. a gateway and an interface endpoint in the same VPC)."
  type        = list(string)
  default     = []
}

variable "browser_cidrs" {
  description = "With browser_access = ip: the public IP ranges your browsers reach S3 from (e.g. [\"203.0.113.0/24\"])."
  type        = list(string)
  default     = []
}

variable "worker_principals" {
  description = "AWS services that may assume the workers' role. Add pods.eks.amazonaws.com for EKS Pod Identity."
  type        = list(string)
  default     = ["ec2.amazonaws.com", "ecs-tasks.amazonaws.com"]
}

variable "worker_assumers" {
  description = "IAM users or roles (ARNs) that may assume the workers' role: for GPUs outside AWS, which can't be given a role directly."
  type        = list(string)
  default     = []
}

variable "judge_models" {
  description = "Judge models you host yourselves (e.g. qwen3-vl-8b): each gets a queue its model pods take grading work from. Empty: judge steps on those models call the model's API instead."
  type        = list(string)
  default     = []
}

variable "enroll_token_parameter" {
  description = "Optional: the name of an SSM parameter (e.g. /studio/enroll-token) holding the workers' enrollment token. The workers' role may then read it, as ec2-user-data.sh does."
  type        = string
  default     = ""
  validation {
    condition     = var.enroll_token_parameter == "" || startswith(var.enroll_token_parameter, "/")
    error_message = "enroll_token_parameter: empty, or a parameter name starting with a slash."
  }
}

variable "allow_bedrock_model_subscription" {
  description = "Let the workers' role subscribe the account to Anthropic models on AWS Marketplace, which Bedrock does on a model's first call. Turn off if you enable the models yourselves."
  type        = bool
  default     = true
}
