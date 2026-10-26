-- Top comercios por volumen junto a sus alertas de fraude
WITH kpis AS (
  SELECT merchant_id, merchant_name, mcc_category, merchant_country,
         SUM(gross_amount_usd) AS volume_usd, SUM(txn_count) AS txns,
         ROUND(SAFE_DIVIDE(SUM(approved_count), SUM(txn_count)), 4) AS approval_rate
  FROM `${project}.${gold_ds}.daily_merchant_kpis`
  GROUP BY 1, 2, 3, 4
),
alerts AS (
  SELECT merchant_id, COUNT(*) AS fraud_alerts, MAX(risk_score) AS max_risk
  FROM `${project}.${gold_ds}.fraud_alerts`
  GROUP BY 1
)
SELECT k.*, COALESCE(a.fraud_alerts, 0) AS fraud_alerts, a.max_risk
FROM kpis k LEFT JOIN alerts a ON k.merchant_id = a.merchant_id
ORDER BY volume_usd DESC
LIMIT 25;
