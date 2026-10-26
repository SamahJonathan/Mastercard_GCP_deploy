-- Intercambio adeudado a cada emisor (lo que pagan los adquirentes), últimos 7 días
SELECT issuer_name,
       SUM(txn_count)                                                         AS approved_txns,
       ROUND(SUM(amount_usd), 2)                                              AS volume_usd,
       ROUND(SUM(interchange_fee_usd), 2)                                     AS interchange_usd,
       ROUND(SAFE_DIVIDE(SUM(interchange_fee_usd), SUM(amount_usd)) * 100, 3) AS effective_rate_pct
FROM `${project}.${gold_ds}.interchange_settlement`
WHERE txn_date >= FORMAT_DATE('%F', DATE_SUB(CURRENT_DATE(), INTERVAL 7 DAY))
GROUP BY issuer_name
ORDER BY interchange_usd DESC;
