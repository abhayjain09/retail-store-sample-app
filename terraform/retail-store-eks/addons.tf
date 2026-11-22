####################################################################
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
# All IRSA roles trust the cluster OIDC provider defined in alb-controller.tf.
# Add-ons wait for the worker nodes to join (aws-auth + ASG) so every DaemonSet
# can schedule and the add-on reaches ACTIVE during the same apply.
####################################################################

locals {
  oidc_issuer = replace(aws_iam_openid_connect_provider.eks.url, "https://", "")

  # IRSA service accounts: key => { namespace, service account }
  irsa_service_accounts = {
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
}

# ---- Resolve add-on versions compatible with the cluster's Kubernetes version ----

data "aws_eks_addon_version" "this" {
  for_each = toset(local.eks_addons)

  addon_name         = each.value
  kubernetes_version = aws_eks_cluster.retail_store.version
  most_recent        = true
}

locals {
  cloudwatch_container_logs_enabled = (
    var.cloudwatch_container_logs_enabled != null
    ? var.cloudwatch_container_logs_enabled
    : !var.fluent_bit_cloudwatch_enabled
  )

  addon_version = {
    for name in local.eks_addons :
    name => coalesce(lookup(var.addon_versions, name, null), data.aws_eks_addon_version.this[name].version)
  }
}

# ---- IRSA trust policies ----

data "aws_iam_policy_document" "irsa_assume" {
  for_each = local.irsa_service_accounts

  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.eks.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:sub"
      values   = ["system:serviceaccount:${each.value.namespace}:${each.value.service_account}"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_issuer}:aud"
      values   = ["sts.amazonaws.com"]
    }
  }
}

# ---- vpc-cni IRSA ----

resource "aws_iam_role" "vpc_cni" {
  name               = "${var.cluster_name}-vpc-cni-role"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["vpc_cni"].json
  description        = "IRSA role for the vpc-cni add-on (kube-system/aws-node)"
}

resource "aws_iam_role_policy_attachment" "vpc_cni" {
  role       = aws_iam_role.vpc_cni.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"
}

# ---- amazon-cloudwatch-observability IRSA ----

resource "aws_iam_role" "cloudwatch_observability" {
  name               = "${var.cluster_name}-cloudwatch-observability-role"
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["cloudwatch"].json
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
  assume_role_policy = data.aws_iam_policy_document.irsa_assume["fluent_bit"].json
  description        = "IRSA role for the fluent-bit add-on (fluent-bit/fluent-bit)"
}

resource "aws_iam_role_policy" "fluent_bit_logs" {
  name = "${var.cluster_name}-fluent-bit-cloudwatch-logs"
  role = aws_iam_role.fluent_bit.id

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
        Resource = "arn:aws:logs:${var.aws_region}:${local.account_id}:*"
      },
    ]
  })
}

# ---- Add-ons ----

# Networking add-ons already exist as self-managed defaults on a new cluster;
# OVERWRITE lets EKS adopt them. preserve keeps the software running if the
# add-on resource is ever removed, so the nodes never lose pod networking.

resource "aws_eks_addon" "vpc_cni" {
  cluster_name                = aws_eks_cluster.retail_store.name
  addon_name                  = "vpc-cni"
  addon_version               = local.addon_version["vpc-cni"]
  service_account_role_arn    = aws_iam_role.vpc_cni.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  preserve                    = true

  depends_on = [
    aws_iam_role_policy_attachment.vpc_cni,
    kubernetes_config_map.aws_auth,
  ]
}

resource "aws_eks_addon" "kube_proxy" {
  cluster_name                = aws_eks_cluster.retail_store.name
  addon_name                  = "kube-proxy"
  addon_version               = local.addon_version["kube-proxy"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
  preserve                    = true

  depends_on = [kubernetes_config_map.aws_auth]
}

resource "aws_eks_addon" "pod_identity_agent" {
  cluster_name                = aws_eks_cluster.retail_store.name
  addon_name                  = "eks-pod-identity-agent"
  addon_version               = local.addon_version["eks-pod-identity-agent"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_addon.vpc_cni]
}

resource "aws_eks_addon" "node_monitoring_agent" {
  cluster_name                = aws_eks_cluster.retail_store.name
  addon_name                  = "eks-node-monitoring-agent"
  addon_version               = local.addon_version["eks-node-monitoring-agent"]
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  depends_on = [aws_eks_addon.vpc_cni]
}

resource "aws_eks_addon" "cloudwatch_observability" {
  cluster_name                = aws_eks_cluster.retail_store.name
  addon_name                  = "amazon-cloudwatch-observability"
  addon_version               = local.addon_version["amazon-cloudwatch-observability"]
  service_account_role_arn    = aws_iam_role.cloudwatch_observability.arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  # The add-on ships its own Fluent Bit for Container Insights logs. It is turned
  # off while the standalone fluent-bit add-on ships to CloudWatch, otherwise
  # every log line lands in CloudWatch twice. Metrics are unaffected.
  configuration_values = local.cloudwatch_container_logs_enabled ? null : jsonencode({
    containerLogs = { enabled = false }
  })

  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    aws_iam_role_policy_attachment.cloudwatch_agent,
    aws_iam_role_policy_attachment.cloudwatch_xray,
    aws_eks_addon.vpc_cni,
  ]
}

# ---- fluent-bit → CloudWatch Logs ----
#
# The add-on's default inputs/filters (upstream fluent-bit chart) tail
# /var/log/containers/*.log tagged kube.* with Kubernetes metadata, and kubelet
# journal logs tagged host.*. Only the outputs are replaced here: the default
# Elasticsearch outputs become CloudWatch Logs. Log groups are created by
# fluent-bit itself (auto_create_group) so the CI role needs no logs:* access.

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

  fluent_bit_configuration_values = (
    var.fluent_bit_configuration_values != null ? var.fluent_bit_configuration_values :
    var.fluent_bit_cloudwatch_enabled ? local.fluent_bit_cloudwatch_config : null
  )
}

resource "aws_eks_addon" "fluent_bit" {
  cluster_name                = aws_eks_cluster.retail_store.name
  addon_name                  = "fluent-bit"
  addon_version               = local.addon_version["fluent-bit"]
  service_account_role_arn    = var.fluent_bit_use_irsa ? aws_iam_role.fluent_bit.arn : null
  configuration_values        = local.fluent_bit_configuration_values
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"

  timeouts {
    create = "30m"
    update = "30m"
  }

  depends_on = [
    aws_iam_role_policy.fluent_bit_logs,
    aws_eks_addon.vpc_cni,
  ]
}
