variable "name" {
  description = "A short name for the environment: it names the queues, the bucket (<name>-data) and the roles. Lowercase letters, digits and hyphens (e.g. acme)."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]{1,40}[a-z0-9]$", var.name))
    error_message = "name: 3 to 42 lowercase letters, digits or hyphens, not starting or ending with a hyphen."
  }
}

variable "temperwork_role_arn" {
  description = "temperwork's own role (in temperwork's account), which the role this module makes for temperwork trusts. Shown on temperwork's Add environment form (Settings → Environments)."
  type        = string
  validation {
    condition     = can(regex("^arn:aws[a-z-]*:iam::[0-9]{12}:role/", var.temperwork_role_arn))
    error_message = "temperwork_role_arn: an IAM role ARN (arn:aws:iam::<account>:role/<name>)."
  }
}

variable "external_id" {
  description = "The external id temperwork sends when it assumes your role. The Add environment form suggests a random one; enter the same value in both places."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.external_id) >= 16
    error_message = "external_id: at least 16 characters. Use the random one temperwork suggests."
  }
}

variable "bucket" {
  description = "An existing bucket for your data, or empty to make one named <name>-data. temperwork can read it only through links that work from your network, and never write to it."
  type        = string
  default     = ""
}

variable "control_bucket" {
  description = "An existing, empty bucket for temperwork's records (not your data's bucket), or empty to make one named <name>-control."
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
  default     = "temperwork/"
  validation {
    condition     = var.prefix == "" || endswith(var.prefix, "/")
    error_message = "prefix: empty, or ending with a slash (e.g. temperwork/)."
  }
}

variable "temperwork_origins" {
  description = "temperwork page's origin, allowed by the bucket's CORS rule: the page opens your listings and files itself."
  type        = list(string)
  default     = ["https://temperwork.com"]
}

variable "vpc_endpoint_id" {
  description = "Your S3 VPC endpoint: the only way temperwork's links to your data work (an interface endpoint for browsers on a VPN, or a gateway endpoint for browsers inside the VPC). Required (this or vpc_endpoint_ids)."
  type        = string
  default     = ""
}

variable "vpc_endpoint_ids" {
  description = "More S3 VPC endpoints, beside vpc_endpoint_id (e.g. a gateway and an interface endpoint in the same VPC)."
  type        = list(string)
  default     = []
}

variable "enroll_token_parameter" {
  description = "The name of an SSM parameter (e.g. /temperwork/enroll-token) holding the workers' enrollment token. The workers' role may then read it, as ec2-user-data.sh does. Required when any workers or judge_worker run on EC2 (instances > 0)."
  type        = string
  default     = ""
  validation {
    condition     = var.enroll_token_parameter == "" || startswith(var.enroll_token_parameter, "/")
    error_message = "enroll_token_parameter: empty, or a parameter name starting with a slash."
  }
}


variable "environment_id" {
  description = "The id you gave the environment in temperwork (STUDIO_CONNECTION_ID). Empty: name."
  type        = string
  default     = ""
}

variable "temperwork_url" {
  description = "temperwork's address, which workers call for their lease (STUDIO_URL)."
  type        = string
  default     = "https://temperwork.com"
}

variable "ec2_subnet_ids" {
  description = "With EC2 instances (workers or judge_worker instances > 0): the subnets they go in. They must reach temperwork.com, the image registry, Hugging Face and S3."
  type        = list(string)
  default     = []
}

variable "ec2_security_group_ids" {
  description = "With EC2 instances: their security groups. Empty: one that allows no inbound traffic and all outbound."
  type        = list(string)
  default     = []
}

variable "bedrock_models" {
  description = "Bedrock model ids (wildcards allowed) the judge workers' LLM steps may call, directly or through an inference profile. Empty: none, and no Bedrock access."
  type        = list(string)
  default     = ["anthropic.claude-*"]
}

# --- workers (queues.tf, ec2_workers.tf) ----------------------------------------------

variable "workers" {
  description = <<-EOT
    One entry per model and kind of work your workers do, keyed by a short name
    (lowercase letters, digits, hyphens; it names the queue <name>-<key>.fifo and
    its EC2 resources). Each gets its own queue, which temperwork sends that work to:
      model         the model, as temperwork names it (e.g. qwen-image-edit-2511)
      work          inference (default), training, or grading (a self-hosted judge model)
      image         the worker image serving that model (a customer-prod-latest tag)
      instances     always-on EC2 GPU instances running it (default 0: run it your own way)
      instance_type default g6e.xlarge; one pod per GPU
      volume_size   GB, default 200 (models take 40 to 70 GB unless the instance has local NVMe)
      ami_id        default: the latest AWS Deep Learning Base GPU AMI (Amazon Linux 2023)
  EOT
  type = map(object({
    model         = string
    work          = optional(string, "inference")
    image         = optional(string, "")
    instances     = optional(number, 0)
    instance_type = optional(string, "g6e.xlarge")
    volume_size   = optional(number, 200)
    ami_id        = optional(string, "")
  }))
  default = {}
  validation {
    condition     = alltrue([for k, w in var.workers : can(regex("^[a-z0-9][a-z0-9-]{0,19}$", k)) && k != "judges"])
    error_message = "workers: keys are 1 to 20 lowercase letters, digits or hyphens, and not \"judges\"."
  }
  validation {
    condition     = alltrue([for w in var.workers : contains(["inference", "training", "grading"], w.work)])
    error_message = "workers: work is inference, training or grading."
  }
  validation {
    condition     = alltrue([for w in var.workers : w.instances >= 0 && floor(w.instances) == w.instances && (w.instances == 0 || w.image != "")])
    error_message = "workers: instances is a whole number, 0 or more, and needs image."
  }
  validation {
    condition     = length(distinct([for w in var.workers : "${w.work == "training" ? "training" : "model"}:${w.model}"])) == length(var.workers)
    error_message = "workers: one entry per model and kind of work (each has its own queue)."
  }
}

variable "judge_worker" {
  description = <<-EOT
    The judge worker, on the judges queue (always made): judge runs, including
    automation judges. Needs no GPU.
      image         the judge worker image (a customer-prod-latest tag)
      instances     always-on EC2 instances running it (default 0: run it your own way)
      instance_type default m7i.large
      ami_id        default: the latest Amazon Linux 2023
  EOT
  type = object({
    image         = optional(string, "")
    instances     = optional(number, 0)
    instance_type = optional(string, "m7i.large")
    volume_size   = optional(number, 30)
    ami_id        = optional(string, "")
  })
  default = {}
  validation {
    condition     = var.judge_worker.instances >= 0 && floor(var.judge_worker.instances) == var.judge_worker.instances && (var.judge_worker.instances == 0 || var.judge_worker.image != "")
    error_message = "judge_worker: instances is a whole number, 0 or more, and needs image."
  }
}

variable "test_mode" {
  description = <<-EOT
    For testing temperwork itself only; leave it unset. Loosens where the control-plane role may read the data bucket from:
      access = "off":  only through your S3 VPC endpoints (vpc_endpoint_id, vpc_endpoint_ids)
      access = "ip":   only from cidrs, with no VPC endpoint needed
      access = "open": from anywhere, so the control-plane role can read the data itself
  EOT
  type = object({
    access = optional(string, "off")
    cidrs  = optional(list(string), [])
  })
  default = {}
  validation {
    condition     = contains(["off", "ip", "open"], var.test_mode.access)
    error_message = "test_mode.access: off, ip or open."
  }
}
