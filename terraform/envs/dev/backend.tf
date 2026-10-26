# Remote state. Create the bucket once (versioned, UBLA, public access
# prevention) outside this configuration, then uncomment and run
# `terraform init -migrate-state`.
#
# terraform {
#   backend "gcs" {
#     bucket = "my-project-tfstate"
#     prefix = "gcp-event-pipeline/dev"
#   }
# }
