resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = local.name
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_response_headers_policy" "security" {
  name = "${local.name}-security"
  security_headers_config {
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
    strict_transport_security {
      access_control_max_age_sec = 31536000
      include_subdomains         = true
      override                   = true
    }
    content_security_policy {
      content_security_policy = "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' blob:; connect-src 'self' https://*.execute-api.${var.aws_region}.amazonaws.com https://*.s3.${var.aws_region}.amazonaws.com; object-src 'none'; base-uri 'none'; frame-ancestors 'none'; form-action 'none'"
      override                = true
    }
  }
}

resource "aws_cloudfront_distribution" "app" {
  enabled             = true
  comment             = "Manara image processing demo"
  default_root_object = "index.html"
  price_class         = "PriceClass_100"
  web_acl_id          = var.enable_waf ? aws_wafv2_web_acl.edge[0].arn : null
  origin {
    domain_name              = aws_s3_bucket.buckets["web"].bucket_regional_domain_name
    origin_id                = "web"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }
  origin {
    domain_name              = aws_s3_bucket.buckets["processed"].bucket_regional_domain_name
    origin_id                = "images"
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }
  default_cache_behavior {
    target_origin_id           = "web"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # Managed-CachingDisabled
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }
  ordered_cache_behavior {
    path_pattern               = "/images/*"
    target_origin_id           = "images"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = "658327ea-f89d-4fab-a63d-7e88639e58f6" # Managed-CachingOptimized
    response_headers_policy_id = aws_cloudfront_response_headers_policy.security.id
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate { cloudfront_default_certificate = true }
}

resource "aws_s3_object" "web" {
  for_each = {
    "index.html" = "text/html; charset=utf-8"
    "app.js"     = "application/javascript"
    "style.css"  = "text/css"
  }
  bucket        = aws_s3_bucket.buckets["web"].id
  key           = each.key
  source        = "${path.module}/../frontend/${each.key}"
  source_hash   = filemd5("${path.module}/../frontend/${each.key}")
  content_type  = each.value
  cache_control = "no-cache"
}

resource "aws_s3_object" "config" {
  bucket        = aws_s3_bucket.buckets["web"].id
  key           = "config.json"
  content       = jsonencode({ api_url = aws_apigatewayv2_api.app.api_endpoint })
  content_type  = "application/json"
  cache_control = "no-store"
}

resource "aws_wafv2_web_acl" "edge" {
  # CLOUDFRONT WAF control plane is us-east-1. This optional feature is restricted to it.
  count = var.enable_waf ? 1 : 0
  name  = "${local.name}-edge"
  scope = "CLOUDFRONT"
  default_action {
    allow {}
  }
  rule {
    name     = "RateLimit"
    priority = 1
    action {
      block {}
    }
    statement {
      rate_based_statement {
        limit              = 1000
        aggregate_key_type = "IP"
      }
    }
    visibility_config {
      cloudwatch_metrics_enabled = true
      metric_name                = "${local.name}-rate"
      sampled_requests_enabled   = false
    }
  }
  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.name}-edge"
    sampled_requests_enabled   = false
  }
  lifecycle {
    precondition {
      condition     = var.aws_region == "us-east-1"
      error_message = "This demo's optional CloudFront WAF must be deployed in us-east-1."
    }
  }
}
