"""Simulador de archivos de transacciones enviados por adquirentes (fuente de la capa Bronze).

Genera autorizaciones de tarjeta ficticias e inyecta a propósito problemas reales de datos
(duplicados, nulos, montos con coma decimal, PAN inválidos, monedas desconocidas) y patrones
de fraude (ráfagas de velocidad y "viaje imposible") para que Silver y Gold tengan trabajo que hacer.
"""
from __future__ import annotations

import random
import uuid
from datetime import datetime, timedelta, timezone

from . import reference as ref
from .quality import luhn_check_digit


def build_card_pool(n: int = 3000, seed: int = 11) -> list[dict]:
    rng = random.Random(seed)
    bins = list(ref.ISSUERS)
    cards = []
    for _ in range(n):
        bin_ = rng.choice(bins)
        body = bin_ + "".join(rng.choice("0123456789") for _ in range(9))
        cards.append(
            {
                "pan": body + luhn_check_digit(body),
                "card_product": rng.choices(ref.CARD_PRODUCTS, ref.CARD_PRODUCT_WEIGHTS)[0],
                "card_country": ref.ISSUERS[bin_][2],
            }
        )
    return cards


def _local_amount(rng: random.Random, mcc: str, currency: str) -> float:
    usd = rng.lognormvariate(0, 0.6) * ref.MCC[mcc][2]
    local = usd / ref.FX_TO_USD[currency]
    decimals = 0 if currency in {"CLP", "COP"} else 2
    return round(local, decimals)


def _iso(ts: datetime) -> str:
    return ts.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"


def generate_batch(
    n: int,
    window_start: datetime,
    window_end: datetime,
    seed: int | None = None,
    anomaly_rate: float = 0.04,
    fraud_cards: int = 3,
) -> list[dict]:
    rng = random.Random(seed)
    merchants = ref.build_merchants().to_dict("records")
    by_country: dict[str, list[dict]] = {}
    for m in merchants:
        by_country.setdefault(m["merchant_country"], []).append(m)
    cards = build_card_pool()
    span = (window_end - window_start).total_seconds()

    def make(card: dict, merchant: dict, ts: datetime, entry_mode: str | None = None) -> dict:
        currency = ref.COUNTRY_CURRENCY[merchant["merchant_country"]]
        return {
            "transaction_id": str(uuid.UUID(int=rng.getrandbits(128))),
            "event_ts": _iso(ts),
            "acquirer_id": merchant["acquirer_id"],
            "pan": card["pan"],
            "card_product": card["card_product"],
            "card_country": card["card_country"],
            "merchant_id": merchant["merchant_id"],
            "mcc": merchant["mcc"],
            "merchant_country": merchant["merchant_country"],
            "amount": _local_amount(rng, merchant["mcc"], currency),
            "currency": currency,
            "entry_mode": entry_mode or rng.choices(ref.ENTRY_MODES, ref.ENTRY_MODE_WEIGHTS)[0],
            "response_code": rng.choices(ref.RESPONSE_CODES, ref.RESPONSE_CODE_WEIGHTS)[0],
            "schema_version": "1.0",
        }

    records = []
    for _ in range(n):
        card = rng.choice(cards)
        # ~88% de las compras son domésticas (comercio en el país de la tarjeta)
        if rng.random() < 0.88 and card["card_country"] in by_country:
            merchant = rng.choice(by_country[card["card_country"]])
        else:
            merchant = rng.choice(merchants)
        ts = window_start + timedelta(seconds=rng.random() * span)
        records.append(make(card, merchant, ts))

    # Patrones de fraude
    for _ in range(fraud_cards):
        card = rng.choice(cards)
        t0 = window_start + timedelta(seconds=rng.random() * max(span - 900, 1))
        ecommerce = [m for m in merchants if m["mcc"] in {"5732", "5999", "5311"}]
        for k in range(rng.randint(5, 8)):  # ráfaga de velocidad: varias compras e-commerce en minutos
            records.append(make(card, rng.choice(ecommerce), t0 + timedelta(seconds=40 * k), "ECOMMERCE"))
        far = rng.choice([c for c in by_country if c != card["card_country"]])
        records.append(make(card, rng.choice(by_country[card["card_country"]]), t0 + timedelta(minutes=12), "CHIP"))
        records.append(make(card, rng.choice(by_country[far]), t0 + timedelta(minutes=35), "CHIP"))  # viaje imposible

    # Problemas de calidad de datos
    dirty = []
    for rec in records:
        if rng.random() >= anomaly_rate:
            continue
        issue = rng.choice(["duplicate", "null_merchant", "comma_amount", "bad_pan", "bad_currency", "negative", "bad_ts"])
        if issue == "duplicate":
            dirty.append(dict(rec))  # reenvío del mismo mensaje
        elif issue == "null_merchant":
            rec["merchant_id"] = None
        elif issue == "comma_amount":
            rec["amount"] = f"{rec['amount']:,.2f}".replace(",", "X").replace(".", ",").replace("X", ".")
        elif issue == "bad_pan":
            rec["pan"] = rec["pan"][:-1] + str((int(rec["pan"][-1]) + 1) % 10)
        elif issue == "bad_currency":
            rec["currency"] = "XXX"
        elif issue == "negative":
            rec["amount"] = -abs(float(rec["amount"]))
        elif issue == "bad_ts":
            rec["event_ts"] = "31/02/2026 25:61"
    records.extend(dirty)
    rng.shuffle(records)
    return records


def new_batch_id() -> str:
    return datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S") + "-" + uuid.uuid4().hex[:8]
