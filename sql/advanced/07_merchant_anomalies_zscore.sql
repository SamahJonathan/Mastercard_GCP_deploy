-- Detección de anomalías: días en que un comercio se aleja más de 3 desviaciones estándar de su promedio
WITH stats AS (
  SELECT merchant_id, merchant_name, txn_date, gross_amount_usd,
         AVG(gross_amount_usd)         OVER (PARTITION BY merchant_id) AS mean_usd,
         STDDEV_SAMP(gross_amount_usd) OVER (PARTITION BY merchant_id) AS std_usd,
         COUNT(*)                      OVER (PARTITION BY merchant_id) AS days_observed
  FROM `${project}.${gold_ds}.daily_merchant_kpis`
)
SELECT merchant_id, merchant_name, txn_date,
       ROUND(gross_amount_usd, 2)                                            AS gross_usd,
       ROUND(mean_usd, 2)                                                    AS mean_usd,
       ROUND(SAFE_DIVIDE(gross_amount_usd - mean_usd, NULLIF(std_usd, 0)), 2) AS z_score
FROM stats
WHERE days_observed >= 5
  AND ABS(SAFE_DIVIDE(gross_amount_usd - mean_usd, NULLIF(std_usd, 0))) >= 3
ORDER BY ABS(SAFE_DIVIDE(gross_amount_usd - mean_usd, NULLIF(std_usd, 0))) DESC;
