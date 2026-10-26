"""Capa Silver: datos limpios, tipados, deduplicados, enriquecidos y sin PAN en claro.

Hay un adaptador por fuente que lleva su esquema al modelo canónico (SILVER_COLUMNS):
  - simulator      : autorizaciones en línea enviadas por adquirentes (JSON lines, con PAN)
  - core           : sistema core bancario (español, ya tokenizado). Llega como extracto JSON completo
                     o replicado con Datastream (backfill + CDC) desde Cloud SQL PostgreSQL
Los registros que no pasan las reglas no se pierden: van a la tabla de cuarentena con el motivo.
"""
from __future__ import annotations

import json

import numpy as np
import pandas as pd

from . import reference as ref
from .quality import join_flags, luhn_is_valid, mask_pans, parse_amount, tokenize_pan

REQUIRED = ["transaction_id", "event_ts", "pan", "merchant_id", "amount", "currency"]

SILVER_COLUMNS = [
    "transaction_id", "event_ts", "txn_date", "acquirer_id", "issuer_id", "issuer_name",
    "pan_token", "pan_bin", "pan_last4", "card_product", "card_country", "card_status",
    "merchant_id", "merchant_name", "mcc", "mcc_category", "merchant_country",
    "entry_mode", "is_card_present", "is_cross_border", "is_wallet", "is_3ds_authenticated", "ip_country",
    "amount", "currency", "fx_rate_usd", "amount_usd", "response_code", "is_approved",
    "fraud_confirmed", "chargeback",
    "source_system", "_batch_id", "_ingest_ts", "_source_file",
]
OPTIONAL_BOOL = ["is_wallet", "is_3ds_authenticated", "fraud_confirmed", "chargeback"]
# Tipo explícito de cada columna: si una fuente no trae un campo (p.ej. card_status en el simulador) la
# columna queda 100 % vacía, y sin tipo declarado BigQuery no puede registrarla.
SILVER_TYPES = {
    **{c: "string" for c in SILVER_COLUMNS},
    "event_ts": "datetime64[ns]",
    "amount": "float64", "fx_rate_usd": "float64", "amount_usd": "float64",
    "is_card_present": "bool", "is_cross_border": "bool", "is_approved": "bool",
    **{c: "boolean" for c in OPTIONAL_BOOL},
}
QUARANTINE_COLUMNS = ["transaction_id", "reject_reasons", "raw_payload", "source_system", "_source_file", "_ingest_ts"]


def _dedupe(df: pd.DataFrame, metrics: dict) -> pd.DataFrame:
    """El mismo transaction_id reenviado se conserva una sola vez (el primero en llegar)."""
    df = df.sort_values("_ingest_ts", kind="stable")
    dup = df["transaction_id"].notna() & df.duplicated(subset=["transaction_id"], keep="first")
    metrics["duplicates_removed"] = int(dup.sum())
    return df[~dup].reset_index(drop=True)


def _split(df: pd.DataFrame, rules: dict[str, pd.Series], metrics: dict) -> tuple[pd.DataFrame, pd.DataFrame]:
    checks = pd.DataFrame({k: m.fillna(False).astype(bool) for k, m in rules.items()}, index=df.index)
    rejected = checks.any(axis=1)
    bad = df[rejected]
    quarantine = pd.DataFrame(
        {
            "transaction_id": bad["transaction_id"].astype("string"),
            "reject_reasons": join_flags(checks[rejected]),
            "raw_payload": bad["_raw"].map(mask_pans),  # nunca PAN en claro fuera de Bronze
            "source_system": bad["source_system"],
            "_source_file": bad["_source_file"],
            "_ingest_ts": bad["_ingest_ts"].astype("string"),
        }
    )
    metrics["rejected_records"] = int(rejected.sum())
    metrics["rejected_by_reason"] = {k: int(v) for k, v in checks.sum().items() if v}
    return df[~rejected].copy(), quarantine.reset_index(drop=True)


def _finalize(ok: pd.DataFrame, metrics: dict) -> pd.DataFrame:
    """Columnas derivadas comunes a todas las fuentes y orden/tipos canónicos."""
    ok["event_ts"] = ok["event_ts_parsed"].dt.tz_convert("UTC").dt.tz_localize(None)
    ok["txn_date"] = ok["event_ts"].dt.strftime("%Y-%m-%d")
    ok["amount"] = ok["amount_num"].astype(float)
    ok["amount_usd"] = (ok["amount"] * ok["fx_rate_usd"]).round(2)
    ok["is_card_present"] = ok["entry_mode"].isin(ref.CARD_PRESENT_MODES)
    ok["is_cross_border"] = ok["card_country"] != ok["merchant_country"]
    ok["is_approved"] = ok["response_code"] == "00"
    for col in SILVER_COLUMNS:
        if col not in ok.columns:
            ok[col] = None
    silver = ok[SILVER_COLUMNS].astype(SILVER_TYPES).reset_index(drop=True)
    metrics["silver_records"] = len(silver)
    metrics["approval_rate"] = round(float(np.mean(silver["is_approved"])) if len(silver) else 0.0, 4)
    return silver


def _empty() -> tuple[pd.DataFrame, pd.DataFrame]:
    return pd.DataFrame(columns=SILVER_COLUMNS), pd.DataFrame(columns=QUARANTINE_COLUMNS)


# --- Fuente 1: simulador de adquirentes ------------------------------------------------------

def transform(raw: list[dict], pan_secret: str) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    metrics = {"source_system": "simulator", "bronze_records": len(raw)}
    if not raw:
        return (*_empty(), metrics)

    df = pd.DataFrame(raw)
    for col in REQUIRED + ["acquirer_id", "card_product", "card_country", "mcc", "merchant_country", "entry_mode",
                           "response_code", "_batch_id", "_ingest_ts", "_parse_error", "_raw", "_source_file"]:
        if col not in df.columns:
            df[col] = None
    df["source_system"] = "simulator"
    df = _dedupe(df, metrics)

    # Tipado
    df["amount_num"] = pd.to_numeric(df["amount"].map(parse_amount), errors="coerce")
    df["event_ts_parsed"] = pd.to_datetime(df["event_ts"], utc=True, errors="coerce", format="ISO8601")
    df["pan"] = df["pan"].astype("object").where(df["pan"].notna(), None)
    df["pan_bin"] = df["pan"].map(lambda p: p[:6] if isinstance(p, str) else None)

    # Enriquecimiento con datos de referencia
    df = df.merge(ref.build_merchants()[["merchant_id", "merchant_name"]], on="merchant_id", how="left")
    df = df.merge(ref.issuers_frame()[["pan_bin", "issuer_id", "issuer_name"]], on="pan_bin", how="left")
    df = df.merge(ref.mcc_frame()[["mcc", "mcc_category"]], on="mcc", how="left")
    df["fx_rate_usd"] = df["currency"].map(ref.FX_TO_USD)

    ok, quarantine = _split(df, {
        "malformed_json": df["_parse_error"].fillna(False).astype(bool),
        "missing_required_field": df[REQUIRED].isna().any(axis=1),
        "invalid_pan_luhn": df["pan"].notna() & ~df["pan"].map(lambda p: isinstance(p, str) and luhn_is_valid(p)),
        "unparseable_amount": df["amount"].notna() & df["amount_num"].isna(),
        "non_positive_amount": df["amount_num"].notna() & (df["amount_num"] <= 0),
        "unknown_currency": df["currency"].notna() & df["fx_rate_usd"].isna(),
        "invalid_timestamp": df["event_ts"].notna() & df["event_ts_parsed"].isna(),
        "unknown_merchant": df["merchant_id"].notna() & df["merchant_name"].isna(),
        "unknown_issuer_bin": df["pan_bin"].notna() & df["issuer_id"].isna(),
    }, metrics)

    ok["pan_token"] = ok["pan"].map(lambda p: tokenize_pan(p, pan_secret))
    ok["pan_last4"] = ok["pan"].str[-4:]  # el PAN en claro NO pasa a Silver
    return _finalize(ok, metrics), quarantine, metrics


# --- Fuente 2: sistema core (sample_data/mastercard_db_ficticia.json o réplica Datastream) ---

ENTRY_MODE_MAP = {"contactless": "CONTACTLESS", "online": "ECOMMERCE", "chip": "CHIP", "banda": "MAGSTRIPE"}


def transform_core_snapshot(
    snapshot: dict, source_file: str, ingest_ts: str, channel: str = "file_snapshot"
) -> tuple[pd.DataFrame, pd.DataFrame, dict]:
    """channel indica cómo llegó el dato: 'file_snapshot' (extracto JSON) o 'datastream_cdc' (réplica Datastream)."""
    txns = snapshot.get("transacciones") or []
    metrics = {"source_system": "core", "channel": channel, "bronze_records": len(txns)}
    if not txns:
        return (*_empty(), metrics)

    fx = {**ref.FX_TO_USD, **snapshot.get("metadata", {}).get("tipos_cambio_ficticios_a_usd", {})}
    issuers = pd.DataFrame(snapshot.get("emisores", [])).rename(columns={"emisor_id": "issuer_id", "nombre": "issuer_name"})
    merchants = pd.DataFrame(snapshot.get("comercios", [])).rename(columns={"comercio_id": "merchant_id", "nombre": "merchant_name"})
    cards = pd.DataFrame(snapshot.get("tarjetas", [])).rename(columns={"token_tarjeta": "pan_token", "estado": "card_status"})
    cards["pan_bin"] = cards["bin"]
    cards["pan_last4"] = cards["pan_enmascarado"].str[-4:]
    cards["card_product"] = cards["producto"].str.upper()

    df = pd.DataFrame(txns).rename(columns={
        "transaccion_id": "transaction_id", "fecha_hora": "event_ts", "token_tarjeta": "pan_token",
        "comercio_id": "merchant_id", "emisor_id": "issuer_id", "adquirente_id": "acquirer_id",
        "monto": "amount", "moneda": "currency", "pais_emisor": "card_country", "pais_comercio": "merchant_country",
        "pais_ip": "ip_country", "wallet": "is_wallet", "autenticacion_3ds": "is_3ds_authenticated",
        "codigo_respuesta": "response_code", "fraude_confirmado": "fraud_confirmed", "contracargo": "chargeback",
    })
    df["_raw"] = [json.dumps(t, ensure_ascii=False) for t in txns]
    df["_source_file"], df["_ingest_ts"], df["_batch_id"] = source_file, ingest_ts, channel
    df["source_system"] = "core"
    df = _dedupe(df, metrics)

    df["amount_num"] = pd.to_numeric(df["amount"].map(parse_amount), errors="coerce")
    # El core entrega hora local sin zona; se asume America/Santiago y se normaliza a UTC
    local = pd.to_datetime(df["event_ts"], errors="coerce", format="ISO8601")
    df["event_ts_parsed"] = local.dt.tz_localize("America/Santiago", ambiguous="NaT", nonexistent="shift_forward")
    df["entry_mode"] = df["modo_entrada"].map(ENTRY_MODE_MAP)
    df["fx_rate_usd"] = df["currency"].map(fx)
    df = df.merge(issuers[["issuer_id", "issuer_name"]], on="issuer_id", how="left")
    df = df.merge(merchants[["merchant_id", "merchant_name"]], on="merchant_id", how="left")
    df = df.merge(cards[["pan_token", "pan_bin", "pan_last4", "card_product", "card_status"]], on="pan_token", how="left")
    df = df.merge(ref.mcc_frame()[["mcc", "mcc_category"]], on="mcc", how="left")

    ok, quarantine = _split(df, {
        "missing_required_field": df[["transaction_id", "event_ts", "pan_token", "merchant_id", "amount", "currency"]].isna().any(axis=1),
        "unparseable_amount": df["amount"].notna() & df["amount_num"].isna(),
        "non_positive_amount": df["amount_num"].notna() & (df["amount_num"] <= 0),
        "unknown_currency": df["currency"].notna() & df["fx_rate_usd"].isna(),
        "invalid_timestamp": df["event_ts"].notna() & df["event_ts_parsed"].isna(),
        "unknown_merchant": df["merchant_id"].notna() & df["merchant_name"].isna(),
        "unknown_card_token": df["pan_token"].notna() & df["card_product"].isna(),
        "unknown_entry_mode": df["entry_mode"].isna(),
        "usd_amount_mismatch": (df["amount_num"] * df["fx_rate_usd"]).round(2).sub(df["monto_usd"]).abs() > 0.011,
    }, metrics)
    return _finalize(ok, metrics), quarantine, metrics


def reconcile_core_snapshot(snapshot: dict, silver_core: pd.DataFrame) -> pd.DataFrame:
    """Compara los totales que declara la fuente (metricas_resumen) con lo que quedó en Silver."""
    reported = snapshot.get("metricas_resumen", {})
    s = silver_core
    approved = s[s["is_approved"]]
    computed = {
        "transacciones_procesadas": len(s),
        "transacciones_aprobadas": len(approved),
        "gdv_usd": round(float(approved["amount_usd"].sum()), 2),
        "volumen_cross_border_usd": round(float(approved.loc[approved["is_cross_border"], "amount_usd"].sum()), 2),
        "fraudes_confirmados": int(s["fraud_confirmed"].fillna(False).sum()),
        "contracargos": int(s["chargeback"].fillna(False).sum()),
    }
    rows = []
    for metric, value in computed.items():
        rep = reported.get(metric)
        diff = None if rep is None else round(value - rep, 2)
        ok = rep is not None and abs(diff) <= max(0.01, abs(rep) * 0.0005)
        rows.append({"metric": metric, "reported": rep, "computed": value, "diff": diff,
                     "status": "OK" if ok else ("MISSING" if rep is None else "MISMATCH")})
    return pd.DataFrame(rows).astype({"reported": "float64", "computed": "float64", "diff": "float64"})


# --- Réplica Datastream (backfill + CDC) -> mismo formato que el extracto ---------------------

CORE_PRIMARY_KEYS = {
    "emisores": "emisor_id",
    "adquirentes": "adquirente_id",
    "comercios": "comercio_id",
    "tarjetas": "token_tarjeta",
    "transacciones": "transaccion_id",
}
CORE_BOOL_COLUMNS = {"wallet", "cross_border", "autenticacion_3ds", "alerta_fraude", "fraude_confirmado",
                     "contracargo", "tokenizada_wallet"}
CORE_TS_COLUMNS = {"fecha_hora"}
CORE_NUMERIC_COLUMNS = {"monto", "monto_usd"}
CORE_DROP_COLUMNS = {"actualizado_en"}  # columna técnica de la base, no es parte del extracto
_TEXT_BOOL = {"true": True, "t": True, "1": True, "false": False, "f": False, "0": False}


def _plain(value):
    """Convierte tipos de pandas/numpy/Decimal a tipos JSON nativos (NA -> None)."""
    if value is None or (not isinstance(value, (str, bytes)) and pd.isna(value)):
        return None
    if isinstance(value, pd.Timestamp):
        return value.strftime("%Y-%m-%dT%H:%M:%S")
    if hasattr(value, "item"):  # numpy scalar
        return value.item()
    if type(value).__name__ == "Decimal":
        return float(value)
    return value


def _to_bool(value):
    """Booleanos como llegan: true/false de JSON o texto ('t', 'true'...), según la versión del conector."""
    if value is None or isinstance(value, bool):
        return value
    if not isinstance(value, str) and pd.isna(value):
        return None
    return _TEXT_BOOL.get(str(value).strip().lower())


def _core_ts(value):
    """TIMESTAMP de PostgreSQL: texto ISO-8601 (con o sin zona) o microsegundos epoch.

    La columna no tiene zona horaria: se conserva la hora "de pared" (el adaptador del core la interpreta
    como America/Santiago), por eso se quita la zona sin convertir.
    """
    if value is None:
        return None
    if isinstance(value, (int, float)) and not isinstance(value, bool):
        ts = pd.Timestamp(int(value), unit="us")
    else:
        ts = pd.Timestamp(str(value))
    if ts.tzinfo is not None:
        ts = ts.tz_localize(None)
    return ts.strftime("%Y-%m-%dT%H:%M:%S")


def _core_number(value):
    """NUMERIC llega como número o como texto (para no perder precisión)."""
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        return None


def _normalize_core(column: str, value):
    if column in CORE_BOOL_COLUMNS:
        return _to_bool(value)
    if column in CORE_TS_COLUMNS:
        return _core_ts(value)
    if column in CORE_NUMERIC_COLUMNS:
        return _core_number(value)
    return _plain(value)


def _lsn(value) -> int:
    """LSN de PostgreSQL ('16/B374D848') como número, para ordenar cambios con la misma marca de tiempo."""
    try:
        high, low = str(value).split("/")
        return (int(high, 16) << 32) | int(low, 16)
    except (ValueError, AttributeError):
        return -1


def _event_order(event: dict) -> tuple:
    meta = event.get("source_metadata") or {}
    ts = event.get("source_timestamp")
    when = pd.Timestamp(ts, unit="ms") if isinstance(ts, (int, float)) else pd.Timestamp(ts or 0)
    return (when.tz_localize(None) if when.tzinfo else when), _lsn(meta.get("lsn"))


def datastream_to_snapshot(events: list[dict]) -> dict:
    """Aplica backfill + CDC de Datastream: por clave primaria gana el último cambio; los borrados eliminan.

    Cada línea de los JSONL que escribe Datastream en Bronze trae la fila completa en `payload` y en
    `source_metadata` la tabla, el tipo de cambio (INSERT / UPDATE / DELETE), `is_deleted` y el LSN.
    `source_timestamp` es el momento del cambio en la base: ordena backfill y CDC en una sola historia.
    """
    snapshot: dict = {"metadata": {"origen": "datastream"}}
    by_table: dict[str, list[dict]] = {}
    for ev in events:
        table = (ev.get("source_metadata") or {}).get("table") or str(ev.get("object", "")).split("_", 1)[-1]
        if table in CORE_PRIMARY_KEYS:
            by_table.setdefault(table, []).append(ev)

    for table, pk in CORE_PRIMARY_KEYS.items():
        latest: dict = {}
        for ev in sorted(by_table.get(table, []), key=_event_order):
            row = ev.get("payload") or {}
            key = row.get(pk)
            if key is None:
                continue
            meta = ev.get("source_metadata") or {}
            if meta.get("is_deleted") or str(meta.get("change_type", "")).upper() == "DELETE":
                latest.pop(key, None)
            else:
                latest[key] = row
        snapshot[table] = [
            {k: _normalize_core(k, v) for k, v in row.items() if k not in CORE_DROP_COLUMNS}
            for row in latest.values()
        ]
    return snapshot
