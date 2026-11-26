####################################################################
#
# Argo CD (GitOps) + the retail-store Helm chart
#
# - helm_release.argocd       installs Argo CD into the "argocd" namespace
# - helm_release.argocd_apps  creates the Argo CD Application that syncs
#                             deploy/helm/retail-store from this Git repo
#                             into the retail-* namespaces
# - null_resource.retail_store_sync waits for the first sync and the ALB
#
# Values that change per run or per account (private ECR registry, image
# tag, ACM certificate, Cognito config) are passed to the chart through the
# Application's helm.valuesObject, so nothing account-specific is committed.
#
####################################################################

variable "argocd_chart_version" {
  type        = string
  description = "argo-cd Helm chart version (https://artifacthub.io/packages/helm/argo/argo-cd)"
  default     = "7.7.0"
}

variable "argocd_apps_chart_version" {
  type        = string
  description = "argocd-apps Helm chart version (https://artifacthub.io/packages/helm/argo/argocd-apps)"
  default     = "2.0.0"
}

variable "gitops_repo_url" {
  type        = string
  description = "Git repository Argo CD pulls the retail-store chart from (set by the pipeline to this GitHub repo)"
  default     = ""
}

variable "gitops_target_revision" {
  type        = string
  description = "Branch, tag or commit Argo CD tracks"
  default     = "main"
}

variable "gitops_chart_path" {
  type        = string
  description = "Path of the retail-store Helm chart inside the Git repo"
  default     = "deploy/helm/retail-store"
}

variable "gitops_repo_username" {
  type        = string
  description = "Username for a private Git repo (any non-empty value works with a GitHub token)"
  default     = "git"
}

variable "gitops_repo_token" {
  type        = string
  description = "Read-only token for a private Git repo. Leave empty for a public repo."
  default     = ""
  sensitive   = true
}

variable "argocd_server_enabled" {
  type        = bool
  description = <<-EOT
    Run the argocd-server (web UI/API) pod. Off by default: the lab allows
    3 pods per namespace and controller + repo-server + redis already use
    them. Without it, open the UI locally with `argocd admin dashboard -n argocd`.
  EOT
  default     = false
}

variable "image_registry" {
  type        = string
  description = "Private ECR registry (<account>.dkr.ecr.<region>.amazonaws.com). Empty = public images."
  default     = ""
}

variable "image_tag" {
  type        = string
  description = "Tag of the retail-store service images"
  default     = "1.5.0"
}

locals {
  argocd_namespace   = "argocd"
  retail_store_app   = "retail-store"
  use_private_images = var.image_registry != ""

  # One namespace per service group: the lab allows 3 pods per namespace
  retail_store_namespaces = {
    catalog  = "retail-catalog"
    carts    = "retail-carts"
    orders   = "retail-orders"
    checkout = "retail-checkout"
    ui       = "retail-ui"
  }

  retail_store_values = {
    namespaces = local.retail_store_namespaces
    image = {
      registry = local.use_private_images ? var.image_registry : "public.ecr.aws/aws-containers"
      tag      = var.image_tag
    }
    dependencyImages = {
      mysql         = local.use_private_images ? "${var.image_registry}/retail-store-sample-mysql:8.0" : "public.ecr.aws/docker/library/mysql:8.0"
      postgres      = local.use_private_images ? "${var.image_registry}/retail-store-sample-postgres:16.1" : "public.ecr.aws/docker/library/postgres:16.1"
      rabbitmq      = local.use_private_images ? "${var.image_registry}/retail-store-sample-rabbitmq:3-management" : "public.ecr.aws/docker/library/rabbitmq:3-management"
      dynamodbLocal = local.use_private_images ? "${var.image_registry}/retail-store-sample-dynamodb-local:1.25.1" : "public.ecr.aws/aws-dynamodb-local/aws-dynamodb-local:1.25.1"
      redis         = local.use_private_images ? "${var.image_registry}/retail-store-sample-redis:6.0-alpine" : "redis:6.0-alpine"
    }
    ingress = {
      host              = local.app_fqdn
      certificateArn    = aws_acm_certificate.ui.arn
      cognitoAuthConfig = local.cognito_auth_config
    }
    ui = {
      authLogoutUrl = local.cognito_logout_url
    }
  }
}

resource "kubernetes_namespace_v1" "argocd" {
  metadata {
    name = local.argocd_namespace
  }

  depends_on = [
    aws_cloudformation_stack.autoscaling_group,
    kubernetes_config_map.aws_auth,
  ]
}

# Redis password, created here instead of by the chart's redis-secret-init
# hook Job (that Job would be a 4th pod in the argocd namespace).
resource "kubernetes_secret_v1" "argocd_redis" {
  metadata {
    name      = "argocd-redis"
    namespace = kubernetes_namespace_v1.argocd.metadata[0].name
  }

  data = {
    auth = substr(sha256("argocd-redis:${tls_private_key.key_pair.private_key_pem}"), 0, 32)
  }
}

resource "helm_release" "argocd" {
  name       = "argocd"
  repository = "https://argoproj.github.io/argo-helm"
  chart      = "argo-cd"
  version    = var.argocd_chart_version
  namespace  = kubernetes_namespace_v1.argocd.metadata[0].name
  wait       = true
  timeout    = 900

  # Lab limits: 3 pods per namespace, 256m CPU / 512Mi per pod.
  # Runs only application-controller + repo-server + redis: no Dex (SSO),
  # notifications, ApplicationSet controller, redis init Job or (by default)
  # argocd-server. Limits total 350m / 704Mi.
  values = [yamlencode({
    dex             = { enabled = false }
    notifications   = { enabled = false }
    applicationSet  = { replicas = 0 }
    redisSecretInit = { enabled = false }
    server = {
      replicas = var.argocd_server_enabled ? 1 : 0
      resources = {
        requests = { cpu = "25m", memory = "64Mi" }
        limits   = { cpu = "100m", memory = "128Mi" }
      }
    }
    controller = {
      resources = {
        requests = { cpu = "100m", memory = "256Mi" }
        limits   = { cpu = "200m", memory = "384Mi" }
      }
    }
    repoServer = {
      # No surge: a rolling update would be a 4th pod in the namespace
      deploymentStrategy = { type = "Recreate" }
      resources = {
        requests = { cpu = "50m", memory = "128Mi" }
        limits   = { cpu = "100m", memory = "256Mi" }
      }
    }
    redis = {
      resources = {
        requests = { cpu = "25m", memory = "32Mi" }
        limits   = { cpu = "50m", memory = "64Mi" }
      }
    }
    configs = {
      cm = {
        # Annotation tracking: the label method would overwrite the
        # app.kubernetes.io/instance labels the retail-store services use.
        "application.resourceTrackingMethod" = "annotation"
        "timeout.reconciliation"             = "120s"
      }
      params = {
        # TLS is not terminated by Argo CD (UI reached via port-forward)
        "server.insecure" = true
      }
    }
  })]

  depends_on = [
    aws_cloudformation_stack.autoscaling_group,
    kubernetes_config_map.aws_auth,
    aws_eks_addon.vpc_cni,
    null_resource.alb_webhook_ready,
    kubernetes_secret_v1.argocd_redis,
  ]
}

# Namespaces for the app (created here so the OpenAI secret can be placed in
# retail-ui before Argo CD syncs; Argo CD never prunes them).
resource "kubernetes_namespace_v1" "retail_store" {
  for_each = local.retail_store_namespaces

  metadata {
    name = each.value
    labels = {
      "app.kubernetes.io/part-of" = "retail-store"
    }
  }

  depends_on = [
    aws_cloudformation_stack.autoscaling_group,
    kubernetes_config_map.aws_auth,
  ]
}

# Credentials for a private Git repo (only when a token is supplied)
resource "kubernetes_secret_v1" "argocd_repo" {
  count = var.gitops_repo_token != "" ? 1 : 0

  metadata {
    name      = "retail-store-repo"
    namespace = local.argocd_namespace
    labels = {
      "argocd.argoproj.io/secret-type" = "repository"
    }
  }

  data = {
    type     = "git"
    url      = var.gitops_repo_url
    username = var.gitops_repo_username
    password = var.gitops_repo_token
  }

  depends_on = [helm_release.argocd]
}

resource "helm_release" "argocd_apps" {
  name      = "argocd-apps"
  chart     = "argocd-apps"
  version   = var.argocd_apps_chart_version
  namespace = local.argocd_namespace

  repository = "https://argoproj.github.io/argo-helm"

  values = [yamlencode({
    # Argo CD's built-in "default" project is created by argocd-server on
    # startup; that pod is off (3-pods-per-namespace limit), so the app gets
    # its own project, limited to this repo and the retail-* namespaces.
    projects = {
      (local.retail_store_app) = {
        namespace   = local.argocd_namespace
        description = "retail-store sample app"
        sourceRepos = [var.gitops_repo_url]
        destinations = [for ns in values(local.retail_store_namespaces) : {
          server    = "https://kubernetes.default.svc"
          namespace = ns
        }]
        # The chart has no cluster-scoped objects (Terraform owns the namespaces)
        clusterResourceWhitelist   = []
        namespaceResourceWhitelist = [{ group = "*", kind = "*" }]
      }
    }
    applications = {
      (local.retail_store_app) = {
        namespace = local.argocd_namespace
        project   = local.retail_store_app
        # Deleting the Application deletes its resources (incl. the ALB ingress)
        finalizers = ["resources-finalizer.argocd.argoproj.io"]
        source = {
          repoURL        = var.gitops_repo_url
          targetRevision = var.gitops_target_revision
          path           = var.gitops_chart_path
          helm = {
            releaseName  = local.retail_store_app
            valuesObject = local.retail_store_values
          }
        }
        destination = {
          server    = "https://kubernetes.default.svc"
          namespace = local.retail_store_namespaces.ui
        }
        syncPolicy = {
          automated = {
            prune    = true
            selfHeal = true
          }
          syncOptions = ["RespectIgnoreDifferences=true"]
          retry = {
            limit = 10
            backoff = {
              duration    = "10s"
              factor      = 2
              maxDuration = "3m"
            }
          }
        }
        # HPAs own the replica count of catalog and ui
        ignoreDifferences = [{
          group        = "apps"
          kind         = "Deployment"
          jsonPointers = ["/spec/replicas"]
        }]
      }
    }
  })]

  lifecycle {
    precondition {
      condition     = var.gitops_repo_url != ""
      error_message = "gitops_repo_url must be set (the pipeline passes the GitHub repository URL)."
    }
  }

  depends_on = [
    helm_release.argocd,
    helm_release.alb_controller,
    kubernetes_secret_v1.argocd_repo,
    kubernetes_namespace_v1.retail_store,
    null_resource.retail_store_openai_secret,
  ]
}

# Waits for Argo CD to sync the app and the ALB controller to publish the
# ingress hostname (needed by the ui_alb_dns_name output and DuckDNS step).
# On destroy, deletes the Application first and waits, so Argo CD removes the
# app and its ALB while Argo CD and the ALB controller are still running.
resource "null_resource" "retail_store_sync" {
  triggers = {
    cluster_name = aws_eks_cluster.demo_eks.name
    region       = var.aws_region
    namespace    = local.argocd_namespace
    app          = local.retail_store_app
    ui_namespace = local.retail_store_namespaces.ui
    values_hash  = sha256(jsonencode(helm_release.argocd_apps.values))
  }

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      aws eks update-kubeconfig --region ${self.triggers.region} --name ${self.triggers.cluster_name}
      NS=${self.triggers.namespace}
      APP=${self.triggers.app}

      kubectl -n "$NS" annotate application "$APP" argocd.argoproj.io/refresh=hard --overwrite

      for i in $(seq 1 90); do
        sync=$(kubectl -n "$NS" get application "$APP" -o jsonpath='{.status.sync.status}' 2>/dev/null || true)
        health=$(kubectl -n "$NS" get application "$APP" -o jsonpath='{.status.health.status}' 2>/dev/null || true)
        host=$(kubectl get ingress ui -n ${self.triggers.ui_namespace} -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
        echo "Argo CD $APP: sync=$${sync:-?} health=$${health:-?} alb=$${host:-pending} ($i/90)"
        if [ "$sync" = "Synced" ] && [ -n "$host" ]; then
          echo "ALB hostname: $host"
          exit 0
        fi
        sleep 10
      done

      echo "Argo CD application $APP did not sync within 15 minutes:"
      kubectl -n "$NS" get application "$APP" -o jsonpath='{range .status.conditions[*]}{.type}: {.message}{"\n"}{end}' || true
      kubectl -n "$NS" get application "$APP" -o jsonpath='{.status.operationState.message}{"\n"}' || true
      exit 1
    EOT
  }

  provisioner "local-exec" {
    when    = destroy
    command = <<-EOT
      aws eks update-kubeconfig --region ${self.triggers.region} --name ${self.triggers.cluster_name} || exit 0
      kubectl -n ${self.triggers.namespace} delete application ${self.triggers.app} \
        --ignore-not-found=true --wait=true --timeout=15m || true
    EOT
  }

  depends_on = [helm_release.argocd_apps]
}

output "argocd_namespace" {
  value       = local.argocd_namespace
  description = "Namespace Argo CD is installed in"
}

output "argocd_access_commands" {
  value = {
    ui             = var.argocd_server_enabled ? "kubectl port-forward svc/argocd-server -n ${local.argocd_namespace} 8080:80" : "argocd admin dashboard -n ${local.argocd_namespace}"
    admin_password = var.argocd_server_enabled ? "kubectl -n ${local.argocd_namespace} get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d" : "not needed: argocd admin dashboard uses your kubeconfig"
    app_status     = "kubectl -n ${local.argocd_namespace} get application ${local.retail_store_app}"
  }
  description = "How to reach the Argo CD UI (user: admin) and check the app"
}
