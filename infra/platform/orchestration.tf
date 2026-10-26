# El agente de servicio de Workflows no existe hasta el primer uso de la API: se crea explícitamente
resource "google_project_service_identity" "workflows" {
  provider = google-beta
  service  = "workflows.googleapis.com"
}

# Cloud Workflows orquesta el pipeline (Ingest -> Bronze->Silver -> Silver->Gold) y el job diario de Spark;
# Cloud Scheduler los dispara.

resource "google_workflows_workflow" "pipeline" {
  name            = "${local.name}-pipeline"
  region          = var.region
  description     = "Pipeline medallion con reintentos y backoff"
  service_account = google_service_account.this["pipeline-wf"].id
  call_log_level  = "LOG_ERRORS_ONLY"
  source_contents = file("${path.module}/workflows/pipeline.yaml")

  user_env_vars = {
    INGEST_URL           = google_cloudfunctions2_function.fn["ingest"].url
    BRONZE_TO_SILVER_URL = google_cloudfunctions2_function.fn["bronze-to-silver"].url
    SILVER_TO_GOLD_URL   = google_cloudfunctions2_function.fn["silver-to-gold"].url
  }

  deletion_protection = false
  depends_on          = [google_cloud_run_v2_service_iam_member.invoke_stage, google_project_service_identity.workflows]
}

resource "google_workflows_workflow" "gold_analytics" {
  name            = "${local.name}-gold-analytics"
  region          = var.region
  description     = "Batch diario de Spark: calidad de datos y analítica Gold"
  service_account = google_service_account.this["analytics-wf"].id
  call_log_level  = "LOG_ERRORS_ONLY"
  source_contents = file("${path.module}/workflows/gold_analytics.yaml")

  user_env_vars = {
    REGION         = var.region
    JOB_URI        = "${local.uri["artifacts"]}/${google_storage_bucket_object.dataproc_job.name}"
    SILVER_PATH    = "${local.uri["silver"]}/transactions/"
    GOLD_PATH      = local.uri["gold"]
    DATAPROC_SA    = google_service_account.this["dataproc"].email
    SUBNET         = google_compute_subnetwork.main.id
    STAGING_BUCKET = google_storage_bucket.layer["artifacts"].name
  }

  deletion_protection = false
  depends_on          = [google_service_account_iam_member.act_as_dataproc, google_project_iam_member.grant, google_project_service_identity.workflows]
}

# --- Agenda --------------------------------------------------------------------------------

locals {
  schedules = {
    pipeline = {
      workflow = google_workflows_workflow.pipeline
      cron     = var.schedule_cron
      argument = { generate = true }
    }
    gold-analytics = {
      workflow = google_workflows_workflow.gold_analytics
      cron     = var.dataproc_schedule
      argument = {}
    }
  }
}

resource "google_cloud_scheduler_job" "this" {
  for_each  = local.schedules
  name      = "${local.name}-${each.key}"
  region    = var.region
  schedule  = each.value.cron
  time_zone = "Etc/UTC"
  paused    = !var.schedule_enabled

  http_target {
    http_method = "POST"
    uri         = "https://workflowexecutions.googleapis.com/v1/${each.value.workflow.id}/executions"
    body        = base64encode(jsonencode({ argument = jsonencode(each.value.argument) }))
    headers     = { "Content-Type" = "application/json" }

    oauth_token {
      service_account_email = google_service_account.this["scheduler"].email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  retry_config {
    retry_count = 1
  }

  depends_on = [google_project_iam_member.grant]
}
