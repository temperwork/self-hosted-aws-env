# The network the temperwork module needs, for an account that has none yet.
# If you already have a VPC, skip this file and pass your own S3 endpoint
# (or IP ranges) to the module, as main.tf does with these.
#
#   - a VPC with public subnets and an internet gateway, no NAT: workers get
#     public IPs and reach temperwork.com (their leases), the image registry
#     and Hugging Face directly
#   - an S3 gateway endpoint (free): workers' and in-VPC browsers' S3
#     traffic, and the endpoint the data bucket's policy accepts
#
# vpn.tf adds the way in for browsers outside AWS.

data "aws_region" "current" {}

data "aws_availability_zones" "up" {
  state = "available"
}

locals {
  region = data.aws_region.current.region
  zones  = length(var.zone_names) > 0 ? var.zone_names : slice(data.aws_availability_zones.up.names, 0, 2)
}

resource "aws_vpc" "this" {
  cidr_block           = var.cidr
  enable_dns_support   = true # both, for the interface endpoint's private DNS
  enable_dns_hostnames = true
  tags                 = { Name = var.name }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = var.name }
}

resource "aws_subnet" "public" {
  count                   = length(local.zones)
  vpc_id                  = aws_vpc.this.id
  availability_zone       = local.zones[count.index]
  cidr_block              = cidrsubnet(var.cidr, 8, count.index)
  map_public_ip_on_launch = true
  tags                    = { Name = "${var.name}-public-${local.zones[count.index]}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${var.name}-public" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_vpc_endpoint" "s3_gateway" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${local.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.public.id]
  tags              = { Name = "${var.name}-s3-gateway" }
}
