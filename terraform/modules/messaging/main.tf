data "google_project" "this" {
  project_id = var.project_id
}

data "google_storage_project_service_account" "gcs" {
  project = var.project_id
}

locals {
  pubsub_agent = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

# ---------------------------------------------------------------------------
# GCS OBJECT_FINALIZE -> notification topic
# ---------------------------------------------------------------------------
resource "google_pubsub_topic" "raw_events" {
  name                       = "${var.name_prefix}-raw-object-events"
  project                    = var.project_id
  labels                     = var.labels
  kms_key_name               = var.kms_key_name
  message_retention_duration = var.topic_message_retention
}

resource "google_pubsub_topic_iam_member" "gcs_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.raw_events.id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${data.google_storage_project_service_account.gcs.email_address}"
}

resource "google_storage_notification" "raw_finalize" {
  bucket             = var.raw_bucket_name
  topic              = google_pubsub_topic.raw_events.id
  payload_format     = "JSON_API_V1"
  event_types        = ["OBJECT_FINALIZE"]
  object_name_prefix = var.raw_object_prefix

  # The notification is validated at creation time by publishing a test
  # message, so the publisher grant must exist first.
  depends_on = [google_pubsub_topic_iam_member.gcs_publisher]
}

# ---------------------------------------------------------------------------
# Dead-letter topic + pull subscription for inspection / replay
# ---------------------------------------------------------------------------
resource "google_pubsub_topic" "dead_letter" {
  count = var.create_push_subscription ? 1 : 0

  name                       = "${var.name_prefix}-raw-object-events-dlq"
  project                    = var.project_id
  labels                     = var.labels
  kms_key_name               = var.kms_key_name
  message_retention_duration = var.dead_letter_retention
}

resource "google_pubsub_subscription" "dead_letter" {
  count = var.create_push_subscription ? 1 : 0

  name                       = "${var.name_prefix}-raw-object-events-dlq-sub"
  project                    = var.project_id
  topic                      = google_pubsub_topic.dead_letter[0].id
  labels                     = var.labels
  ack_deadline_seconds       = 60
  message_retention_duration = var.dead_letter_retention
  retain_acked_messages      = false

  expiration_policy {
    ttl = "" # never expire, even if nobody pulls for 31 days
  }
}

# Pub/Sub forwards dead letters as its own service agent.
resource "google_pubsub_topic_iam_member" "dlq_publisher" {
  count = var.create_push_subscription ? 1 : 0

  project = var.project_id
  topic   = google_pubsub_topic.dead_letter[0].id
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_agent
}

# ---------------------------------------------------------------------------
# Push subscription -> processor, exponential backoff, dead-lettering
# ---------------------------------------------------------------------------
resource "google_pubsub_subscription" "processor" {
  count = var.create_push_subscription ? 1 : 0

  name                       = "${var.name_prefix}-raw-object-events-processor"
  project                    = var.project_id
  topic                      = google_pubsub_topic.raw_events.id
  labels                     = var.labels
  ack_deadline_seconds       = var.ack_deadline_seconds
  message_retention_duration = var.subscription_message_retention
  enable_message_ordering    = false

  push_config {
    push_endpoint = var.push_endpoint

    oidc_token {
      service_account_email = var.push_service_account_email
      audience              = var.push_endpoint
    }
  }

  retry_policy {
    minimum_backoff = var.minimum_backoff
    maximum_backoff = var.maximum_backoff
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter[0].id
    max_delivery_attempts = var.max_delivery_attempts
  }

  expiration_policy {
    ttl = ""
  }

  lifecycle {
    precondition {
      condition     = var.push_endpoint != null && var.push_service_account_email != null
      error_message = "push_endpoint and push_service_account_email are required when create_push_subscription is true."
    }
  }

  depends_on = [google_pubsub_topic_iam_member.dlq_publisher]
}

# Required so the service agent can ack messages it forwards to the DLQ.
resource "google_pubsub_subscription_iam_member" "processor_dlq_subscriber" {
  count = var.create_push_subscription ? 1 : 0

  project      = var.project_id
  subscription = google_pubsub_subscription.processor[0].id
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}
