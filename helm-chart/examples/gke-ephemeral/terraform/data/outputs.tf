output "data_bucket_name" {
  value       = google_storage_bucket.data.name
  description = "GCS bucket backing Onyxia user files."
}

output "bridge_sa_email" {
  value       = google_service_account.bridge.email
  description = "GCP service account impersonated by the STS bridge KSA."
}

output "sts_bridge_url" {
  value       = local.bridge_url
  description = "Public STS bridge URL used by Onyxia's browser S3 client."
}

output "polaris_warehouse_bucket_name" {
  value       = google_storage_bucket.polaris_warehouse.name
  description = "GCS bucket backing the Polaris Iceberg warehouse."
}

output "polaris_warehouse_gsa_email" {
  value       = google_service_account.polaris_warehouse.email
  description = "GCP service account that Polaris can impersonate through Workload Identity."
}
