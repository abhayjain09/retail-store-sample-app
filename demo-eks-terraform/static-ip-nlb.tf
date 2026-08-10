####################################################################
#
# Static public IP entry point for the UI ALB. The NLB forwards TCP
# unchanged, so TLS and Cognito authentication remain on the ALB.
#
####################################################################

data "aws_lb" "ui" {
  name       = "retail-store-ui"
  depends_on = [null_resource.retail_store]
}

locals {
  static_ip_subnet_id = sort(data.aws_subnets.public.ids)[0]
}

resource "aws_eip" "ui_nlb" {
  domain = "vpc"

  tags = {
    Name = "${var.cluster_name}-ui-nlb"
  }
}

resource "aws_lb" "ui_static" {
  name                             = substr("${var.cluster_name}-ui-nlb", 0, 32)
  internal                         = false
  load_balancer_type               = "network"
  enable_cross_zone_load_balancing = true

  subnet_mapping {
    subnet_id     = local.static_ip_subnet_id
    allocation_id = aws_eip.ui_nlb.id
  }

  tags = {
    Name = "${var.cluster_name}-ui-nlb"
  }
}

resource "aws_lb_target_group" "ui_http" {
  name        = substr("${var.cluster_name}-ui-http", 0, 32)
  port        = 80
  protocol    = "TCP"
  target_type = "alb"
  vpc_id      = data.aws_vpc.default_vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 30
    matcher             = "200-499"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTP"
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group" "ui_https" {
  name        = substr("${var.cluster_name}-ui-https", 0, 32)
  port        = 443
  protocol    = "TCP"
  target_type = "alb"
  vpc_id      = data.aws_vpc.default_vpc.id

  health_check {
    enabled             = true
    healthy_threshold   = 3
    interval            = 30
    matcher             = "200-499"
    path                = "/"
    port                = "traffic-port"
    protocol            = "HTTPS"
    unhealthy_threshold = 3
  }
}

resource "aws_lb_target_group_attachment" "ui_http" {
  target_group_arn = aws_lb_target_group.ui_http.arn
  target_id        = data.aws_lb.ui.arn
  port             = 80
}

resource "aws_lb_target_group_attachment" "ui_https" {
  target_group_arn = aws_lb_target_group.ui_https.arn
  target_id        = data.aws_lb.ui.arn
  port             = 443
}

resource "aws_lb_listener" "ui_http" {
  load_balancer_arn = aws_lb.ui_static.arn
  port              = 80
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui_http.arn
  }
}

resource "aws_lb_listener" "ui_https" {
  load_balancer_arn = aws_lb.ui_static.arn
  port              = 443
  protocol          = "TCP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui_https.arn
  }
}

output "static_ipv4_address" {
  value       = aws_eip.ui_nlb.public_ip
  description = "Static Elastic IP assigned to the public Network Load Balancer"
}

output "duckdns_ipv4_address" {
  value       = aws_eip.ui_nlb.public_ip
  description = "Static IPv4 address published to DuckDNS"
}

output "network_load_balancer_dns_name" {
  value       = aws_lb.ui_static.dns_name
  description = "Public Network Load Balancer DNS name"
}
