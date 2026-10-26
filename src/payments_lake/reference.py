"""Datos de referencia ficticios: emisores, comercios, MCC, tipos de cambio y tabla de intercambio.

Todos los bancos, comercios, tasas y BINs son inventados para fines de demostración.
"""
from __future__ import annotations

import random

import pandas as pd

# Prefijos BIN de 6 dígitos (rango 51-55, formato Mastercard) -> emisor ficticio
# Los emisores coinciden con los de sample_data/mastercard_db_ficticia.json para que ambas fuentes compartan universo.
ISSUERS = {
    "510510": ("EM001", "Banco Andino (ficticio)", "CL"),
    "520082": ("EM002", "Banco del Pacífico Sur (ficticio)", "CL"),
    "540176": ("EM003", "Cooperativa Cordillera (ficticio)", "CL"),
    "512345": ("EM004", "FinTech Cóndor (ficticio)", "CL"),
    "530125": ("EM005", "Banco Río Plata (ficticio)", "AR"),
    "550692": ("EM006", "Banco Inca (ficticio)", "PE"),
}

ACQUIRERS = {
    "CL": "ACQ-CL-01",
    "AR": "ACQ-AR-01",
    "BR": "ACQ-BR-01",
    "PE": "ACQ-PE-01",
    "CO": "ACQ-CO-01",
    "MX": "ACQ-MX-01",
    "US": "ACQ-US-01",
    "ES": "ACQ-ES-01",
}

COUNTRY_CURRENCY = {
    "CL": "CLP", "AR": "ARS", "BR": "BRL", "PE": "PEN",
    "CO": "COP", "MX": "MXN", "US": "USD", "ES": "EUR",
}

# Tipos de cambio ficticios: 1 unidad de moneda local = X USD
FX_TO_USD = {
    "CLP": 0.00105, "ARS": 0.001, "BRL": 0.18, "PEN": 0.27,
    "COP": 0.00025, "MXN": 0.055, "USD": 1.0, "EUR": 1.08,
}

# MCC -> (descripción, categoría, ticket medio en USD)
MCC = {
    "5411": ("Supermercados", "everyday", 45.0),
    "5541": ("Estaciones de servicio", "everyday", 38.0),
    "5812": ("Restaurantes", "dining", 32.0),
    "5814": ("Comida rapida", "dining", 12.0),
    "5912": ("Farmacias", "everyday", 22.0),
    "5732": ("Electronica", "retail", 280.0),
    "5311": ("Tiendas por departamento", "retail", 95.0),
    "5999": ("Retail miscelaneo", "retail", 40.0),
    "4111": ("Transporte publico", "everyday", 3.0),
    "4814": ("Telecomunicaciones", "services", 30.0),
    "5815": ("Bienes digitales / streaming", "services", 12.0),
    "7011": ("Hoteles", "travel", 180.0),
    "4511": ("Aerolineas", "travel", 420.0),
}

CARD_PRODUCTS = ["DEBIT", "STANDARD", "GOLD", "PLATINUM", "BLACK"]  # + BUSINESS en la fuente core
CARD_PRODUCT_WEIGHTS = [0.40, 0.30, 0.15, 0.10, 0.05]

ENTRY_MODES = ["CHIP", "CONTACTLESS", "ECOMMERCE", "MAGSTRIPE"]
ENTRY_MODE_WEIGHTS = [0.30, 0.40, 0.27, 0.03]
CARD_PRESENT_MODES = {"CHIP", "CONTACTLESS", "MAGSTRIPE"}

# Códigos de respuesta ISO 8583 más comunes
RESPONSE_CODES = ["00", "05", "51", "54", "91"]
RESPONSE_CODE_WEIGHTS = [0.92, 0.03, 0.03, 0.01, 0.01]

_MERCHANT_WORDS = [
    "Andes", "Pacifico", "Sol", "Luna", "Cordillera", "Austral", "Rio", "Valle",
    "Norte", "Sur", "Plaza", "Central", "Mercado", "Express", "Total", "Nova",
]


def build_merchants(n: int = 250, seed: int = 7) -> pd.DataFrame:
    """Comercios deterministas (misma semilla => mismos comercios en local y en GCP)."""
    rng = random.Random(seed)
    countries = list(ACQUIRERS)
    weights = [0.55, 0.08, 0.08, 0.07, 0.05, 0.05, 0.07, 0.05]
    rows = []
    for i in range(1, n + 1):
        mcc = rng.choice(list(MCC))
        country = rng.choices(countries, weights)[0]
        name = f"{rng.choice(_MERCHANT_WORDS)} {rng.choice(_MERCHANT_WORDS)} {MCC[mcc][0].split()[0]}"
        rows.append(
            {
                "merchant_id": f"M{i:06d}",
                "merchant_name": name,
                "mcc": mcc,
                "merchant_country": country,
                "acquirer_id": ACQUIRERS[country],
            }
        )
    return pd.DataFrame(rows)


def issuers_frame() -> pd.DataFrame:
    return pd.DataFrame(
        [
            {"pan_bin": b, "issuer_id": iid, "issuer_name": name, "issuer_country": c}
            for b, (iid, name, c) in ISSUERS.items()
        ]
    )


def mcc_frame() -> pd.DataFrame:
    return pd.DataFrame(
        [{"mcc": k, "mcc_description": d, "mcc_category": cat} for k, (d, cat, _) in MCC.items()]
    )


# --- Tabla de intercambio (ficticia) -------------------------------------------------------
# Tasa base por producto: (porcentaje, fijo en USD)
INTERCHANGE_BASE = {
    "DEBIT": (0.0080, 0.03),
    "STANDARD": (0.0120, 0.05),
    "GOLD": (0.0145, 0.05),
    "PLATINUM": (0.0165, 0.10),
    "BLACK": (0.0190, 0.10),
    "BUSINESS": (0.0200, 0.10),
}
CATEGORY_ADJ = {"everyday": -0.0020, "dining": 0.0, "retail": 0.0, "services": 0.0, "travel": 0.0020}
ECOMMERCE_ADJ = 0.0015
CROSS_BORDER_ADJ = 0.0100
