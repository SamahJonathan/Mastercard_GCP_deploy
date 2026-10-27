variable "project_id" {
  description = "Proyecto de GCP (lo crea infra/bootstrap/bootstrap.ps1 y lo escribe en project.auto.tfvars)"
  type        = string
}

variable "region" {
  type    = string
  default = "southamerica-east1"
}

variable "project" {
  type    = string
  default = "paylake"
}

variable "environment" {
  type    = string
  default = "dev"
}

variable "github_repo" {
  description = "Repositorio owner/nombre que despliega con Workload Identity Federation"
  type        = string
  default     = "SamahJonathan/Mastercard_GCP_deploy"
}

variable "schedule_cron" {
  description = "Frecuencia con que llega un lote nuevo y se ejecuta el pipeline (cron de Cloud Scheduler)"
  type        = string
  default     = "0 * * * *"
}

variable "schedule_enabled" {
  description = "Apagar (false) para no generar costos cuando no se está mostrando el proyecto"
  type        = bool
  default     = true
}

variable "batch_size" {
  type    = number
  default = 2000
}

variable "lookback_days" {
  type    = number
  default = 3
}

variable "partner_issuers" {
  description = "Emisores que reciben sus archivos de liquidación con una cuenta de servicio propia (intercambio de datos)"
  type        = list(string)
  default     = ["EM001", "EM005"]
}

variable "partner_principals" {
  description = "Quién puede actuar como cada emisor (p.ej. una identidad federada del banco). Por defecto, los admin_members"
  type        = list(string)
  default     = []
}

variable "core_snapshot_ingest_date" {
  description = "Partición ingest_date con que se aterriza el extracto core de sample_data en Bronze"
  type        = string
  default     = "2026-10-21"
}

# --- Piezas opcionales (con costo por hora) ---------------------------------------------------

variable "enable_cdc" {
  description = "Core bancario en Cloud SQL PostgreSQL + VM de carga + Datastream (backfill + CDC) hacia Bronze"
  type        = bool
  default     = true
}

variable "core_db_tier" {
  description = "Tipo de máquina de Cloud SQL (db-f1-micro: núcleo compartido, el más barato)"
  type        = string
  default     = "db-f1-micro"
}

variable "loader_machine_type" {
  type    = string
  default = "e2-micro"
}

# --- Gobierno y observabilidad -----------------------------------------------------------------

variable "admin_members" {
  description = "Personas que administran el lake (ven Silver y Gold), p.ej. [\"user:tu@gmail.com\"]"
  type        = list(string)
  default     = []
}

variable "analyst_members" {
  description = "Personas con el mismo acceso que la cuenta analyst (sólo Gold)"
  type        = list(string)
  default     = []
}

variable "consultant_members" {
  description = "Consultores externos (cuentas de Google): consultan Gold directo, sin cambiar de identidad"
  type        = list(string)
  default     = []
}

variable "alert_email" {
  description = "Correo que recibe las alertas (vacío = sin canal de notificación)"
  type        = string
  default     = ""
}

variable "dataproc_schedule" {
  description = "Cron del job diario de Dataproc Serverless (UTC)"
  type        = string
  default     = "0 6 * * *"
}

variable "max_bytes_billed" {
  description = "Tope de bytes facturados por consulta de los analistas (1 GB)"
  type        = number
  default     = 1073741824
}

# --- Dashboard web (Identity-Aware Proxy) ------------------------------------------------------
# En un proyecto sin organización IAP necesita un cliente OAuth propio, que sólo se crea desde la consola
# (Google Auth Platform → Clientes). Vacíos = IAP sin configurar (el dashboard responde 502).

variable "iap_oauth_client_id" {
  description = "ID del cliente OAuth (aplicación web) que usa IAP para el inicio de sesión del dashboard"
  type        = string
  default     = ""
}

variable "iap_oauth_client_secret" {
  description = "Secreto de ese cliente OAuth (va en secrets.auto.tfvars, fuera de git)"
  type        = string
  default     = ""
  sensitive   = true
}
