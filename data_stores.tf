# --- RDS PostgreSQL: the source of truth ---

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_subnet_group" "this" {
  name       = "${var.name}-db-private"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "${var.name}-db-private"
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_db_instance" "this" {
  identifier     = "${var.name}-db"
  engine         = "postgres"
  engine_version = var.db_engine_version
  instance_class = var.db_instance_class

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true

  db_name  = var.db_name
  username = var.db_username
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.this.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false

  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true

  tags = {
    Name = "${var.name}-db"
  }
}

# --- ElastiCache (Valkey, Redis-compatible): the cache in front of RDS ---

resource "aws_elasticache_subnet_group" "this" {
  name       = "${var.name}-cache-subnets"
  subnet_ids = local.subnet_ids
}

resource "aws_elasticache_parameter_group" "this" {
  name   = "${var.name}-valkey8"
  family = "valkey8"

  # Once memory is full, evict the least-recently-used keys (any key, TTL or not)
  # instead of rejecting writes. The cache only ever holds re-derivable data.
  parameter {
    name  = "maxmemory-policy"
    value = "allkeys-lru"
  }
}

resource "aws_elasticache_replication_group" "this" {
  replication_group_id = "${var.name}-cache"
  description          = "Cache-aside layer in front of the catalog database"

  engine               = "valkey"
  engine_version       = "8.0"
  node_type            = var.cache_node_type
  port                 = 6379
  parameter_group_name = aws_elasticache_parameter_group.this.name

  # One primary + replicas spread across AZs; if the primary fails a replica is promoted.
  num_cache_clusters         = 1 + var.cache_replicas
  automatic_failover_enabled = var.cache_replicas > 0
  multi_az_enabled           = var.cache_replicas > 0

  subnet_group_name  = aws_elasticache_subnet_group.this.name
  security_group_ids = [aws_security_group.cache.id]

  at_rest_encryption_enabled = true
  transit_encryption_enabled = true

  apply_immediately = true

  tags = {
    Name = "${var.name}-cache"
  }
}
