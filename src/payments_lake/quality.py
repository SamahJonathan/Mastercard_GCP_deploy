"""Reglas de calidad de datos y utilidades de protección de PAN (PCI DSS)."""
from __future__ import annotations

import hashlib
import hmac
import re


def luhn_is_valid(pan: str) -> bool:
    if not pan or not pan.isdigit() or not 12 <= len(pan) <= 19:
        return False
    total = 0
    for i, ch in enumerate(reversed(pan)):
        d = int(ch)
        if i % 2 == 1:
            d *= 2
            if d > 9:
                d -= 9
        total += d
    return total % 10 == 0


def luhn_check_digit(partial: str) -> str:
    """Dígito verificador para que partial + dígito sea Luhn-válido."""
    for d in "0123456789":
        if luhn_is_valid(partial + d):
            return d
    raise ValueError(partial)


def tokenize_pan(pan: str, secret: str) -> str:
    """Token irreversible y estable (HMAC-SHA256): permite agrupar por tarjeta sin guardar el PAN."""
    return hmac.new(secret.encode(), pan.encode(), hashlib.sha256).hexdigest()


def parse_amount(value) -> float | None:
    """Acepta 1234.5, "1234.5" y el formato latino "1.234,50". Devuelve None si no se puede parsear."""
    if value is None:
        return None
    if isinstance(value, bool):
        return None
    if isinstance(value, (int, float)):
        return float(value)
    s = str(value).strip()
    if not s:
        return None
    if "," in s:
        s = s.replace(".", "").replace(",", ".")
    try:
        return float(s)
    except ValueError:
        return None


_PAN_RE = re.compile(r"(?<!\d)(\d{6})\d{2,9}(\d{4})(?!\d)")


def mask_pans(text: str) -> str:
    """Enmascara cualquier secuencia tipo PAN (12-19 dígitos) dejando BIN y últimos 4: 510510******1234."""
    return _PAN_RE.sub(lambda m: m.group(1) + "*" * (len(m.group(0)) - 10) + m.group(2), text)


def join_flags(flags: "pd.DataFrame") -> "pd.Series":
    """Por fila, une con comas los nombres de las columnas booleanas en True (seguro con DataFrames vacíos)."""
    import pandas as pd

    cols = flags.columns.to_numpy()
    return pd.Series([",".join(cols[row]) for row in flags.to_numpy(dtype=bool)], index=flags.index, dtype=object)
