"""Capa de almacenamiento: disco local o Cloud Storage (gs://).

En GCS las escrituras Parquet registran la tabla en BigQuery como tabla BigLake (externa, con particiones
Hive y una conexión que lee GCS en nombre del usuario), por lo que quedan consultables inmediatamente.
"""
from __future__ import annotations

import glob
import os
import shutil
from functools import lru_cache

import pandas as pd

# BigQuery no lee timestamps en nanosegundos: se escriben en microsegundos (también en local, para igualar)
PARQUET_OPTS = {"coerce_timestamps": "us", "allow_truncated_timestamps": True}


def _is_gcs(path: str) -> bool:
    return path.startswith("gs://")


def _split_gcs(path: str) -> tuple[str, str]:
    bucket, _, key = path[len("gs://"):].partition("/")
    return bucket, key


@lru_cache(maxsize=1)
def _client():
    from google.cloud import storage

    return storage.Client()


@lru_cache(maxsize=1)
def _fs():
    import gcsfs

    return gcsfs.GCSFileSystem()


def _content_type(path: str) -> str:
    return {".json": "application/json", ".csv": "text/csv"}.get(os.path.splitext(path)[1], "text/plain")


def write_text(path: str, text: str) -> None:
    if _is_gcs(path):
        bucket, key = _split_gcs(path)
        # Una sola llamada (objects.create): la identidad de ingesta sólo puede crear, no leer
        _client().bucket(bucket).blob(key).upload_from_string(text.encode("utf-8"), content_type=_content_type(path))
        return
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8", newline="\n") as fh:
        fh.write(text)


def read_text(path: str) -> str:
    if _is_gcs(path):
        bucket, key = _split_gcs(path)
        return _client().bucket(bucket).blob(key).download_as_bytes().decode("utf-8")
    with open(path, encoding="utf-8") as fh:
        return fh.read()


def _gcs_dirs(prefix: str) -> list[str]:
    """'Subcarpetas' directas de un prefijo (GCS no tiene carpetas: se listan con delimitador)."""
    bucket, key = _split_gcs(prefix)
    it = _client().list_blobs(bucket, prefix=key.rstrip("/") + "/", delimiter="/")
    for _ in it.pages:  # hay que recorrer las páginas para que se llene it.prefixes
        pass
    return [f"gs://{bucket}/{p}" for p in it.prefixes]


def list_partitions(table_path: str, partition_key: str) -> list[str]:
    """Valores existentes de una partición estilo Hive (p.ej. ingest_date=2026-10-21)."""
    dirs = _gcs_dirs(table_path) if _is_gcs(table_path) else glob.glob(os.path.join(table_path, f"{partition_key}=*"))
    values = []
    for d in dirs:
        name = d.rstrip("/\\").replace("\\", "/").rsplit("/", 1)[-1]
        if name.startswith(f"{partition_key}="):
            values.append(name.split("=", 1)[1])
    return sorted(values)


def list_files(prefix: str, suffix: str) -> list[str]:
    if _is_gcs(prefix):
        bucket, key = _split_gcs(prefix)
        blobs = _client().list_blobs(bucket, prefix=key.rstrip("/") + "/")
        return sorted(f"gs://{bucket}/{b.name}" for b in blobs if b.name.endswith(suffix))
    return sorted(glob.glob(os.path.join(prefix, "**", f"*{suffix}"), recursive=True))


def read_parquet(table_path: str, partition_key: str | None = None, values: list[str] | None = None) -> pd.DataFrame:
    """Lee una tabla Parquet (particiones Hive en cualquier nivel); opcionalmente filtra por partition_key in values."""
    wanted = set(values) if partition_key and values is not None else None
    if wanted is not None and not wanted:
        return pd.DataFrame()
    filters = [(partition_key, "in", sorted(wanted))] if wanted else None
    if _is_gcs(table_path):
        if not list_files(table_path, ".parquet"):
            return pd.DataFrame()
        df = pd.read_parquet(table_path[len("gs://"):].rstrip("/"), filters=filters, filesystem=_fs())
    else:
        if not os.path.exists(table_path):
            return pd.DataFrame()
        df = pd.read_parquet(table_path, filters=filters)
    for col in df.columns:
        if isinstance(df[col].dtype, pd.CategoricalDtype):
            df[col] = df[col].astype(str)
    return df


def _delete_prefix(path: str) -> None:
    if _is_gcs(path):
        bucket, key = _split_gcs(path)
        blobs = list(_client().list_blobs(bucket, prefix=key.rstrip("/") + "/"))
        if blobs:
            _client().bucket(bucket).delete_blobs(blobs)
    else:
        shutil.rmtree(path, ignore_errors=True)


def write_parquet(
    df: pd.DataFrame,
    table_path: str,
    partition_cols: list[str] | None = None,
    dataset: str | None = None,
    table: str | None = None,
) -> None:
    """Escritura idempotente: reemplaza sólo las particiones presentes en df (o toda la tabla si no hay particiones)."""
    if df.empty:
        return
    # Red de seguridad: una columna object sin ningún valor no tiene tipo inferible para BigQuery
    empty_objects = [c for c in df.columns if df[c].dtype == object and df[c].isna().all()]
    if empty_objects:
        df = df.astype({c: "string" for c in empty_objects})
    gcs = _is_gcs(table_path)
    target = table_path[len("gs://"):].rstrip("/") if gcs else table_path
    fs = {"filesystem": _fs()} if gcs else {}
    if partition_cols:
        for keys, _ in df.groupby(partition_cols):
            keys = keys if isinstance(keys, tuple) else (keys,)
            _delete_prefix("/".join([table_path.rstrip("/"), *[f"{c}={k}" for c, k in zip(partition_cols, keys)]]))
        df.to_parquet(target, partition_cols=partition_cols, index=False, **fs, **PARQUET_OPTS)
    else:
        _delete_prefix(table_path)
        if gcs:
            with _fs().open(f"{target}/part-0.parquet", "wb") as fh:
                df.to_parquet(fh, index=False, **PARQUET_OPTS)
        else:
            os.makedirs(table_path, exist_ok=True)
            df.to_parquet(os.path.join(table_path, "part-0.parquet"), index=False, **PARQUET_OPTS)
    if gcs and dataset and table:
        register_biglake_table(dataset, table, table_path, partition_cols)


_registered: set[str] = set()


def register_biglake_table(dataset: str, table: str, table_path: str, partition_cols: list[str] | None) -> None:
    """Crea (si no existe) la tabla BigLake sobre la carpeta. Las particiones nuevas se ven sin hacer nada más:
    BigQuery lista los archivos al consultar."""
    from google.cloud import bigquery

    table_id = f"{os.environ['GCP_PROJECT']}.{dataset}.{table}"
    if table_id in _registered:
        return
    prefix = table_path.rstrip("/")
    ext = bigquery.ExternalConfig("PARQUET")
    ext.source_uris = [f"{prefix}/*"]
    ext.connection_id = os.environ["BQ_CONNECTION"]  # <proyecto>.<región>.<conexión>
    if partition_cols:
        hive = bigquery.HivePartitioningOptions()
        hive.mode = "STRINGS"  # claves de partición como texto: txn_date = '2026-10-21'
        hive.source_uri_prefix = f"{prefix}/"
        ext.hive_partitioning = hive
    t = bigquery.Table(table_id)
    t.external_data_configuration = ext
    t.labels = {"managed-by": "pipeline"}
    client = bigquery.Client(project=os.environ["GCP_PROJECT"])
    client.create_table(t, exists_ok=True)

    # Vista para BI: el navegador de Power BI no lista tablas externas, pero sí vistas
    reports = os.getenv("BQ_DATASET_REPORTS")
    if reports and dataset == os.getenv("BQ_DATASET_GOLD"):
        view = bigquery.Table(f"{os.environ['GCP_PROJECT']}.{reports}.{table}")
        view.view_query = f"SELECT * FROM `{table_id}`"
        client.create_table(view, exists_ok=True)
    _registered.add(table_id)
