locals {
  name_prefix = "${var.name}-${var.environment}"
  use_push    = var.delivery_mode == "pubsub_push"

  services = toset([
    "artifactregistry.googleapis.com",
    "billingbudgets.googleapis.com",
    "cloudbuild.googleapis.com",
    "cloudfunctions.googleapis.com",
    "eventarc.googleapis.com",
    "iam.googleapis.com",
    "logging.googleapis.com",
    "monitoring.googleapis.com",
    "pubsub.googleapis.com",
    "run.googleapis.com",
    "storage.googleapis.com",
  ])
}

resource "google_project_service" "enabled" {
  for_each = local.services

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}

module "storage" {
  source = "../../modules/storage"

  project_id        = var.project_id
  name_prefix       = local.name_prefix
  location          = var.region
  kms_key_name      = var.kms_key_name
  force_destroy     = var.force_destroy_buckets
  quarantine_prefix = "quarantine/"

  depends_on = [google_project_service.enabled]
}

module "messaging" {
  source = "../../modules/messaging"

  project_id        = var.project_id
  name_prefix       = local.name_prefix
  raw_bucket_name   = module.storage.raw_bucket_name
  raw_object_prefix = var.raw_object_prefix

  create_push_subscription   = local.use_push
  push_endpoint              = local.use_push ? module.processor.function_uri : null
  push_service_account_email = local.use_push ? module.processor.invoker_service_account_email : null
  ack_deadline_seconds       = var.function_timeout_seconds
  max_delivery_attempts      = var.max_delivery_attempts

  depends_on = [google_project_service.enabled]
}

module "processor" {
  source = "../../modules/processor"

  project_id            = var.project_id
  region                = var.region
  name_prefix           = local.name_prefix
  source_dir            = "${path.module}/../../../processor"
  raw_bucket_name       = module.storage.raw_bucket_name
  curated_bucket_name   = module.storage.curated_bucket_name
  raw_prefix            = var.raw_object_prefix
  notification_topic_id = module.messaging.topic_id
  delivery_mode         = var.delivery_mode
  timeout_seconds       = var.function_timeout_seconds
  available_memory      = var.function_memory
  min_instance_count    = var.min_instances
  max_instance_count    = var.max_instances

  depends_on = [google_project_service.enabled]
}

module "observability" {
  source = "../../modules/observability"

  project_id                    = var.project_id
  name_prefix                   = local.name_prefix
  service_name                  = module.processor.service_name
  enable_subscription_alerts    = local.use_push
  processor_subscription_name   = module.messaging.processor_subscription_name
  dead_letter_subscription_name = module.messaging.dead_letter_subscription_name
  alert_emails                  = var.alert_emails
  billing_account               = var.billing_account
  budget_amount                 = var.monthly_budget

  depends_on = [google_project_service.enabled]
}
