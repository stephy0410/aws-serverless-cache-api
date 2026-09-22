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

# --- Private subnets: RDS only ---
# The default subnets are public (the main route table sends 0.0.0.0/0 to the IGW),
# so the database gets its own subnets with a route table that has only the local
# VPC route. The Lambda still reaches it through that local route.

resource "aws_route_table" "private" {
  vpc_id = data.aws_vpc.default.id

  tags = {
    Name = "${var.name}-private-rt"
  }
}

resource "aws_subnet" "private" {
  count = length(var.availability_zone_ids)

  vpc_id                  = data.aws_vpc.default.id
  availability_zone_id    = var.availability_zone_ids[count.index]
  cidr_block              = var.private_subnet_cidrs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "${var.name}-private-${var.availability_zone_ids[count.index]}"
  }
}

resource "aws_route_table_association" "private" {
  count = length(aws_subnet.private)

  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
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
