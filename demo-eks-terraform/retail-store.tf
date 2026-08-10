####################################################################
#
# Retail-store sample app + ALB ingress.
#
# Applied with `kubectl apply -f` after the cluster, nodes, and
# ALB controller are ready. Using a single null_resource here is
# simpler than splitting the 30+ resources in retail-store.yaml
# into individual kubernetes_manifest blocks.
#
####################################################################

locals {
  retail_store_manifest = templatefile("${path.module}/retail-store.yaml.tftpl", {
    cognito_auth_config = local.cognito_auth_config
    cognito_logout_url  = local.cognito_logout_url
    ui_certificate_arn  = aws_acm_certificate.ui.arn
    ui_fqdn             = local.app_fqdn
  })
}

resource "local_file" "retail_store_manifest" {
  filename = "${path.module}/retail-store.rendered.yaml"
  content  = local.retail_store_manifest
}

resource "null_resource" "retail_store" {
  triggers = {
    manifest_sha       = sha256(local.retail_store_manifest)
    manifest_payload   = sensitive(base64encode(local.retail_store_manifest))
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

      kubectl apply -f ${local_file.retail_store_manifest.filename}

      # Block until the ALB controller publishes the ingress hostname so the
      # kubernetes_ingress_v1 data source below sees a stable value when read.
      for i in $(seq 1 60); do
        host=$(kubectl get ingress ui -n default -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        if [ -n "$host" ]; then
          echo "ALB hostname: $host"
          exit 0
        fi
        echo "Waiting for ALB hostname ($i/60)..."
        sleep 10
      done
      echo "WARNING: ALB hostname not available after 10 minutes"
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      manifest_payload='${lookup(self.triggers, "manifest_payload", "")}'
      if [ -n "$manifest_payload" ]; then
        printf '%s' "$manifest_payload" | base64 --decode | kubectl delete -f - --ignore-not-found=true || true
      else
        echo "Skipping manifest deletion for legacy state without a stored payload."
      fi
    EOT
  }

  depends_on = [
    aws_acm_certificate.ui,
    helm_release.alb_controller,
    kubernetes_config_map.aws_auth,
    local_file.retail_store_manifest,
    aws_cloudformation_stack.autoscaling_group,
  ]
}

data "kubernetes_ingress_v1" "ui" {
  metadata {
    name      = "ui"
    namespace = "default"
  }
  depends_on = [null_resource.retail_store]
}

output "ui_alb_dns_name" {
  value       = data.kubernetes_ingress_v1.ui.status[0].load_balancer[0].ingress[0].hostname
  description = "Application Load Balancer DNS name for the retail-store UI"
}
