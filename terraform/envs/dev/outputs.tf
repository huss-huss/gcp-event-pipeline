output "raw_bucket" {
  description = "Upload JSONL files to gs://<raw_bucket>/<raw_object_prefix>."
  value       = module.storage.raw_bucket_name
}

output "curated_bucket" {
  description = "Curated output and quarantine bucket."
  value       = module.storage.curated_bucket_name
}

output "notification_topic" {
  description = "Topic receiving raw bucket OBJECT_FINALIZE notifications."
  value       = module.messaging.topic_id
}

output "processor_subscription" {
  description = "Push subscription feeding the function (null in eventarc mode)."
  value       = module.messaging.processor_subscription_name
}

output "dead_letter_subscription" {
  description = "Pull subscription holding dead-lettered events (null in eventarc mode)."
  value       = module.messaging.dead_letter_subscription_name
}

output "function_name" {
  description = "Processor function name."
  value       = module.processor.function_name
}

output "runtime_service_account" {
  description = "Runtime identity of the processor."
  value       = module.processor.runtime_service_account_email
}

output "alert_policy_ids" {
  description = "Created alert policies."
  value       = module.observability.alert_policy_ids
}
