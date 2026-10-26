#!/usr/bin/env python3
"""Genera los Parquet "marcadores" (0 filas) de las tablas que escribe Spark.

BigQuery no deja crear una tabla externa con particiones Hive si la carpeta está vacía, y Terraform crea
las tablas antes de que el job diario corra por primera vez. Cada marcador vive en una partición de 1900
(month=1900-01, txn_date=1900-01-01...), no aporta filas a ninguna consulta y Spark no lo toca porque
sólo reemplaza las particiones que recalcula.

El esquema sale de infra/platform/spark_tables.json, el mismo archivo que usa Terraform:

    python scripts/make_placeholders.py      # después de cambiar spark_tables.json
"""
import json
from pathlib import Path

import pyarrow as pa
import pyarrow.parquet as pq

PLATFORM = Path(__file__).resolve().parents[1] / "infra" / "platform"
TYPES = {"STRING": pa.string(), "INT64": pa.int64(), "FLOAT64": pa.float64(), "TIMESTAMP": pa.timestamp("us", tz="UTC")}

out = PLATFORM / "placeholders"
out.mkdir(exist_ok=True)
for table, spec in json.loads((PLATFORM / "spark_tables.json").read_text(encoding="utf-8")).items():
    schema = pa.schema([(name, TYPES[t]) for name, t in spec["columns"].items()])
    pq.write_table(schema.empty_table(), out / f"{table}.parquet")
    print(f"{table}: {len(schema)} columnas -> placeholders/{table}.parquet")
