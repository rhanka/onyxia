variable "project_id" {
  type        = string
  description = "Google Cloud project ID."
}

variable "region" {
  type        = string
  description = "GCP region used by the GKE cluster."
  default     = "us-central1"
}

variable "namespace" {
  type        = string
  description = "Kubernetes namespace where the STS bridge runs."
  default     = "onyxia"
}

variable "public_hostname" {
  type        = string
  description = "Public Onyxia hostname allowed by browser CORS."
}

variable "data_bucket_name" {
  type        = string
  description = "GCS bucket backing Onyxia user files."
}

variable "polaris_warehouse_bucket_name" {
  type        = string
  description = "GCS bucket backing the Polaris Iceberg warehouse."
}

variable "bucket_location" {
  type        = string
  description = "GCS bucket location."
  default     = "US-CENTRAL1"
}

variable "bridge_image" {
  type        = string
  description = "Container image for the GCS STS bridge."
}

variable "bridge_hostname" {
  type        = string
  description = "Public hostname for the STS bridge. Leave empty to skip Ingress."
  default     = ""
}

variable "oidc_issuer" {
  type        = string
  description = "OIDC issuer used to validate Onyxia web identity tokens."
}

variable "oidc_audience" {
  type        = string
  description = "OIDC audience expected by the STS bridge."
  default     = "onyxia"
}

variable "ingress_class_name" {
  type        = string
  description = "IngressClass served by the shared ingress-nginx LoadBalancer."
  default     = "nginx"
}

variable "cert_manager_cluster_issuer_name" {
  type        = string
  description = "cert-manager ClusterIssuer used for the bridge TLS certificate."
  default     = "letsencrypt-prod"
}

variable "polaris_namespace" {
  type        = string
  description = "Namespace of the Polaris KSA that may impersonate the warehouse GSA."
  default     = "polaris"
}

variable "polaris_ksa_name" {
  type        = string
  description = "Name of the Polaris KSA that may impersonate the warehouse GSA."
  default     = "polaris"
}
