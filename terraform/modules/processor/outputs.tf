output "function_name" {
  description = "Name of the Cloud Function."
  value       = google_cloudfunctions2_function.processor.name
}

output "function_uri" {
  description = "HTTPS URI of the underlying Cloud Run service (push endpoint)."
  value       = google_cloudfunctions2_function.processor.service_config[0].uri
}

output "service_name" {
  description = "Cloud Run service name backing the function (used in log/metric filters)."
  value       = local.function_name
}

output "runtime_service_account_email" {
  description = "Runtime service account of the function."
  value       = google_service_account.runtime.email
}

output "invoker_service_account_email" {
  description = "Service account used by Pub/Sub push / Eventarc to invoke the function."
  value       = google_service_account.invoker.email
}

output "source_archive_sha256" {
  description = "SHA-256 of the deployed source archive."
  value       = data.archive_file.source.output_sha256
}
