"""Punto de entrada que Cloud Run functions busca en la raíz del código (main.py).

Las cuatro funciones comparten el mismo paquete; Terraform elige cuál exponer con entry_point.
"""
from payments_lake.handlers import bronze_to_silver, gold_api, ingest, silver_to_gold  # noqa: F401
