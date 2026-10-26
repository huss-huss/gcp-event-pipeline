output "topic_id" {
  description = "Fully qualified ID of the raw object notification topic."
  value       = google_pubsub_topic.raw_events.id
}

output "topic_name" {
  description = "Short name of the raw object notification topic."
  value       = google_pubsub_topic.raw_events.name
}

output "processor_subscription_name" {
  description = "Push subscription that feeds the processor (null when Eventarc is used)."
  value       = one(google_pubsub_subscription.processor[*].name)
}

output "dead_letter_topic_id" {
  description = "Dead-letter topic ID (null when Eventarc is used)."
  value       = one(google_pubsub_topic.dead_letter[*].id)
}

output "dead_letter_subscription_name" {
  description = "Pull subscription on the dead-letter topic used for inspection and replay (null when Eventarc is used)."
  value       = one(google_pubsub_subscription.dead_letter[*].name)
}

output "notification_id" {
  description = "ID of the bucket notification configuration."
  value       = google_storage_notification.raw_finalize.notification_id
}
