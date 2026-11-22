# The data bucket: your datasets anywhere in it, and what your workers write
# (outputs under <prefix>datasets/, LoRAs under <prefix>loras/). temperwork
# can read it only through links that work through your VPC endpoints, and
# never write it.

resource "aws_s3_bucket" "data" {
  count  = var.bucket == "" ? 1 : 0
  bucket = "${var.name}-data"
}

# temperwork's page fetches listings and files with the links it signs: from
# temperwork's origin, inside your network.
resource "aws_s3_bucket_cors_configuration" "data" {
  bucket = local.bucket
  cors_rule {
    allowed_methods = ["GET"]
    allowed_origins = var.temperwork_origins
    allowed_headers = ["*"]
    max_age_seconds = 3600
  }
}

# --- your data: read only inside your network --------------------------------------

locals {

  # The data bucket policy's test for "outside your network": not through
  # one of your VPC endpoints. A request from the internet carries no
  # aws:SourceVpce, and a negated condition on a missing key is true, so it
  # is denied. (test_mode_access = ip tests the source IP instead.)
  outside = {
    vpce = { test = "StringNotEquals", variable = "aws:SourceVpce", values = local.endpoints }
    ip   = { test = "NotIpAddress", variable = "aws:SourceIp", values = var.test_mode_cidrs }
  }
  deny = local.outside[var.test_mode_access == "ip" ? "ip" : "vpce"]
}

data "aws_iam_policy_document" "bucket" {
  source_policy_documents = var.bucket_policy_source_documents

  statement {
    sid     = "TemperworkReadsOnlyFromYourNetwork"
    effect  = "Deny"
    actions = ["s3:GetObject", "s3:ListBucket"]
    principals {
      type        = "AWS"
      identifiers = [aws_iam_role.temperwork.arn]
    }
    resources = [local.bucket_arn, "${local.bucket_arn}/*"]
    condition {
      test     = local.deny.test
      variable = local.deny.variable
      values   = local.deny.values
    }
  }
}

# With an existing bucket this replaces its policy: pass the statements it
# already has in bucket_policy_source_documents to keep them.
resource "aws_s3_bucket_policy" "data" {
  count  = var.test_mode_access != "open" ? 1 : 0
  bucket = local.bucket
  policy = data.aws_iam_policy_document.bucket.json
}
