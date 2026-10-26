# VPC propia (sin costo por sí misma) con una subred para Dataproc Serverless y la VM de carga.
# Private Google Access: Spark llega a GCS y BigQuery sin IP pública ni NAT.

resource "google_compute_network" "main" {
  name                    = "${local.name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "main" {
  name                     = "${local.name}-main"
  region                   = var.region
  network                  = google_compute_network.main.id
  ip_cidr_range            = "10.20.0.0/24"
  private_ip_google_access = true

  # VPC Flow Logs: muestreo del 50 % agregado cada 5 minutos
  log_config {
    aggregation_interval = "INTERVAL_5_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# --- Firewall -------------------------------------------------------------------------------------
# Lo que no está permitido está denegado (regla implícita de GCP); la regla explícita de abajo además
# deja registro de cada intento rechazado.

resource "google_compute_firewall" "internal" {
  name          = "${local.name}-allow-internal"
  network       = google_compute_network.main.id
  description   = "Dataproc Serverless: los nodos de Spark se hablan entre sí dentro de la subred"
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = [google_compute_subnetwork.main.ip_cidr_range]
  allow { protocol = "all" }
}

resource "google_compute_firewall" "iap_ssh" {
  name          = "${local.name}-allow-iap-ssh"
  network       = google_compute_network.main.id
  description   = "SSH a la VM de carga sólo a través de IAP (sin puertos abiertos a internet)"
  direction     = "INGRESS"
  priority      = 1000
  source_ranges = ["35.235.240.0/20"] # rango de IAP TCP forwarding
  target_tags   = ["core-loader"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

resource "google_compute_firewall" "deny_all_ingress" {
  name          = "${local.name}-deny-all-ingress"
  network       = google_compute_network.main.id
  description   = "Todo lo demás se rechaza y queda registrado"
  direction     = "INGRESS"
  priority      = 65000
  source_ranges = ["0.0.0.0/0"]
  deny { protocol = "all" }

  log_config {
    metadata = "INCLUDE_ALL_METADATA"
  }
}

# --- Acceso privado a servicios (IP privada de Cloud SQL) -----------------------------------------

resource "google_compute_global_address" "psa" {
  count         = var.enable_cdc ? 1 : 0
  name          = "${local.name}-psa"
  purpose       = "VPC_PEERING"
  address_type  = "INTERNAL"
  prefix_length = 20
  network       = google_compute_network.main.id
}

resource "google_service_networking_connection" "psa" {
  count                   = var.enable_cdc ? 1 : 0
  network                 = google_compute_network.main.id
  service                 = "servicenetworking.googleapis.com"
  reserved_peering_ranges = [google_compute_global_address.psa[0].name]
  # Al destruir, el peering suele seguir "en uso" unos minutos después de borrar Cloud SQL:
  # se abandona y se va con la VPC.
  deletion_policy = "ABANDON"
}
