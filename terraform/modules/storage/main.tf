locals {
  buckets = {
    raw     = "${var.project_id}-${var.name_prefix}-raw"
    curated = "${var.project_id}-${var.name_prefix}-curated"
  }
}

# The Cloud Storage service agent must be able to use the CMEK key, otherwise
# every write to the buckets fails.
data "google_storage_project_service_account" "gcs" {
  count   = var.kms_key_name == null ? 0 : 1
  project = var.project_id
}

resource "google_kms_crypto_key_iam_member" "gcs_cmek" {
  count         = var.kms_key_name == null ? 0 : 1
  crypto_key_id = var.kms_key_name
  role          = "roles/cloudkms.cryptoKeyEncrypterDecrypter"
  member        = "serviceAccount:${data.google_storage_project_service_account.gcs[0].email_address}"
}

resource "google_storage_bucket" "raw" {
  #checkov:skip=CKV_GCP_62:Access is audited with Cloud Audit Logs (Data Access) rather than legacy usage-log buckets.
  name                        = local.buckets.raw
  project                     = var.project_id
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy
  labels                      = merge(var.labels, { zone = "raw" })

  versioning {
    enabled = true
  }

  dynamic "encryption" {
    for_each = var.kms_key_name == null ? [] : [var.kms_key_name]
    content {
      default_kms_key_name = encryption.value
    }
  }

  lifecycle_rule {
    condition {
      age                   = var.raw_nearline_after_days
      matches_storage_class = ["STANDARD"]
    }
    action {
      type          = "SetStorageClass"
      storage_class = "NEARLINE"
    }
  }

  dynamic "lifecycle_rule" {
    for_each = var.raw_delete_after_days > 0 ? [var.raw_delete_after_days] : []
    content {
      condition {
        age = lifecycle_rule.value
      }
      action {
        type = "Delete"
      }
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.noncurrent_version_retention_days
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_cmek]
}

resource "google_storage_bucket" "curated" {
  #checkov:skip=CKV_GCP_62:Access is audited with Cloud Audit Logs (Data Access) rather than legacy usage-log buckets.
  name                        = local.buckets.curated
  project                     = var.project_id
  location                    = var.location
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = var.force_destroy
  labels                      = merge(var.labels, { zone = "curated" })

  versioning {
    enabled = true
  }

  dynamic "encryption" {
    for_each = var.kms_key_name == null ? [] : [var.kms_key_name]
    content {
      default_kms_key_name = encryption.value
    }
  }

  lifecycle_rule {
    condition {
      age            = var.quarantine_delete_after_days
      matches_prefix = [var.quarantine_prefix]
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      days_since_noncurrent_time = var.noncurrent_version_retention_days
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  lifecycle_rule {
    condition {
      age = 1
    }
    action {
      type = "AbortIncompleteMultipartUpload"
    }
  }

  depends_on = [google_kms_crypto_key_iam_member.gcs_cmek]
}
