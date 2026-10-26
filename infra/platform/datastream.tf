# Datastream: replica el core bancario (Cloud SQL PostgreSQL) a Bronze en JSONL, backfill + CDC continuo.
# Cada línea trae la fila en `payload` y en `source_metadata` el tipo de cambio, is_deleted y el LSN;
# Silver aplica los cambios (silver.datastream_to_snapshot).

resource "google_datastream_connection_profile" "core" {
  count                 = local.cdc_count
  connection_profile_id = "${local.name}-core-postgres"
  display_name          = "Core bancario (Cloud SQL PostgreSQL)"
  location              = var.region

  postgresql_profile {
    hostname = google_sql_database_instance.core[0].public_ip_address
    port     = 5432
    database = local.core_db_name
    username = local.core_db_user
    password = random_password.core_db[0].result

    # TLS con verificación del certificado del servidor (CA de la instancia)
    ssl_config {
      server_verification {
        ca_certificate = google_sql_database_instance.core[0].server_ca_cert[0].cert
      }
    }
  }

  # La API no devuelve el certificado ni la contraseña: sin esto, cada plan reemplazaría el perfil y el stream
  # (y Datastream volvería a hacer el backfill completo)
  lifecycle {
    ignore_changes = [postgresql_profile[0].ssl_config, postgresql_profile[0].password]
  }

  depends_on = [google_sql_user.core, google_sql_database.core]
}

resource "google_datastream_connection_profile" "bronze" {
  count                 = local.cdc_count
  connection_profile_id = "${local.name}-bronze-gcs"
  display_name          = "Bronze (GCS)"
  location              = var.region

  gcs_profile {
    bucket    = google_storage_bucket.layer["bronze"].name
    root_path = "/datastream"
  }

  depends_on = [google_storage_bucket_iam_member.grant]
}

# Espera a que la VM cree el esquema, la publicación y el slot antes de iniciar el stream
resource "time_sleep" "wait_core_load" {
  count           = local.cdc_count
  create_duration = "5m"
  depends_on      = [google_compute_instance.loader]
}

resource "google_datastream_stream" "core" {
  count         = local.cdc_count
  stream_id     = "${local.name}-core-to-bronze"
  display_name  = "Core bancario -> Bronze (backfill + CDC)"
  location      = var.region
  desired_state = "RUNNING"

  source_config {
    source_connection_profile = google_datastream_connection_profile.core[0].id
    postgresql_source_config {
      publication      = "paylake_pub"  # scripts/core_db/load_core_db.py: PUBLICATION
      replication_slot = "paylake_slot" # scripts/core_db/load_core_db.py: REPLICATION_SLOT
      include_objects {
        postgresql_schemas {
          schema = "core"
        }
      }
    }
  }

  destination_config {
    destination_connection_profile = google_datastream_connection_profile.bronze[0].id
    gcs_destination_config {
      file_rotation_mb       = 50
      file_rotation_interval = "60s"
      json_file_format {
        schema_file_format = "NO_SCHEMA_FILE"
        compression        = "NO_COMPRESSION"
      }
    }
  }

  backfill_all {}

  depends_on = [time_sleep.wait_core_load]
}
