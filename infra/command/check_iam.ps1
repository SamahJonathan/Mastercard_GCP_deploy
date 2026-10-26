<#
.SYNOPSIS
  Comprobación de IAM: actúa COMO cada identidad (impersonación) e intenta operaciones reales contra los
  recursos desplegados, para verificar lo que PUEDE y, sobre todo, lo que NO PUEDE hacer.
  Apuntes: docs/iam.md

  Son pruebas de verdad y no una simulación: Policy Troubleshooter no evalúa las condiciones por prefijo
  de objeto de Cloud Storage, así que una simulación daría falsos negativos.
  Las escrituras que se prueban son sólo las que deben quedar DENEGADAS (no ensucian nada); que las
  escrituras permitidas funcionan lo demuestra el pipeline.

  Sale con código 0 si todas las respuestas coinciden con lo esperado, 1 si alguna no.

.EXAMPLE
  ./infra/command/check_iam.ps1
#>
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
# Sin BOM: con [Text.Encoding]::UTF8 PowerShell antepone un BOM al texto que pasa por tubería y bq recibe
# la consulta con un carácter invisible al inicio (error de sintaxis que parecía un problema de permisos)
$OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = "utf-8"
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Platform = Join-Path $Root "infra/platform"

$Project = terraform "-chdir=$Platform" output -raw project_id
$buckets = terraform "-chdir=$Platform" output -json buckets | ConvertFrom-Json
$apiUrl = terraform "-chdir=$Platform" output -raw api_url
$name = "paylake-dev"
$ds = "paylake_dev"

function Sa([string]$id) { "$name-$id@$Project.iam.gserviceaccount.com" }
function Gs([string]$layer, [string]$path = "") { "gs://$($buckets.$layer)/$path" }

$DeniedPattern = "403|PERMISSION_DENIED|AccessDenied|Access Denied|does not have|Forbidden|denied|IAM_PERMISSION"

# Objetos reales sobre los que se prueba la lectura (los deja el despliegue y el pipeline)
$snapshot = Gs bronze "core_snapshot/ingest_date=2026-10-21/mastercard_db_ficticia.json"
$own = gcloud storage ls (Gs exchange "outbound/issuer_id=EM001/**/settlement.csv") --project=$Project 2>$null | Select-Object -First 1
$other = gcloud storage ls (Gs exchange "outbound/issuer_id=EM005/**/settlement.csv") --project=$Project 2>$null | Select-Object -First 1
$goldObj = gcloud storage ls (Gs gold "fraud_rule_performance/**") --project=$Project 2>$null | Select-Object -First 1
$silverObj = gcloud storage ls (Gs silver "dim_issuer/**") --project=$Project 2>$null | Select-Object -First 1

$probe = New-TemporaryFile
"iam-check" | Set-Content $probe

function Invoke-As([string]$sa, [scriptblock]$cmd) {
    # Devuelve "allowed", "denied" o "error: ..." según el resultado del comando ejecutado como $sa
    $env:CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT = $sa
    try { $out = (& $cmd 2>&1 | Out-String) } finally { Remove-Item Env:CLOUDSDK_AUTH_IMPERSONATE_SERVICE_ACCOUNT }
    if ($LASTEXITCODE -eq 0) { return "allowed" }
    if ($out -match $DeniedPattern) { return "denied" }
    return "error: " + (($out -split "`n" | Where-Object { $_ -match "rror" } | Select-Object -First 1) ?? $out).Trim()
}
function Read-Gcs([string]$uri) { gcloud storage cat $uri --project=$Project | Out-Null }
function List-Gcs([string]$uri) { gcloud storage ls $uri --project=$Project | Out-Null }
function List-Prefix([string]$layer, [string]$prefix) {
    # Como lo haría un banco con la API o un SDK: listar con prefijo. (gcloud storage ls consulta antes el
    # bucket completo, y un emisor sólo tiene permiso sobre su carpeta administrada.)
    $token = gcloud auth print-access-token 2>$null
    $uri = "https://storage.googleapis.com/storage/v1/b/$($buckets.$layer)/o?maxResults=5&prefix=$([uri]::EscapeDataString($prefix))"
    $r = Invoke-WebRequest -Uri $uri -Headers @{ Authorization = "Bearer $token" } -SkipHttpErrorCheck
    Write-Output "HTTP $($r.StatusCode)"
    $global:LASTEXITCODE = if ($r.StatusCode -eq 200) { 0 } else { 1 }
}
function Count-Keys([string]$sa) { @(gcloud iam service-accounts keys list --iam-account=$sa --managed-by=user --project=$Project --format="value(name)" 2>$null).Where({ $_ }).Count }
$apiSa = Sa api
$keysBefore = Count-Keys $apiSa
function Write-Gcs([string]$uri) { gcloud storage cp $probe $uri --project=$Project --quiet | Out-Null }
function Query([string]$table) {
    # bq escribe "Access Denied" en stdout (no en stderr): la salida se deja pasar para clasificar el resultado
    "SELECT COUNT(*) FROM ``$Project.$table``" | bq --project_id=$Project --quiet query --use_legacy_sql=false --format=csv
}

# Identidad, operación, resultado esperado, por qué importa
$checks = @(
    @{ who = "ingest"; what = "leer Bronze"; expect = "denied"; why = "escribe lotes, pero no lee datos con PAN"; run = { Read-Gcs $snapshot } }
    @{ who = "ingest"; what = "escribir Silver"; expect = "denied"; why = "no salta capas"; run = { Write-Gcs (Gs silver "_iam_probe.txt") } }
    @{ who = "ingest"; what = "escribir Bronze fuera de transactions/"; expect = "denied"; why = "sólo su prefijo"; run = { Write-Gcs (Gs bronze "core_snapshot/_iam_probe.txt") } }
    @{ who = "bronze-to-silver"; what = "leer Bronze"; expect = "allowed"; why = "lee la capa anterior"; run = { Read-Gcs $snapshot } }
    @{ who = "bronze-to-silver"; what = "escribir Gold"; expect = "denied"; why = "sólo escribe Silver"; run = { Write-Gcs (Gs gold "_iam_probe.txt") } }
    @{ who = "silver-to-gold"; what = "leer Bronze"; expect = "denied"; why = "Gold nunca toca datos con PAN"; run = { Read-Gcs $snapshot } }
    @{ who = "silver-to-gold"; what = "listar Silver"; expect = "allowed"; why = "lee la capa anterior"; run = { List-Gcs (Gs silver) } }
    @{ who = "silver-to-gold"; what = "escribir Exchange fuera de outbound/"; expect = "denied"; why = "publica sólo liquidaciones salientes"; run = { Write-Gcs (Gs exchange "inbound/_iam_probe.txt") } }
    @{ who = "api"; what = "listar Gold"; expect = "allowed"; why = "sirve Gold"; run = { List-Gcs (Gs gold) } }
    @{ who = "api"; what = "listar Silver"; expect = "denied"; why = "la API no expone detalle transaccional"; run = { List-Gcs (Gs silver) } }
    @{ who = "api"; what = "escribir Gold"; expect = "denied"; why = "la API es de sólo lectura"; run = { Write-Gcs (Gs gold "_iam_probe.txt") } }
    @{ who = "dataproc"; what = "leer Bronze"; expect = "denied"; why = "Spark parte desde Silver (sin roles/dataproc.worker)"; run = { Read-Gcs $snapshot } }
    @{ who = "dataproc"; what = "listar Silver"; expect = "allowed"; why = "entrada del job"; run = { List-Gcs (Gs silver) } }
    @{ who = "dataproc"; what = "cambiar IAM de Bronze"; expect = "denied"; why = "el rol predefinido sí lo permitiría"; run = { gcloud storage buckets add-iam-policy-binding (Gs bronze) --member="serviceAccount:$(Sa dataproc)" --role=roles/storage.objectViewer --project=$Project | Out-Null } }
    @{ who = "analyst"; what = "BigQuery: Gold"; expect = "allowed"; why = "consulta los productos de datos"; run = { Query "$ds`_gold.interchange_settlement" } }
    @{ who = "analyst"; what = "BigQuery: vista de reports (Power BI)"; expect = "allowed"; why = "las vistas de BI llevan la etiqueta de Gold"; run = { Query "$ds`_reports.interchange_settlement" } }
    @{ who = "analyst"; what = "BigQuery: Silver"; expect = "denied"; why = "la etiqueta layer=silver no le corresponde"; run = { Query "$ds`_silver.transactions" } }
    @{ who = "analyst"; what = "BigQuery: Bronze"; expect = "denied"; why = "ningún humano lee Bronze"; run = { Query "$ds`_bronze.transactions" } }
    @{ who = "analyst"; what = "leer Gold directo en GCS"; expect = "denied"; why = "los datos sólo llegan vía BigLake"; run = { Read-Gcs $goldObj } }
    @{ who = "analyst"; what = "otorgarse Owner"; expect = "denied"; why = "no administra IAM"; run = { gcloud projects add-iam-policy-binding $Project --member="serviceAccount:$(Sa analyst)" --role=roles/owner --condition=None --quiet | Out-Null } }
    @{ who = "risk-analyst"; what = "BigQuery: Silver"; expect = "allowed"; why = "ve el detalle tokenizado"; run = { Query "$ds`_silver.transactions" } }
    @{ who = "risk-analyst"; what = "BigQuery: Bronze"; expect = "denied"; why = "tampoco ve PAN en claro"; run = { Query "$ds`_bronze.transactions" } }
    @{ who = "risk-analyst"; what = "leer Silver directo en GCS"; expect = "denied"; why = "sólo vía BigLake"; run = { Read-Gcs $silverObj } }
    @{ who = "partner-em001"; what = "leer SU liquidación"; expect = "allowed"; why = "intercambio B2B"; run = { Read-Gcs $own } }
    @{ who = "partner-em001"; what = "listar SU carpeta"; expect = "allowed"; why = "descubre sus archivos"; run = { List-Prefix exchange "outbound/issuer_id=EM001/" } }
    @{ who = "partner-em001"; what = "leer liquidación de EM005"; expect = "denied"; why = "no ve las de otro banco"; run = { Read-Gcs $other } }
    @{ who = "partner-em001"; what = "listar todo Exchange"; expect = "denied"; why = "ni siquiera sabe qué otros bancos hay"; run = { List-Prefix exchange "outbound/" } }
    @{ who = "scheduler"; what = "invocar una function"; expect = "denied"; why = "sólo inicia workflows"; run = {
            $token = gcloud auth print-identity-token --audiences=$apiUrl.Replace("-api", "-ingest") --include-email
            $r = Invoke-WebRequest -Uri $apiUrl.Replace("-api", "-ingest") -Headers @{ Authorization = "Bearer $token" } -Method Post -SkipHttpErrorCheck
            if ($r.StatusCode -eq 403) { Write-Output "403 Forbidden"; $global:LASTEXITCODE = 1 } elseif ($r.StatusCode -ge 400) { Write-Output "HTTP $($r.StatusCode)"; $global:LASTEXITCODE = 1 } else { $global:LASTEXITCODE = 0 } } }
    @{ who = "core-loader"; what = "leer el extracto core"; expect = "allowed"; why = "lo carga en la base"; run = { Read-Gcs $snapshot } }
    @{ who = "core-loader"; what = "listar Bronze"; expect = "denied"; why = "sólo esos dos objetos exactos"; run = { List-Gcs (Gs bronze) } }
)
# La cuenta de despliegue de GitHub: administra recursos pero no puede fabricar un admin
$checks += @(
    @{ who = "!paylake-deploy"; what = "otorgarse Owner"; expect = "denied"; why = "el techo (grantable_roles.txt) lo impide"; run = { gcloud projects add-iam-policy-binding $Project --member="serviceAccount:paylake-deploy@$Project.iam.gserviceaccount.com" --role=roles/owner --condition=None --quiet | Out-Null } }
    @{ who = "!paylake-deploy"; what = "otorgar roles/editor a otra cuenta"; expect = "denied"; why = "tampoco a terceros"; run = { gcloud projects add-iam-policy-binding $Project --member="serviceAccount:$(Sa analyst)" --role=roles/editor --condition=None --quiet | Out-Null } }
    @{ who = "!paylake-deploy"; what = "crear una llave JSON"; expect = "denied"; why = "sin llaves de larga duración"; run = { gcloud iam service-accounts keys create "$env:TEMP/iam-check-key.json" --iam-account=$apiSa --project=$Project | Out-Null } }
)

$failed = 0
$rows = foreach ($c in $checks) {
    $sa = if ($c.who.StartsWith("!")) { "$($c.who.Substring(1))@$Project.iam.gserviceaccount.com" } else { Sa $c.who }
    $got = Invoke-As $sa $c.run
    $ok = $got -eq $c.expect
    if (-not $ok) { $failed++ }
    [pscustomobject]@{
        OK        = if ($ok) { "OK" } else { "FALLA" }
        Identidad = $c.who.TrimStart("!")
        Operacion = $c.what
        Esperado  = $c.expect
        Obtenido  = $got
        Porque    = $c.why
    }
}
Remove-Item $probe
# gcloud crea el archivo de salida aunque luego falle: lo que importa es si apareció una llave en IAM
if (Test-Path "$env:TEMP/iam-check-key.json") { Remove-Item "$env:TEMP/iam-check-key.json" }
if ((Count-Keys $apiSa) -gt $keysBefore) { Write-Host "¡Se creó una llave en $apiSa! Borrarla en IAM." -ForegroundColor Red; $failed++ }

$rows | Format-Table -AutoSize -Wrap

if ($failed) {
    Write-Host "$failed comprobación(es) no coinciden con lo esperado" -ForegroundColor Red
    exit 1
}
Write-Host "Las $($checks.Count) comprobaciones de IAM coinciden con lo esperado." -ForegroundColor Green
