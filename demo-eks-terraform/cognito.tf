####################################################################
#
# Cognito resources for SSO in front of the UI ALB.
#
####################################################################

locals {
  root_domain   = lower(trim(var.root_domain, "."))
  app_subdomain = lower(trim(var.app_subdomain, "."))
  app_fqdn      = local.app_subdomain == "" ? local.root_domain : "${local.app_subdomain}.${local.root_domain}"

  derived_cognito_domain_prefix = substr(
    replace(
      join("-", compact(["retail-store", local.app_subdomain != "" ? local.app_subdomain : "app", data.aws_caller_identity.current.account_id])),
      "/[^a-z0-9-]/",
      "-"
    ),
    0,
    63
  )

  cognito_domain_prefix = var.cognito_domain_prefix != "" ? lower(trim(var.cognito_domain_prefix, ".")) : local.derived_cognito_domain_prefix

  cognito_auth_config = jsonencode({
    userPoolARN      = aws_cognito_user_pool.retail_store.arn
    userPoolClientID = aws_cognito_user_pool_client.retail_store.id
    userPoolDomain   = aws_cognito_user_pool_domain.retail_store.domain
  })

  cognito_logout_url = "https://${aws_cognito_user_pool_domain.retail_store.domain}.auth.${var.aws_region}.amazoncognito.com/logout?client_id=${aws_cognito_user_pool_client.retail_store.id}&response_type=code&redirect_uri=${urlencode("https://${local.app_fqdn}/oauth2/idpresponse")}&scope=openid+email+profile"
}

resource "aws_cognito_user_pool" "retail_store" {
  name           = "${var.cluster_name}-users"
  user_pool_tier = "PLUS"

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  auto_verified_attributes = ["email"]
  mfa_configuration        = "OFF"
  username_attributes      = ["email"]

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  password_policy {
    minimum_length                   = 12
    require_lowercase                = true
    require_numbers                  = true
    require_symbols                  = true
    require_uppercase                = true
    temporary_password_validity_days = 7
  }

  user_pool_add_ons {
    advanced_security_mode = "ENFORCED"
  }

  username_configuration {
    case_sensitive = false
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }
}

resource "aws_cognito_user_pool_client" "retail_store" {
  name         = "${var.cluster_name}-alb-client"
  user_pool_id = aws_cognito_user_pool.retail_store.id

  access_token_validity                = 1
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_flows_user_pool_client = true
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  callback_urls                        = ["https://${local.app_fqdn}/oauth2/idpresponse"]
  explicit_auth_flows                  = ["ALLOW_REFRESH_TOKEN_AUTH", "ALLOW_USER_SRP_AUTH"]
  generate_secret                      = true
  id_token_validity                    = 1
  logout_urls                          = ["https://${local.app_fqdn}/"]
  prevent_user_existence_errors        = "ENABLED"
  refresh_token_validity               = 30
  supported_identity_providers         = ["COGNITO"]

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

resource "aws_cognito_user_pool_domain" "retail_store" {
  domain       = local.cognito_domain_prefix
  user_pool_id = aws_cognito_user_pool.retail_store.id
}

output "ui_url" {
  value       = "https://${local.app_fqdn}"
  description = "Friendly HTTPS URL for the retail-store UI"
}

output "cognito_user_pool_id" {
  value       = aws_cognito_user_pool.retail_store.id
  description = "Cognito user pool ID backing ALB authentication"
}

output "cognito_user_pool_client_id" {
  value       = aws_cognito_user_pool_client.retail_store.id
  description = "Cognito user pool client used by the ALB"
}

output "cognito_login_domain" {
  value       = "https://${aws_cognito_user_pool_domain.retail_store.domain}.auth.${var.aws_region}.amazoncognito.com"
  description = "Amazon Cognito managed login domain used by the ALB"
}

output "cognito_domain_prefix" {
  value       = aws_cognito_user_pool_domain.retail_store.domain
  description = "Amazon Cognito domain prefix used for the user pool domain"
}
