resource "aws_sqs_queue" "dlq" {
  name                      = "${local.name}-dlq"
  message_retention_seconds = 1209600
  sqs_managed_sse_enabled   = true
}

resource "aws_sqs_queue" "uploads" {
  name                       = "${local.name}-uploads"
  visibility_timeout_seconds = 180
  message_retention_seconds  = 345600
  receive_wait_time_seconds  = 20
  sqs_managed_sse_enabled    = true
  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 5
  })
}

resource "aws_sqs_queue_redrive_allow_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  redrive_allow_policy = jsonencode({
    redrivePermission = "byQueue"
    sourceQueueArns   = [aws_sqs_queue.uploads.arn]
  })
}

resource "aws_sqs_queue_policy" "uploads" {
  queue_url = aws_sqs_queue.uploads.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { Service = "s3.amazonaws.com" }
        Action    = "sqs:SendMessage"
        Resource  = aws_sqs_queue.uploads.arn
        Condition = {
          ArnEquals    = { "aws:SourceArn" = aws_s3_bucket.buckets["source"].arn }
          StringEquals = { "aws:SourceAccount" = local.account }
        }
      },
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "sqs:*"
        Resource  = aws_sqs_queue.uploads.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_sqs_queue_policy" "dlq" {
  queue_url = aws_sqs_queue.dlq.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Deny"
      Principal = "*"
      Action    = "sqs:*"
      Resource  = aws_sqs_queue.dlq.arn
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

resource "aws_s3_bucket_notification" "uploads" {
  bucket = aws_s3_bucket.buckets["source"].id
  queue {
    queue_arn     = aws_sqs_queue.uploads.arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = "uploads/"
    filter_suffix = "/input"
  }
  depends_on = [aws_sqs_queue_policy.uploads, aws_s3_bucket_versioning.source]
}

resource "aws_kms_key" "notifications" {
  description             = "Encrypt image job notifications and CloudWatch alarms"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnableAccountIAMPolicies"
        Effect    = "Allow"
        Principal = { AWS = "${local.prefix}:iam::${local.account}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      {
        Sid       = "AllowCloudWatchAlarms"
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = ["kms:Decrypt", "kms:GenerateDataKey*"]
        Resource  = "*"
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account }
          ArnLike      = { "aws:SourceArn" = "${local.prefix}:cloudwatch:${var.aws_region}:${local.account}:alarm:${local.name}-*" }
        }
      }
    ]
  })
}

resource "aws_kms_alias" "notifications" {
  name          = "alias/${local.name}-notifications"
  target_key_id = aws_kms_key.notifications.key_id
}

resource "aws_sns_topic" "jobs" {
  name              = "${local.name}-notifications"
  kms_master_key_id = aws_kms_key.notifications.arn
}

resource "aws_sns_topic_policy" "jobs" {
  arn = aws_sns_topic.jobs.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "${local.prefix}:iam::${local.account}:root" }
        Action    = "sns:*"
        Resource  = aws_sns_topic.jobs.arn
      },
      {
        Effect    = "Allow"
        Principal = { Service = "cloudwatch.amazonaws.com" }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.jobs.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = local.account }
          ArnLike      = { "aws:SourceArn" = "${local.prefix}:cloudwatch:${var.aws_region}:${local.account}:alarm:${local.name}-*" }
        }
      },
      {
        Effect    = "Deny"
        Principal = "*"
        Action    = "sns:*"
        Resource  = aws_sns_topic.jobs.arn
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.notification_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.jobs.arn
  protocol  = "email"
  endpoint  = var.notification_email
}
