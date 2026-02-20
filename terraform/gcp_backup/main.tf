terraform {
  required_version = ">= 1.5.0"
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

# ── Random suffix for globally unique resource names ───────
resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_prefix = "imgpipeline"
  suffix      = random_id.suffix.hex
}

# ══════════════════════════════════════════════════════════
# 1. ENABLE REQUIRED GCP APIs
# ══════════════════════════════════════════════════════════
resource "google_project_service" "required_apis" {
  for_each = toset([
    "cloudfunctions.googleapis.com",
    "cloudbuild.googleapis.com",
    "run.googleapis.com",
    "pubsub.googleapis.com",
    "storage.googleapis.com",
    "secretmanager.googleapis.com",
    "apigateway.googleapis.com",
    "servicemanagement.googleapis.com",
    "servicecontrol.googleapis.com",
    "eventarc.googleapis.com",
    "artifactregistry.googleapis.com",
    "logging.googleapis.com",
    "iam.googleapis.com",
  ])
  service            = each.value
  disable_on_destroy = false
}

# ══════════════════════════════════════════════════════════
# 2. CLOUD STORAGE BUCKETS
# ══════════════════════════════════════════════════════════

# Bucket: raw image uploads (7-day auto-delete lifecycle)
resource "google_storage_bucket" "uploads" {
  name                        = "${local.name_prefix}-uploads-${local.suffix}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 7
    }
  }

  depends_on = [google_project_service.required_apis]
}

# Bucket: processed (grayscale) images
resource "google_storage_bucket" "processed" {
  name                        = "${local.name_prefix}-processed-${local.suffix}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  depends_on = [google_project_service.required_apis]
}

# Bucket: Cloud Function source code zips
resource "google_storage_bucket" "fn_source" {
  name                        = "${local.name_prefix}-fn-source-${local.suffix}"
  location                    = var.region
  force_destroy               = true
  uniform_bucket_level_access = true

  depends_on = [google_project_service.required_apis]
}

# ══════════════════════════════════════════════════════════
# 3. PUB/SUB TOPICS & DEAD-LETTER QUEUE
# ══════════════════════════════════════════════════════════
resource "google_pubsub_topic" "image_requests" {
  name       = "image-processing-requests"
  depends_on = [google_project_service.required_apis]
}

resource "google_pubsub_topic" "image_results" {
  name       = "image-processing-results"
  depends_on = [google_project_service.required_apis]
}

resource "google_pubsub_topic" "dead_letter" {
  name       = "image-processing-dead-letter"
  depends_on = [google_project_service.required_apis]
}

# Explicit subscription with dead-letter policy
resource "google_pubsub_subscription" "image_requests_sub" {
  name  = "image-processing-requests-sub"
  topic = google_pubsub_topic.image_requests.name

  ack_deadline_seconds = 60

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = 5
  }

  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "300s"
  }

  depends_on = [google_project_service.required_apis]
}

# ══════════════════════════════════════════════════════════
# 4. IAM SERVICE ACCOUNT (principle of least privilege)
# ══════════════════════════════════════════════════════════
resource "google_service_account" "functions_sa" {
  account_id   = "image-pipeline-sa"
  display_name = "Image Pipeline — Cloud Functions Service Account"
  depends_on   = [google_project_service.required_apis]
}

resource "google_project_iam_member" "sa_storage_admin" {
  project = var.project_id
  role    = "roles/storage.objectAdmin"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "sa_pubsub_publisher" {
  project = var.project_id
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "sa_pubsub_subscriber" {
  project = var.project_id
  role    = "roles/pubsub.subscriber"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "sa_secret_accessor" {
  project = var.project_id
  role    = "roles/secretmanager.secretAccessor"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "sa_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "sa_run_invoker" {
  project = var.project_id
  role    = "roles/run.invoker"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

resource "google_project_iam_member" "sa_eventarc_receiver" {
  project = var.project_id
  role    = "roles/eventarc.eventReceiver"
  member  = "serviceAccount:${google_service_account.functions_sa.email}"
}

# ══════════════════════════════════════════════════════════
# Dead-letter queue: Pub/Sub service agent IAM
# GCP requires the Pub/Sub service agent to have subscriber access
# on the source subscription and publisher access on the DLQ topic.
# Without these, the dead-letter policy silently does nothing.
# ══════════════════════════════════════════════════════════
data "google_project" "project" {}

locals {
  pubsub_sa = "serviceAccount:service-${data.google_project.project.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_sa
}

resource "google_pubsub_subscription_iam_member" "requests_sub_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.image_requests_sub.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_sa
}

# ══════════════════════════════════════════════════════════
# 5. SECRET MANAGER — API KEY
# ══════════════════════════════════════════════════════════
resource "random_password" "api_key" {
  length  = 40
  special = false
}

resource "google_secret_manager_secret" "api_key" {
  secret_id = "image-pipeline-api-key"

  replication {
    auto {}
  }

  depends_on = [google_project_service.required_apis]
}

resource "google_secret_manager_secret_version" "api_key_v1" {
  secret      = google_secret_manager_secret.api_key.id
  secret_data = random_password.api_key.result
}

# ══════════════════════════════════════════════════════════
# 6. CLOUD FUNCTION SOURCE ARCHIVES
# ══════════════════════════════════════════════════════════
data "archive_file" "upload_fn_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/upload-image"
  output_path = "/tmp/upload-image.zip"
}

data "archive_file" "process_fn_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/process-image"
  output_path = "/tmp/process-image.zip"
}

data "archive_file" "notify_fn_zip" {
  type        = "zip"
  source_dir  = "${path.module}/../functions/log-notification"
  output_path = "/tmp/log-notification.zip"
}

resource "google_storage_bucket_object" "upload_fn_src" {
  name   = "upload-image-${data.archive_file.upload_fn_zip.output_md5}.zip"
  bucket = google_storage_bucket.fn_source.name
  source = data.archive_file.upload_fn_zip.output_path
}

resource "google_storage_bucket_object" "process_fn_src" {
  name   = "process-image-${data.archive_file.process_fn_zip.output_md5}.zip"
  bucket = google_storage_bucket.fn_source.name
  source = data.archive_file.process_fn_zip.output_path
}

resource "google_storage_bucket_object" "notify_fn_src" {
  name   = "log-notification-${data.archive_file.notify_fn_zip.output_md5}.zip"
  bucket = google_storage_bucket.fn_source.name
  source = data.archive_file.notify_fn_zip.output_path
}

# ══════════════════════════════════════════════════════════
# 7. CLOUD FUNCTION 1: upload-image (HTTP triggered)
# ══════════════════════════════════════════════════════════
resource "google_cloudfunctions2_function" "upload_image" {
  name     = "upload-image"
  location = var.region

  build_config {
    runtime     = "python311"
    entry_point = "upload_image"
    source {
      storage_source {
        bucket = google_storage_bucket.fn_source.name
        object = google_storage_bucket_object.upload_fn_src.name
      }
    }
  }

  service_config {
    available_memory      = "256M"
    timeout_seconds       = 60
    max_instance_count    = 10
    min_instance_count    = 0
    service_account_email = google_service_account.functions_sa.email

    environment_variables = {
      UPLOADS_BUCKET    = google_storage_bucket.uploads.name
      PUBSUB_TOPIC      = google_pubsub_topic.image_requests.id
      PROJECT_ID        = var.project_id
      API_KEY_SECRET_ID = google_secret_manager_secret.api_key.secret_id
    }
  }

  depends_on = [
    google_project_service.required_apis,
    google_storage_bucket_object.upload_fn_src,
  ]
}

# Allow API Gateway (allUsers via gateway) to invoke the function
resource "google_cloud_run_service_iam_member" "upload_fn_invoker" {
  project  = var.project_id
  location = var.region
  service  = google_cloudfunctions2_function.upload_image.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# ══════════════════════════════════════════════════════════
# 8. CLOUD FUNCTION 2: process-image (Pub/Sub triggered)
# ══════════════════════════════════════════════════════════
resource "google_cloudfunctions2_function" "process_image" {
  name     = "process-image"
  location = var.region

  build_config {
    runtime     = "python311"
    entry_point = "process_image"
    source {
      storage_source {
        bucket = google_storage_bucket.fn_source.name
        object = google_storage_bucket_object.process_fn_src.name
      }
    }
  }

  service_config {
    available_memory      = "512M"
    timeout_seconds       = 120
    max_instance_count    = 10
    min_instance_count    = 0
    service_account_email = google_service_account.functions_sa.email

    environment_variables = {
      UPLOADS_BUCKET   = google_storage_bucket.uploads.name
      PROCESSED_BUCKET = google_storage_bucket.processed.name
      RESULTS_TOPIC    = google_pubsub_topic.image_results.id
      PROJECT_ID       = var.project_id
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.image_requests.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.functions_sa.email
  }

  depends_on = [
    google_project_service.required_apis,
    google_storage_bucket_object.process_fn_src,
  ]
}

# ══════════════════════════════════════════════════════════
# 9. CLOUD FUNCTION 3: log-notification (Pub/Sub triggered)
# ══════════════════════════════════════════════════════════
resource "google_cloudfunctions2_function" "log_notification" {
  name     = "log-notification"
  location = var.region

  build_config {
    runtime     = "python311"
    entry_point = "log_notification"
    source {
      storage_source {
        bucket = google_storage_bucket.fn_source.name
        object = google_storage_bucket_object.notify_fn_src.name
      }
    }
  }

  service_config {
    available_memory      = "128M"
    timeout_seconds       = 30
    max_instance_count    = 5
    min_instance_count    = 0
    service_account_email = google_service_account.functions_sa.email

    environment_variables = {
      PROJECT_ID = var.project_id
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.image_results.id
    retry_policy          = "RETRY_POLICY_RETRY"
    service_account_email = google_service_account.functions_sa.email
  }

  depends_on = [
    google_project_service.required_apis,
    google_storage_bucket_object.notify_fn_src,
  ]
}

# ══════════════════════════════════════════════════════════
# 10. API GATEWAY (OpenAPI + API Key + Rate Limit)
# ══════════════════════════════════════════════════════════
resource "google_api_gateway_api" "image_api" {
  provider   = google-beta
  api_id     = "image-pipeline-api"
  depends_on = [google_project_service.required_apis]
}

resource "google_api_gateway_api_config" "image_api_config" {
  provider      = google-beta
  api           = google_api_gateway_api.image_api.api_id
  api_config_id = "config-${local.suffix}"

  openapi_documents {
    document {
      path = "openapi.yaml"
      contents = base64encode(templatefile("${path.module}/openapi.yaml.tpl", {
        upload_function_url = google_cloudfunctions2_function.upload_image.service_config[0].uri
        project_id          = var.project_id
      }))
    }
  }

  gateway_config {
    backend_config {
      google_service_account = google_service_account.functions_sa.email
    }
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    google_cloudfunctions2_function.upload_image,
    google_project_service.required_apis,
  ]
}

resource "google_api_gateway_gateway" "image_gateway" {
  provider   = google-beta
  api_config = google_api_gateway_api_config.image_api_config.id
  gateway_id = "image-pipeline-gateway"
  region     = var.region

  depends_on = [google_api_gateway_api_config.image_api_config]
}
