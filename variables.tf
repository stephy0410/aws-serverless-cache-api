variable "region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}

variable "profile" {
  description = "AWS CLI profile to use (AWS Academy Learner Lab credentials)"
  type        = string
  default     = "academy"
}

variable "name" {
  description = "Name prefix for every resource in this project"
  type        = string
  default     = "cache-api"
}

variable "availability_zone_ids" {
  description = "AZ IDs whose default subnets host the ALB, Lambda ENIs, ElastiCache and RDS. use1-az3 is excluded because Lambda does not support it."
  type        = list(string)
  default     = ["use1-az1", "use1-az2", "use1-az4"]
}

# --- Lambda ---

variable "lambda_memory_mb" {
  description = "Lambda memory (MB). CPU scales with memory, so this also sets per-request CPU."
  type        = number
  default     = 512
}

variable "lambda_timeout_seconds" {
  description = "Lambda timeout. Also bounds the one-off seed invocation."
  type        = number
  default     = 30
}

variable "lambda_reserved_concurrency" {
  description = "Max concurrent Lambda executions. Each execution holds at most one Postgres connection, so this caps DB connections below the RDS max_connections."
  type        = number
  default     = 60
}

variable "lambda_provisioned_concurrency" {
  description = "Pre-initialized (warm) Lambda environments on the live alias. Avoids cold starts at the start of a load test. 0 disables it."
  type        = number
  default     = 10
}

# --- Cache ---

variable "cache_node_type" {
  description = "ElastiCache node type"
  type        = string
  default     = "cache.t3.micro"
}

variable "cache_replicas" {
  description = "Read replicas in addition to the primary. With >= 1, Multi-AZ automatic failover is turned on."
  type        = number
  default     = 1
}

variable "cache_ttl_seconds" {
  description = "Base TTL for cached entries. A random jitter is added so keys filled together do not expire together."
  type        = number
  default     = 300
}

variable "cache_ttl_jitter_seconds" {
  description = "Upper bound of the random jitter added to each TTL"
  type        = number
  default     = 60
}

# --- Database ---

variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_engine_version" {
  description = "PostgreSQL major version"
  type        = string
  default     = "16"
}

variable "db_name" {
  description = "Database name"
  type        = string
  default     = "catalogdb"
}

variable "db_username" {
  description = "Master username"
  type        = string
  default     = "catalog_admin"
}

variable "seed_products" {
  description = "Number of products inserted by the seed invocation"
  type        = number
  default     = 10000
}

variable "seed_reviews" {
  description = "Number of reviews inserted by the seed invocation (spread randomly across products)"
  type        = number
  default     = 300000
}
