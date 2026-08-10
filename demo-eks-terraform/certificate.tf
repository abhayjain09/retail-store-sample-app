####################################################################
#
# Let's Encrypt certificate issued through DuckDNS DNS-01 and
# imported into ACM for the ALB HTTPS listener.
#
####################################################################

resource "acme_registration" "retail_store" {}

resource "acme_certificate" "ui" {
  account_key_pem    = acme_registration.retail_store.account_key_pem
  common_name        = local.app_fqdn
  key_type           = "2048"
  min_days_remaining = 30

  dns_challenge {
    provider = "duckdns"
  }
}

resource "aws_acm_certificate" "ui" {
  certificate_body  = acme_certificate.ui.certificate_pem
  certificate_chain = acme_certificate.ui.issuer_pem
  private_key       = acme_certificate.ui.private_key_pem

  lifecycle {
    create_before_destroy = true
  }
}
