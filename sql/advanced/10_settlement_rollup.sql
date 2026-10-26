-- Liquidación de intercambio con subtotales por emisor y total general (ROLLUP + GROUPING()).
-- GROUPING() recibe una sola columna: el nivel se arma combinando ambas
-- (0 = detalle, 1 = subtotal del emisor, 3 = total general).
WITH rollup_rows AS (
  SELECT issuer_name,
         acquirer_id,
         SUM(txn_count)                                                         AS txns,
         ROUND(SUM(amount_usd), 2)                                              AS volume_usd,
         ROUND(SUM(interchange_fee_usd), 2)                                     AS interchange_usd,
         ROUND(SAFE_DIVIDE(SUM(interchange_fee_usd), SUM(amount_usd)) * 100, 3) AS effective_rate_pct,
         GROUPING(issuer_name) * 2 + GROUPING(acquirer_id)                      AS grouping_level
  FROM `${project}.${gold_ds}.interchange_settlement`
  GROUP BY ROLLUP (issuer_name, acquirer_id)
)
SELECT COALESCE(issuer_name, '== TOTAL ==')                                  AS issuer_name,
       COALESCE(acquirer_id, IF(grouping_level = 1, '-- subtotal --', NULL)) AS acquirer_id,
       txns, volume_usd, interchange_usd, effective_rate_pct, grouping_level
FROM rollup_rows
ORDER BY grouping_level = 3, issuer_name, grouping_level, interchange_usd DESC;
