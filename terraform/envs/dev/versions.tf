terraform {
  # 1.7+ is required for `terraform test` mock providers used in CI.
  required_version = ">= 1.7.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.8"
    }
    # Used by modules/processor; pinned here so the root controls the exact version.
    # tflint-ignore: terraform_unused_required_providers
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.8"
    }
  }
}
