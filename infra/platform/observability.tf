# Observabilidad: métricas propias del pipeline (Cloud Monitoring), alertas técnicas y de calidad de datos,
# canal de correo y dashboard. El presupuesto lo crea el bootstrap (necesita permisos de facturación).

locals {
  # Creado por el bootstrap para que el historial sobreviva a un destroy
  deployments_log = "paylake-deployments"

  alert_channels = google_monitoring_notification_channel.email[*].id

  custom_metrics = {
    IngestedRecords          = "Registros que llegaron a Bronze desde el simulador"
    BronzeRecords            = "Registros leídos de Bronze por fuente"
    SilverRecords            = "Registros escritos en Silver por fuente"
    RejectedRecords          = "Registros enviados a cuarentena"
    DuplicatesRemoved        = "Duplicados eliminados"
    RejectionRate            = "Fracción de registros rechazados (0-1)"
    ReconciliationMismatches = "Métricas del core que no cuadran con Silver"
    FraudAlerts              = "Alertas de fraude generadas en Gold"
    ExchangeFiles            = "Archivos de liquidación publicados"
    InterchangeUsd           = "Intercambio total calculado (USD)"
  }
  metric_type = { for k in keys(local.custom_metrics) : k => "custom.googleapis.com/paylake/${lower(join("_", regexall("[A-Z][a-z]*", k)))}" }
}

resource "google_monitoring_notification_channel" "email" {
  count        = var.alert_email != "" ? 1 : 0
  display_name = "${local.name} alertas"
  type         = "email"
  labels       = { email_address = var.alert_email }
}

# Descriptores de las métricas propias (las escriben las functions: observability.py)
resource "google_monitoring_metric_descriptor" "custom" {
  for_each     = local.custom_metrics
  type         = local.metric_type[each.key]
  display_name = "paylake ${each.key}"
  description  = each.value
  metric_kind  = "GAUGE"
  value_type   = "DOUBLE"
  unit         = each.key == "InterchangeUsd" ? "USD" : (each.key == "RejectionRate" ? "1" : "{records}")

  labels {
    key = "stage"
  }
  labels {
    key = "source"
  }
  labels {
    key = "environment"
  }
}

# --- Alertas técnicas y de calidad de datos -------------------------------------------------------

locals {
  alerts = {
    workflow-failed = {
      description = "Un workflow (pipeline o Spark diario) terminó con error"
      filter      = "resource.type=\"workflows.googleapis.com/Workflow\" AND metric.type=\"workflows.googleapis.com/finished_execution_count\" AND metric.label.status=\"FAILED\""
      aligner     = "ALIGN_SUM"
      threshold   = 0
      period      = "300s"
      group_by    = ["resource.label.workflow_id"]
    }
    function-5xx = {
      description = "Una function del pipeline o la API respondió con error 5xx"
      filter      = "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.label.response_code_class=\"5xx\" AND resource.label.service_name=starts_with(\"${local.name}-\")"
      aligner     = "ALIGN_SUM"
      threshold   = 0
      period      = "300s"
      group_by    = ["resource.label.service_name"]
    }
    dq-rejection-rate = {
      description = "Más del 8 % de los registros del simulador fue a cuarentena"
      filter      = "resource.type=\"global\" AND metric.type=\"${local.metric_type["RejectionRate"]}\" AND metric.label.source=\"simulator\""
      aligner     = "ALIGN_MAX"
      threshold   = 0.08
      period      = "3600s"
      group_by    = []
    }
    dq-reconciliation = {
      description = "Los totales que declara el core no cuadran con Silver"
      filter      = "resource.type=\"global\" AND metric.type=\"${local.metric_type["ReconciliationMismatches"]}\" AND metric.label.source=\"core\""
      aligner     = "ALIGN_MAX"
      threshold   = 0
      period      = "3600s"
      group_by    = []
    }
  }
  cdc_alerts = var.enable_cdc ? {
    cdc-freshness = {
      description = "La réplica CDC del core lleva más de 10 minutos de atraso"
      filter      = "resource.type=\"datastream.googleapis.com/Stream\" AND metric.type=\"datastream.googleapis.com/stream/freshness\""
      aligner     = "ALIGN_MAX"
      threshold   = 600
      period      = "300s"
      group_by    = []
    }
  } : {}
}

resource "google_monitoring_alert_policy" "pipeline" {
  for_each     = merge(local.alerts, local.cdc_alerts)
  display_name = "${local.name} ${each.key}"
  combiner     = "OR"

  conditions {
    display_name = each.value.description
    condition_threshold {
      filter          = each.value.filter
      comparison      = "COMPARISON_GT"
      threshold_value = each.value.threshold
      duration        = "0s"
      aggregations {
        alignment_period     = each.value.period
        per_series_aligner   = each.value.aligner
        cross_series_reducer = length(each.value.group_by) > 0 ? "REDUCE_SUM" : null
        group_by_fields      = each.value.group_by
      }
    }
  }

  documentation {
    content = each.value.description
  }

  notification_channels = local.alert_channels
  alert_strategy {
    auto_close = "3600s"
  }

  depends_on = [google_monitoring_metric_descriptor.custom]
}

# --- Observabilidad del proceso de despliegue -----------------------------------------------------
# scripts/deploy_record.py escribe un JSON por despliegue en el log paylake-deployments (PC y GitHub Actions).

resource "google_logging_metric" "deployments" {
  for_each    = { failed = "failed", succeeded = "success" }
  name        = "${local.ds_prefix}_deployments_${each.key}"
  description = "Despliegues con resultado ${each.value}"
  filter      = "logName=\"projects/${var.project_id}/logs/${local.deployments_log}\" AND jsonPayload.kind=\"deploy\" AND jsonPayload.result=\"${each.value}\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
  }
}

resource "google_monitoring_alert_policy" "deployment_failed" {
  display_name = "${local.name} despliegue fallido"
  combiner     = "OR"

  conditions {
    display_name = "Un despliegue (PC o GitHub Actions) terminó con error"
    condition_threshold {
      # gcloud logging write escribe con el recurso "global"
      filter          = "metric.type=\"logging.googleapis.com/user/${google_logging_metric.deployments["failed"].name}\" AND resource.type=\"global\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period     = "300s"
        per_series_aligner   = "ALIGN_SUM"
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  documentation {
    content = "Ver el panel 'Historial de despliegues' del dashboard o el log ${local.deployments_log}."
  }
  notification_channels = local.alert_channels
}

# --- Dashboard ----------------------------------------------------------------------------------

locals {
  charts = merge(
    {
      workflows = {
        title  = "Workflows: ejecuciones por estado"
        series = [{ filter = "resource.type=\"workflows.googleapis.com/Workflow\" AND metric.type=\"workflows.googleapis.com/finished_execution_count\"", aligner = "ALIGN_SUM", group = ["metric.label.status"] }]
      }
      simulator = {
        title  = "Registros por capa (simulador)"
        series = [for m in ["BronzeRecords", "SilverRecords", "RejectedRecords", "DuplicatesRemoved"] : { filter = "resource.type=\"global\" AND metric.type=\"${local.metric_type[m]}\" AND metric.label.source=\"simulator\"", aligner = "ALIGN_MAX", group = [] }]
      }
      core = {
        title  = "Fuente core (extracto o Datastream)"
        series = [for m in ["SilverRecords", "RejectedRecords", "ReconciliationMismatches"] : { filter = "resource.type=\"global\" AND metric.type=\"${local.metric_type[m]}\" AND metric.label.source=\"core\"", aligner = "ALIGN_MAX", group = [] }]
      }
      gold = {
        title  = "Gold: alertas de fraude e intercambio (USD)"
        series = [for m in ["FraudAlerts", "InterchangeUsd"] : { filter = "resource.type=\"global\" AND metric.type=\"${local.metric_type[m]}\"", aligner = "ALIGN_MAX", group = [] }]
      }
      latency = {
        title  = "Functions: latencia p95 (ms)"
        series = [{ filter = "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_latencies\" AND resource.label.service_name=starts_with(\"${local.name}-\")", aligner = "ALIGN_PERCENTILE_95", group = ["resource.label.service_name"] }]
      }
      errors = {
        title  = "Functions: respuestas 5xx"
        series = [{ filter = "resource.type=\"cloud_run_revision\" AND metric.type=\"run.googleapis.com/request_count\" AND metric.label.response_code_class=\"5xx\" AND resource.label.service_name=starts_with(\"${local.name}-\")", aligner = "ALIGN_SUM", group = ["resource.label.service_name"] }]
      }
    },
    var.enable_cdc ? {
      freshness = {
        title  = "Datastream: frescura de la réplica CDC (s)"
        series = [{ filter = "resource.type=\"datastream.googleapis.com/Stream\" AND metric.type=\"datastream.googleapis.com/stream/freshness\"", aligner = "ALIGN_MAX", group = [] }]
      }
      cloudsql = {
        title  = "Cloud SQL core: CPU"
        series = [{ filter = "resource.type=\"cloudsql_database\" AND metric.type=\"cloudsql.googleapis.com/database/cpu/utilization\"", aligner = "ALIGN_MEAN", group = [] }]
      }
    } : {},
  )

  chart_widgets = [for k in sort(keys(local.charts)) : {
    title = local.charts[k].title
    xyChart = {
      dataSets = [for s in local.charts[k].series : {
        plotType = "LINE"
        timeSeriesQuery = {
          timeSeriesFilter = {
            filter = s.filter
            aggregation = {
              alignmentPeriod    = "3600s"
              perSeriesAligner   = s.aligner
              crossSeriesReducer = length(s.group) > 0 ? "REDUCE_SUM" : "REDUCE_NONE"
              groupByFields      = s.group
            }
          }
        }
      }]
    }
  }]

  log_widgets = [
    {
      title = "Últimos errores del pipeline"
      logsPanel = {
        filter        = "resource.type=\"cloud_run_revision\" AND resource.labels.service_name:\"${local.name}-\" AND severity>=ERROR"
        resourceNames = ["projects/${var.project_id}"]
      }
    },
    {
      title = "Historial de despliegues (PC y GitHub Actions)"
      logsPanel = {
        filter        = "logName=\"projects/${var.project_id}/logs/${local.deployments_log}\""
        resourceNames = ["projects/${var.project_id}"]
      }
    },
  ]

  widgets = concat(
    [{ title = "Payments Lakehouse (${var.environment})", text = { content = "Pipeline medallion: ingesta → Bronze → Silver → Gold. Datos sintéticos.", format = "MARKDOWN" } }],
    local.chart_widgets,
    local.log_widgets,
  )
}

resource "google_monitoring_dashboard" "pipeline" {
  dashboard_json = jsonencode({
    displayName = "${local.name} pipeline"
    mosaicLayout = {
      columns = 12
      tiles = [for i, w in local.widgets : {
        # Encabezado y logs a lo ancho; gráficos de a tres por fila
        xPos   = (i == 0 || i > length(local.chart_widgets)) ? 0 : ((i - 1) % 3) * 4
        yPos   = i == 0 ? 0 : (i <= length(local.chart_widgets) ? 2 + floor((i - 1) / 3) * 4 : 2 + ceil(length(local.chart_widgets) / 3) * 4 + (i - length(local.chart_widgets) - 1) * 5)
        width  = (i == 0 || i > length(local.chart_widgets)) ? 12 : 4
        height = i == 0 ? 2 : (i <= length(local.chart_widgets) ? 4 : 5)
        widget = w
      }]
    }
  })

  # La API normaliza el JSON (agrega etag y estilos, quita las posiciones 0): se ignora esa diferencia y el
  # dashboard se reemplaza sólo cuando cambia lo que declaramos
  lifecycle {
    ignore_changes       = [dashboard_json]
    replace_triggered_by = [terraform_data.dashboard_spec]
  }

  depends_on = [google_monitoring_metric_descriptor.custom]
}

resource "terraform_data" "dashboard_spec" {
  input = sha1(jsonencode(local.widgets))
}
