-- Tasa de aprobación diaria y promedio móvil de 7 días (window frame) con variación vs. día anterior
WITH daily AS (
  SELECT txn_date,
         SUM(txn_count)        AS txns,
         SUM(approved_count)   AS approved,
         SUM(gross_amount_usd) AS gross_usd
  FROM `${project}.${gold_ds}.daily_merchant_kpis`
  GROUP BY txn_date
)
SELECT txn_date,
       txns,
       ROUND(approved / txns, 4)                                                                    AS approval_rate,
       ROUND(AVG(approved / txns) OVER (ORDER BY txn_date ROWS BETWEEN 6 PRECEDING AND CURRENT ROW), 4) AS approval_rate_7d,
       ROUND(gross_usd, 2)                                                                          AS gross_usd,
       ROUND(gross_usd - LAG(gross_usd) OVER (ORDER BY txn_date), 2)                                AS gross_delta_vs_prev_day,
       ROUND(SUM(gross_usd) OVER (PARTITION BY SUBSTR(txn_date, 1, 7) ORDER BY txn_date), 2)         AS gross_month_to_date
FROM daily
ORDER BY txn_date DESC;
