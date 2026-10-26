provider "google" {
  project = var.project_id
  region  = var.region

  # Billing Budgets API calls are attributed to this project's quota.
  user_project_override = true
  billing_project       = var.project_id

  default_labels = {
    app         = "gcp-event-pipeline"
    environment = var.environment
    managed_by  = "terraform"
  }
}
