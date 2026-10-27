<#
.SYNOPSIS
  Bootstrap del proyecto en Google Cloud (una vez): crea lo que Terraform necesita ANTES de poder
  ejecutarse (el proyecto, el bucket de su estado y la identidad con que despliega GitHub).

    1. Proyecto nuevo ligado a la cuenta de facturación (o reutiliza uno existente con -ProjectId)
    2. APIs de los servicios que usa la plataforma
    3. Bucket del estado de Terraform (versionado, acceso uniforme, sin acceso público)
    4. Cuenta de servicio de despliegue con un TECHO: sólo puede otorgar los roles de grantable_roles.txt
    5. Workload Identity Federation para GitHub Actions (OIDC, sin llaves JSON)
    6. Historial de despliegues: log bucket con retención de 1 año + sink
    7. Presupuesto mensual con avisos al 80 % real y 100 % pronosticado
    8. infra/platform/backend.hcl (ignorado por git) y, si no existe, infra/platform/project.auto.tfvars
    9. Variables del repositorio de GitHub (si existe y gh está autenticado)

  Es idempotente: se puede volver a ejecutar para actualizar el techo de roles o las variables de GitHub.

.EXAMPLE
  ./infra/bootstrap/bootstrap.ps1 -BillingAccount 01D9FA-58E398-5AA6F7 -AlertEmail tu@correo.com
  ./infra/bootstrap/bootstrap.ps1 -ProjectId paylake-gcp-1a2b     # re-ejecución sobre un proyecto existente
#>
param(
    [string]$ProjectId = "",
    [string]$BillingAccount = "",
    [string]$Region = "southamerica-east1",
    [string]$GithubRepo = "SamahJonathan/Mastercard_GCP_deploy",
    [string]$AlertEmail = "",
    [int]$BudgetUsd = 25,
    # Monto en la moneda de la cuenta de facturación; si se omite, se convierte BudgetUsd con $UsdRate
    [int]$BudgetAmount = 0
)
# Conversión aproximada (sólo para fijar el umbral del presupuesto)
$UsdRate = @{ USD = 1; CLP = 1000; EUR = 1; BRL = 6; MXN = 20; ARS = 1500; COP = 4200; PEN = 4 }
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.Encoding]::UTF8
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Platform = Join-Path $Root "infra/platform"
$TfVars = Join-Path $Platform "project.auto.tfvars"

function Step($msg) { Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Invoke-GCloud {
    # gcloud con verificación de código de salida. Reintenta: una cuenta de servicio recién creada tarda
    # unos segundos en ser visible para las políticas de IAM (consistencia eventual).
    for ($attempt = 1; $attempt -le 6; $attempt++) {
        & gcloud @args
        if ($LASTEXITCODE -eq 0) { return }
        if ($args[1] -notmatch "add-iam-policy-binding") { break }
        Write-Host "  reintento $attempt/5 en 10 s..." -ForegroundColor DarkGray
        Start-Sleep -Seconds 10
    }
    throw "Falló: gcloud $($args -join ' ')"
}
function Exists([scriptblock]$cmd) {
    & $cmd 2>$null | Out-Null
    return $LASTEXITCODE -eq 0
}

# Re-ejecución: si no se indica proyecto, se reutiliza el de project.auto.tfvars
if (-not $ProjectId -and (Test-Path $TfVars)) {
    $ProjectId = ((Get-Content $TfVars | Select-String 'project_id\s*=\s*"([^"]+)"').Matches.Groups[1].Value)
}
if (-not $ProjectId) {
    $ProjectId = "paylake-gcp-" + -join ((48..57) + (97..102) | Get-Random -Count 4 | ForEach-Object { [char]$_ })
}
$Account = (gcloud config get-value account 2>$null)
Write-Host "Proyecto: $ProjectId  ·  Región: $Region  ·  Cuenta: $Account" -ForegroundColor DarkGray

Step "1/9 Proyecto y facturación"
if (-not (Exists { gcloud projects describe $ProjectId --format="value(projectId)" })) {
    Invoke-GCloud projects create $ProjectId --name="Payments Lakehouse" --labels="project=paylake,managed-by=bootstrap"
}
if (-not $BillingAccount) {
    $BillingAccount = (gcloud billing projects describe $ProjectId --format="value(billingAccountName)") -replace "^billingAccounts/", ""
}
if (-not $BillingAccount) { throw "Indica -BillingAccount (gcloud billing accounts list)" }
Invoke-GCloud billing projects link $ProjectId --billing-account=$BillingAccount --quiet | Out-Null
$ProjectNumber = gcloud projects describe $ProjectId --format="value(projectNumber)"

Step "2/9 APIs"
$apis = @(
    "storage", "bigquery", "bigqueryconnection", "bigquerystorage", "cloudfunctions", "run", "cloudbuild",
    "artifactregistry", "workflows", "workflowexecutions", "cloudscheduler", "dataproc", "sqladmin",
    "datastream", "compute", "servicenetworking", "cloudkms", "secretmanager", "monitoring", "logging",
    "iam", "iamcredentials", "sts", "cloudresourcemanager", "policytroubleshooter", "billingbudgets",
    "cloudbilling", "serviceusage", "iap", "eventarc"
) | ForEach-Object { "$_.googleapis.com" }
# La API acepta como máximo 20 servicios por llamada
for ($i = 0; $i -lt $apis.Count; $i += 20) {
    [string[]]$batch = $apis[$i..([Math]::Min($i + 19, $apis.Count - 1))]
    & gcloud services enable @batch --project=$ProjectId
    if ($LASTEXITCODE -ne 0) { throw "Falló la habilitación de APIs: $($batch -join ', ')" }
}

Step "3/9 Bucket del estado de Terraform"
$StateBucket = "$ProjectId-tfstate"
if (-not (Exists { gcloud storage buckets describe "gs://$StateBucket" --project=$ProjectId })) {
    Invoke-GCloud storage buckets create "gs://$StateBucket" --project=$ProjectId --location=$Region `
        --uniform-bucket-level-access --public-access-prevention
}
Invoke-GCloud storage buckets update "gs://$StateBucket" --versioning | Out-Null

Step "4/9 Cuenta de despliegue y su techo de roles"
$DeploySa = "paylake-deploy@$ProjectId.iam.gserviceaccount.com"
if (-not (Exists { gcloud iam service-accounts describe $DeploySa --project=$ProjectId })) {
    Invoke-GCloud iam service-accounts create paylake-deploy --project=$ProjectId `
        --display-name="Despliegue (GitHub Actions)" `
        --description="Terraform desde GitHub Actions vía OIDC. Sólo otorga los roles de grantable_roles.txt"
}
# Roles de administración por servicio (crear y borrar los recursos de la plataforma). Ninguno es Owner/Editor
# y ninguno permite otorgar roles a nivel de proyecto: eso lo hace sólo el projectIamAdmin condicionado.
$deployRoles = @(
    "roles/storage.admin", "roles/bigquery.admin", "roles/bigquery.connectionAdmin", "roles/cloudfunctions.admin",
    "roles/run.admin", "roles/workflows.admin", "roles/cloudscheduler.admin", "roles/dataproc.editor",
    "roles/cloudsql.admin", "roles/datastream.admin", "roles/compute.networkAdmin", "roles/compute.securityAdmin",
    "roles/compute.instanceAdmin.v1", "roles/servicenetworking.networksAdmin", "roles/cloudkms.admin",
    "roles/secretmanager.admin", "roles/monitoring.editor", "roles/logging.configWriter", "roles/logging.logWriter",
    "roles/iam.serviceAccountAdmin", "roles/iam.serviceAccountUser", "roles/iam.roleAdmin",
    "roles/resourcemanager.tagAdmin", "roles/resourcemanager.tagUser", "roles/serviceusage.serviceUsageConsumer",
    "roles/cloudbuild.builds.editor", "roles/artifactregistry.reader",
    # IAP del dashboard: su configuración y quién pasa (actúa sobre recursos de IAP, no sobre el proyecto)
    "roles/iap.admin"
)
foreach ($r in $deployRoles) {
    Invoke-GCloud projects add-iam-policy-binding $ProjectId --member="serviceAccount:$DeploySa" --role=$r --condition=None --quiet | Out-Null
}
# El techo: projectIamAdmin sólo para los roles de la lista
$grantable = Get-Content "$PSScriptRoot/grantable_roles.txt" |
    Where-Object { $_ -and -not $_.StartsWith("#") } |
    ForEach-Object { "'" + ($_.Trim() -replace "\{project\}", $ProjectId) + "'" }
$expr = "api.getAttribute('iam.googleapis.com/modifiedGrantsByRole', []).hasOnly([$($grantable -join ', ')])"
function Write-Condition([string]$expression) {
    # La expresión lleva comas y comillas: se pasa por archivo (--condition no admite comas)
    $file = New-TemporaryFile
    @"
title: paylake-grantable-roles
description: Solo puede otorgar los roles de infra/bootstrap/grantable_roles.txt
expression: "$expression"
"@ | Set-Content -Path $file -Encoding utf8
    return $file
}
# Reemplaza la versión anterior de la condición (si cambió la lista) sin tocar otros miembros
$old = gcloud projects get-iam-policy $ProjectId --format=json | ConvertFrom-Json
foreach ($b in $old.bindings | Where-Object { $_.role -eq "roles/resourcemanager.projectIamAdmin" -and $_.condition.title -eq "paylake-grantable-roles" -and $_.members -contains "serviceAccount:$DeploySa" }) {
    if ($b.condition.expression -ne $expr) {
        $oldFile = Write-Condition $b.condition.expression
        Invoke-GCloud projects remove-iam-policy-binding $ProjectId --member="serviceAccount:$DeploySa" --role=roles/resourcemanager.projectIamAdmin `
            --condition-from-file=$oldFile --quiet | Out-Null
        Remove-Item $oldFile
    }
}
$condFile = Write-Condition $expr
Invoke-GCloud projects add-iam-policy-binding $ProjectId --member="serviceAccount:$DeploySa" --role=roles/resourcemanager.projectIamAdmin `
    --condition-from-file=$condFile --quiet | Out-Null
Remove-Item $condFile
# El estado de Terraform: sólo esta cuenta (y los dueños del proyecto)
Invoke-GCloud storage buckets add-iam-policy-binding "gs://$StateBucket" --member="serviceAccount:$DeploySa" --role=roles/storage.objectAdmin | Out-Null

Step "5/9 Workload Identity Federation (GitHub OIDC)"
$Pool = "github"
$Provider = "github-oidc"
if (-not (Exists { gcloud iam workload-identity-pools describe $Pool --location=global --project=$ProjectId })) {
    Invoke-GCloud iam workload-identity-pools create $Pool --location=global --project=$ProjectId --display-name="GitHub Actions"
}
if (-not (Exists { gcloud iam workload-identity-pools providers describe $Provider --workload-identity-pool=$Pool --location=global --project=$ProjectId })) {
    # attribute-condition: sólo tokens emitidos para ESTE repositorio pueden canjearse (evita que otro repo lo use)
    Invoke-GCloud iam workload-identity-pools providers create-oidc $Provider --workload-identity-pool=$Pool --location=global `
        --project=$ProjectId --issuer-uri="https://token.actions.githubusercontent.com" `
        --attribute-mapping="google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.ref=assertion.ref" `
        --attribute-condition="assertion.repository == '$GithubRepo'"
}
$PoolName = "projects/$ProjectNumber/locations/global/workloadIdentityPools/$Pool"
Invoke-GCloud iam service-accounts add-iam-policy-binding $DeploySa --project=$ProjectId --role=roles/iam.workloadIdentityUser `
    --member="principalSet://iam.googleapis.com/$PoolName/attribute.repository/$GithubRepo" | Out-Null
$WifProvider = "$PoolName/providers/$Provider"
# check_iam.ps1 prueba de verdad que esta cuenta NO puede fabricar un admin: el administrador debe poder actuar como ella
if ($Account) {
    Invoke-GCloud iam service-accounts add-iam-policy-binding $DeploySa --project=$ProjectId --role=roles/iam.serviceAccountTokenCreator `
        --member="user:$Account" | Out-Null
}

Step "6/9 Historial de despliegues (Cloud Logging, 1 año)"
if (-not (Exists { gcloud logging buckets describe paylake-deployments --location=$Region --project=$ProjectId })) {
    Invoke-GCloud logging buckets create paylake-deployments --location=$Region --retention-days=365 --project=$ProjectId `
        --description="Un registro por despliegue (PC y GitHub Actions). Sobrevive a destroy.ps1"
}
$sinkFilter = "logName=`"projects/$ProjectId/logs/paylake-deployments`""
$sinkDest = "logging.googleapis.com/projects/$ProjectId/locations/$Region/buckets/paylake-deployments"
if (-not (Exists { gcloud logging sinks describe paylake-deployments --project=$ProjectId })) {
    Invoke-GCloud logging sinks create paylake-deployments $sinkDest --log-filter=$sinkFilter --project=$ProjectId
}

# El monto del presupuesto debe ir en la moneda de la cuenta de facturación (p.ej. CLP en una cuenta chilena)
$Currency = gcloud billing accounts describe $BillingAccount --format="value(currencyCode)"
if (-not $BudgetAmount) { $BudgetAmount = $BudgetUsd * ($UsdRate[$Currency] ?? 1) }
Step "7/9 Presupuesto mensual ($BudgetAmount $Currency ≈ USD $BudgetUsd)"
$budgets = gcloud billing budgets list --billing-account=$BillingAccount --billing-project=$ProjectId --format="value(displayName)" 2>$null
if ($budgets -notcontains "$ProjectId-monthly") {
    Invoke-GCloud billing budgets create --billing-account=$BillingAccount --billing-project=$ProjectId `
        --display-name="$ProjectId-monthly" --budget-amount="$BudgetAmount$Currency" `
        --filter-projects="projects/$ProjectId" `
        --threshold-rule=percent=0.8 --threshold-rule="percent=1.0,basis=forecasted-spend" | Out-Null
}

Step "8/9 Configuración local de Terraform"
@"
bucket = "$StateBucket"
prefix = "platform"
"@ | Set-Content -Path (Join-Path $Platform "backend.hcl") -Encoding utf8
# Sólo se crea si no existe: después se edita a mano (personas, cliente OAuth) y re-ejecutar el bootstrap
# no debe pisar esos cambios
if (-not (Test-Path $TfVars)) {
    $lines = @("project_id  = `"$ProjectId`"", "region      = `"$Region`"", "github_repo = `"$GithubRepo`"")
    if ($AlertEmail) { $lines += "alert_email = `"$AlertEmail`"" }
    if ($Account) { $lines += "admin_members = [`"user:$Account`"]" }
    $lines | Set-Content -Path $TfVars -Encoding utf8
    if (Get-Command terraform -ErrorAction SilentlyContinue) { terraform fmt $TfVars | Out-Null }  # deploy.ps1 exige fmt
}

Step "9/9 Variables de GitHub Actions"
if ((Get-Command gh -ErrorAction SilentlyContinue) -and (Exists { gh repo view $GithubRepo })) {
    $vars = @{
        GCP_PROJECT_ID = $ProjectId; GCP_REGION = $Region; GCP_WIF_PROVIDER = $WifProvider
        GCP_DEPLOY_SA = $DeploySa; TF_STATE_BUCKET = $StateBucket
    }
    if ($AlertEmail) { $vars.ALERT_EMAIL = $AlertEmail }
    # Mismos administradores que el despliegue local: si no, un deploy desde GitHub les quitaría el acceso
    if ($Account) { $vars.ADMIN_MEMBERS = "[`"user:$Account`"]" }
    # Lo que está en project.auto.tfvars y secrets.auto.tfvars también tiene que llegar a GitHub: si no, un
    # deploy desde Actions quitaría el acceso a los consultores y la configuración de IAP del dashboard
    $tfvarsText = Get-Content $TfVars -Raw
    foreach ($pair in @(@("consultant_members", "CONSULTANT_MEMBERS"), @("analyst_members", "ANALYST_MEMBERS"), @("iap_oauth_client_id", "IAP_OAUTH_CLIENT_ID"))) {
        $m = [regex]::Match($tfvarsText, "(?m)^\s*$($pair[0])\s*=\s*(.+?)\s*$")
        if ($m.Success) { $vars[$pair[1]] = $m.Groups[1].Value.Trim('"') }
    }
    $secretsFile = Join-Path $Platform "secrets.auto.tfvars"
    $secretsText = if (Test-Path $secretsFile) { Get-Content $secretsFile -Raw } else { "" }
    $secret = [regex]::Match($secretsText, '(?m)^\s*iap_oauth_client_secret\s*=\s*"(.+?)"')
    if ($secret.Success) {
        # Como secret cifrado de GitHub (no variable): no aparece en los logs ni en la interfaz
        $secret.Groups[1].Value | gh secret set IAP_OAUTH_CLIENT_SECRET --repo $GithubRepo | Out-Null
    }
    foreach ($k in $vars.Keys) { gh variable set $k --repo $GithubRepo --body $vars[$k] | Out-Null }
    Write-Host "Variables configuradas en $GithubRepo"
} else {
    Write-Host "Repositorio $GithubRepo no disponible todavía: vuelve a correr el bootstrap después de crearlo." -ForegroundColor Yellow
}

Write-Host "`nListo." -ForegroundColor Green
Write-Host "  Proyecto         : $ProjectId ($ProjectNumber)"
Write-Host "  Estado Terraform : gs://$StateBucket/platform"
Write-Host "  Cuenta despliegue: $DeploySa"
Write-Host "  WIF provider     : $WifProvider"
Write-Host "Siguiente paso: ./infra/command/deploy.ps1"
