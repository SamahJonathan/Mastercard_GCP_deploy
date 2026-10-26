# BigQuery: catálogo, motor SQL y gobierno de acceso del lake.
#  - Un dataset por capa. Las tablas de Silver/Gold las registra el pipeline al escribir (storage.py) como
#    tablas BigLake: la CONEXIÓN lee GCS, así que quien consulta no necesita permisos sobre los buckets
#    (acceso delegado por tabla).
#  - Bronze es una tabla externa común (sin conexión): sólo la consulta quien ya puede leer el bucket.
#    Ningún humano ni analista tiene ese permiso: Bronze queda protegida sólo por IAM.
#  - Gobierno por ETIQUETAS (Resource Manager tags) en los datasets: layer y sensitivity. Los permisos de
#    lectura se otorgan con condiciones sobre esas etiquetas (iam.tf) y alcanzan a las tablas futuras.

resource "google_bigquery_dataset" "layer" {
  for_each    = toset(["bronze", "silver", "gold"])
  dataset_id  = "${local.ds_prefix}_${each.key}"
  location    = var.region
  description = "Payments Lakehouse: capa ${each.key}"

  delete_contents_on_destroy = var.environment != "prod"

  # Etiquetas de gobierno (más abajo). Van en el dataset: si fueran bindings aparte, BigQuery las reporta
  # como resource_tags del dataset y cada plan querría quitarlas (y el analista perdería el acceso)
  resource_tags = { for k, v in local.dataset_tags[each.key] : "${var.project_id}/${k}" => v }

  depends_on = [google_tags_tag_value.this]
}

# Conexión de recursos de Cloud: su cuenta de servicio (de Google) lee Silver y Gold
resource "google_bigquery_connection" "lake" {
  connection_id = "${local.name}-lake"
  location      = var.region
  friendly_name = "Payments Lakehouse (BigLake)"
  description   = "Lee Silver y Gold en GCS en nombre de quien consulta"
  cloud_resource {}
}

# --- Etiquetas de gobierno ---------------------------------------------------------------------

locals {
  tag_keys = {
    layer       = ["bronze", "silver", "gold"]
    sensitivity = ["restricted", "confidential", "public"]
  }
  dataset_tags = {
    bronze = { layer = "bronze", sensitivity = "restricted" }   # PAN en claro
    silver = { layer = "silver", sensitivity = "confidential" } # tokens de tarjeta, detalle transaccional
    gold   = { layer = "gold", sensitivity = "public" }         # agregados para negocio
  }
}

resource "google_tags_tag_key" "this" {
  for_each    = local.tag_keys
  parent      = "projects/${var.project_id}"
  short_name  = each.key
  description = "Payments Lakehouse: ${each.key} del dataset"
}

resource "google_tags_tag_value" "this" {
  for_each   = { for p in flatten([for k, vals in local.tag_keys : [for v in vals : { key = k, value = v }]]) : "${p.key}/${p.value}" => p }
  parent     = google_tags_tag_key.this[each.value.key].id
  short_name = each.value.value
}

# Antes las etiquetas se ataban con google_tags_location_tag_binding: se sueltan del estado SIN borrarlas
removed {
  from = google_tags_location_tag_binding.dataset
  lifecycle {
    destroy = false
  }
}

# --- Tablas definidas aquí (las demás las registra el pipeline) ------------------------------------

# BigQuery no deja crear una tabla externa particionada sobre una carpeta vacía: cada tabla definida aquí
# lleva un marcador sin filas en una partición de 1900 que ninguna consulta ni el pipeline toca.
resource "google_storage_bucket_object" "bronze_placeholder" {
  bucket  = google_storage_bucket.layer["bronze"].name
  name    = "transactions/ingest_date=1900-01-01/_placeholder.jsonl"
  content = "\n"
}

# Bronze: JSON crudo tal como llegó; todo texto, el tipado ocurre en Silver
locals {
  bronze_columns = [
    "transaction_id", "event_ts", "acquirer_id", "pan", "card_product", "card_country", "merchant_id",
    "mcc", "merchant_country", "amount", "currency", "entry_mode", "response_code", "schema_version",
    "_batch_id", "_ingest_ts", "_source",
  ]
}

resource "google_bigquery_table" "bronze_transactions" {
  dataset_id          = google_bigquery_dataset.layer["bronze"].dataset_id
  table_id            = "transactions"
  deletion_protection = false

  schema = jsonencode([for c in local.bronze_columns : { name = c, type = "STRING", mode = "NULLABLE" }])

  external_data_configuration {
    source_format         = "NEWLINE_DELIMITED_JSON"
    autodetect            = false
    source_uris           = ["${local.uri["bronze"]}/transactions/*"]
    ignore_unknown_values = true
    max_bad_records       = 10000 # las líneas corruptas inyectadas a propósito no rompen la consulta

    hive_partitioning_options {
      mode              = "STRINGS"
      source_uri_prefix = "${local.uri["bronze"]}/transactions/"
    }
  }

  # BigQuery agrega la columna de partición (ingest_date) al esquema que devuelve: se ignora esa diferencia
  # y la tabla se reemplaza sólo si cambia el esquema declarado aquí
  lifecycle {
    ignore_changes       = [schema]
    replace_triggered_by = [terraform_data.table_schema["bronze_transactions"]]
  }

  depends_on = [google_storage_bucket_object.bronze_placeholder]
}

# Salidas del job de Spark: el esquema vive aquí (spark_tables.json, que también usa
# scripts/make_placeholders.py); el job sólo escribe Parquet
locals {
  spark_gold_tables = jsondecode(file("${path.module}/spark_tables.json"))
}

resource "google_storage_bucket_object" "spark_placeholder" {
  for_each = local.spark_gold_tables
  bucket   = google_storage_bucket.layer["gold"].name
  name     = "${each.key}/${each.value.partition}=${each.value.placeholder}/_placeholder.parquet"
  source   = "${path.module}/placeholders/${each.key}.parquet"
}

resource "google_bigquery_table" "spark_gold" {
  for_each            = local.spark_gold_tables
  dataset_id          = google_bigquery_dataset.layer["gold"].dataset_id
  table_id            = each.key
  deletion_protection = false

  schema = jsonencode([for name, type in each.value.columns : { name = name, type = type, mode = "NULLABLE" }])

  external_data_configuration {
    source_format = "PARQUET"
    autodetect    = false
    connection_id = google_bigquery_connection.lake.name
    source_uris   = ["${local.uri["gold"]}/${each.key}/*"]

    hive_partitioning_options {
      mode              = "STRINGS"
      source_uri_prefix = "${local.uri["gold"]}/${each.key}/"
    }
  }

  lifecycle {
    ignore_changes       = [schema]
    replace_triggered_by = [terraform_data.table_schema[each.key]]
  }

  depends_on = [google_storage_bucket_iam_member.grant, google_storage_bucket_object.spark_placeholder]
}

resource "terraform_data" "table_schema" {
  for_each = merge(
    { bronze_transactions = local.bronze_columns },
    { for k, v in local.spark_gold_tables : k => v.columns },
  )
  input = sha1(jsonencode(each.value))
}
