#!/usr/bin/env python3
"""Genera SQL para el "core bancario" en PostgreSQL (Cloud SQL), fuente que Datastream replica a Bronze.

Sólo usa la librería estándar: corre en la VM de carga (Compute Engine) sin instalar paquetes de Python.

    python3 load_core_db.py init snapshot.json | psql -v ON_ERROR_STOP=1      # esquema + carga inicial
    python3 load_core_db.py cdc  snapshot.json --new 25 | psql -v ON_ERROR_STOP=1  # actividad nueva (CDC)
"""
from __future__ import annotations

import argparse
import json
import random
import uuid
from datetime import datetime, timedelta

SCHEMA = """
CREATE SCHEMA IF NOT EXISTS core;

CREATE TABLE IF NOT EXISTS core.emisores (
    emisor_id   TEXT PRIMARY KEY,
    nombre      TEXT NOT NULL,
    pais        CHAR(2) NOT NULL,
    tipo        TEXT
);
CREATE TABLE IF NOT EXISTS core.adquirentes (
    adquirente_id TEXT PRIMARY KEY,
    nombre        TEXT NOT NULL,
    pais          CHAR(2) NOT NULL
);
CREATE TABLE IF NOT EXISTS core.comercios (
    comercio_id      TEXT PRIMARY KEY,
    nombre           TEXT NOT NULL,
    mcc              CHAR(4) NOT NULL,
    categoria        TEXT,
    pais             CHAR(2) NOT NULL,
    ciudad           TEXT,
    adquirente_id    TEXT REFERENCES core.adquirentes,
    canal            TEXT,
    fecha_afiliacion DATE
);
CREATE TABLE IF NOT EXISTS core.tarjetas (
    token_tarjeta     TEXT PRIMARY KEY,
    pan_enmascarado   TEXT NOT NULL,
    bin               CHAR(6) NOT NULL,
    producto          TEXT,
    tipo              TEXT,
    emisor_id         TEXT REFERENCES core.emisores,
    pais_emisor       CHAR(2),
    fecha_emision     DATE,
    estado            TEXT,
    tokenizada_wallet BOOLEAN
);
CREATE TABLE IF NOT EXISTS core.transacciones (
    transaccion_id        TEXT PRIMARY KEY,
    fecha_hora            TIMESTAMP NOT NULL,
    token_tarjeta         TEXT REFERENCES core.tarjetas,
    comercio_id           TEXT REFERENCES core.comercios,
    mcc                   CHAR(4),
    emisor_id             TEXT,
    adquirente_id         TEXT,
    monto                 NUMERIC(14, 2) NOT NULL,
    moneda                CHAR(3) NOT NULL,
    monto_usd             NUMERIC(14, 2),
    modo_entrada          TEXT,
    wallet                BOOLEAN,
    pais_emisor           CHAR(2),
    pais_comercio         CHAR(2),
    cross_border          BOOLEAN,
    pais_ip               CHAR(2),
    autenticacion_3ds     BOOLEAN,
    resultado             TEXT,
    codigo_respuesta      CHAR(2),
    descripcion_respuesta TEXT,
    score_riesgo          INTEGER,
    alerta_fraude         BOOLEAN,
    fraude_confirmado     BOOLEAN,
    contracargo           BOOLEAN,
    actualizado_en        TIMESTAMP NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS ix_transacciones_fecha ON core.transacciones (fecha_hora);

-- Datastream lee el WAL con replicación lógica (flag cloudsql.logical_decoding=on en la instancia).
-- En Cloud SQL los miembros de cloudsqlsuperuser pueden darse el atributo REPLICATION.
ALTER ROLE CURRENT_USER WITH REPLICATION;
"""

# Publicación y slot que nombra el stream de Datastream (infra/platform/datastream.tf)
PUBLICATION = "paylake_pub"
REPLICATION_SLOT = "paylake_slot"

# Fuera de la transacción de carga: un slot lógico no se puede crear en una transacción que ya escribió
REPLICATION = f"""
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_publication WHERE pubname = '{PUBLICATION}') THEN
        CREATE PUBLICATION {PUBLICATION} FOR TABLES IN SCHEMA core;
    END IF;
END $$;
SELECT pg_create_logical_replication_slot('{REPLICATION_SLOT}', 'pgoutput')
WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name = '{REPLICATION_SLOT}');
"""

TABLES = [
    ("emisores", ["emisor_id", "nombre", "pais", "tipo"]),
    ("adquirentes", ["adquirente_id", "nombre", "pais"]),
    ("comercios", ["comercio_id", "nombre", "mcc", "categoria", "pais", "ciudad", "adquirente_id", "canal", "fecha_afiliacion"]),
    ("tarjetas", ["token_tarjeta", "pan_enmascarado", "bin", "producto", "tipo", "emisor_id", "pais_emisor",
                  "fecha_emision", "estado", "tokenizada_wallet"]),
    ("transacciones", ["transaccion_id", "fecha_hora", "token_tarjeta", "comercio_id", "mcc", "emisor_id", "adquirente_id",
                       "monto", "moneda", "monto_usd", "modo_entrada", "wallet", "pais_emisor", "pais_comercio",
                       "cross_border", "pais_ip", "autenticacion_3ds", "resultado", "codigo_respuesta",
                       "descripcion_respuesta", "score_riesgo", "alerta_fraude", "fraude_confirmado", "contracargo"]),
]
PRIMARY_KEYS = {"emisores": "emisor_id", "adquirentes": "adquirente_id", "comercios": "comercio_id",
                "tarjetas": "token_tarjeta", "transacciones": "transaccion_id"}


def literal(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, bool):
        return "TRUE" if value else "FALSE"
    if isinstance(value, (int, float)):
        return repr(value)
    return "'" + str(value).replace("'", "''") + "'"


def insert_sql(table: str, columns: list[str], rows: list[dict]) -> str:
    if not rows:
        return ""
    values = ",\n".join("(" + ", ".join(literal(r.get(c)) for c in columns) + ")" for r in rows)
    return (f"INSERT INTO core.{table} ({', '.join(columns)}) VALUES\n{values}\n"
            f"ON CONFLICT ({PRIMARY_KEYS[table]}) DO NOTHING;\n")


def init_sql(snapshot: dict) -> str:
    parts = [SCHEMA, "BEGIN;"]
    for table, columns in TABLES:
        parts.append(insert_sql(table, columns, snapshot.get(table, [])))
    parts.append("COMMIT;")
    parts.append(REPLICATION)
    return "\n".join(parts)


def cdc_sql(snapshot: dict, new: int, now: datetime | None = None, seed: int | None = None) -> str:
    """Actividad nueva para que Datastream la capture como CDC: compras recientes + cambios en compras antiguas."""
    rng = random.Random(seed)
    now = now or datetime.utcnow()
    fx = snapshot.get("metadata", {}).get("tipos_cambio_ficticios_a_usd", {"USD": 1.0})
    cards = [c for c in snapshot["tarjetas"] if c.get("estado") == "activa"]
    merchants = snapshot["comercios"]
    templates = snapshot["transacciones"]
    rows = []
    for _ in range(new):
        card, merchant, tpl = rng.choice(cards), rng.choice(merchants), rng.choice(templates)
        currency = tpl["moneda"] if tpl["pais_comercio"] == merchant["pais"] else rng.choice(sorted(fx))
        amount = round(max(1.0, tpl["monto_usd"] * rng.uniform(0.5, 1.8)) / fx.get(currency, 1.0), 2)
        approved = rng.random() < 0.95
        online = merchant.get("canal") == "online"
        rows.append({
            "transaccion_id": "TXC" + uuid.UUID(int=rng.getrandbits(128)).hex[:12].upper(),
            "fecha_hora": (now - timedelta(seconds=rng.randint(0, 900))).strftime("%Y-%m-%dT%H:%M:%S"),
            "token_tarjeta": card["token_tarjeta"], "comercio_id": merchant["comercio_id"], "mcc": merchant["mcc"],
            "emisor_id": card["emisor_id"], "adquirente_id": merchant["adquirente_id"],
            "monto": amount, "moneda": currency, "monto_usd": round(amount * fx.get(currency, 1.0), 2),
            "modo_entrada": "online" if online else rng.choice(["contactless", "chip"]),
            "wallet": bool(card.get("tokenizada_wallet")) and rng.random() < 0.4,
            "pais_emisor": card["pais_emisor"], "pais_comercio": merchant["pais"],
            "cross_border": card["pais_emisor"] != merchant["pais"],
            "pais_ip": card["pais_emisor"] if online else None,
            "autenticacion_3ds": (rng.random() < 0.85) if online else None,
            "resultado": "aprobada" if approved else "rechazada",
            "codigo_respuesta": "00" if approved else rng.choice(["05", "51", "54"]),
            "descripcion_respuesta": "Aprobada" if approved else "Rechazada",
            "score_riesgo": rng.randint(50, 700), "alerta_fraude": False,
            "fraude_confirmado": False, "contracargo": False,
        })
    columns = dict(TABLES)["transacciones"]
    sql = ["BEGIN;", insert_sql("transacciones", columns, rows)]
    # Cambios tardíos sobre compras existentes: un contracargo y un fraude confirmado (UPDATE -> CDC 'U')
    old = rng.sample(templates, k=min(2, len(templates)))
    sql.append(f"UPDATE core.transacciones SET contracargo = TRUE, actualizado_en = now() "
               f"WHERE transaccion_id = {literal(old[0]['transaccion_id'])};")
    if len(old) > 1:
        sql.append(f"UPDATE core.transacciones SET fraude_confirmado = TRUE, alerta_fraude = TRUE, actualizado_en = now() "
                   f"WHERE transaccion_id = {literal(old[1]['transaccion_id'])};")
    sql.append("COMMIT;")
    return "\n".join(sql)


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=["init", "cdc"])
    p.add_argument("snapshot")
    p.add_argument("--new", type=int, default=25)
    args = p.parse_args()
    with open(args.snapshot, encoding="utf-8") as fh:
        snapshot = json.load(fh)
    print(init_sql(snapshot) if args.mode == "init" else cdc_sql(snapshot, args.new))


if __name__ == "__main__":
    main()
