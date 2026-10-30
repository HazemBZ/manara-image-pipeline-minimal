terraform {
  required_version = ">= 1.10, < 2.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  profile = var.aws_profile
  region  = var.aws_region
  default_tags {
    tags = { Project = var.project_name, ManagedBy = "Terraform", Environment = "demo" }
  }
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  account   = data.aws_caller_identity.current.account_id
  partition = data.aws_partition.current.partition
  prefix    = "arn:${local.partition}"
  name      = var.project_name
  state_arn = "${local.prefix}:states:${var.aws_region}:${local.account}:stateMachine:${local.name}"
  topic_arn = "${local.prefix}:sns:${var.aws_region}:${local.account}:${local.name}-notifications"
  lambda_arns = {
    for name in ["authorizer", "api", "dispatcher", "validate", "resize", "watermark", "store", "fail"] :
    name => "${local.prefix}:lambda:${var.aws_region}:${local.account}:function:${local.name}-${name}"
  }
}
