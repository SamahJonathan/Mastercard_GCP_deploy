<#
.SYNOPSIS
  Comandos que se ejecutan cada vez que se actualiza un cambio.
  Es la versión local de .github/workflows/deploy.yml (tests -> validate -> plan -> apply -> smoke test).

  Cada ejecución queda registrada (docs/observabilidad-despliegues.md):
    - transcript completo en logs/deploy-<id>.log
    - registro estructurado en Cloud Logging (log paylake-deployments) y en GCS (bucket del estado)

.EXAMPLE
  ./infra/command/deploy.ps1                  # tests + validate + plan + apply (pide confirmación)
  ./infra/command/deploy.ps1 -PlanOnly        # sólo muestra qué cambiaría
  ./infra/command/deploy.ps1 -RunPipeline     # además ejecuta el pipeline en GCP y espera el resultado
#>
param(
    [switch]$PlanOnly,
    [switch]$AutoApprove,
    [switch]$RunPipeline,
    [switch]$SkipTests
)
$ErrorActionPreference = "Stop"
# Terraform y Python escriben UTF-8; si la consola usa la página de códigos de Windows (CP850), al pasar
# su salida por PowerShell (| Out-Host, para el log) los caracteres se corrompen: "─" se ve como "ÔöÇ".
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.UTF8Encoding]::new($false)  # sin BOM: lo que pasa por tubería a python o bq llega limpio
$env:PYTHONIOENCODING = "utf-8"
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Platform = Join-Path $Root "infra/platform"

# --- Registro del despliegue -----------------------------------------------------------------------
$Started = (Get-Date).ToUniversalTime()
$Sha = (git -C $Root rev-parse --short HEAD 2>$null)
$DeployId = "{0:yyyyMMdd-HHmmss}-{1}" -f $Started, ($Sha ? $Sha : "nogit")
$LogDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "deploy-$DeployId.log"
# Sin colores ANSI en los comandos de Terraform, para que el log se lea limpio
foreach ($c in "init", "validate", "plan", "apply", "show") { Set-Item "env:TF_CLI_ARGS_$c" "-no-color" }

$script:CurrentStep = ""
$script:Outcome = "failed"
$script:Execution = ""
$script:PipelineStatus = ""
$script:IamChecks = ""
$script:PlanFile = ""

function Step($msg) { $script:CurrentStep = $msg; Write-Host "`n==> $msg" -ForegroundColor Cyan }
function Invoke-Checked([scriptblock]$cmd) {
    # | Out-Host: la salida de los comandos externos pasa por PowerShell y queda en el transcript
    & $cmd | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "Falló: $cmd" }
}

Start-Transcript -Path $LogFile | Out-Null
Write-Host "Despliegue $DeployId  (log: logs/deploy-$DeployId.log)" -ForegroundColor DarkGray
$failure = $null
try {
    Step "1/6 Herramientas y credenciales de Google Cloud"
    foreach ($tool in "python", "terraform", "gcloud") {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) { throw "Falta '$tool' en el PATH" }
    }
    if (-not (Test-Path "$Platform/backend.hcl")) {
        throw "No existe infra/platform/backend.hcl. Ejecuta primero ./infra/bootstrap/bootstrap.ps1"
    }
    $Project = ((Get-Content "$Platform/project.auto.tfvars" | Select-String 'project_id\s*=\s*"([^"]+)"').Matches.Groups[1].Value)
    $env:GCP_PROJECT_ID = $Project
    Write-Host "Cuenta: $(gcloud config get-value account 2>$null)  ·  Proyecto: $Project"
    # Terraform usa las Application Default Credentials: si no hay, falla en el plan con un error poco claro
    gcloud auth application-default print-access-token 2>$null | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "Sin credenciales de aplicación: gcloud auth application-default login" }

    if (-not $SkipTests) {
        Step "2/6 Tests de Python (bronze / silver / gold)"
        Invoke-Checked { python -m pip install -q -r "$Root/requirements-dev.txt" }
        Push-Location $Root
        try { Invoke-Checked { python -m pytest -q -p no:cacheprovider } } finally { Pop-Location }
    }

    Step "3/6 Formato de Terraform"
    Invoke-Checked { terraform fmt -check -recursive "$Root/infra" }

    Step "4/6 Init + validate (estado remoto en GCS)"
    Invoke-Checked { terraform "-chdir=$Platform" init -input=false "-backend-config=backend.hcl" }
    Invoke-Checked { terraform "-chdir=$Platform" validate }

    Step "5/6 Plan"
    terraform "-chdir=$Platform" plan -input=false -detailed-exitcode -out=tfplan | Out-Host
    $planExit = $LASTEXITCODE  # 0 = sin cambios, 1 = error, 2 = hay cambios
    if ($planExit -eq 1) { throw "terraform plan falló" }
    $script:PlanFile = "tfplan"

    if ($PlanOnly) {
        Write-Host "`nModo -PlanOnly: no se aplica nada." -ForegroundColor Yellow
        $script:Outcome = "planned"
        return
    }

    if ($planExit -eq 2) {
        Step "6/6 Apply"
        if (-not $AutoApprove) {
            $answer = Read-Host "¿Aplicar estos cambios en Google Cloud? (s/N)"
            if ($answer -notin "s", "S", "si", "sí") {
                Write-Host "Cancelado."
                $script:Outcome = "cancelled"
                return
            }
        }
        Invoke-Checked { terraform "-chdir=$Platform" apply -input=false tfplan }
    } else {
        Write-Host "`nSin cambios de infraestructura." -ForegroundColor Green
    }

    if ($RunPipeline) {
        Step "Smoke test: ejecutando el pipeline en Cloud Workflows"
        $workflow = terraform "-chdir=$Platform" output -raw pipeline_workflow
        $region = ((Get-Content "$Platform/project.auto.tfvars" | Select-String 'region\s*=\s*"([^"]+)"').Matches.Groups[1].Value)
        # API REST de Workflow Executions (pasar JSON a gcloud.cmd desde PowerShell rompe las comillas)
        $headers = @{ Authorization = "Bearer $(gcloud auth print-access-token)"; "x-goog-user-project" = $Project }
        $api = "https://workflowexecutions.googleapis.com/v1"
        $body = @{ argument = (@{ generate = $true } | ConvertTo-Json -Compress) } | ConvertTo-Json
        $exec = Invoke-RestMethod -Method Post -Uri "$api/projects/$Project/locations/$region/workflows/$workflow/executions" `
            -Headers $headers -ContentType "application/json" -Body $body
        $script:Execution = $exec.name
        do {
            Start-Sleep -Seconds 10
            $exec = Invoke-RestMethod -Uri "$api/$($script:Execution)" -Headers $headers
            Write-Host "  estado: $($exec.state)"
        } while ($exec.state -eq "ACTIVE")
        $script:PipelineStatus = $exec.state
        if ($exec.state -ne "SUCCEEDED") {
            # El registro debe bastarse solo: etapa y causa, sacadas del error de la ejecución
            $reason = $exec | ConvertTo-Json -Depth 20 | python "$Root/scripts/workflow_failure_reason.py"
            throw "El pipeline terminó en $($exec.state): $reason"
        }
        $exec.result | Out-Host
    }

    Step "Comprobaciones de IAM (lo permitido y lo que debe quedar denegado)"
    & "$PSScriptRoot/check_iam.ps1"
    $script:IamChecks = if ($LASTEXITCODE -eq 0) { "passed" } else { "failed" }
    if ($LASTEXITCODE -ne 0) { throw "Las comprobaciones de IAM no coinciden con lo esperado" }

    Write-Host "`nListo. API: $(terraform "-chdir=$Platform" output -raw api_url)" -ForegroundColor Green
    $script:Outcome = if ($planExit -eq 2) { "success" } else { "no_changes" }
}
catch {
    $failure = $_
    $script:Outcome = "failed"
    Write-Host "`nERROR en '$($script:CurrentStep)': $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
    $recordArgs = @(
        "$Root/scripts/deploy_record.py",
        "--deployment-id", $DeployId,
        "--kind", "deploy",
        "--status", $script:Outcome,
        "--started-at", $Started.ToString("o"),
        "--tf-dir", $Platform,
        "--log-file", $LogFile
    )
    if ($script:PlanFile) { $recordArgs += @("--plan-file", $script:PlanFile) }
    if ($script:Outcome -eq "failed") { $recordArgs += @("--failed-step", $script:CurrentStep, "--error", "$($failure.Exception.Message)") }
    if ($script:Execution) { $recordArgs += @("--pipeline-execution", $script:Execution, "--pipeline-status", $script:PipelineStatus) }
    if ($script:IamChecks) { $recordArgs += @("--iam-checks", $script:IamChecks) }
    python @recordArgs
}
if ($failure) { throw $failure }
