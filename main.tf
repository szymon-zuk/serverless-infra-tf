terraform {
  required_version = ">=1.12.2"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.5"
    }
  }
}

provider "aws" {
  region = var.region
}

# Packaging Lambda function code
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_dir  = "${path.module}/lambda/src"
  output_path = "${path.module}/build/lambda.zip"
}

# IAM Role for Lambda
data "aws_iam_policy_document" "assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_role" {
  name               = "${var.name_prefix}-lambda-role"
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}
 
data "aws_iam_policy_document" "lambda_permissions" {
    statement {
      sid = "DescribeEBS"
      actions = [
        "ec2:DescribeVolumes",
        "ec2:DescribeSnapshots",
        "ec2:DescribeVolumeStatus"
      ]
      resources = ["*"]
    }

    statement {
      sid = "PutMetrics"
      actions = ["cloudwatch:PutMetricData"]
      resources = ["*"]
    }

    statement {
      sid = "Logs"
      actions = [
        "logs:CreateLogGroup",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
      ]
      resources = ["*"]
    }
}

resource "aws_iam_role_policy" "lambda_policy" {
  name   = "${var.name_prefix}-lambda-policy"
  role   = aws_iam_role.lambda_exec_role.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_exec_role.name
  policy_arn = aws_iam_role_policy.lambda_policy.arn
}

# Lambda Function
resource "aws_lambda_function" "metrics_collector" {
  function_name = "${var.name_prefix}-ebs-metrics"
  role = aws_iam_role.lambda_exec_role.arn
  handler = "handler.lambda_handler"
  runtime = "python3.11"
  timeout = 300

  filename = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256

  layers = [aws_lambda_layer_version.shared_dependencies.arn]

  environment {
    variables = {
      METRIC_NAMESPACE = var.metric_namespace
      SCAN_MODE = var.scan_mode
    }
  }
}

# EventBridge (Scheduled) Trigger for Lambda
resource "aws_cloudwatch_event_rule" "lambda_schedule" {
    name = "${var.name_prefix}-daily-schedule"
    description = "Daily trigger for EBS metrics collection"
    schedule_expression = var.cron_expression
}

resource "aws_cloudwatch_event_target" "invoke_lambda" {
    rule = aws_cloudwatch_event_rule.lambda_schedule.name
    target_id = "Lambda"
    arn = aws_lambda_function.metrics_collector.arn
}

# Permission for EventBridge to invoke Lambda
resource "aws_lambda_permission" "allow_events" {
    statement_id  = "AllowExecutionFromEventBridge"
    action        = "lambda:InvokeFunction"
    function_name = aws_lambda_function.metrics_collector.function_name
    principal     = "events.amazonaws.com"
    source_arn    = aws_cloudwatch_event_rule.lambda_schedule.arn
}

output "lambda_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.metrics_collector.function_name
}