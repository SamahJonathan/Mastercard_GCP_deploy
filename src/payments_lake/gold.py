"""Capa Gold: productos de datos listos para negocio y para intercambio con terceros.

- daily_merchant_kpis      -> desempeño por comercio (volumen, aprobación, ticket medio)
- interchange_settlement   -> tarifa de intercambio adeudada adquirente -> emisor (liquidación)
- fraud_alerts             -> transacciones sospechosas según reglas (velocidad, viaje imposible, IP, 3DS...)
- fraud_rule_performance   -> precision / recall de cada regla contra fraudes confirmados
- cross_border_corridors   -> flujos entre país de la tarjeta y país del comercio
"""
from __future__ import annotations

import hashlib
import io
import json

import numpy as np
import pandas as pd

from . import reference as ref
from .quality import join_flags

VELOCITY_WINDOW = "10min"
VELOCITY_THRESHOLD = 5
TRAVEL_WINDOW_MIN = 60
HIGH_TICKET_ECOM_USD = 1500


def _flag(values) -> np.ndarray:
    """Condición como array de bool de numpy, con NA = False.

    Al leer Silver desde Parquet llegan tipos anulables ('string', 'boolean'): comparar con un valor vacío
    da NA, y combinar NA con & falla ("boolean value of NA is ambiguous"). Cada condición se normaliza
    ANTES de combinarla. Test: tests/test_gold_nullable_types.py (bug real: el pipeline fallaba en silver_to_gold).
    """
    series = values if isinstance(values, pd.Series) else pd.Series(values)
    return series.astype("boolean").fillna(False).to_numpy(dtype=bool)


def daily_merchant_kpis(silver: pd.DataFrame) -> pd.DataFrame:
    s = silver.assign(approved_usd=silver["amount_usd"].where(_flag(silver["is_approved"]), 0.0))
    g = (
        s.groupby(["txn_date", "merchant_id", "merchant_name", "mcc", "mcc_category", "merchant_country"], as_index=False)
        .agg(
            txn_count=("transaction_id", "count"),
            approved_count=("is_approved", "sum"),
            gross_amount_usd=("approved_usd", "sum"),
        )
    )
    g["approved_count"] = g["approved_count"].astype("int64")
    g["approval_rate"] = (g["approved_count"] / g["txn_count"]).round(4)
    g["avg_ticket_usd"] = (g["gross_amount_usd"] / g["approved_count"].replace(0, np.nan)).round(2).fillna(0.0)
    g["gross_amount_usd"] = g["gross_amount_usd"].round(2)
    return g


def interchange_rate(df: pd.DataFrame) -> pd.Series:
    """Tasa porcentual según producto, categoría MCC, canal y si es transfronteriza (tabla ficticia)."""
    base = df["card_product"].map({k: v[0] for k, v in ref.INTERCHANGE_BASE.items()})
    adj = df["mcc_category"].map(ref.CATEGORY_ADJ).fillna(0.0)
    ecom = np.where(_flag(df["entry_mode"] == "ECOMMERCE"), ref.ECOMMERCE_ADJ, 0.0)
    xb = np.where(_flag(df["is_cross_border"]), ref.CROSS_BORDER_ADJ, 0.0)
    return base + adj + ecom + xb


def with_interchange(silver: pd.DataFrame) -> pd.DataFrame:
    approved = silver[_flag(silver["is_approved"])].copy()
    fixed = approved["card_product"].map({k: v[1] for k, v in ref.INTERCHANGE_BASE.items()})
    approved["interchange_rate"] = interchange_rate(approved)
    approved["interchange_fee_usd"] = (approved["amount_usd"] * approved["interchange_rate"] + fixed).round(4)
    return approved


def interchange_settlement(silver: pd.DataFrame) -> pd.DataFrame:
    a = with_interchange(silver)
    g = a.groupby(["txn_date", "issuer_id", "issuer_name", "acquirer_id"], as_index=False).agg(
        txn_count=("transaction_id", "count"),
        amount_usd=("amount_usd", "sum"),
        interchange_fee_usd=("interchange_fee_usd", "sum"),
        cross_border_count=("is_cross_border", "sum"),
    )
    g["cross_border_count"] = g["cross_border_count"].astype("int64")
    g["effective_rate"] = (g["interchange_fee_usd"] / g["amount_usd"]).round(5)
    g["amount_usd"] = g["amount_usd"].round(2)
    g["interchange_fee_usd"] = g["interchange_fee_usd"].round(2)
    return g


def fraud_alerts(silver: pd.DataFrame) -> pd.DataFrame:
    s = silver.sort_values(["pan_token", "event_ts"], kind="stable").reset_index(drop=True)
    # Regla 1: velocidad -> N o más intentos con la misma tarjeta en una ventana deslizante de 10 minutos
    counts = s.assign(one=1).set_index("event_ts").groupby("pan_token", sort=True)["one"].rolling(VELOCITY_WINDOW).sum()
    s["txn_count_10m"] = counts.to_numpy().astype("int64")
    # Regla 2: viaje imposible -> dos compras presenciales en países distintos con menos de 60 minutos de diferencia
    prev = s.groupby("pan_token")[["event_ts", "merchant_country", "is_card_present"]].shift(1)
    minutes = (s["event_ts"] - prev["event_ts"]).dt.total_seconds() / 60
    s["impossible_travel"] = (
        _flag(s["is_card_present"])
        & _flag(prev["is_card_present"])
        & _flag(prev["merchant_country"].notna())
        & _flag(s["merchant_country"] != prev["merchant_country"])
        & _flag(minutes <= TRAVEL_WINDOW_MIN)
    )
    ecom = _flag(s["entry_mode"] == "ECOMMERCE")
    # Regla 3: ticket alto en comercio electrónico
    s["high_ticket_ecom"] = ecom & _flag(s["amount_usd"] >= HIGH_TICKET_ECOM_USD)
    # Regla 4: compra online desde una IP de un país distinto al de la tarjeta (sólo si la fuente informa IP)
    ip = s["ip_country"] if "ip_country" in s else pd.Series(None, index=s.index, dtype="object")
    s["ip_country_mismatch"] = ecom & _flag(ip.notna()) & _flag(ip != s["card_country"])
    # Regla 5: compra online sin autenticación 3DS (sólo si la fuente informa 3DS)
    three_ds = s["is_3ds_authenticated"] if "is_3ds_authenticated" in s else pd.Series(pd.NA, index=s.index, dtype="boolean")
    s["ecom_without_3ds"] = ecom & _flag(three_ds.astype("boolean").eq(False))

    s["velocity"] = _flag(s["txn_count_10m"] >= VELOCITY_THRESHOLD)
    flags = s[list(RULE_WEIGHTS)].fillna(False).astype(bool)
    s["risk_score"] = np.minimum(100, sum(flags[r] * w for r, w in RULE_WEIGHTS.items()))
    s["fraud_confirmed"] = s["fraud_confirmed"].astype("boolean") if "fraud_confirmed" in s else pd.NA
    alerts = s[flags.any(axis=1)].copy()
    alerts["rules"] = join_flags(flags[flags.any(axis=1)])
    cols = ["txn_date", "transaction_id", "event_ts", "pan_token", "pan_last4", "issuer_id", "merchant_id",
            "merchant_country", "entry_mode", "amount_usd", "txn_count_10m", "rules", "risk_score", "fraud_confirmed"]
    return alerts[cols].reset_index(drop=True)


RULE_WEIGHTS = {"velocity": 40, "impossible_travel": 50, "high_ticket_ecom": 30, "ip_country_mismatch": 35, "ecom_without_3ds": 20}


def fraud_rule_performance(silver: pd.DataFrame, alerts: pd.DataFrame) -> pd.DataFrame:
    """Precision / recall de cada regla contra fraude_confirmado (sólo transacciones con etiqueta)."""
    if "fraud_confirmed" not in silver:
        return pd.DataFrame()
    labeled = silver[silver["fraud_confirmed"].notna()]
    if labeled.empty:
        return pd.DataFrame()
    frauds = set(labeled.loc[_flag(labeled["fraud_confirmed"]), "transaction_id"])
    labeled_alerts = alerts[alerts["transaction_id"].isin(set(labeled["transaction_id"]))]
    rows = []
    for rule in [*RULE_WEIGHTS, "any_rule"]:
        hit = labeled_alerts if rule == "any_rule" else labeled_alerts[labeled_alerts["rules"].str.split(",").map(lambda r: rule in r)]
        flagged = set(hit["transaction_id"])
        tp = len(flagged & frauds)
        rows.append({
            "rule": rule,
            "labeled_txns": len(labeled),
            "confirmed_frauds": len(frauds),
            "flagged": len(flagged),
            "true_positives": tp,
            "precision": round(tp / len(flagged), 4) if flagged else None,
            "recall": round(tp / len(frauds), 4) if frauds else None,
        })
    return pd.DataFrame(rows).astype({"precision": "float64", "recall": "float64"})


def cross_border_corridors(silver: pd.DataFrame) -> pd.DataFrame:
    xb = silver[_flag(silver["is_cross_border"]) & _flag(silver["is_approved"])]
    return xb.groupby(["txn_date", "card_country", "merchant_country"], as_index=False).agg(
        txn_count=("transaction_id", "count"), amount_usd=("amount_usd", "sum")
    ).round({"amount_usd": 2})


def issuer_settlement_files(settlement: pd.DataFrame) -> list[tuple[str, str, str, str]]:
    """Archivos de salida para cada emisor (intercambio de datos B2B): CSV + manifiesto con checksum.

    Devuelve tuplas (issuer_id, settlement_date, csv_text, manifest_json).
    """
    out = []
    for (issuer_id, date), part in settlement.groupby(["issuer_id", "txn_date"]):
        buf = io.StringIO()
        part.drop(columns=["issuer_name"]).to_csv(buf, index=False, lineterminator="\n")
        csv_text = buf.getvalue()
        manifest = {
            "issuer_id": issuer_id,
            "settlement_date": date,
            "file": "settlement.csv",
            "record_count": int(len(part)),
            "total_amount_usd": round(float(part["amount_usd"].sum()), 2),
            "total_interchange_fee_usd": round(float(part["interchange_fee_usd"].sum()), 2),
            "sha256": hashlib.sha256(csv_text.encode("utf-8")).hexdigest(),
            "schema_version": "1.0",
        }
        out.append((issuer_id, date, csv_text, json.dumps(manifest, indent=2)))
    return out
