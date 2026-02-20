output "api_gateway_url" {
  description = "Base URL of the deployed API Gateway — use in submission.json"
  value       = "https://${google_api_gateway_gateway.image_gateway.default_hostname}"
}

output "upload_endpoint" {
  description = "Full endpoint for image uploads"
  value       = "https://${google_api_gateway_gateway.image_gateway.default_hostname}/v1/images/upload"
}

output "api_key_value" {
  description = "API key for x-api-key header — use in submission.json"
  value       = random_password.api_key.result
  sensitive   = true
}

output "api_key_secret_id" {
  description = "Secret Manager secret ID holding the API key"
  value       = google_secret_manager_secret.api_key.secret_id
}

output "uploads_bucket" {
  description = "GCS bucket for raw uploads"
  value       = google_storage_bucket.uploads.name
}

output "processed_bucket" {
  description = "GCS bucket for grayscale processed images"
  value       = google_storage_bucket.processed.name
}

output "service_account_email" {
  description = "Cloud Functions service account email"
  value       = google_service_account.functions_sa.email
}

output "upload_function_url" {
  description = "Direct URL of the upload-image Cloud Function"
  value       = google_cloudfunctions2_function.upload_image.service_config[0].uri
}
