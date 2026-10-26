# Power BI sobre la capa Gold

Power BI Desktop trae un conector nativo de **Google BigQuery**: no hace falta instalar drivers ni configurar DSN.

## Conexión

1. *Obtener datos → Google BigQuery → Conectar*.
2. *Iniciar sesión* con una cuenta de Google que esté en `analyst_members` o `consultant_members`
   ([`variables.tf`](../infra/platform/variables.tf)). Esa cuenta recibe `paylakeLayerReader` sólo sobre los
   datasets con la etiqueta `layer = gold`, más `paylakeBigQueryJobRunner` (consultas y Storage Read API).
3. En el navegador aparecen el proyecto y **sólo** el dataset `paylake_dev_gold`: Silver y Bronze no se ven.
4. Elegir `daily_merchant_kpis`, `interchange_settlement`, `fraud_alerts`, `cross_border_corridors`,
   `fraud_rule_performance`, `card_monthly_segments`.

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
