variable "enable_free_tier_mode" {
  type        = bool
  default     = true
  description = "Free-tier hard lock. Must remain true."
  validation {
    condition     = var.enable_free_tier_mode == true
    error_message = "Free-tier lock must remain enabled."
  }
}

variable "region" {
  description = "The AWS region to deploy resources in."
  type        = string
  default     = "eu-central-1"
}

variable "aws_profile" {
  description = "AWS CLI profile to use for authentication."
  type        = string
  default     = "private"
}

variable "name_prefix" {
  description = "Prefix for naming AWS resources."
  type        = string
  default     = "serverless-infra-tf"
}

variable "metric_namespace" {
  description = "Namespace for CloudWatch metrics."
  type        = string
  default     = "ServerlessInfraTF"
}

variable "scan_mode" {
  type        = string
  default     = "current" # 'current' or 'all'
  description = "Whether to scan only the current region or all enabled regions"
}

variable "cron_expression" {
  type        = string
  default     = "cron(0 2 * * ? *)" # 02:00 UTC daily
  description = "EventBridge schedule expression"
}