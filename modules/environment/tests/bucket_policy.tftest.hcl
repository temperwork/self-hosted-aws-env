# The bucket policy and CORS, offline: `terraform test` in modules/environment
# (no AWS account: a mocked provider, nothing real is made). Each
# browser_access mode's policy is checked: the studio's role is denied the
# data outside your network (vpce: not through your endpoints; ip: not from
# your ranges; open: no policy at all), never the control prefix. The mock
# doesn't render the JSON, so the statements are checked as the module
# writes them.

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
    browser_access   = "vpce"
    vpc_endpoint_id  = "vpce-gateway"
    vpc_endpoint_ids = ["vpce-interface"]
  }
  assert {
    condition     = length(aws_s3_bucket_policy.data) == 1
    error_message = "vpce: the bucket has a policy"
  }
  assert {
    condition = length(data.aws_iam_policy_document.bucket.statement) == 2 && alltrue([
      for st in data.aws_iam_policy_document.bucket.statement :
      st.effect == "Deny" &&
      one(st.principals).identifiers == toset(["arn:aws:iam::222222222222:role/temperwork-studio-acme"]) &&
      anytrue([for c in st.condition : c.test == "StringNotEquals" && c.variable == "aws:SourceVpce" &&
      toset(c.values) == toset(["vpce-gateway", "vpce-interface"])])
    ])
    error_message = "vpce: both statements deny the studio's role unless the request comes through one of the customer's endpoints"
  }
  assert {
    condition = one([for st in data.aws_iam_policy_document.bucket.statement :
    st.not_resources if contains(st.actions, "s3:GetObject")]) == toset(["arn:aws:s3:::acme-data/studio/.studio/*"])
    error_message = "vpce: reading is denied everywhere but the control prefix"
  }
  assert {
    condition     = tolist(aws_s3_bucket_cors_configuration.data.cors_rule)[0].allowed_origins == toset(["https://temperwork.com"])
    error_message = "CORS lets the prod studio's page in by default"
  }
}

run "ip" {
  command = apply
  variables {
    browser_access = "ip"
    browser_cidrs  = ["203.0.113.0/24", "198.51.100.7/32"]
  }
  assert {
    condition = alltrue([for st in data.aws_iam_policy_document.bucket.statement :
      st.effect == "Deny" &&
      anytrue([for c in st.condition : c.test == "NotIpAddress" && c.variable == "aws:SourceIp" &&
      toset(c.values) == toset(["203.0.113.0/24", "198.51.100.7/32"])]) &&
      !anytrue([for c in st.condition : c.variable == "aws:SourceVpce"])
    ])
    error_message = "ip: both statements deny the studio's role unless the request comes from the customer's ranges"
  }
}

run "open" {
  command = apply
  variables {
    browser_access = "open"
  }
  assert {
    condition     = length(aws_s3_bucket_policy.data) == 0
    error_message = "open: no bucket policy"
  }
}

run "vpce_needs_an_endpoint" {
  command = plan
  variables {
    browser_access = "vpce"
  }
  expect_failures = [aws_iam_role.studio]
}

run "ip_needs_ranges" {
  command = plan
  variables {
    browser_access = "ip"
  }
  expect_failures = [aws_iam_role.studio]
}

run "custom_origin" {
  command = apply
  variables {
    browser_access  = "vpce"
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
    browser_access         = "open"
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
    browser_access = "open"
  }
  assert {
    condition     = length([for st in data.aws_iam_policy_document.worker.statement : st if st.sid == "EnrollToken"]) == 0
    error_message = "without enroll_token_parameter the workers get no SSM access"
  }
}
