terraform {
  required_version = ">= 1.10"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 6.20, < 8.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 6.20, < 8.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.4"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }

  # Configuración parcial: el bucket se entrega con -backend-config=backend.hcl (lo escribe el bootstrap)
  backend "gcs" {}
}

provider "google" {
  project = var.project_id
  region  = var.region

  # Las cuotas de las APIs se cargan al proyecto (necesario con credenciales de usuario)
  user_project_override = true
  billing_project       = var.project_id

  default_labels = {
    project     = var.project
    environment = var.environment
    managed-by  = "terraform"
    data-class  = "synthetic-payments"
  }
}

provider "google-beta" {
  project               = var.project_id
  region                = var.region
  user_project_override = true
  billing_project       = var.project_id
}
