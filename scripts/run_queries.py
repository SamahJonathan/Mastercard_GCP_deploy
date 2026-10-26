#!/usr/bin/env python3
"""Ejecuta las consultas de sql/ en BigQuery.

    python scripts/run_queries.py                                   # todas, con tu identidad
    python scripts/run_queries.py --only 03 10                      # algunas
    python scripts/run_queries.py --as analyst --expect-denied 01 02 08 09
                                   # como la cuenta analyst: lo de Silver/Bronze debe quedar DENEGADO

Cada consulta lleva un tope de bytes facturados (--max-bytes, 1 GB por defecto). Sólo usa la librería estándar y el CLI bq (Google Cloud SDK).
Sale con 0 si cada consulta terminó como se esperaba (OK o DENEGADA cuando así se pidió).
"""
from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DENIED = re.compile(r"Access Denied|permission|PERMISSION_DENIED|403", re.IGNORECASE)


def render(sql: str, project: str, prefix: str) -> str:
    values = {"project": project, "bronze_ds": f"{prefix}_bronze", "silver_ds": f"{prefix}_silver", "gold_ds": f"{prefix}_gold"}
    return re.sub(r"\$\{(\w+)\}", lambda m: values[m.group(1)], sql)


def queries(only: list[str]) -> list[Path]:
    files = sorted((ROOT / "sql").rglob("*.sql"), key=lambda p: p.name)
    return [f for f in files if not only or f.name[:2] in only]


def run(sql: str, project: str, max_bytes: int, impersonate: str | None) -> tuple[bool, str, int]:
    """Devuelve (ok, detalle, filas)."""
    env = dict(os.environ)
    if impersonate:
        env["CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT"] = impersonate
    cmd = [shutil.which("bq") or "bq", f"--project_id={project}", "--format=json", "--quiet", "query",
           "--use_legacy_sql=false", f"--maximum_bytes_billed={max_bytes}", "--max_rows=1000"]
    proc = subprocess.run(cmd, input=sql, capture_output=True, text=True, encoding="utf-8", errors="replace", env=env)
    if proc.returncode != 0:
        # bq parte el mensaje en líneas de 80 columnas: se une para no cortar "Access Denied" a la mitad
        lines = [ln.strip() for ln in (proc.stdout + proc.stderr).splitlines() if ln.strip() and not ln.startswith("WARNING")]
        msg = " ".join(lines).replace("- ", "-")
        return False, msg[msg.find("rror") - 1:] if "rror" in msg else (msg or "error"), 0
    try:
        rows = json.loads(proc.stdout or "[]")
    except json.JSONDecodeError:
        rows = []
    return True, "", len(rows)


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("--project", default=os.getenv("GCP_PROJECT_ID"))
    p.add_argument("--prefix", default="paylake_dev", help="prefijo de los datasets (<prefix>_bronze, _silver, _gold)")
    p.add_argument("--only", nargs="*", default=[], help="números de consulta, p.ej. 03 10")
    p.add_argument("--as", dest="as_identity", help="nombre de la cuenta (analyst, risk-analyst...) a impersonar")
    p.add_argument("--expect-denied", nargs="*", default=[], help="consultas que DEBEN fallar por permisos")
    p.add_argument("--max-bytes", type=int, default=1 << 30)
    args = p.parse_args(argv)
    if not args.project:
        p.error("falta --project (o la variable GCP_PROJECT_ID)")

    impersonate = f"paylake-dev-{args.as_identity}@{args.project}.iam.gserviceaccount.com" if args.as_identity else None
    who = args.as_identity or "tu identidad"
    failures = 0
    print(f"Consultas en {args.project} como {who}\n")
    for f in queries(args.only):
        ok, detail, rows = run(render(f.read_text(encoding="utf-8"), args.project, args.prefix), args.project,
                               args.max_bytes, impersonate)
        expect_denied = f.name[:2] in args.expect_denied
        if expect_denied:
            good = not ok and bool(DENIED.search(detail))
            status = "DENEGADA (esperado)" if good else ("PERMITIDA (¡debía negarse!)" if ok else f"ERROR: {detail[:120]}")
        else:
            good = ok
            status = f"OK  {rows} filas" if ok else f"ERROR: {detail[:160]}"
        failures += not good
        print(f"  {'✔' if good else '✘'} {f.name:<42} {status}")
    print(f"\n{'Todo como se esperaba' if not failures else f'{failures} consulta(s) no coinciden con lo esperado'}.")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
