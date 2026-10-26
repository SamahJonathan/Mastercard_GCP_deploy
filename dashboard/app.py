"""Dashboard de la capa Gold (Streamlit).

Fuente de datos:
  - API en GCP:  GOLD_API_URL=https://paylake-dev-api-xxxx.southamerica-east1.run.app  GOLD_API_KEY=...
  - Local:       DATA_ROOT=data (lee los Parquet que deja `python -m payments_lake.pipeline demo`)

    streamlit run dashboard/app.py
"""
from __future__ import annotations

import hmac
import os

import pandas as pd
import requests
import streamlit as st

API_URL = os.getenv("GOLD_API_URL", "").rstrip("/")
API_KEY = os.getenv("GOLD_API_KEY", "")
DATA_ROOT = os.getenv("DATA_ROOT", "data")
PASSWORD = os.getenv("DASHBOARD_PASSWORD", "")  # en Cloud Run viene de Secret Manager

st.set_page_config(page_title="Payments Lakehouse", layout="wide")

# Acceso con contraseña: sin ella no se carga ningún dato (en local, sin DASHBOARD_PASSWORD, no se pide)
if PASSWORD and not st.session_state.get("authenticated"):
    st.title("Payments Lakehouse")
    attempt = st.text_input("Contraseña", type="password")
    if attempt and hmac.compare_digest(attempt.encode(), PASSWORD.encode()):
        st.session_state["authenticated"] = True
        st.rerun()
    elif attempt:
        st.error("Contraseña incorrecta")
    st.stop()


@st.cache_data(ttl=300)
def available_dates() -> list[str]:
    if API_URL:
        r = requests.get(f"{API_URL}/dates", headers={"x-api-key": API_KEY}, timeout=30)
        r.raise_for_status()
        return r.json()
    base = os.path.join(DATA_ROOT, "gold", "interchange_settlement")
    return sorted(d.split("=", 1)[1] for d in os.listdir(base)) if os.path.isdir(base) else []


@st.cache_data(ttl=300)
def load(table: str, day: str | None = None) -> pd.DataFrame:
    if API_URL:
        params = {"date": day, "limit": 5000} if day else {}
        r = requests.get(f"{API_URL}/gold/{table}", params=params, headers={"x-api-key": API_KEY}, timeout=30)
        r.raise_for_status()
        return pd.DataFrame(r.json()["rows"])
    path = os.path.join(DATA_ROOT, "gold", table, f"txn_date={day}" if day else "")
    return pd.read_parquet(path) if os.path.isdir(path) else pd.DataFrame()


st.title("Payments Lakehouse · capa Gold")
st.caption(f"Fuente: {'API de Gold' if API_URL else 'local ' + DATA_ROOT} · datos 100% sintéticos")

dates = available_dates()
if not dates:
    st.warning("No hay datos en Gold todavía. Ejecuta el pipeline primero.")
    st.stop()
day = st.sidebar.selectbox("Fecha de transacción", dates[::-1])

kpis = load("daily_merchant_kpis", day)
settlement = load("interchange_settlement", day)
alerts = load("fraud_alerts", day)
corridors = load("cross_border_corridors", day)

c1, c2, c3, c4 = st.columns(4)
c1.metric("Transacciones", f"{int(kpis['txn_count'].sum()):,}")
c2.metric("Volumen aprobado (USD)", f"{kpis['gross_amount_usd'].sum():,.0f}")
c3.metric("Tasa de aprobación", f"{kpis['approved_count'].sum() / kpis['txn_count'].sum():.1%}")
c4.metric("Intercambio (USD)", f"{settlement['interchange_fee_usd'].sum():,.0f}")

left, right = st.columns(2)
with left:
    st.subheader("Intercambio por emisor")
    st.bar_chart(settlement.groupby("issuer_name")["interchange_fee_usd"].sum().sort_values())
with right:
    st.subheader("Volumen por categoría MCC")
    st.bar_chart(kpis.groupby("mcc_category")["gross_amount_usd"].sum().sort_values())

st.subheader(f"Alertas de fraude ({len(alerts)})")
if not alerts.empty:
    st.dataframe(alerts.sort_values("risk_score", ascending=False), width="stretch", hide_index=True)

st.subheader("Desempeño de reglas de fraude vs. fraudes confirmados")
st.caption("Calculado sobre las transacciones con etiqueta (fuente core). Todas las fechas.")
perf = load("fraud_rule_performance")
if not perf.empty:
    st.dataframe(perf, width="stretch", hide_index=True)

st.subheader("Corredores transfronterizos")
if not corridors.empty:
    st.dataframe(corridors.sort_values("amount_usd", ascending=False), width="stretch", hide_index=True)

st.subheader("Top comercios")
st.dataframe(kpis.sort_values("gross_amount_usd", ascending=False).head(20), width="stretch", hide_index=True)
