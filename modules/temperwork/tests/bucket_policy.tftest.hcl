# The studio's access, offline: `terraform test` in modules/temperwork (no
# AWS account: a mocked provider, nothing real is made). Checked: the
# studio's role writes only the control bucket, never the data bucket, and
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
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::222222222222:role/temperwork-studio-acme" }
  }
  mock_resource "aws_s3_bucket" {
    defaults = { bucket = "acme-control" }
  }
}

variables {
  name            = "acme"
  bucket          = "acme-data" # a bucket of theirs: its name is known at plan time
  studio_role_arn = "arn:aws:iam::111111111111:role/studio-task"
  external_id     = "0123456789abcdef0123"
}

run "vpce" {
  command = apply
  variables {
    vpc_endpoint_id  = "vpce-gateway"
    vpc_endpoint_ids = ["vpce-interface"]
  }
  assert {
    condition = one([for st in data.aws_iam_policy_document.bucket.statement : st
      if st.sid == "StudioReadsOnlyFromYourNetwork"]).effect == "Deny" && anytrue([
      for c in one([for st in data.aws_iam_policy_document.bucket.statement : st if st.sid == "StudioReadsOnlyFromYourNetwork"]).condition :
      c.test == "StringNotEquals" && c.variable == "aws:SourceVpce" && toset(c.values) == toset(["vpce-gateway", "vpce-interface"])
    ])
    error_message = "vpce: the studio's role is denied the data unless the request comes through one of your endpoints"
  }
  assert {
    condition = alltrue([for st in data.aws_iam_policy_document.bucket.statement :
    one(st.principals).identifiers == toset(["arn:aws:iam::222222222222:role/temperwork-studio-acme"])])
    error_message = "the data bucket's statements name only the studio's role"
  }
  assert {
    condition     = tolist(aws_s3_bucket_cors_configuration.data.cors_rule)[0].allowed_origins == toset(["https://temperwork.com"])
    error_message = "CORS lets the studio's page in by default"
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
      for c in one([for st in data.aws_iam_policy_document.bucket.statement : st if st.sid == "StudioReadsOnlyFromYourNetwork"]).condition :
      c.test == "NotIpAddress" && c.variable == "aws:SourceIp" && toset(c.values) == toset(["203.0.113.0/24", "198.51.100.7/32"])
    ])
    error_message = "test_mode_access = ip: the studio's role is denied the data unless the request comes from your ranges"
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

run "studio_writes_only_the_control_bucket" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
  }
  assert {
    condition = alltrue(flatten([for st in data.aws_iam_policy_document.studio.statement : [
      for r in st.resources : startswith(r, "arn:aws:s3:::acme-control/.studio/")
    ] if contains(st.actions, "s3:PutObject")]))
    error_message = "the studio's role may put objects only under the control bucket's .studio/"
  }
  assert {
    condition = alltrue(flatten([for st in data.aws_iam_policy_document.studio.statement : [
      for r in st.resources : !startswith(r, "arn:aws:s3:::acme-data")
    ] if contains(st.actions, "s3:PutObject")]))
    error_message = "the studio's role has no write access to the data bucket"
  }
  assert {
    condition     = output.worker_env.STUDIO_CONTROL_URI == "s3://acme-control/.studio/" && output.environment.control_uri == "s3://acme-control/.studio/"
    error_message = "the control URI is in the control bucket"
  }
  assert {
    condition     = output.worker_env.STUDIO_LORA_URI == "s3://acme-data/studio/loras/"
    error_message = "LoRAs go to the data bucket, not the control bucket"
  }
}

run "control_bucket_must_differ" {
  command = plan
  variables {
    vpc_endpoint_id = "vpce-gateway"
    control_bucket  = "acme-data"
  }
  expect_failures = [aws_iam_role.studio]
}

run "an_endpoint_is_required" {
  command = plan
  variables {
    vpc_endpoint_ids = []
  }
  expect_failures = [aws_iam_role.studio]
}

run "test_mode_ip_needs_ranges" {
  command = plan
  variables {
    test_mode_access = "ip"
  }
  expect_failures = [aws_iam_role.studio]
}

run "custom_origin" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
    studio_origins  = ["https://studio.example.com"]
  }
  assert {
    condition     = tolist(aws_s3_bucket_cors_configuration.data.cors_rule)[0].allowed_origins == toset(["https://studio.example.com"])
    error_message = "studio_origins sets CORS"
  }
}

run "enroll_token_parameter" {
  command = apply
  variables {
    test_mode_access       = "open"
    enroll_token_parameter = "/studio/enroll-token"
  }
  assert {
    condition = one([for st in data.aws_iam_policy_document.worker.statement :
    st.resources if st.sid == "EnrollToken"]) == toset(["arn:aws:ssm:us-west-2:222222222222:parameter/studio/enroll-token"])
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

run "studio_sees_but_cannot_feed_judge_model_queues" {
  command = apply
  variables {
    vpc_endpoint_id = "vpce-gateway"
    judge_models    = ["qwen3-vl-8b"]
  }
  assert {
    condition     = one([for st in data.aws_iam_policy_document.studio.statement : st.actions if st.sid == "SeeJudgeModelQueues"]) == toset(["sqs:GetQueueAttributes"])
    error_message = "the studio may read the judge model queues' attributes, and nothing else on them"
  }
  assert {
    condition = alltrue([for st in data.aws_iam_policy_document.studio.statement :
    !contains(st.actions, "sqs:SendMessage") || st.sid == "Queues"])
    error_message = "the studio sends only to the runs, trainings and judges queues"
  }
}
