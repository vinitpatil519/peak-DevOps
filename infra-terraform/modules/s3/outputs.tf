output "bucket_names" {
  description = "Map of key -> bucket name"
  value       = { for k, b in aws_s3_bucket.this : k => b.bucket }
}

output "bucket_arns" {
  description = "Map of key -> bucket ARN"
  value       = { for k, b in aws_s3_bucket.this : k => b.arn }
}
