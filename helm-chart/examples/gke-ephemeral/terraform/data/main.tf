terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.30"
    }
  }
}

locals {
  bridge_name        = "onyxia-sts-bridge"
  bridge_origin      = "https://${var.public_hostname}"
  bridge_url         = var.bridge_hostname == "" ? "" : "https://${var.bridge_hostname}/"
  polaris_gsa_id     = "polaris-warehouse"
  polaris_gsa_member = "serviceAccount:${var.project_id}.svc.id.goog[${var.polaris_namespace}/${var.polaris_ksa_name}]"
}

resource "google_storage_bucket" "data" {
  name                        = var.data_bucket_name
  project                     = var.project_id
  location                    = var.bucket_location
  uniform_bucket_level_access = true
  force_destroy               = true

  cors {
    origin          = [local.bridge_origin]
    method          = ["GET", "HEAD", "POST", "PUT", "DELETE"]
    response_header = ["*"]
    max_age_seconds = 3600
  }

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 30
    }
  }
}

resource "google_storage_bucket" "polaris_warehouse" {
  name                        = var.polaris_warehouse_bucket_name
  project                     = var.project_id
  location                    = var.bucket_location
  uniform_bucket_level_access = true
  force_destroy               = true
}

resource "google_service_account" "bridge" {
  account_id   = local.bridge_name
  display_name = "Onyxia GCS STS bridge"
  project      = var.project_id
}

resource "google_project_iam_member" "bridge_storage_admin" {
  project = var.project_id
  role    = "roles/storage.admin"
  member  = "serviceAccount:${google_service_account.bridge.email}"
}

resource "google_project_iam_member" "bridge_hmac_key_admin" {
  project = var.project_id
  role    = "roles/storage.hmacKeyAdmin"
  member  = "serviceAccount:${google_service_account.bridge.email}"
}

resource "google_project_iam_member" "bridge_sa_admin" {
  project = var.project_id
  role    = "roles/iam.serviceAccountAdmin"
  member  = "serviceAccount:${google_service_account.bridge.email}"
}

resource "kubernetes_service_account_v1" "bridge" {
  metadata {
    name      = local.bridge_name
    namespace = var.namespace
    annotations = {
      "iam.gke.io/gcp-service-account" = google_service_account.bridge.email
    }
    labels = {
      "app.kubernetes.io/name"      = local.bridge_name
      "app.kubernetes.io/component" = "gcs-sts"
    }
  }
}

resource "google_service_account_iam_member" "bridge_workload_identity" {
  service_account_id = google_service_account.bridge.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${var.project_id}.svc.id.goog[${var.namespace}/${local.bridge_name}]"
}

resource "kubernetes_role_v1" "bridge_secrets" {
  metadata {
    name      = "${local.bridge_name}-secrets"
    namespace = var.namespace
  }

  rule {
    api_groups = [""]
    resources  = ["secrets"]
    verbs      = ["get", "list", "create", "update", "patch"]
  }
}

resource "kubernetes_role_binding_v1" "bridge_secrets" {
  metadata {
    name      = "${local.bridge_name}-secrets"
    namespace = var.namespace
  }

  role_ref {
    api_group = "rbac.authorization.k8s.io"
    kind      = "Role"
    name      = kubernetes_role_v1.bridge_secrets.metadata[0].name
  }

  subject {
    kind      = "ServiceAccount"
    name      = kubernetes_service_account_v1.bridge.metadata[0].name
    namespace = var.namespace
  }
}

resource "kubernetes_deployment_v1" "bridge" {
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      spec[0].template[0].spec[0].container[0].security_context,
      spec[0].template[0].spec[0].security_context,
      spec[0].template[0].spec[0].toleration,
    ]
  }

  metadata {
    name      = local.bridge_name
    namespace = var.namespace
    labels = {
      "app.kubernetes.io/name"      = local.bridge_name
      "app.kubernetes.io/component" = "gcs-sts"
    }
  }

  spec {
    replicas = 1
    selector {
      match_labels = {
        "app.kubernetes.io/name" = local.bridge_name
      }
    }
    template {
      metadata {
        labels = {
          "app.kubernetes.io/name"      = local.bridge_name
          "app.kubernetes.io/component" = "gcs-sts"
        }
      }
      spec {
        service_account_name = kubernetes_service_account_v1.bridge.metadata[0].name
        container {
          name  = "bridge"
          image = var.bridge_image

          port {
            name           = "http"
            container_port = 8080
          }

          env {
            name  = "PROJECT_ID"
            value = var.project_id
          }
          env {
            name  = "BUCKET"
            value = google_storage_bucket.data.name
          }
          env {
            name  = "OIDC_ISSUER"
            value = var.oidc_issuer
          }
          env {
            name  = "OIDC_AUDIENCE"
            value = var.oidc_audience
          }
          env {
            name  = "K8S_NAMESPACE"
            value = var.namespace
          }
          env {
            name  = "BRIDGE_SA_EMAIL"
            value = google_service_account.bridge.email
          }
          env {
            name  = "CORS_ALLOW_ORIGINS"
            value = local.bridge_origin
          }
          env {
            name  = "DEFAULT_DURATION_SECONDS"
            value = "86400"
          }

          resources {
            requests = {
              cpu                 = "50m"
              memory              = "64Mi"
              "ephemeral-storage" = "1Gi"
            }
            limits = {
              memory              = "256Mi"
              "ephemeral-storage" = "1Gi"
            }
          }

          readiness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            period_seconds = 5
          }
          liveness_probe {
            http_get {
              path = "/healthz"
              port = "http"
            }
            period_seconds = 30
          }
        }
      }
    }
  }
}

resource "kubernetes_service_v1" "bridge" {
  metadata {
    name      = local.bridge_name
    namespace = var.namespace
  }

  spec {
    selector = {
      "app.kubernetes.io/name" = local.bridge_name
    }
    port {
      name        = "http"
      port        = 80
      target_port = "http"
    }
  }
}

resource "kubernetes_manifest" "bridge_ingress" {
  count = var.bridge_hostname == "" ? 0 : 1

  manifest = {
    apiVersion = "networking.k8s.io/v1"
    kind       = "Ingress"
    metadata = {
      name      = local.bridge_name
      namespace = var.namespace
      annotations = {
        "cert-manager.io/cluster-issuer"                 = var.cert_manager_cluster_issuer_name
        "nginx.ingress.kubernetes.io/ssl-redirect"       = "true"
        "nginx.ingress.kubernetes.io/enable-global-auth" = "false"
        "nginx.ingress.kubernetes.io/enable-cors"        = "true"
        "nginx.ingress.kubernetes.io/cors-allow-origin"  = local.bridge_origin
        "nginx.ingress.kubernetes.io/cors-allow-methods" = "GET, POST, OPTIONS"
        "nginx.ingress.kubernetes.io/cors-allow-headers" = "Authorization, Content-Type, Accept, X-Amz-Date, X-Amz-Content-Sha256, X-Amz-Security-Token, X-Amz-User-Agent, Amz-Sdk-Invocation-Id, Amz-Sdk-Request"
      }
      labels = {
        "app.kubernetes.io/name"      = local.bridge_name
        "app.kubernetes.io/component" = "gcs-sts"
      }
    }
    spec = {
      ingressClassName = var.ingress_class_name
      tls = [{
        hosts      = [var.bridge_hostname]
        secretName = "${local.bridge_name}-tls"
      }]
      rules = [{
        host = var.bridge_hostname
        http = {
          paths = [{
            path     = "/"
            pathType = "Prefix"
            backend = {
              service = {
                name = kubernetes_service_v1.bridge.metadata[0].name
                port = { number = 80 }
              }
            }
          }]
        }
      }]
    }
  }
}

resource "kubernetes_cron_job_v1" "rotate" {
  lifecycle {
    ignore_changes = [
      metadata[0].annotations,
      spec[0].job_template[0].spec[0].template[0].spec[0].container[0].security_context,
      spec[0].job_template[0].spec[0].template[0].spec[0].security_context,
      spec[0].job_template[0].spec[0].template[0].spec[0].toleration,
    ]
  }

  metadata {
    name      = "${local.bridge_name}-rotate"
    namespace = var.namespace
  }

  spec {
    schedule = "0 3 * * *"
    job_template {
      metadata {}
      spec {
        template {
          metadata {}
          spec {
            service_account_name = kubernetes_service_account_v1.bridge.metadata[0].name
            restart_policy       = "OnFailure"
            container {
              name    = "rotate"
              image   = var.bridge_image
              command = ["python", "-m", "app.rotate"]
              env {
                name  = "PROJECT_ID"
                value = var.project_id
              }
              resources {
                requests = {
                  cpu                 = "50m"
                  memory              = "64Mi"
                  "ephemeral-storage" = "1Gi"
                }
                limits = {
                  memory              = "128Mi"
                  "ephemeral-storage" = "1Gi"
                }
              }
            }
          }
        }
      }
    }
  }
}

resource "google_service_account" "polaris_warehouse" {
  account_id   = local.polaris_gsa_id
  display_name = "Polaris Iceberg warehouse"
  project      = var.project_id
}

resource "google_storage_bucket_iam_member" "polaris_warehouse_object_admin" {
  bucket = google_storage_bucket.polaris_warehouse.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.polaris_warehouse.email}"
}

resource "google_service_account_iam_member" "polaris_workload_identity" {
  service_account_id = google_service_account.polaris_warehouse.name
  role               = "roles/iam.workloadIdentityUser"
  member             = local.polaris_gsa_member
}
