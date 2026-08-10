####################################################################
#
# Static public IP entry point for the UI ALB. DuckDNS publishes the
# first accelerator IPv4 address because it supports one IPv4 record.
#
####################################################################

data "aws_lb" "ui" {
  name       = "retail-store-ui"
  depends_on = [null_resource.retail_store]
}

resource "aws_globalaccelerator_accelerator" "ui" {
  name            = "${var.cluster_name}-ui"
  enabled         = true
  ip_address_type = "IPV4"
}

resource "aws_globalaccelerator_listener" "ui" {
  accelerator_arn = aws_globalaccelerator_accelerator.ui.arn
  client_affinity = "SOURCE_IP"
  protocol        = "TCP"

  port_range {
    from_port = 80
    to_port   = 80
  }

  port_range {
    from_port = 443
    to_port   = 443
  }
}

resource "aws_globalaccelerator_endpoint_group" "ui" {
  listener_arn                  = aws_globalaccelerator_listener.ui.arn
  endpoint_group_region         = var.aws_region
  health_check_port             = 443
  health_check_protocol         = "TCP"
  health_check_interval_seconds = 30
  threshold_count               = 3

  endpoint_configuration {
    endpoint_id                    = data.aws_lb.ui.arn
    client_ip_preservation_enabled = false
    weight                         = 100
  }
}

locals {
  accelerator_ipv4_addresses = flatten([
    for ip_set in aws_globalaccelerator_accelerator.ui.ip_sets : ip_set.ip_addresses
  ])
}

output "global_accelerator_ipv4_addresses" {
  value       = local.accelerator_ipv4_addresses
  description = "Static Global Accelerator IPv4 addresses"
}

output "duckdns_ipv4_address" {
  value       = local.accelerator_ipv4_addresses[0]
  description = "Static IPv4 address published to DuckDNS"
}

output "global_accelerator_dns_name" {
  value       = aws_globalaccelerator_accelerator.ui.dns_name
  description = "Global Accelerator DNS name"
}
