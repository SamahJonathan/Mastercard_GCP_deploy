-- Cohortes: tarjetas agrupadas por su primer mes de uso y % que vuelve a transar en los meses siguientes
WITH activity AS (
  SELECT DISTINCT pan_token, DATE_TRUNC(DATE(event_ts), MONTH) AS month
  FROM `${project}.${silver_ds}.transactions`
  WHERE is_approved
),
first_seen AS (
  SELECT pan_token, MIN(month) AS cohort_month FROM activity GROUP BY pan_token
),
cohort_activity AS (
  SELECT f.cohort_month, DATE_DIFF(a.month, f.cohort_month, MONTH) AS month_offset, COUNT(DISTINCT a.pan_token) AS cards
  FROM activity a JOIN first_seen f ON a.pan_token = f.pan_token
  GROUP BY 1, 2
)
SELECT cohort_month, month_offset, cards,
       ROUND(cards / FIRST_VALUE(cards) OVER (PARTITION BY cohort_month ORDER BY month_offset), 4) AS retention
FROM cohort_activity
ORDER BY cohort_month, month_offset;
