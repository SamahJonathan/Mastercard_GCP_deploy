# Cloud Audit Logs:
#  - Admin Activity siempre está activo en GCP (quién creó, borró o cambió permisos de qué).
#  - Data Access de Cloud Storage se activa aquí: quién lee o escribe objetos (en Bronze están los PAN).
#  - Un sink copia la actividad administrativa y los accesos a Bronze a un bucket de auditoría (90 días).
#  - Métricas basadas en logs + alertas: accesos denegados, cambios de IAM y cambios de gobierno.

resource "google_project_iam_audit_config" "storage" {
  project = var.project_id
  service = "storage.googleapis.com"
  audit_log_config { log_type = "DATA_READ" }
  audit_log_config { log_type = "DATA_WRITE" }
}

resource "google_logging_project_sink" "audit" {
  name        = "${local.name}-audit"
  destination = "storage.googleapis.com/${google_storage_bucket.layer["audit"].name}"
  filter      = <<-EOT
    logName:"cloudaudit.googleapis.com%2Factivity"
    OR (logName:"cloudaudit.googleapis.com%2Fdata_access"
        AND protoPayload.resourceName:"projects/_/buckets/${google_storage_bucket.layer["bronze"].name}/")
  EOT

  unique_writer_identity = true
}

resource "google_storage_bucket_iam_member" "audit_sink" {
  bucket     = google_storage_bucket.layer["audit"].name
  role       = local.role["paylakeObjectCreator"]
  member     = google_logging_project_sink.audit.writer_identity
  depends_on = [google_project_iam_custom_role.this]
}

# --- Alertas de seguridad a partir de los audit logs ---------------------------------------------

locals {
  audited_types = ["project", "gcs_bucket", "service_account", "iam_role", "audited_resource", "bigquery_dataset", "bigquery_resource", "cloud_run_revision", "gce_instance"]

  security_metrics = {
    permission_denied = {
      description = "Llamadas rechazadas por falta de permisos"
      threshold   = 5
      filter      = "logName:\"cloudaudit.googleapis.com\" AND protoPayload.status.code=7"
    }
    iam_policy_changes = {
      description = "Cambios de políticas de IAM o de roles propios"
      threshold   = 1
      filter      = "logName:\"cloudaudit.googleapis.com%2Factivity\" AND (protoPayload.methodName:\"SetIamPolicy\" OR protoPayload.methodName:\"CreateRole\" OR protoPayload.methodName:\"UpdateRole\" OR protoPayload.methodName:\"DeleteRole\")"
    }
    governance_changes = {
      description = "Cambios de las etiquetas de gobierno de los datasets (cambian quién lee cada capa)"
      threshold   = 1
      filter      = "logName:\"cloudaudit.googleapis.com%2Factivity\" AND protoPayload.serviceName=\"cloudresourcemanager.googleapis.com\" AND (protoPayload.methodName:\"TagBinding\" OR protoPayload.methodName:\"TagValue\")"
    }
  }
}

resource "google_logging_metric" "security" {
  for_each    = local.security_metrics
  name        = "${local.ds_prefix}_security_${each.key}"
  description = each.value.description
  filter      = each.value.filter
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "security" {
  for_each     = local.security_metrics
  display_name = "${local.name} seguridad: ${each.key}"
  combiner     = "OR"

  conditions {
    display_name = each.value.description
    condition_threshold {
      # Monitoring exige acotar resource.type: los audit logs llegan con el tipo del recurso auditado
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.security[each.key].name}\" AND resource.type=one_of(${join(",", [for t in local.audited_types : "\"${t}\""])})"
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold - 1
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  documentation {
    content = "Evento de seguridad detectado en Cloud Audit Logs: ${each.value.description}. Revisar en Logs Explorer con el filtro: ${each.value.filter}"
  }

  notification_channels = local.alert_channels
  alert_strategy {
    auto_close = "1800s"
  }
}
