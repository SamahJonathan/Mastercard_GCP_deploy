-- Calidad de las reglas de fraude: precision, recall, F1 y lift sobre la tasa base de fraude
SELECT rule,
       flagged,
       true_positives,
       precision,
       recall,
       ROUND(SAFE_DIVIDE(2 * precision * recall, precision + recall), 4)            AS f1,
       ROUND(SAFE_DIVIDE(precision, SAFE_DIVIDE(confirmed_frauds, labeled_txns)), 1) AS lift_vs_base_rate
FROM `${project}.${gold_ds}.fraud_rule_performance`
ORDER BY f1 DESC NULLS LAST;
