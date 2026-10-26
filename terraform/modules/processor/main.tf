data "google_project" "this" {
  project_id = var.project_id
}

locals {
  function_name = "${var.name_prefix}-processor"
  pubsub_agent  = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
  use_eventarc  = var.delivery_mode == "eventarc"
}

# ---------------------------------------------------------------------------
# Identities
# ---------------------------------------------------------------------------
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-fn-run"
  display_name = "Event processor runtime"
  description  = "Runtime identity of ${local.function_name}: read raw, create curated objects."
}

resource "google_service_account" "invoker" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-fn-invoke"
  display_name = "Event processor invoker"
  description  = "Identity Pub/Sub push (or Eventarc) uses to call ${local.function_name}."
}

resource "google_service_account" "build" {
  project      = var.project_id
  account_id   = "${var.name_prefix}-fn-build"
  display_name = "Event processor build"
  description  = "Cloud Build identity used to build ${local.function_name}."
}

# Runtime: bucket-scoped, no project-level roles at all.
resource "google_storage_bucket_iam_member" "runtime_raw_reader" {
  bucket = var.raw_bucket_name
  role   = "roles/storage.objectViewer"
  member = google_service_account.runtime.member
}

resource "google_storage_bucket_iam_member" "runtime_curated_creator" {
  bucket = var.curated_bucket_name
  role   = "roles/storage.objectCreator"
  member = google_service_account.runtime.member
}

# Invoker: may call this one service only.
resource "google_cloud_run_v2_service_iam_member" "invoker" {
  project  = var.project_id
  location = var.region
  name     = google_cloudfunctions2_function.processor.service_config[0].service
  role     = "roles/run.invoker"
  member   = google_service_account.invoker.member
}

# Eventarc requires the trigger identity to hold eventReceiver (project-level role by design).
resource "google_project_iam_member" "invoker_event_receiver" {
  count   = local.use_eventarc ? 1 : 0
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = google_service_account.invoker.member
}

# Pub/Sub mints the OIDC token for push requests as the invoker SA.
resource "google_service_account_iam_member" "pubsub_token_creator" {
  service_account_id = google_service_account.invoker.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = local.pubsub_agent
}

# Build: logs, push the image to the gcf-artifacts repository, read the source archive.
resource "google_project_iam_member" "build" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/artifactregistry.writer",
  ])
  project = var.project_id
  role    = each.value
  member  = google_service_account.build.member
}

resource "google_storage_bucket_iam_member" "build_source_reader" {
  bucket = google_storage_bucket.source.name
  role   = "roles/storage.objectViewer"
  member = google_service_account.build.member
}

# ---------------------------------------------------------------------------
# Source packaging
# ---------------------------------------------------------------------------
data "archive_file" "source" {
  type        = "zip"
  source_dir  = var.source_dir
  output_path = "${path.root}/.build/${local.function_name}.zip"
  excludes = [
    "tests",
    ".pytest_cache",
    ".ruff_cache",
    "__pycache__",
    "pipeline/__pycache__",
    "pyproject.toml",
    "requirements-dev.txt",
    ".gcloudignore",
  ]
}

resource "google_storage_bucket" "source" {
  #checkov:skip=CKV_GCP_62:Build artefact bucket; access is covered by Cloud Audit Logs.
  name                        = "${var.project_id}-${var.name_prefix}-fn-source"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = true # contains only reproducible build inputs
  labels                      = var.labels

  versioning {
    enabled = true
  }

  lifecycle_rule {
    condition {
      age = var.source_object_retention_days
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 7
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }
}

# Content-addressed object name: any code change produces a new object and
# therefore a new function revision; unchanged code is a no-op plan.
resource "google_storage_bucket_object" "source" {
  name   = "processor/${data.archive_file.source.output_sha256}.zip"
  bucket = google_storage_bucket.source.name
  source = data.archive_file.source.output_path
}

# ---------------------------------------------------------------------------
# Function (Cloud Functions 2nd gen = Cloud Run service + Cloud Build)
# ---------------------------------------------------------------------------
resource "google_cloudfunctions2_function" "processor" {
  name        = local.function_name
  project     = var.project_id
  location    = var.region
  description = "Validates raw order events and writes curated JSONL."
  labels      = var.labels

  build_config {
    runtime         = var.runtime
    entry_point     = var.entry_point
    service_account = google_service_account.build.id

    source {
      storage_source {
        bucket = google_storage_bucket.source.name
        object = google_storage_bucket_object.source.name
      }
    }
  }

  service_config {
    available_memory                 = var.available_memory
    available_cpu                    = var.available_cpu
    timeout_seconds                  = var.timeout_seconds
    min_instance_count               = var.min_instance_count
    max_instance_count               = var.max_instance_count
    max_instance_request_concurrency = var.max_instance_request_concurrency
    ingress_settings                 = "ALLOW_INTERNAL_ONLY" # Pub/Sub push and Eventarc count as internal
    all_traffic_on_latest_revision   = true
    service_account_email            = google_service_account.runtime.email

    environment_variables = {
      CURATED_BUCKET    = var.curated_bucket_name
      RAW_PREFIX        = var.raw_prefix
      CURATED_PREFIX    = var.curated_prefix
      QUARANTINE_PREFIX = var.quarantine_prefix
    }
  }

  dynamic "event_trigger" {
    for_each = local.use_eventarc ? [1] : []
    content {
      trigger_region        = var.region
      event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
      pubsub_topic          = var.notification_topic_id
      retry_policy          = "RETRY_POLICY_RETRY"
      service_account_email = google_service_account.invoker.email
    }
  }

  depends_on = [
    google_project_iam_member.build,
    google_storage_bucket_iam_member.build_source_reader,
    google_project_iam_member.invoker_event_receiver,
    google_service_account_iam_member.pubsub_token_creator,
  ]
}
