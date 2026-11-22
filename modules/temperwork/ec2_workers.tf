# EC2 workers: for each workers entry and judge model (judge_worker.models)
# with instances > 0, and the judge worker with judge_worker.instances > 0, a
# launch template and an Auto Scaling group keeping that many always-on
# instances. Each instance runs ec2-user-data.sh with its settings filled in:
# one pod per GPU serving the entry's model on its queue, or the judge worker
# on the judges queue.
# Entries left at 0 instances you run your own way; the outputs have what
# those workers need.
#
# Changing a launch template doesn't touch running instances: new instances
# get it (terminate the old ones when nothing runs on them).

locals {
  common_settings = {
    STUDIO_URL           = var.temperwork_url
    STUDIO_CONNECTION_ID = local.environment_id
    STUDIO_CONTROL_URI   = local.control_uri
    STUDIO_LORA_URI      = local.lora_uri
    AWS_REGION           = local.region
    TOKEN_PARAM          = var.enroll_token_parameter
    IDLE_S               = "0" # always on: the group keeps them
    # Every queue setting is given, empty when unused, so the script's
    # defaults never apply.
    POD_MODEL       = ""
    POD_RUNS        = ""
    QUEUE_URL       = ""
    QUEUE_ID        = ""
    TRAIN_QUEUE_URL = ""
    TRAIN_QUEUE_ID  = ""
    MODEL_QUEUE_URL = ""
    JUDGE_QUEUE_URL = ""
    JUDGE_QUEUES    = ""
    JUDGE_IMAGE     = ""
  }

  # The judge worker's self-hosted judge models: their judging queues.
  judge_queues = jsonencode([for k, q in local.judging : { id = local.queue_ids[k], kind = "sqs", url = q.url }])

  fleets = merge(
    { for k, w in local.entries : k => {
      instances     = w.instances
      instance_type = w.instance_type
      volume_size   = w.volume_size
      ami_id        = w.ami_id
      gpu           = true
      image         = w.image
      settings = merge(local.common_settings, {
        IMAGE     = w.image
        POD_MODEL = w.model
        POD_RUNS  = w.work == "judging" ? "grading" : w.work # the worker's own name for judging
        }, w.work == "training" ? {
        TRAIN_QUEUE_URL = aws_sqs_queue.workers[k].url
        TRAIN_QUEUE_ID  = local.temperwork_queue_ids[k]
        } : w.work == "inference" ? {
        QUEUE_URL       = aws_sqs_queue.workers[k].url
        QUEUE_ID        = local.temperwork_queue_ids[k]
        MODEL_QUEUE_URL = aws_sqs_queue.workers[k].url
        } : {
        MODEL_QUEUE_URL = aws_sqs_queue.workers[k].url
      })
    } if w.instances > 0 },
    var.judge_worker.instances > 0 ? { judges = {
      instances     = var.judge_worker.instances
      instance_type = var.judge_worker.instance_type
      volume_size   = var.judge_worker.volume_size
      ami_id        = var.judge_worker.ami_id
      gpu           = false
      image         = var.judge_worker.image
      settings = merge(local.common_settings, {
        IMAGE           = ""
        JUDGE_QUEUE_URL = aws_sqs_queue.judges.url
        JUDGE_QUEUES    = local.judge_queues
        JUDGE_IMAGE     = var.judge_worker.image
      })
    } } : {},
  )

  any_fleet    = length(local.fleets) > 0
  need_gpu_ami = anytrue([for f in local.fleets : f.gpu && f.ami_id == ""])
  need_cpu_ami = anytrue([for f in local.fleets : !f.gpu && f.ami_id == ""])
  ecr          = anytrue([for f in local.fleets : length(regexall("\\.dkr\\.ecr\\.", f.image)) > 0])
  own_sg       = local.any_fleet && length(var.ec2_security_group_ids) == 0 && length(var.ec2_subnet_ids) > 0
  sg_ids       = length(var.ec2_security_group_ids) > 0 ? var.ec2_security_group_ids : aws_security_group.ec2_workers[*].id

  user_data = { for k, f in local.fleets : k => join("\n", concat(
    ["#!/bin/bash"],
    [for name, v in merge(f.settings, { REGISTRY_LOGIN = length(regexall("\\.dkr\\.ecr\\.", f.image)) > 0 ? "ecr" : "none" }) :
    format("export %s='%s'", name, replace(v, "'", "'\\''"))],
    [trimprefix(file("${path.module}/ec2-user-data.sh"), "#!/bin/bash\n")],
  )) }
}

# The latest AWS Deep Learning Base GPU AMI (Docker and the NVIDIA container
# toolkit), and the latest Amazon Linux 2023 for the judge worker.
data "aws_ssm_parameter" "gpu_ami" {
  count = local.need_gpu_ami ? 1 : 0
  name  = "/aws/service/deeplearning/ami/x86_64/base-oss-nvidia-driver-gpu-amazon-linux-2023/latest/ami-id"
}

data "aws_ssm_parameter" "cpu_ami" {
  count = local.need_cpu_ami ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_subnet" "ec2_workers" {
  count = local.own_sg ? 1 : 0
  id    = var.ec2_subnet_ids[0]
}

# Out only: the workers call temperwork.com, the registry, Hugging Face and S3.
resource "aws_security_group" "ec2_workers" {
  count       = local.own_sg ? 1 : 0
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
  count      = local.ecr ? 1 : 0
  role       = aws_iam_role.worker.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"
}

resource "aws_launch_template" "ec2_workers" {
  for_each      = local.fleets
  name          = "${var.name}-tw-${each.key}"
  instance_type = each.value.instance_type
  image_id = each.value.ami_id != "" ? each.value.ami_id : (
    each.value.gpu ? nonsensitive(data.aws_ssm_parameter.gpu_ami[0].value) : nonsensitive(data.aws_ssm_parameter.cpu_ami[0].value)
  )
  vpc_security_group_ids               = local.sg_ids
  instance_initiated_shutdown_behavior = "terminate" # a worker that leaves ends its instance; the group starts another
  update_default_version               = true
  user_data                            = base64encode(local.user_data[each.key])

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
      volume_size           = each.value.volume_size
      volume_type           = "gp3"
      delete_on_termination = true
      encrypted             = true
    }
  }
  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "${var.name}-tw-${each.key}" }
  }
}

resource "aws_autoscaling_group" "ec2_workers" {
  for_each            = local.fleets
  name                = "${var.name}-tw-${each.key}"
  min_size            = each.value.instances
  max_size            = each.value.instances
  desired_capacity    = each.value.instances
  vpc_zone_identifier = var.ec2_subnet_ids
  health_check_type   = "EC2"

  launch_template {
    id      = aws_launch_template.ec2_workers[each.key].id
    version = "$Latest"
  }

  lifecycle {
    precondition {
      condition     = length(var.ec2_subnet_ids) > 0
      error_message = "EC2 workers need ec2_subnet_ids: where the instances go."
    }
    precondition {
      condition     = var.enroll_token_parameter != ""
      error_message = "EC2 workers need enroll_token_parameter: the SSM parameter holding the enrollment token."
    }
  }
}
