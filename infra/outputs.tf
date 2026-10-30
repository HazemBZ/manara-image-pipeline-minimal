output "website_url" {
  value = "https://${aws_cloudfront_distribution.app.domain_name}"
}
output "api_url" {
  value = aws_apigatewayv2_api.app.api_endpoint
}
output "state_machine_arn" {
  value = aws_sfn_state_machine.pipeline.arn
}
output "source_bucket" {
  value = aws_s3_bucket.buckets["source"].id
}
output "processed_bucket" {
  value = aws_s3_bucket.buckets["processed"].id
}
output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}
output "queue_url" {
  value = aws_sqs_queue.uploads.url
}
output "jobs_table" {
  value = aws_dynamodb_table.jobs.name
}
output "notification_topic_arn" {
  value = aws_sns_topic.jobs.arn
}
