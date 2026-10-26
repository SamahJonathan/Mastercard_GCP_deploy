-- Distribución del ticket por producto de tarjeta y canal (percentiles aproximados).
-- Requiere acceso a Silver (cuenta risk-analyst)
SELECT card_product,
       entry_mode,
       COUNT(*)                                                AS approved_txns,
       ROUND(APPROX_QUANTILES(amount_usd, 100)[OFFSET(50)], 2) AS p50_usd,
       ROUND(APPROX_QUANTILES(amount_usd, 100)[OFFSET(90)], 2) AS p90_usd,
       ROUND(APPROX_QUANTILES(amount_usd, 100)[OFFSET(99)], 2) AS p99_usd,
       ROUND(MAX(amount_usd), 2)                               AS max_usd
FROM `${project}.${silver_ds}.transactions`
WHERE is_approved
GROUP BY card_product, entry_mode
ORDER BY card_product, p90_usd DESC;
