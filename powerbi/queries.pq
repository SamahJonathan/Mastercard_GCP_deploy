// Power Query M: consultas a BigQuery con el conector nativo (ver docs/powerbi.md).
// Reemplazar el ID del proyecto por el de infra/platform/project.auto.tfvars.
let
    Proyecto = "paylake-gcp-xxxx",
    Fuente = GoogleBigQuery.Database([BillingProject = Proyecto, UseStorageApi = true]),
    // Vistas de Gold para BI: el navegador no lista las tablas externas de paylake_dev_gold
    Reportes = Fuente{[Name = Proyecto]}[Data]{[Name = "paylake_dev_reports", Kind = "Schema"]}[Data],

    Intercambio = Value.NativeQuery(
        Fuente{[Name = Proyecto]}[Data],
        "SELECT txn_date, issuer_name, acquirer_id, txn_count, amount_usd, interchange_fee_usd, effective_rate
         FROM `" & Proyecto & ".paylake_dev_reports.interchange_settlement`
         WHERE txn_date >= FORMAT_DATE('%F', DATE_SUB(CURRENT_DATE(), INTERVAL 30 DAY))",
        null,
        [EnableFolding = true]
    ),

    Tipado = Table.TransformColumnTypes(
        Intercambio,
        {
            {"txn_date", type date}, {"txn_count", Int64.Type}, {"amount_usd", type number},
            {"interchange_fee_usd", type number}, {"effective_rate", type number}
        }
    )
in
    Tipado
