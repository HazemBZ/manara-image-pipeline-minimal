variable "aws_profile" {
  type    = string
  default = "manara"
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

variable "project_name" {
  type    = string
  default = "manara-images"
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,24}$", var.project_name))
    error_message = "Use 3–25 lowercase letters, digits, or hyphens; start with a letter."
  }
}

variable "token_sha256" {
  description = "SHA-256 of a random demo token; only the hash is deployed. Run scripts/setup_token.py."
  type        = string
  sensitive   = true
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.token_sha256))
    error_message = "A 64-character lowercase SHA-256 hash is required."
  }
}

variable "notification_email" {
  description = "Optional email for job notifications and operational alarms. Confirm the SNS email."
  type        = string
  default     = ""
}

variable "watermark_text" {
  type    = string
  default = "Manara"
  validation {
    condition     = can(regex("^[A-Za-z0-9 ._-]{1,24}$", var.watermark_text))
    error_message = "Use 1–24 ASCII letters, digits, spaces, dots, underscores, or hyphens."
  }
}

variable "enable_waf" {
  description = "Optional paid CloudFront WAF. Enable before sharing a public demo widely."
  type        = bool
  default     = false
}

variable "force_destroy_buckets" {
  description = "Leave false. Set true only when intentionally deleting ALL project image data."
  type        = bool
  default     = false
}
