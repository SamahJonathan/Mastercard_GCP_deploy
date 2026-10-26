-- Motivos de rechazo de calidad de datos
SELECT reason, COUNT(*) AS records
FROM `${project}.${silver_ds}.quarantine`
CROSS JOIN UNNEST(SPLIT(reject_reasons, ',')) AS reason
GROUP BY reason
ORDER BY records DESC;
