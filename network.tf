# Default VPC in the region
data "aws_vpc" "default" {
  default = true
}

# Default subnets, restricted to AZs that Lambda, ElastiCache and RDS all support
data "aws_subnets" "selected" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }

  filter {
    name   = "default-for-az"
    values = ["true"]
  }

  filter {
    name   = "availability-zone-id"
    values = var.availability_zone_ids
  }
}

locals {
  # Deterministic ordering so placement doesn't shuffle between applies
  subnet_ids = sort(data.aws_subnets.selected.ids)
}

# --- Security groups ---
# Traffic can only flow: internet -> ALB -> Lambda -> (ElastiCache | RDS).
# Neither data store is reachable from anything except the Lambda's ENIs.

resource "aws_security_group" "alb" {
  name        = "${var.name}-alb-sg"
  description = "Internet-facing: allow HTTP+HTTPS in, all egress"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-alb-sg"
  }
}

resource "aws_security_group" "lambda" {
  name        = "${var.name}-lambda-sg"
  description = "Lambda ENIs: no inbound (ALB invokes Lambda through the service API), all egress"
  vpc_id      = data.aws_vpc.default.id

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.name}-lambda-sg"
  }
}

resource "aws_security_group" "cache" {
  name        = "${var.name}-cache-sg"
  description = "ElastiCache: Redis protocol only from the Lambda"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "Valkey/Redis from Lambda"
    from_port       = 6379
    to_port         = 6379
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = {
    Name = "${var.name}-cache-sg"
  }
}

resource "aws_security_group" "db" {
  name        = "${var.name}-db-sg"
  description = "RDS: PostgreSQL only from the Lambda"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description     = "PostgreSQL from Lambda"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.lambda.id]
  }

  tags = {
    Name = "${var.name}-db-sg"
  }
}
