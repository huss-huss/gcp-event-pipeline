output "raw_bucket_name" {
  description = "Name of the raw (landing) bucket."
  value       = google_storage_bucket.raw.name
}

output "curated_bucket_name" {
  description = "Name of the curated bucket (curated and quarantine prefixes)."
  value       = google_storage_bucket.curated.name
}

output "raw_bucket_url" {
  description = "gs:// URL of the raw bucket."
  value       = google_storage_bucket.raw.url
}

output "curated_bucket_url" {
  description = "gs:// URL of the curated bucket."
  value       = google_storage_bucket.curated.url
}
