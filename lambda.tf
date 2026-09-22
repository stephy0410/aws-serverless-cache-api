# AWS Academy Learner Lab accounts cannot create IAM roles; every Lambda runs as the
# pre-provisioned LabRole (it already has the VPC-networking and CloudWatch Logs permissions).
data "aws_iam_role" "lab" {
  name = "LabRole"
}

# The package is zipped from app/ as-is, so dependencies and the RDS CA bundle
# must already be there (`make build`); the precondition below enforces it.
data "archive_file" "lambda" {
  type        = "zip"
  source_dir  = "${path.module}/app"
  output_path = "${path.module}/build/lambda.zip"
  excludes    = ["package-lock.json"]
}

resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.name}"
  retention_in_days = 7
}

resource "aws_lambda_function" "api" {
  function_name = var.name
  description   = "Catalog API: cache-aside reads through ElastiCache, RDS PostgreSQL as source of truth"
  role          = data.aws_iam_role.lab.arn

  runtime       = "nodejs22.x"
  architectures = ["arm64"]
  handler       = "src/index.handler"
  memory_size   = var.lambda_memory_mb
  timeout       = var.lambda_timeout_seconds

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  # Publish an immutable version on every code/config change; the alias points at it.
  publish = true

  reserved_concurrent_executions = var.lambda_reserved_concurrency

  vpc_config {
    subnet_ids         = local.subnet_ids
    security_group_ids = [aws_security_group.lambda.id]
  }

  environment {
    variables = {
      DB_HOST                  = aws_db_instance.this.address
      DB_PORT                  = tostring(aws_db_instance.this.port)
      DB_NAME                  = var.db_name
      DB_USER                  = var.db_username
      DB_PASSWORD              = random_password.db.result
      REDIS_HOST               = aws_elasticache_replication_group.this.primary_endpoint_address
      REDIS_PORT               = "6379"
      CACHE_TTL_SECONDS        = tostring(var.cache_ttl_seconds)
      CACHE_TTL_JITTER_SECONDS = tostring(var.cache_ttl_jitter_seconds)
      NODE_OPTIONS             = "--enable-source-maps"
    }
  }

  logging_config {
    log_format = "Text"
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  lifecycle {
    precondition {
      condition     = fileexists("${path.module}/app/node_modules/pg/package.json") && fileexists("${path.module}/app/rds-ca.pem")
      error_message = "Lambda dependencies are missing. Run `make build` (or `make deploy`) before terraform plan/apply."
    }
  }
}

# Stable name the ALB targets; always moves to the newest published version.
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.api.function_name
  function_version = aws_lambda_function.api.version
}

# Warm environments that have already run the init code (TLS handshakes to
# ElastiCache done, modules loaded), so a sudden burst doesn't pay cold starts.
resource "aws_lambda_provisioned_concurrency_config" "live" {
  count = var.lambda_provisioned_concurrency > 0 ? 1 : 0

  function_name                     = aws_lambda_function.api.function_name
  qualifier                         = aws_lambda_alias.live.name
  provisioned_concurrent_executions = var.lambda_provisioned_concurrency
}

# One-off schema creation + seed data. Idempotent, so re-running it is harmless;
# Terraform re-invokes it only if the input changes.
resource "aws_lambda_invocation" "seed" {
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name

  input = jsonencode({
    action   = "seed"
    products = var.seed_products
    reviews  = var.seed_reviews
  })

  depends_on = [aws_db_instance.this]
}
