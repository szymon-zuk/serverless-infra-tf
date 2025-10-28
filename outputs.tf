output "event_rule" {
    value = aws_cloudwatch_event_rule.lambda_schedule.name
}