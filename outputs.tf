output "api_url" {
  description = "HTTPS URL of the API (self-signed cert - browsers/curl will warn; use curl -k)"
  value       = "https://${aws_lb.this.dns_name}"
}

output "alb_dns_name" {
  description = "Public DNS name of the load balancer"
  value       = aws_lb.this.dns_name
}

output "lambda_function_name" {
  description = "Name of the Lambda function"
  value       = aws_lambda_function.api.function_name
}

output "rds_endpoint" {
  description = "Private endpoint of the PostgreSQL instance (reachable only from the Lambda)"
  value       = aws_db_instance.this.address
}

output "cache_primary_endpoint" {
  description = "Private primary endpoint of the ElastiCache replication group (reachable only from the Lambda)"
  value       = aws_elasticache_replication_group.this.primary_endpoint_address
}

output "seed_result" {
  description = "What the one-off seed invocation reported"
  value       = jsondecode(aws_lambda_invocation.seed.result)
}

output "smoke_test_cmd" {
  description = "Hit each endpoint once; run twice to see X-Cache go MISS -> HIT"
  value       = "curl -sk -D - https://${aws_lb.this.dns_name}/products/42 -o /dev/null | grep -i x-cache; curl -sk https://${aws_lb.this.dns_name}/products/42"
}

output "load_test_cmd" {
  description = "Run the wrk2 benchmark suite (cached vs uncached vs mixed read/write)"
  value       = "make loadtest URL=https://${aws_lb.this.dns_name}"
}
