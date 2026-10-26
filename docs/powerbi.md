# Power BI sobre la capa Gold

Power BI Desktop trae un conector nativo de **Google BigQuery**: no hace falta instalar drivers ni configurar DSN.

## Conexión

1. *Obtener datos → Google BigQuery → Conectar*.
2. *Iniciar sesión* con una cuenta de Google que esté en `analyst_members` o `consultant_members`
   ([`variables.tf`](../infra/platform/variables.tf)). Esa cuenta recibe `paylakeLayerReader` sólo sobre los
   datasets con la etiqueta `layer = gold`, más `paylakeBigQueryJobRunner` (consultas y Storage Read API).
3. En el navegador, abrir **`paylake_dev_reports`** y elegir `daily_merchant_kpis`, `interchange_settlement`,
   `fraud_alerts`, `cross_border_corridors`, `fraud_rule_performance`, `card_monthly_segments`.

`paylake_dev_reports` tiene una **vista** por cada tabla de Gold. Las tablas del lake son externas (BigLake sobre
los Parquet de Cloud Storage) y el navegador del conector **no lista tablas externas**: por eso `paylake_dev_gold`
aparece vacío. Las vistas llevan la misma etiqueta `layer = gold`, así que un analista las lee igual que Gold y
sigue sin ver Silver ni Bronze. Las de las tablas de Spark las crea Terraform; las del pipeline, la function
`silver-to-gold` al registrar cada tabla.

Con la opción *Usar la API de Storage* activada, Power BI lee con la Storage Read API (rápida); por eso el rol
incluye `bigquery.readsessions.*`.

## Consultas y medidas

- [`powerbi/queries.pq`](../powerbi/queries.pq): Power Query M con una consulta nativa (`Value.NativeQuery`) sobre
  Gold y el tipado de columnas.
- [`powerbi/measures.dax`](../powerbi/measures.dax): medidas DAX del modelo (volumen, % de
  aprobación, intercambio, tasa efectiva, promedio móvil de 7 días, alertas de alto riesgo, % transfronterizo).

## Por qué no una llave de cuenta de servicio

El conector también acepta una cuenta de servicio con su llave JSON. No se usa: sería una credencial de larga
duración en el PC de cada analista. Con el inicio de sesión de Google cada persona entra con su cuenta y el
acceso se quita sacándola de la lista y aplicando Terraform.
