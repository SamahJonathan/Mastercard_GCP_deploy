-- Corredores transfronterizos: de qué país son las tarjetas y dónde compran
SELECT card_country, merchant_country, SUM(txn_count) AS txns, ROUND(SUM(amount_usd), 2) AS amount_usd
FROM `${project}.${gold_ds}.cross_border_corridors`
GROUP BY 1, 2
ORDER BY amount_usd DESC;
