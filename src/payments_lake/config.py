"""Configuración por variables de entorno.

El mismo código corre en local (rutas de disco) y en Cloud Run functions (rutas gs://).
"""
from __future__ import annotations

import os
from dataclasses import dataclass
from functools import lru_cache


@dataclass(frozen=True)
class Settings:
    bronze_root: str
    silver_root: str
    gold_root: str
    exchange_root: str
    bq_dataset_silver: str | None
    bq_dataset_gold: str | None
    lookback_days: int
    pan_token_secret: str

    @property
    def is_gcs(self) -> bool:
        return self.bronze_root.startswith("gs://")


@lru_cache(maxsize=8)
def read_secret(name: str) -> str:
    """Última versión de un secreto de Secret Manager (name = projects/<p>/secrets/<s>)."""
    from google.cloud import secretmanager

    resp = secretmanager.SecretManagerServiceClient().access_secret_version(name=f"{name}/versions/latest")
    return resp.payload.data.decode("utf-8")


def _pan_secret() -> str:
    # En GCP el secreto vive en Secret Manager (cifrado con la llave del lake); en local, una variable de entorno.
    name = os.getenv("PAN_TOKEN_SECRET_NAME")
    if name:
        return read_secret(name)
    return os.getenv("PAN_TOKEN_SECRET", "local-dev-secret-not-for-prod")


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    data_root = os.getenv("DATA_ROOT", "data")
    return Settings(
        bronze_root=os.getenv("BRONZE_ROOT", f"{data_root}/bronze").rstrip("/"),
        silver_root=os.getenv("SILVER_ROOT", f"{data_root}/silver").rstrip("/"),
        gold_root=os.getenv("GOLD_ROOT", f"{data_root}/gold").rstrip("/"),
        exchange_root=os.getenv("EXCHANGE_ROOT", f"{data_root}/exchange").rstrip("/"),
        bq_dataset_silver=os.getenv("BQ_DATASET_SILVER"),
        bq_dataset_gold=os.getenv("BQ_DATASET_GOLD"),
        lookback_days=int(os.getenv("LOOKBACK_DAYS", "7")),
        pan_token_secret=_pan_secret(),
    )
