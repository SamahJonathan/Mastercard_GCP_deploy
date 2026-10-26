"""Dataproc Serverless (PySpark, runtime 2.2): calidad de datos sobre Silver + analítica Gold con Spark SQL.

Corre una vez al día (workflow gold-analytics). Las Cloud Run functions cubren el pipeline horario de bajo
volumen; este job muestra el camino de escala: misma capa Silver, motor distribuido.

Salidas (Parquet en GCS; las tablas BigLake las define Terraform en infra/platform/bigquery.tf):
  - card_monthly_segments  : comportamiento mensual por tarjeta + segmentación con NTILE / PERCENT_RANK
  - merchant_daily_trends  : promedio móvil 7 días, ranking y participación dentro de su categoría
  - dq_results             : resultado de cada regla de calidad sobre Silver, una partición por día

El job NO toca BigQuery: escribe sólo archivos, así el esquema queda versionado en Terraform y la cuenta
de Spark no necesita permisos sobre el catálogo. Los tipos se fijan con CAST para que coincidan.
"""
import argparse
import json
from datetime import datetime, timezone

from pyspark.sql import SparkSession

p = argparse.ArgumentParser()
p.add_argument("--silver-path", required=True)
p.add_argument("--gold-path", required=True)
args = p.parse_args()

spark = SparkSession.builder.appName("paylake-gold-card-analytics").getOrCreate()

# Lectura directa de Silver (descubre las particiones source_system / txn_date)
silver = spark.read.parquet(args.silver_path)
silver.createOrReplaceTempView("silver_tx")

# --- 1) Calidad de datos: reglas declarativas sobre Silver -------------------------------------
CURRENCIES = ["CLP", "ARS", "BRL", "PEN", "COP", "MXN", "USD", "EUR"]
ENTRY_MODES = ["CHIP", "CONTACTLESS", "ECOMMERCE", "MAGSTRIPE"]


def in_list(values):
    return ", ".join(f"'{v}'" for v in values)


# (regla, columna, filas que fallan, umbral de cumplimiento: 1.0 = todas deben pasar)
RULES = [
    ("IsComplete", "transaction_id", "transaction_id IS NULL", 1.0),
    ("IsUnique", "transaction_id", None, 1.0),
    ("IsComplete", "pan_token", "pan_token IS NULL", 1.0),
    ("IsComplete", "event_ts", "event_ts IS NULL", 1.0),
    ("ColumnValues > 0", "amount_usd", "NOT (amount_usd > 0)", 1.0),
    ("ColumnValues in", "currency", f"currency NOT IN ({in_list(CURRENCIES)})", 1.0),
    ("ColumnValues in", "entry_mode", f"entry_mode NOT IN ({in_list(ENTRY_MODES)})", 1.0),
    ("ColumnLength = 4", "pan_last4", "length(pan_last4) <> 4", 1.0),
    ("Completeness > 0.99", "issuer_id", "issuer_id IS NULL", 0.99),
    ("ColumnValues matches [0-9]{2}", "response_code", "NOT (response_code RLIKE '^[0-9]{2}$')", 1.0),
]
checks = ",\n".join(
    f"CAST(SUM(CASE WHEN {cond} THEN 1 ELSE 0 END) AS BIGINT) AS r{i}" for i, (_, _, cond, _) in enumerate(RULES) if cond
)
stats = spark.sql(f"""
    SELECT CAST(COUNT(*) AS BIGINT) AS total_rows,
           CAST(COUNT(*) - COUNT(DISTINCT transaction_id) AS BIGINT) AS duplicated_ids,
           {checks}
    FROM silver_tx
""").first()

total = stats["total_rows"]
evaluated_at = datetime.now(timezone.utc)
results = [("RowCount > 0", "*", "PASS" if total > 0 else "FAIL", 0 if total > 0 else 1, total, float(total), 0.0, evaluated_at)]
for i, (rule, column, cond, threshold) in enumerate(RULES):
    failed = stats["duplicated_ids"] if cond is None else stats[f"r{i}"]
    observed = 1 - failed / total if total else 0.0
    outcome = "PASS" if total and observed >= threshold else "FAIL"
    results.append((rule, column, outcome, int(failed), total, round(observed, 6), threshold, evaluated_at))

for r in results:
    # Un log estructurado por regla: Cloud Logging lo indexa y una FAIL queda como WARNING
    print(json.dumps({"severity": "WARNING" if r[2] == "FAIL" else "INFO", "message": "paylake dq",
                      "dq": {"rule": r[0], "column": r[1], "outcome": r[2], "failed_rows": r[3], "total_rows": r[4]}}))

dq = spark.createDataFrame(
    results,
    "rule STRING, column_name STRING, outcome STRING, failed_rows BIGINT, total_rows BIGINT, "
    "observed DOUBLE, threshold DOUBLE, evaluated_at TIMESTAMP",
).selectExpr("*", f"'{evaluated_at.date().isoformat()}' AS run_date")
# Sólo se reemplaza la partición del día: el historial de ejecuciones se conserva
dq.write.mode("overwrite").option("partitionOverwriteMode", "dynamic").partitionBy("run_date").parquet(f"{args.gold_path}/dq_results/")

# --- 2) Analítica Gold con Spark SQL --------------------------------------------------------
spark.sql("""
    SELECT date_format(event_ts, 'yyyy-MM')                                    AS month,
           pan_token,
           issuer_id,
           CAST(COUNT(*) AS BIGINT)                                                     AS txn_count,
           CAST(SUM(CASE WHEN is_approved THEN 1 ELSE 0 END) AS BIGINT)                 AS approved_count,
           CAST(ROUND(SUM(CASE WHEN is_approved THEN amount_usd ELSE 0 END), 2) AS DOUBLE) AS spend_usd,
           CAST(COUNT(DISTINCT merchant_id) AS BIGINT)                                  AS distinct_merchants,
           CAST(COUNT(DISTINCT txn_date) AS BIGINT)                                     AS active_days,
           CAST(ROUND(AVG(CASE WHEN is_cross_border THEN 1.0 ELSE 0.0 END), 4) AS DOUBLE)  AS cross_border_share,
           CAST(ROUND(AVG(CASE WHEN entry_mode = 'ECOMMERCE' THEN 1.0 ELSE 0.0 END), 4) AS DOUBLE) AS ecommerce_share
    FROM silver_tx
    GROUP BY date_format(event_ts, 'yyyy-MM'), pan_token, issuer_id
""").createOrReplaceTempView("card_monthly")

card_segments = spark.sql("""
    WITH ranked AS (
        SELECT *,
               CAST(NTILE(4) OVER (PARTITION BY month ORDER BY spend_usd) AS BIGINT)    AS spend_quartile,
               CAST(ROUND(PERCENT_RANK() OVER (PARTITION BY month, issuer_id ORDER BY spend_usd), 4) AS DOUBLE) AS spend_pct_rank_in_issuer
        FROM card_monthly
    )
    SELECT *,
           CASE WHEN spend_quartile = 4 AND active_days >= 3 THEN 'high_value'
                WHEN ecommerce_share >= 0.8                 THEN 'digital_first'
                WHEN active_days = 1                        THEN 'occasional'
                ELSE 'regular' END AS segment
    FROM ranked
""")

merchant_trends = spark.sql("""
    WITH daily AS (
        SELECT CAST(txn_date AS STRING) AS txn_date, merchant_id, merchant_name, mcc_category,
               CAST(COUNT(*) AS BIGINT)                                                        AS txn_count,
               CAST(ROUND(SUM(CASE WHEN is_approved THEN amount_usd ELSE 0 END), 2) AS DOUBLE) AS gross_usd
        FROM silver_tx
        GROUP BY txn_date, merchant_id, merchant_name, mcc_category
    )
    SELECT *,
           CAST(ROUND(AVG(gross_usd) OVER (PARTITION BY merchant_id ORDER BY txn_date
                                           ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 2) AS DOUBLE) AS gross_usd_7d_avg,
           CAST(RANK() OVER (PARTITION BY txn_date, mcc_category ORDER BY gross_usd DESC) AS BIGINT) AS rank_in_category,
           CAST(ROUND(gross_usd / NULLIF(SUM(gross_usd) OVER (PARTITION BY txn_date, mcc_category), 0), 4) AS DOUBLE) AS share_of_category,
           CAST(ROUND(gross_usd - LAG(gross_usd) OVER (PARTITION BY merchant_id ORDER BY txn_date), 2) AS DOUBLE)   AS delta_vs_prev_day
    FROM daily
""")

# Recalculo diario idempotente: se reemplazan las particiones recalculadas (todas las que tiene Silver).
# Con overwrite "dynamic" no se borra la carpeta entera: así sobrevive el marcador de 0 filas que
# BigQuery necesita para que la tabla exista antes de la primera ejecución (scripts/make_placeholders.py).
for name, df, partition in [
    ("card_monthly_segments", card_segments, "month"),
    ("merchant_daily_trends", merchant_trends, "txn_date"),
]:
    df.write.mode("overwrite").option("partitionOverwriteMode", "dynamic").partitionBy(partition).parquet(f"{args.gold_path}/{name}/")

failed_rules = [r for r in results if r[2] == "FAIL"]
print(json.dumps({"severity": "INFO", "message": "paylake gold-analytics terminado",
                  "rows": total, "dq_failed_rules": len(failed_rules)}))
spark.stop()
