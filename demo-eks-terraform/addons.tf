####################################################################
#
# EKS managed add-ons + IRSA roles
#
#  Add-on                           Type           IAM
#  ------------------------------   -------------  -------------------------------------------
#  vpc-cni                          networking     IRSA  kube-system/aws-node
#  kube-proxy                       networking     none
#  eks-pod-identity-agent           security       none (node role: AmazonEKSWorkerNodePolicy)
#  eks-node-monitoring-agent        observability  none
#  amazon-cloudwatch-observability  observability  IRSA  amazon-cloudwatch/cloudwatch-agent
#  fluent-bit (community)           observability  IRSA  fluent-bit/fluent-bit
#
# All IRSA roles trust the cluster OIDC provider created in alb-controller.tf.
# Lab IAM user restrictions shape this file:
#   - iam:PutRolePolicy denied → managed policies + attachments only
#   - iam:PassRole denied      → no service_account_role_arn on add-ons; roles
#                                are bound by annotating the service accounts
#                                (see "IRSA binding" below)
#
# Add-ons wait for the worker nodes to join (aws-auth + ASG) so every
# DaemonSet can schedule and the add-on reaches ACTIVE in the same apply.
#
####################################################################

variable "addon_versions" {
  type        = map(string)
  description = "Optional pinned versions per EKS add-on name (e.g. { \"vpc-cni\" = \"v1.19.2-eksbuild.1\" }). Unset add-ons use the latest version compatible with the cluster."
  default     = {}
}

variable "fluent_bit_cloudwatch_enabled" {
  type        = bool
  description = "Configure the fluent-bit add-on to ship container (kube.*) and kubelet (host.*) logs to CloudWatch Logs under /aws/eks/<cluster>/fluent-bit/"
  default     = true
}

variable "fluent_bit_log_retention_days" {
  type        = number
  description = "Retention (days) fluent-bit sets on the CloudWatch log groups it creates"
  default     = 30
}

variable "fluent_bit_use_irsa" {
  type        = bool
  description = "Attach the fluent-bit IRSA role (CloudWatch Logs write) to the fluent-bit add-on service account"
  default     = true
}

variable "fluent_bit_configuration_values" {
  type        = string
  description = "Optional raw JSON configuration for the fluent-bit add-on; overrides the built-in CloudWatch config (schema: aws eks describe-addon-configuration --addon-name fluent-bit --addon-version <ver>)"
  default     = null
}

variable "cloudwatch_container_logs_enabled" {
  type        = bool
  description = "Container Insights log collection (built-in Fluent Bit) in amazon-cloudwatch-observability. null = automatic: off while fluent_bit_cloudwatch_enabled is true (avoids duplicate logs), on otherwise."
  default     = null
}

locals {
  addons_oidc_issuer = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")

  # IRSA service accounts: key => namespace / service account name
  addon_irsa_service_accounts = {
    vpc_cni = {
      namespace       = "kube-system"
      service_account = "aws-node"
    }
    cloudwatch = {
      namespace       = "amazon-cloudwatch"
      service_account = "cloudwatch-agent"
    }
    fluent_bit = {
      namespace       = "fluent-bit"
      service_account = "fluent-bit"
    }
  }

  eks_addons = [
    "vpc-cni",
    "kube-proxy",
    "eks-pod-identity-agent",
    "eks-node-monitoring-agent",
    "amazon-cloudwatch-observability",
    "fluent-bit",
  ]

  cloudwatch_container_logs_enabled = var.cloudwatch_container_logs_enabled != null ? var.cloudwatch_container_logs_enabled : !var.fluent_bit_cloudwatch_enabled
}

# ---- Resolve add-on versions compatible with the cluster's Kubernetes version ----

data "aws_eks_addon_version" "this" {
  for_each = toset(local.eks_addons)

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.demo_eks.version
  most_recent        = true
}

locals {
  addon_version = {
    for name in local.eks_addons :
    name => coalesce(lookup(var.addon_versions, name, null), data.aws_eks_addon_version.this[name].version)
  }
}

# ---- IRSA trust policies ----

data "aws_iam_policy_document" "addon_irsa_assume" {
  for_each = local.addon_irsa_service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.addons_oidc_issuer}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.addons_oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---- vpc-cni IRSA ----

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.cluster_name}-vpc-cni-role"
  assume_role_policy = data.aws_iam_policy_document.addon_irsa_assume["vpc_cni"].json
  description        = "IRSA role for the vpc-cni add-on (kube-system/aws-node)"
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ---- amazon-cloudwatch-observability IRSA ----

resource "aws_iam_role" "cloudwatch_observability" {
  name               = "${var.cluster_name}-cloudwatch-observability-role"
  assume_role_policy = data.aws_iam_policy_document.addon_irsa_assume["cloudwatch"].json
  description        = "IRSA role for the amazon-cloudwatch-observability add-on"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_agent" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_role_policy_attachment" "cloudwatch_xray" {
  role       = aws_iam_role.cloudwatch_observability.name
  policy_arn = "arn:aws:iam::aws:policy/AWSXrayWriteOnlyAccess"
}

# ---- fluent-bit IRSA (CloudWatch Logs write) ----

resource "aws_iam_role" "fluent_bit" {
  name               = "${var.cluster_name}-fluent-bit-role"
  assume_role_policy = data.aws_iam_policy_document.addon_irsa_assume["fluent_bit"].json
  description        = "IRSA role for the fluent-bit add-on (fluent-bit/fluent-bit)"
}

resource "aws_iam_policy" "fluent_bit_logs" {
  name        = "${var.cluster_name}-fluent-bit-cloudwatch-logs"
  description = "Allows the fluent-bit add-on to write logs to CloudWatch Logs"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CloudWatchLogsWrite"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:DescribeLogGroups",
          "logs:DescribeLogStreams",
          "logs:PutLogEvents",
          "logs:PutRetentionPolicy",
        ]
        Resource = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*"
      },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "fluent_bit_logs" {
  role       = aws_iam_role.fluent_bit.name
  policy_arn = aws_iam_policy.fluent_bit_logs.arn
}

# ---- fluent-bit → CloudWatch Logs configuration ----
#
# The add-on's default inputs/filters (upstream fluent-bit chart) tail
# /var/log/containers/*.log tagged kube.* with Kubernetes metadata, and kubelet
# journal logs tagged host.*. Only the outputs are replaced here: the default
# Elasticsearch outputs become CloudWatch Logs. Log groups are created by
# fluent-bit itself (auto_create_group), so Terraform needs no logs:* access.

locals {
  fluent_bit_log_group_prefix = "/aws/eks/${var.cluster_name}/fluent-bit"

  fluent_bit_cloudwatch_config = jsonencode({
    config = {
      outputs = <<-EOT
        [OUTPUT]
            Name                cloudwatch_logs
            Match               kube.*
            region              ${var.aws_region}
            log_group_name      ${local.fluent_bit_log_group_prefix}/application
            log_stream_prefix   app-
            auto_create_group   true
            log_retention_days  ${var.fluent_bit_log_retention_days}

        [OUTPUT]
            Name                cloudwatch_logs
            Match               host.*
            region              ${var.aws_region}
            log_group_name      ${local.fluent_bit_log_group_prefix}/host
            log_stream_prefix   host-
            auto_create_group   true
            log_retention_days  ${var.fluent_bit_log_retention_days}
      EOT
    }
  })

  fluent_bit_configuration_values = var.fluent_bit_configuration_values != null ? var.fluent_bit_configuration_values : (var.fluent_bit_cloudwatch_enabled ? local.fluent_bit_cloudwatch_config : null)
}

# ---- Add-ons ----

# Networking add-ons already exist as self-managed defaults on a new cluster;
# OVERWRITE lets EKS adopt them. preserve keeps the software running if the
# add-on resource is ever removed, so the nodes never lose pod networking.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.demo_eks.name
  addon_name                  = "vpc-cni"
  addon_version               = local.addon_version["vpc-cni"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  preserve                    = true

  # Prefix delegation: each ENI slot gets a /28 (16 IPs) instead of one IP, so
  # a t3.medium is no longer capped at 17 pods. Paired with kubelet
  # --max-pods=var.node_max_pods in the node user data (nodes.tf).
  configuration_values = jsonencode({
    env = {
      ENABLE_PREFIX_DELEGATION = "true"
      WARM_PREFIX_TARGET       = "1"
    }
  })

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni,
    kubernetes_config_map.aws_auth,
  ]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.demo_eks.name
  addon_name                  = "kube-proxy"
  addon_version               = local.addon_version["kube-proxy"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  preserve                    = true

  depends_on = [
    kubernetes_config_map.aws_auth,
  ]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.demo_eks.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = local.addon_version["eks-pod-identity-agent"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_addon.vpc_cni,
  ]
}

resource "aws_eks_addon" "node_monitoring_agent" {
  cluster_name                = aws_eks_cluster.demo_eks.name
  addon_name                  = "eks-node-monitoring-agent"
  addon_version               = local.addon_version["eks-node-monitoring-agent"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [
    aws_eks_addon.vpc_cni,
  ]
}

# ---- Wait for the ALB controller webhook ----
# The aws-load-balancer-controller registers a mutating webhook for every
# Service (failurePolicy: Fail). While its pods are not ready -- right after
# install, or while nodes are being replaced -- any add-on that creates a
# Service fails with "no endpoints available for service
# aws-load-balancer-webhook-service". Block until the webhook has endpoints.
resource "null_resource" "alb_webhook_ready" {
  triggers = {
    cluster_name  = aws_eks_cluster.demo_eks.name
    alb_release   = "${helm_release.alb_controller.version}-${helm_release.alb_controller.metadata[0].revision}"
    node_template = aws_launch_template.node_launch_template.latest_version
    node_count    = var.node_group_desired_capacity
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.demo_eks.name}
      kubectl -n kube-system rollout status deployment/aws-load-balancer-controller --timeout=10m || true
      for i in $(seq 1 60); do
        ep=$(kubectl -n kube-system get endpoints aws-load-balancer-webhook-service \
          -o jsonpath='{.subsets[*].addresses[*].ip}' 2>/dev/null || true)
        if [ -n "$ep" ]; then
          echo "ALB controller webhook ready: $ep"
          exit 0
        fi
        echo "Waiting for aws-load-balancer-webhook-service endpoints ($i/60)..."
        sleep 10
      done
      echo "ALB controller webhook has no endpoints after 10 minutes:"
      kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller -o wide || true
      exit 1
    EOT
  }

  depends_on = [
    helm_release.alb_controller,
    aws_cloudformation_stack.autoscaling_group,
    aws_eks_addon.vpc_cni,
  ]
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = aws_eks_cluster.demo_eks.name
  addon_name                  = "amazon-cloudwatch-observability"
  addon_version               = local.addon_version["amazon-cloudwatch-observability"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The add-on ships its own Fluent Bit for Container Insights logs. It is turned
  # off while the standalone fluent-bit add-on ships to CloudWatch, otherwise
  # every log line lands in CloudWatch twice. Metrics are unaffected.
  configuration_values = local.cloudwatch_container_logs_enabled ? null : jsonencode({ containerLogs = { enabled = false } })

  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_iam_role_policy_attachment.cloudwatch_xray,
    aws_eks_addon.vpc_cni,
    null_resource.alb_webhook_ready,
  ]
}

resource "aws_eks_addon" "fluent_bit" {
  cluster_name                = aws_eks_cluster.demo_eks.name
  addon_name                  = "fluent-bit"
  addon_version               = local.addon_version["fluent-bit"]
  configuration_values        = local.fluent_bit_configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    aws_iam_role_policy_attachment.fluent_bit_logs,
    aws_eks_addon.vpc_cni,
    null_resource.alb_webhook_ready,
  ]
}

# ---- IRSA binding: annotate add-on service accounts ----
#
# The add-ons are created WITHOUT service_account_role_arn: EKS requires
# iam:PassRole for that, which this lab's IAM user does not have. Instead the
# role is bound the same way as aws-load-balancer-controller and
# cluster-autoscaler: an eks.amazonaws.com/role-arn annotation on the service
# account (no PassRole needed). EKS add-on reconciliation leaves annotations it
# does not manage in place.

locals {
  addon_irsa_role_arns = {
    vpc_cni    = aws_iam_role.vpc_cni.arn
    cloudwatch = aws_iam_role.cloudwatch_observability.arn
    fluent_bit = aws_iam_role.fluent_bit.arn
  }

  addon_irsa_bindings = {
    for k, v in local.addon_irsa_service_accounts : k => merge(v, { role_arn = local.addon_irsa_role_arns[k] })
    if k != "fluent_bit" || var.fluent_bit_use_irsa
  }
}

# This runs IN PARALLEL with the add-on installs (it depends only on vpc-cni,
# like the add-ons themselves), not after them: an add-on whose pods need AWS
# credentials to become Ready (fluent-bit) never reaches ACTIVE without the
# role, so waiting for ACTIVE first would deadlock. It waits for the add-on to
# create its service account, annotates it, then restarts the workloads using
# it - pods only receive IRSA credentials when they are created.
resource "null_resource" "addon_irsa" {
  for_each = local.addon_irsa_bindings

  triggers = {
    role_arn        = each.value.role_arn
    namespace       = each.value.namespace
    service_account = each.value.service_account
    cluster_name    = aws_eks_cluster.demo_eks.name
    vpc_cni_addon   = aws_eks_addon.vpc_cni.id
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      NS="${each.value.namespace}"
      SA="${each.value.service_account}"
      aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.demo_eks.name} >/dev/null

      # 1. Wait (up to 20 min) for the add-on to create the service account
      for i in $(seq 1 120); do
        kubectl get serviceaccount "$SA" -n "$NS" >/dev/null 2>&1 && break
        echo "Waiting for service account $NS/$SA ($i/120)..."
        sleep 10
      done
      kubectl get serviceaccount "$SA" -n "$NS" >/dev/null

      # 2. Bind the IRSA role
      kubectl annotate serviceaccount "$SA" -n "$NS" --overwrite \
        "eks.amazonaws.com/role-arn=${each.value.role_arn}"
      echo "Annotated $NS/$SA with ${each.value.role_arn}"

      # 3. Wait (up to 10 min) for workloads using the service account, then restart them
      workloads=""
      for i in $(seq 1 60); do
        workloads=$(kubectl get daemonsets,deployments -n "$NS" -o json \
          | jq -r --arg sa "$SA" \
            '.items[] | select(.spec.template.spec.serviceAccountName == $sa) | "\(.kind | ascii_downcase)/\(.metadata.name)"')
        [ -n "$workloads" ] && break
        echo "Waiting for workloads using $NS/$SA ($i/60)..."
        sleep 10
      done

      if [ -z "$workloads" ]; then
        echo "WARNING: no workloads use $NS/$SA - nothing to restart"
        exit 0
      fi

      for w in $workloads; do
        echo "Restarting $w in $NS to pick up the IRSA role"
        kubectl rollout restart "$w" -n "$NS"
      done
      for w in $workloads; do
        kubectl rollout status "$w" -n "$NS" --timeout=10m || echo "WARNING: $w not fully rolled out yet (checked again by the pipeline verify step)"
      done
    EOT
  }

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni,
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_iam_role_policy_attachment.cloudwatch_xray,
    aws_iam_role_policy_attachment.fluent_bit_logs,
  ]
}

# ---- Outputs ----

output "eks_addon_versions" {
  value = {
    for a in [
      aws_eks_addon.vpc_cni,
      aws_eks_addon.kube_proxy,
      aws_eks_addon.pod_identity_agent,
      aws_eks_addon.node_monitoring_agent,
      aws_eks_addon.cloudwatch_observability,
      aws_eks_addon.fluent_bit,
    ] : a.addon_name => a.addon_version
  }
  description = "Installed EKS add-ons and their versions"
}

output "addon_irsa_role_arns" {
  value = {
    vpc_cni                  = aws_iam_role.vpc_cni.arn
    cloudwatch_observability = aws_iam_role.cloudwatch_observability.arn
    fluent_bit               = aws_iam_role.fluent_bit.arn
  }
  description = "IRSA role ARNs used by EKS add-ons"
}

output "fluent_bit_log_groups" {
  value       = var.fluent_bit_cloudwatch_enabled ? ["${local.fluent_bit_log_group_prefix}/application", "${local.fluent_bit_log_group_prefix}/host"] : []
  description = "CloudWatch log groups fluent-bit writes to (created on first log line)"
}
