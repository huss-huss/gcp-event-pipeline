mock_provider "google" {
  mock_data "google_project" {
    override_during = plan
    defaults = {
      number = "123456789012"
    }
  }
}

override_resource {
  target          = google_service_account.runtime
  override_during = plan
  values = {
    email  = "evp-test-fn-run@demo-project.iam.gserviceaccount.com"
    member = "serviceAccount:evp-test-fn-run@demo-project.iam.gserviceaccount.com"
    name   = "projects/demo-project/serviceAccounts/evp-test-fn-run@demo-project.iam.gserviceaccount.com"
  }
}

override_resource {
  target          = google_service_account.invoker
  override_during = plan
  values = {
    email  = "evp-test-fn-invoke@demo-project.iam.gserviceaccount.com"
    member = "serviceAccount:evp-test-fn-invoke@demo-project.iam.gserviceaccount.com"
    name   = "projects/demo-project/serviceAccounts/evp-test-fn-invoke@demo-project.iam.gserviceaccount.com"
  }
}

override_resource {
  target          = google_service_account.build
  override_during = plan
  values = {
    email  = "evp-test-fn-build@demo-project.iam.gserviceaccount.com"
    member = "serviceAccount:evp-test-fn-build@demo-project.iam.gserviceaccount.com"
    name   = "projects/demo-project/serviceAccounts/evp-test-fn-build@demo-project.iam.gserviceaccount.com"
  }
}

# The archive provider is real: it zips ../../processor locally, no cloud calls.

variables {
  project_id            = "demo-project"
  region                = "europe-west1"
  name_prefix           = "evp-test"
  source_dir            = "../../../processor"
  raw_bucket_name       = "demo-project-evp-test-raw"
  curated_bucket_name   = "demo-project-evp-test-curated"
  notification_topic_id = "projects/demo-project/topics/evp-test-raw-object-events"
}

run "least_privilege_runtime" {
  command = plan

  assert {
    condition     = google_storage_bucket_iam_member.runtime_raw_reader.role == "roles/storage.objectViewer" && google_storage_bucket_iam_member.runtime_raw_reader.bucket == var.raw_bucket_name
    error_message = "Runtime SA must only read the raw bucket."
  }

  assert {
    condition     = google_storage_bucket_iam_member.runtime_curated_creator.role == "roles/storage.objectCreator" && google_storage_bucket_iam_member.runtime_curated_creator.bucket == var.curated_bucket_name
    error_message = "Runtime SA must only create objects in the curated bucket."
  }

  assert {
    condition     = alltrue([for m in google_project_iam_member.build : m.member != google_service_account.runtime.member])
    error_message = "Runtime SA must not hold project-level roles."
  }

  assert {
    condition     = toset([for m in google_project_iam_member.build : m.role]) == toset(["roles/logging.logWriter", "roles/artifactregistry.writer"])
    error_message = "Build SA project roles must be limited to log writing and image push."
  }

  assert {
    condition     = google_cloud_run_v2_service_iam_member.invoker.role == "roles/run.invoker"
    error_message = "Invoker SA must hold run.invoker on the service."
  }

  assert {
    condition     = google_service_account_iam_member.pubsub_token_creator.member == "serviceAccount:service-123456789012@gcp-sa-pubsub.iam.gserviceaccount.com"
    error_message = "Pub/Sub service agent must be able to mint OIDC tokens for the invoker."
  }
}

run "function_settings" {
  command = plan

  assert {
    condition     = google_cloudfunctions2_function.processor.service_config[0].ingress_settings == "ALLOW_INTERNAL_ONLY"
    error_message = "Function must not accept traffic from the public internet."
  }

  assert {
    condition = (
      google_cloudfunctions2_function.processor.service_config[0].min_instance_count == 0 &&
      google_cloudfunctions2_function.processor.service_config[0].max_instance_count == 10 &&
      google_cloudfunctions2_function.processor.service_config[0].timeout_seconds == 300
    )
    error_message = "Scaling/timeout defaults changed unexpectedly."
  }

  assert {
    condition     = google_cloudfunctions2_function.processor.service_config[0].environment_variables["CURATED_BUCKET"] == var.curated_bucket_name
    error_message = "Function must be told where to write."
  }

  assert {
    condition     = length(google_cloudfunctions2_function.processor.event_trigger) == 0 && length(google_project_iam_member.invoker_event_receiver) == 0
    error_message = "pubsub_push mode must not create an Eventarc trigger."
  }

  assert {
    condition     = startswith(google_storage_bucket_object.source.name, "processor/") && endswith(google_storage_bucket_object.source.name, ".zip")
    error_message = "Source object must be content-addressed under processor/."
  }

  assert {
    condition     = google_storage_bucket.source.public_access_prevention == "enforced" && google_storage_bucket.source.uniform_bucket_level_access
    error_message = "Source bucket must be private."
  }
}

run "eventarc_mode" {
  command = plan

  variables {
    delivery_mode = "eventarc"
  }

  assert {
    condition     = google_cloudfunctions2_function.processor.event_trigger[0].event_type == "google.cloud.pubsub.topic.v1.messagePublished"
    error_message = "Eventarc trigger must listen to the notification topic."
  }

  assert {
    condition     = google_cloudfunctions2_function.processor.event_trigger[0].retry_policy == "RETRY_POLICY_RETRY"
    error_message = "Eventarc trigger must retry failed events."
  }

  assert {
    condition     = google_project_iam_member.invoker_event_receiver[0].role == "roles/eventarc.eventReceiver"
    error_message = "Trigger identity needs eventarc.eventReceiver."
  }
}

run "rejects_long_timeout" {
  command = plan

  variables {
    timeout_seconds = 900
  }

  expect_failures = [var.timeout_seconds]
}

run "rejects_unknown_delivery_mode" {
  command = plan

  variables {
    delivery_mode = "http"
  }

  expect_failures = [var.delivery_mode]
}
