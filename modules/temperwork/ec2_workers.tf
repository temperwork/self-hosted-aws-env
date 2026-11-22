# EC2 workers (ec2_workers > 0): an Auto Scaling group of always-on GPU
# instances, each running ec2-user-data.sh with its settings filled in: one
# pod per GPU on worker_queue and, with judge_worker_image, a judge worker on
# the judges queue. Leave ec2_workers at 0 to run workers your own way; the
# worker_* outputs have what they need.
#
# Changing the launch template doesn't touch running instances: new
# instances get it (terminate the old ones when nothing runs on them).

locals {
  ec2           = var.ec2_workers > 0
  ecr           = length(regexall("\\.dkr\\.ecr\\.", "${var.worker_image} ${var.judge_worker_image}")) > 0
  ec2_ami       = var.ec2_ami_id != "" ? var.ec2_ami_id : (local.ec2 ? nonsensitive(data.aws_ssm_parameter.dlami[0].value) : "")
  ec2_sg_ids    = length(var.ec2_security_group_ids) > 0 ? var.ec2_security_group_ids : aws_security_group.ec2_workers[*].id
  ec2_own_sg    = local.ec2 && length(var.ec2_security_group_ids) == 0 && length(var.ec2_subnet_ids) > 0
  ec2_queue_url = var.worker_queue == "runs" ? aws_sqs_queue.runs.url : ""

  # ec2-user-data.sh reads each setting from the environment first.
  ec2_settings = {
    IMAGE                = var.worker_image
    REGISTRY_LOGIN       = local.ecr ? "ecr" : "none"
    STUDIO_URL           = var.temperwork_url
    STUDIO_CONNECTION_ID = local.environment_id
    STUDIO_CONTROL_URI   = local.control_uri
    STUDIO_LORA_URI      = local.lora_uri
    AWS_REGION           = local.region
    QUEUE_URL            = local.ec2_queue_url
    TRAIN_QUEUE_URL      = var.worker_queue == "trainings" ? aws_sqs_queue.trainings.url : ""
    JUDGE_QUEUE_URL      = var.judge_worker_image != "" ? aws_sqs_queue.judges.url : ""
    JUDGE_IMAGE          = var.judge_worker_image
    TOKEN_PARAM          = var.enroll_token_parameter
    IDLE_S               = "0" # always on: the group keeps them
  }
  ec2_user_data = join("\n", concat(
    ["#!/bin/bash"],
    [for k, v in local.ec2_settings : format("export %s='%s'", k, replace(v, "'", "'\\''"))],
    [trimprefix(file("${path.module}/ec2-user-data.sh"), "#!/bin/bash\n")],
  ))
}

data "aws_ssm_parameter" "dlami" {
  count = local.ec2 && var.ec2_ami_id == "" ? 1 : 0
  name  = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
}

data "aws_subnet" "ec2_workers" {
  count = local.ec2_own_sg ? 1 : 0
  id    = var.ec2_subnet_ids[0]
}

# Out only: the workers call temperwork.com, the registry, Hugging Face and S3.
resource "aws_security_group" "ec2_workers" {
  count       = local.ec2_own_sg ? 1 : 0
  name        = "${var.name}-tw-workers"
  description = "temperwork workers: no inbound, all outbound"
  vpc_id      = data.aws_subnet.ec2_workers[0].vpc_id
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_iam_role_policy_attachment" "worker_ecr" {
  count      = local.ec2 && local.ecr ? 1 : 0
  role       = aws_iam_role.worker.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_launch_template" "ec2_workers" {
  count                                = local.ec2 ? 1 : 0
  name                                 = "${var.name}-tw-workers"
  image_id                             = local.ec2_ami
  instance_type                        = var.ec2_instance_type
  vpc_security_group_ids               = local.ec2_sg_ids
  instance_initiated_shutdown_behavior = "terminate" # a worker that leaves ends its instance; the group starts another
  update_default_version               = true
  user_data                            = base64encode(local.ec2_user_data)

  iam_instance_profile {
    name = aws_iam_instance_profile.worker.name
  }
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 2 # the containers reach the instance profile's credentials
  }
  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = var.ec2_volume_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-tw-worker" }
  }
}

resource "aws_autoscaling_group" "ec2_workers" {
  count               = local.ec2 ? 1 : 0
  name                = "${var.name}-tw-workers"
  min_size            = var.ec2_workers
  max_size            = var.ec2_workers
  desired_capacity    = var.ec2_workers
  vpc_zone_identifier = var.ec2_subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.ec2_workers[0].id
    version = "$Latest"
  }

  lifecycle {
    precondition {
      condition     = var.worker_image != ""
      error_message = "ec2_workers > 0 needs worker_image: the worker image the pods run."
    }
    precondition {
      condition     = length(var.ec2_subnet_ids) > 0
      error_message = "ec2_workers > 0 needs ec2_subnet_ids: where the instances go."
    }
    precondition {
      condition     = var.enroll_token_parameter != ""
      error_message = "ec2_workers > 0 needs enroll_token_parameter: the SSM parameter holding the enrollment token."
    }
  }
}
