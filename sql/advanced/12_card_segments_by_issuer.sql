-- Mezcla de segmentos de tarjetas por emisor (salida del job de Spark) con pivote por agregación condicional
SELECT month, issuer_id,
       COUNT(*)                           AS cards,
       COUNTIF(segment = 'high_value')    AS high_value,
       COUNTIF(segment = 'digital_first') AS digital_first,
       COUNTIF(segment = 'regular')       AS regular,
       COUNTIF(segment = 'occasional')    AS occasional,
       ROUND(SAFE_DIVIDE(SUM(IF(segment = 'high_value', spend_usd, 0)), SUM(spend_usd)), 4) AS high_value_spend_share
FROM `${project}.${gold_ds}.card_monthly_segments`
GROUP BY month, issuer_id
ORDER BY month DESC, cards DESC;
