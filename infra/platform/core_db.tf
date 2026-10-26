# "Core bancario" de origen: PostgreSQL 16 en Cloud SQL, cargado con sample_data por una VM.
# La VM además simula actividad cada 15 minutos (INSERT/UPDATE) para que Datastream la capture como CDC.
#
# Conectividad:
#  - La VM llega por IP PRIVADA (acceso privado a servicios).
#  - Datastream llega por IP PÚBLICA, autorizada SÓLO para las IPs fijas de Datastream en la región y
#    con TLS obligatorio (ssl_mode ENCRYPTED_ONLY; Datastream verifica el certificado del servidor).

locals {
  cdc_count    = var.enable_cdc ? 1 : 0
  core_db_name = "corebank"
  core_db_user = "core_admin"
}

resource "random_password" "core_db" {
  count   = local.cdc_count
  length  = 32
  special = false
}

data "google_datastream_static_ips" "this" {
  count    = local.cdc_count
  location = var.region
}

resource "google_sql_database_instance" "core" {
  count            = local.cdc_count
  name             = "${local.name}-core-${random_id.suffix.hex}" # los nombres de Cloud SQL no se reutilizan por una semana
  database_version = "POSTGRES_16"
  region           = var.region

  deletion_protection = false

  settings {
    tier              = var.core_db_tier
    edition           = "ENTERPRISE"
    availability_type = "ZONAL"
    disk_type         = "PD_HDD"
    disk_size         = 10

    # Replicación lógica: requisito de Datastream para CDC desde PostgreSQL
    database_flags {
      name  = "cloudsql.logical_decoding"
      value = "on"
    }

    ip_configuration {
      ipv4_enabled    = true
      private_network = google_compute_network.main.id
      ssl_mode        = "ENCRYPTED_ONLY"

      dynamic "authorized_networks" {
        for_each = data.google_datastream_static_ips.this[0].static_ips
        content {
          name  = "datastream-${authorized_networks.key}"
          value = authorized_networks.value
        }
      }
    }

    backup_configuration {
      enabled = false
    }
  }

  depends_on = [google_service_networking_connection.psa]
}

resource "google_sql_database" "core" {
  count    = local.cdc_count
  name     = local.core_db_name
  instance = google_sql_database_instance.core[0].name
}

resource "google_sql_user" "core" {
  count    = local.cdc_count
  name     = local.core_db_user
  instance = google_sql_database_instance.core[0].name
  password = random_password.core_db[0].result
}

# --- VM de carga (Debian 12, sin IP de entrada: SSH sólo por IAP, OS Login) ----------------------

resource "google_compute_instance" "loader" {
  count        = local.cdc_count
  name         = "${local.name}-core-loader"
  machine_type = var.loader_machine_type
  zone         = "${var.region}-a"
  tags         = ["core-loader"]

  boot_disk {
    initialize_params {
      image = "debian-cloud/debian-12"
      size  = 10
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    # IP efímera sólo para salir (paquetes apt); el firewall no deja entrar nada salvo IAP
    access_config {}
  }

  service_account {
    email  = google_service_account.this["core-loader"].email
    scopes = ["cloud-platform"]
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  metadata = {
    enable-oslogin         = "TRUE"
    block-project-ssh-keys = "TRUE"
  }

  metadata_startup_script = templatefile("${path.module}/templates/core_loader_startup.sh.tftpl", {
    project_id     = var.project_id
    loader_uri     = "${local.uri["artifacts"]}/${google_storage_bucket_object.core_loader.name}"
    snapshot_uri   = "${local.uri["bronze"]}/${google_storage_bucket_object.core_snapshot.name}"
    db_host        = google_sql_database_instance.core[0].private_ip_address
    db_name        = local.core_db_name
    db_user        = local.core_db_user
    db_password_id = google_secret_manager_secret.this["core-db-password"].secret_id
  })

  allow_stopping_for_update = true

  depends_on = [
    google_sql_user.core,
    google_sql_database.core,
    google_storage_bucket_iam_member.grant,
    google_secret_manager_secret_iam_member.reader,
    google_secret_manager_secret_version.this,
  ]
}
