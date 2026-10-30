resource "aws_s3_bucket" "buckets" {
  for_each      = toset(["source", "processed", "web"])
  bucket        = "${local.name}-${each.key}-${local.account}-${var.aws_region}"
  force_destroy = var.force_destroy_buckets
}

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each                = aws_s3_bucket.buckets
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "buckets" {
  for_each = aws_s3_bucket.buckets
  bucket   = each.value.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = aws_s3_bucket.buckets
  bucket   = each.value.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_versioning" "source" {
  bucket = aws_s3_bucket.buckets["source"].id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_lifecycle_configuration" "source" {
  bucket     = aws_s3_bucket.buckets["source"].id
  depends_on = [aws_s3_bucket_versioning.source]
  rule {
    id     = "expire-uploads"
    status = "Enabled"
    filter {}
    expiration { days = 7 }
    noncurrent_version_expiration { noncurrent_days = 7 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  rule {
    id     = "remove-delete-markers"
    status = "Enabled"
    filter {}
    expiration { expired_object_delete_marker = true }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "processed" {
  bucket = aws_s3_bucket.buckets["processed"].id
  rule {
    id     = "expire-intermediates"
    status = "Enabled"
    filter { prefix = "internal/" }
    expiration { days = 1 }
    abort_incomplete_multipart_upload { days_after_initiation = 1 }
  }
  rule {
    id     = "expire-results"
    status = "Enabled"
    filter { prefix = "images/" }
    expiration { days = 30 }
  }
}

resource "aws_s3_bucket_cors_configuration" "source" {
  bucket = aws_s3_bucket.buckets["source"].id
  cors_rule {
    allowed_headers = ["Content-Type"]
    allowed_methods = ["POST"]
    allowed_origins = ["https://${aws_cloudfront_distribution.app.domain_name}"]
    max_age_seconds = 300
  }
}

resource "aws_s3_bucket_policy" "buckets" {
  for_each = aws_s3_bucket.buckets
  bucket   = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Sid       = "DenyInsecureTransport"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [each.value.arn, "${each.value.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
      ], each.key == "source" ? [] : [
      {
        Sid       = "AllowOnlyThisCloudFrontDistribution"
        Effect    = "Allow"
        Principal = { Service = "cloudfront.amazonaws.com" }
        Action    = "s3:GetObject"
        Resource  = each.key == "processed" ? "${each.value.arn}/images/*" : "${each.value.arn}/*"
        Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.app.arn } }
      }
    ])
  })
  depends_on = [aws_s3_bucket_public_access_block.buckets]
}

resource "aws_dynamodb_table" "jobs" {
  name         = local.name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"
  attribute {
    name = "job_id"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }
  server_side_encryption { enabled = true }
  point_in_time_recovery { enabled = true }
}
