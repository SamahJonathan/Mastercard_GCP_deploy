-- Reconciliación por día: cuántos registros llegaron a Bronze vs. cuántos quedaron en Silver y en cuarentena.
-- Lee Bronze: sólo la puede ejecutar quien ya puede leer el bucket (ningún analista).
WITH bronze AS (
  SELECT SUBSTR(event_ts, 1, 10) AS txn_date, COUNT(*) AS bronze_rows, COUNT(DISTINCT transaction_id) AS bronze_unique
  FROM `${project}.${bronze_ds}.transactions`
  WHERE ingest_date >= FORMAT_DATE('%F', DATE_SUB(CURRENT_DATE(), INTERVAL 3 DAY))
  GROUP BY 1
),
silver AS (
  SELECT txn_date, COUNT(*) AS silver_rows
  FROM `${project}.${silver_ds}.transactions`
  GROUP BY 1
)
SELECT b.txn_date, b.bronze_rows, b.bronze_unique, s.silver_rows,
       b.bronze_unique - COALESCE(s.silver_rows, 0) AS rejected_or_quarantined
FROM bronze b LEFT JOIN silver s ON b.txn_date = s.txn_date
ORDER BY b.txn_date DESC;
