# temperwork's access, offline: `terraform test` in modules/temperwork (no
# AWS account: a mocked provider, nothing real is made). Checked: the
# temperwork's role writes only the control bucket, never the data bucket, and
# is denied reading the data except through your VPC endpoints (or, with
# test_mode_access, from the test ranges or anywhere). The mock doesn't
# render the JSON, so the statements are checked as the module writes them.

mock_provider "aws" {
  mock_data "aws_iam_policy_document" { # the resources want a JSON object; the statements are what's checked
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_region" {
    defaults = { region = "us-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "222222222222" }
  }
  mock_data "aws_ssm_parameter" {
    defaults = { value = "ami-0123456789abcdef0" }
  }
  mock_data "aws_subnet" {
    defaults = { vpc_id = "vpc-0123456789abcdef0" }
  }
  mock_resource "aws_launch_template" {
    defaults = { id = "lt-0123456789abcdef0" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::222222222222:role/temperwork-cp-acme" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { bucket = "acme-control" }
  }
}

variables {
  name                = "acme"
  bucket              = "acme-data" # a bucket of theirs: its name is known at plan time
  temperwork_role_arn = "arn:aws:iam::111111111111:role/temperwork-task"
  external_id         = "0123456789abcdef0123"
}

run "vpce" {
  command = apply
  variables {
    vpc_endpoint_id  = "vpce-gateway"
    vpc_endpoint_ids = ["vpce-interface"]
  }
  assert {
    condition = one([for st in data.aws_iam_policy_document.bucket.statement : st
      if st.sid == "TemperworkReadsOnlyFromYourNetwork"]).effect == "Deny" && anytrue([
      for c in one([for st in data.aws_iam_policy_document.bucket.statement : st if st.sid == "TemperworkReadsOnlyFromYourNetwork"]).condition :
      c.test == "StringNotEquals" && c.variable == "aws:SourceVpce" && toset(c.values) == toset(["vpce-gateway", "vpce-interface"])
    ])
    error_message = "vpce: temperwork's role is denied the data unless the request comes through one of your endpoints"
  }
  assert {
    condition = alltrue([for st in data.aws_iam_policy_document.bucket.statement :
    one(st.principals).identifiers == toset(["arn:aws:iam::222222222222:role/temperwork-cp-acme"])])
    error_message = "the data bucket's statements name only temperwork's role"
  }
  assert {
    condition     = tolist(aws_s3_bucket_cors_configuration.data.cors_rule)[0].allowed_origins == toset(["https://temperwork.com"])
    error_message = "CORS lets temperwork's page in by default"
  }
}

run "test_mode_ip" {
  command = apply
  variables {
    test_mode_access = "ip"
    test_mode_cidrs  = ["203.0.113.0/24", "198.51.100.7/32"]
  }
  assert {
    condition = anytrue([
      for c in one([for st in data.aws_iam_policy_document.bucket.statement : st if st.sid == "TemperworkReadsOnlyFromYourNetwork"]).condition :
      c.test == "NotIpAddress" && c.variable == "aws:SourceIp" && toset(c.values) == toset(["203.0.113.0/24", "198.51.100.7/32"])
    ])
    error_message = "test_mode_access = ip: temperwork's role is denied the data unless the request comes from your ranges"
  }
}

run "test_mode_open" {
  command = apply
  variables {
    test_mode_access = "open"
  }
  assert {
    condition     = length(aws_s3_bucket_policy.data) == 0
    error_message = "test_mode_access = open: no bucket policy"
  }
}

run "temperwork_writes_only_the_control_bucket" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
  }
  assert {
    condition = alltrue(flatten([for st in data.aws_iam_policy_document.temperwork.statement : [
      for r in st.resources : startswith(r, "arn:aws:s3:::acme-control/.studio/")
    ] if contains(st.actions, "s3:PutObject")]))
    error_message = "temperwork's role may put objects only under the control bucket's .studio/"
  }
  assert {
    condition = alltrue(flatten([for st in data.aws_iam_policy_document.temperwork.statement : [
      for r in st.resources : !startswith(r, "arn:aws:s3:::acme-data")
    ] if contains(st.actions, "s3:PutObject")]))
    error_message = "temperwork's role has no write access to the data bucket"
  }
  assert {
    condition     = output.worker_env.STUDIO_CONTROL_URI == "s3://acme-control/.studio/" && output.environment.control_uri == "s3://acme-control/.studio/"
    error_message = "the control URI is in the control bucket"
  }
  assert {
    condition     = output.worker_env.STUDIO_LORA_URI == "s3://acme-data/temperwork/loras/"
    error_message = "LoRAs go to the data bucket, not the control bucket"
  }
}

run "control_bucket_must_differ" {
  command = plan
  variables {
    vpc_endpoint_id = "vpce-gateway"
    control_bucket  = "acme-data"
  }
  expect_failures = [aws_iam_role.temperwork]
}

run "an_endpoint_is_required" {
  command = plan
  variables {
    vpc_endpoint_ids = []
  }
  expect_failures = [aws_iam_role.temperwork]
}

run "test_mode_ip_needs_ranges" {
  command = plan
  variables {
    test_mode_access = "ip"
  }
  expect_failures = [aws_iam_role.temperwork]
}

run "custom_origin" {
  command = apply
  variables {
    vpc_endpoint_id    = "vpce-gateway"
    temperwork_origins = ["https://tw.example.com"]
  }
  assert {
    condition     = tolist(aws_s3_bucket_cors_configuration.data.cors_rule)[0].allowed_origins == toset(["https://tw.example.com"])
    error_message = "temperwork_origins sets CORS"
  }
}

run "enroll_token_parameter" {
  command = apply
  variables {
    test_mode_access       = "open"
    enroll_token_parameter = "/temperwork/enroll-token"
  }
  assert {
    condition = one([for st in data.aws_iam_policy_document.worker.statement :
    st.resources if st.sid == "EnrollToken"]) == toset(["arn:aws:ssm:us-west-2:222222222222:parameter/temperwork/enroll-token"])
    error_message = "the workers may read the enrollment token's parameter"
  }
}

run "no_enroll_token_parameter" {
  command = apply
  variables {
    test_mode_access = "open"
  }
  assert {
    condition     = length([for st in data.aws_iam_policy_document.worker.statement : st if st.sid == "EnrollToken"]) == 0
    error_message = "without enroll_token_parameter the workers get no SSM access"
  }
}

run "temperwork_sees_but_cannot_feed_judge_model_queues" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
    judge_models    = ["qwen3-vl-8b"]
  }
  assert {
    condition     = one([for st in data.aws_iam_policy_document.temperwork.statement : st.actions if st.sid == "SeeJudgeModelQueues"]) == toset(["sqs:GetQueueAttributes"])
    error_message = "temperwork may read the judge model queues' attributes, and nothing else on them"
  }
  assert {
    condition = alltrue([for st in data.aws_iam_policy_document.temperwork.statement :
    !contains(st.actions, "sqs:SendMessage") || st.sid == "Queues"])
    error_message = "temperwork sends only to the runs, trainings and judges queues"
  }
}

run "workers_cannot_enable_or_list_models" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
  }
  assert {
    condition = !anytrue(flatten([for st in data.aws_iam_policy_document.worker.statement : [
      for a in st.actions : startswith(a, "aws-marketplace:") || startswith(a, "bedrock:List")
    ]]))
    error_message = "the workers' role has no AWS Marketplace access and no Bedrock list actions"
  }
}

run "workers_role_is_ec2_only" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
  }
  assert {
    condition = length(data.aws_iam_policy_document.worker_trust.statement) == 1 && alltrue([
      for st in data.aws_iam_policy_document.worker_trust.statement :
      one(st.principals).type == "Service" && one(st.principals).identifiers == toset(["ec2.amazonaws.com"])
    ])
    error_message = "only EC2 may assume the workers' role"
  }
}

run "no_ec2_workers_by_default" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
  }
  assert {
    condition     = length(aws_autoscaling_group.ec2_workers) == 0 && length(aws_launch_template.ec2_workers) == 0 && output.ec2_autoscaling_group == ""
    error_message = "ec2_workers = 0 starts no instances"
  }
  assert {
    condition     = output.worker_env.STUDIO_CONNECTION_ID == "acme" && output.worker_policy_json != ""
    error_message = "the outputs have what workers run another way need"
  }
}

run "ec2_workers_need_their_settings" {
  command = plan
  variables {
    vpc_endpoint_id = "vpce-gateway"
    ec2_workers     = 1
  }
  expect_failures = [aws_autoscaling_group.ec2_workers]
}

run "ec2_workers" {
  command = apply
  variables {
    vpc_endpoint_id        = "vpce-gateway"
    ec2_workers            = 2
    worker_image           = "ghcr.io/example/qwen-image:customer-prod-latest"
    judge_worker_image     = "123456789012.dkr.ecr.us-west-2.amazonaws.com/judge-worker:customer-prod-latest"
    ec2_subnet_ids         = ["subnet-a", "subnet-b"]
    enroll_token_parameter = "/temperwork/enroll-token"
    environment_id         = "acme-prod"
  }
  assert {
    condition = (aws_autoscaling_group.ec2_workers[0].min_size == 2 && aws_autoscaling_group.ec2_workers[0].max_size == 2
    && aws_autoscaling_group.ec2_workers[0].desired_capacity == 2)
    error_message = "the group keeps exactly ec2_workers instances"
  }
  assert {
    condition = (aws_launch_template.ec2_workers[0].metadata_options[0].http_put_response_hop_limit == 2
      && aws_launch_template.ec2_workers[0].metadata_options[0].http_tokens == "required"
      && aws_launch_template.ec2_workers[0].instance_initiated_shutdown_behavior == "terminate"
    && aws_launch_template.ec2_workers[0].iam_instance_profile[0].name == aws_iam_instance_profile.worker.name)
    error_message = "the instances use the workers' profile, IMDSv2 with hop limit 2, and end when their workers leave"
  }
  assert {
    condition = alltrue([for want in [
      "export IDLE_S='0'", "export TOKEN_PARAM='/temperwork/enroll-token'", "export STUDIO_CONNECTION_ID='acme-prod'",
      "export TRAIN_QUEUE_URL=''", "export REGISTRY_LOGIN='ecr'", "export IMAGE='ghcr.io/example/qwen-image:customer-prod-latest'",
    ] : strcontains(base64decode(aws_launch_template.ec2_workers[0].user_data), want)])
    error_message = "the user data carries the settings: always on, the token's parameter, the environment id, the runs queue only"
  }
  assert {
    condition     = length(aws_iam_role_policy_attachment.worker_ecr) == 1 && length(aws_security_group.ec2_workers) == 1
    error_message = "an ECR image gets pull access; no security groups given gets an outbound-only one"
  }
}

run "ec2_trainer_workers" {
  command = apply
  variables {
    vpc_endpoint_id        = "vpce-gateway"
    ec2_workers            = 1
    worker_image           = "ghcr.io/example/lora-trainer:customer-prod-latest"
    worker_queue           = "trainings"
    ec2_subnet_ids         = ["subnet-a"]
    ec2_security_group_ids = ["sg-mine"]
    enroll_token_parameter = "/temperwork/enroll-token"
  }
  assert {
    condition = (strcontains(base64decode(aws_launch_template.ec2_workers[0].user_data), "export QUEUE_URL=''")
    && strcontains(base64decode(aws_launch_template.ec2_workers[0].user_data), "export JUDGE_QUEUE_URL=''"))
    error_message = "trainer workers take only the trainings queue, and run no judge worker without judge_worker_image"
  }
  assert {
    condition     = length(aws_security_group.ec2_workers) == 0 && length(aws_iam_role_policy_attachment.worker_ecr) == 0
    error_message = "given security groups are used as they are; a non-ECR image needs no pull access"
  }
}
