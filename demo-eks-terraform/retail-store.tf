####################################################################
#
# Retail-store sample app + ALB ingress.
#
# The app is now a Helm chart (deploy/helm/retail-store) deployed and kept
# in sync by Argo CD -- see argocd.tf. This file keeps the pieces that live
# outside the chart: the OpenAI secret and the ingress lookup/output.
#
####################################################################

# The app used to be applied with `kubectl apply` from this null_resource.
# Forget it without running its destroy provisioner (which would delete the
# running app); Argo CD adopts the existing objects on its first sync.
removed {
  from = null_resource.retail_store

  lifecycle {
    destroy = false
  }
}

# Holds the OpenAI key, so it stays out of Git and the Argo CD Application.
# Referenced by the ui Deployment (secretKeyRef retail-store-openai).
resource "null_resource" "retail_store_openai_secret" {
  triggers = {
    cluster_name       = aws_eks_cluster.demo_eks.name
    openai_config_hash = sha256(var.openai_api_key)
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${var.aws_region} --name ${aws_eks_cluster.demo_eks.name}

      if [ -n "$OPENAI_API_KEY" ]; then
        chat_enabled=true
      else
        chat_enabled=false
      fi

      kubectl create secret generic retail-store-openai -n default \
        --from-literal=chat-enabled="$chat_enabled" \
        --from-literal=api-key="$OPENAI_API_KEY" \
        --dry-run=client -o yaml | kubectl apply -f -
    EOT
  }

  depends_on = [
    kubernetes_config_map.aws_auth,
    aws_cloudformation_stack.autoscaling_group,
  ]
}

data "kubernetes_ingress_v1" "ui" {
  metadata {
    name      = "ui"
    namespace = "default"
  }
  depends_on = [null_resource.retail_store_sync]
}

output "ui_alb_dns_name" {
  value       = data.kubernetes_ingress_v1.ui.status[0].load_balancer[0].ingress[0].hostname
  description = "Application Load Balancer DNS name for the retail-store UI"
}
