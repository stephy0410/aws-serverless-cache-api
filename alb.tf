# --- Self-signed TLS certificate, imported into ACM ---
# No public domain is available in this Learner Lab account, so this generates
# a self-signed cert and imports it into ACM (free, no Route53/domain purchase
# needed) for the ALB's HTTPS listener. Browsers/curl will flag it as untrusted
# (expected) but the traffic is real end-to-end TLS.

resource "tls_private_key" "self" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_self_signed_cert" "self" {
  private_key_pem = tls_private_key.self.private_key_pem

  subject {
    common_name  = "${var.name}.local"
    organization = "SD Lab04"
  }

  validity_period_hours = 8760 # 1 year
  early_renewal_hours   = 720

  allowed_uses = [
    "key_encipherment",
    "digital_signature",
    "server_auth",
  ]
}

resource "aws_acm_certificate" "self" {
  private_key      = tls_private_key.self.private_key_pem
  certificate_body = tls_self_signed_cert.self.cert_pem

  lifecycle {
    create_before_destroy = true
  }

  tags = {
    Name = "${var.name}-self-signed"
  }
}

# --- Application Load Balancer -> Lambda ---

resource "aws_lb" "this" {
  name               = "${var.name}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = local.subnet_ids

  tags = {
    Name = "${var.name}-alb"
  }
}

resource "aws_lb_target_group" "lambda" {
  name        = "${var.name}-tg"
  target_type = "lambda"

  health_check {
    enabled             = true
    path                = "/health"
    matcher             = "200"
    interval            = 35
    timeout             = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "${var.name}-tg"
  }
}

resource "aws_lambda_permission" "alb" {
  statement_id  = "AllowExecutionFromALB"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name
  principal     = "elasticloadbalancing.amazonaws.com"
  source_arn    = aws_lb_target_group.lambda.arn
}

resource "aws_lb_target_group_attachment" "lambda" {
  target_group_arn = aws_lb_target_group.lambda.arn
  target_id        = aws_lambda_alias.live.arn

  depends_on = [aws_lambda_permission.alb]
}

# HTTP listener: redirect everything to HTTPS.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.this.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type = "redirect"

    redirect {
      port        = "443"
      protocol    = "HTTPS"
      status_code = "HTTP_301"
    }
  }
}

# HTTPS listener: terminate TLS with the self-signed ACM cert, forward to the Lambda.
resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate.self.arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.lambda.arn
  }
}
