# Looker Studio

Looker Studio es gratis y lee BigQuery directo; no tiene recursos de Terraform, así que se arma desde la web.

1. [lookerstudio.google.com](https://lookerstudio.google.com) → *Crear → Fuente de datos → BigQuery*.
2. Proyecto `paylake-gcp-xxxx` → dataset `paylake_dev_gold` → tabla (`daily_merchant_kpis`, `interchange_settlement`…).
3. *Credenciales de la fuente*: **credenciales del lector** (*viewer's credentials*). Cada persona ve sólo lo que su
   cuenta puede leer en BigQuery: un analista ve Gold y nada más, igual que en Power BI. Con *credenciales del
   propietario* todos verían con los permisos de quien creó la fuente.
4. Campos sugeridos: `txn_date` como fecha (AAAA-MM-DD), `gross_amount_usd` y `interchange_fee_usd` como moneda USD.

Tablas pensadas para Looker Studio:

| Tabla | Gráfico |
|---|---|
| `daily_merchant_kpis` | serie de tiempo de volumen y % de aprobación; top comercios |
| `interchange_settlement` | intercambio por emisor (barras) |
| `cross_border_corridors` | mapa o matriz país de tarjeta × país de comercio |
| `fraud_rule_performance` | tabla de precision / recall por regla |
| `card_monthly_segments` | mezcla de segmentos por emisor (barras apiladas) |
| `dq_results` | semáforo de calidad de datos por regla y día |
