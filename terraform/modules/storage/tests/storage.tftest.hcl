mock_provider "google" {}

variables {
  project_id  = "demo-project"
  name_prefix = "evp-test"
  location    = "europe-west1"
}

run "secure_defaults" {
  command = plan

  assert {
    condition     = google_storage_bucket.raw.versioning[0].enabled && google_storage_bucket.curated.versioning[0].enabled
    error_message = "Both data buckets must have object versioning enabled."
  }

  assert {
    condition     = google_storage_bucket.raw.public_access_prevention == "enforced" && google_storage_bucket.curated.public_access_prevention == "enforced"
    error_message = "Public access prevention must be enforced on both buckets."
  }

  assert {
    condition     = google_storage_bucket.raw.uniform_bucket_level_access && google_storage_bucket.curated.uniform_bucket_level_access
    error_message = "Uniform bucket-level access must be enabled."
  }

  assert {
    condition     = google_storage_bucket.raw.force_destroy == false && google_storage_bucket.curated.force_destroy == false
    error_message = "Data buckets must not be force-destroyable by default."
  }

  assert {
    condition     = length(google_storage_bucket.raw.encryption) == 0 && length(google_kms_crypto_key_iam_member.gcs_cmek) == 0
    error_message = "No CMEK configuration expected when kms_key_name is null."
  }

  assert {
    condition     = google_storage_bucket.raw.name == "demo-project-evp-test-raw"
    error_message = "Unexpected raw bucket name."
  }
}

run "lifecycle_rules" {
  command = plan

  assert {
    condition     = contains([for r in google_storage_bucket.raw.lifecycle_rule : one(r.action).type], "SetStorageClass")
    error_message = "Raw bucket must transition old objects to a colder class."
  }

  assert {
    condition = anytrue([
      for r in google_storage_bucket.raw.lifecycle_rule :
      one(r.action).type == "Delete" && one(r.condition).with_state == "ARCHIVED" && one(r.condition).days_since_noncurrent_time == 30
    ])
    error_message = "Noncurrent versions must be cleaned up on the raw bucket."
  }

  assert {
    condition = anytrue([
      for r in google_storage_bucket.curated.lifecycle_rule :
      one(r.action).type == "Delete" && one(r.condition).matches_prefix == tolist(["quarantine/"]) && one(r.condition).age == 90
    ])
    error_message = "Quarantine prefix must expire."
  }

  assert {
    condition     = contains([for r in google_storage_bucket.curated.lifecycle_rule : one(r.action).type], "AbortIncompleteMultipartUpload")
    error_message = "Incomplete uploads must be aborted."
  }
}

run "raw_deletion_can_be_disabled" {
  command = plan

  variables {
    raw_delete_after_days = 0
  }

  assert {
    condition = !anytrue([
      for r in google_storage_bucket.raw.lifecycle_rule :
      one(r.action).type == "Delete" && one(r.condition).with_state != "ARCHIVED"
    ])
    error_message = "No age-based delete rule expected when raw_delete_after_days = 0."
  }
}

run "cmek" {
  command = plan

  variables {
    kms_key_name = "projects/demo-project/locations/europe-west1/keyRings/data/cryptoKeys/evp"
  }

  assert {
    condition     = google_storage_bucket.raw.encryption[0].default_kms_key_name == var.kms_key_name && google_storage_bucket.curated.encryption[0].default_kms_key_name == var.kms_key_name
    error_message = "Both buckets must use the provided CMEK."
  }

  assert {
    condition     = google_kms_crypto_key_iam_member.gcs_cmek[0].role == "roles/cloudkms.cryptoKeyEncrypterDecrypter"
    error_message = "The Cloud Storage service agent must be granted use of the key."
  }
}
