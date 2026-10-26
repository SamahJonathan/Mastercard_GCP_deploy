output "project_id" {
  value = var.project_id
}

output "buckets" {
  value = local.bucket
}

output "bigquery_datasets" {
  value = { for k, d in google_bigquery_dataset.layer : k => d.dataset_id }
}

output "pipeline_workflow" {
  value = google_workflows_workflow.pipeline.name
}

output "analytics_workflow" {
  value = google_workflows_workflow.gold_analytics.name
}

output "api_url" {
  value = google_cloudfunctions2_function.fn["api"].url
}

output "api_key" {
  value     = random_password.api_key.result
  sensitive = true
}

output "service_accounts" {
  description = "Correo de cada identidad (para impersonar: --impersonate-service-account=<correo>)"
  value       = { for k, s in google_service_account.this : k => s.email }
}

output "partner_accounts" {
  description = "Cuenta de servicio y carpeta de cada emisor"
  value = { for i in var.partner_issuers : i => {
    service_account = google_service_account.this["partner-${lower(i)}"].email
    folder          = "${local.uri["exchange"]}/${google_storage_managed_folder.partner[i].name}"
  } }
}

output "dashboard_url" {
  value = "https://console.cloud.google.com/monitoring/dashboards/builder/${element(split("/", google_monitoring_dashboard.pipeline.id), 3)}?project=${var.project_id}"
}

output "core_db_instance" {
  description = "Cloud SQL del core bancario"
  value       = one(google_sql_database_instance.core[*].connection_name)
}

output "core_loader_ssh" {
  description = "Conectarse a la VM de carga (por IAP, sin IP de entrada)"
  value       = var.enable_cdc ? "gcloud compute ssh ${google_compute_instance.loader[0].name} --zone ${google_compute_instance.loader[0].zone} --tunnel-through-iap --project ${var.project_id}" : null
}

output "datastream_stream" {
  value = one(google_datastream_stream.core[*].name)
}
