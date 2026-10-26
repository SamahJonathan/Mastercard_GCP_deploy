<#
.SYNOPSIS
  Apaga el proyecto para no generar costos.
  -PauseOnly sólo pausa las ejecuciones programadas; -StopCdc además apaga Cloud SQL, la VM y Datastream
  (lo que cuesta por hora); sin parámetros destruye toda la plataforma (el bootstrap -estado remoto, OIDC,
  presupuesto e historial de despliegues- se conserva).
  Para borrar TODO, incluido el proyecto: gcloud projects delete <proyecto>

  Igual que deploy.ps1: muestra el plan, pide confirmación y deja registro
  (logs/<tipo>-<id>.log + Cloud Logging paylake-deployments + GCS).
#>
param([switch]$PauseOnly, [switch]$StopCdc)
$ErrorActionPreference = "Stop"
[Console]::OutputEncoding = [Text.Encoding]::UTF8
$OutputEncoding = [Text.UTF8Encoding]::new($false)  # sin BOM: lo que pasa por tubería a python o bq llega limpio
$env:PYTHONIOENCODING = "utf-8"
$Root = (Resolve-Path "$PSScriptRoot/../..").Path
$Platform = Join-Path $Root "infra/platform"

$Kind = if ($PauseOnly -or $StopCdc) { "pause" } else { "destroy" }
$Started = (Get-Date).ToUniversalTime()
$Sha = (git -C $Root rev-parse --short HEAD 2>$null)
$DeployId = "{0:yyyyMMdd-HHmmss}-{1}-{2}" -f $Started, ($Sha ? $Sha : "nogit"), $Kind
New-Item -ItemType Directory -Force -Path (Join-Path $Root "logs") | Out-Null
$LogFile = Join-Path $Root "logs/$Kind-$DeployId.log"
foreach ($c in "init", "plan", "apply", "show") { Set-Item "env:TF_CLI_ARGS_$c" "-no-color" }

$outcome = "failed"
$step = ""
$planFile = ""
$failure = $null
Start-Transcript -Path $LogFile | Out-Null
try {
    $step = "init"
    terraform "-chdir=$Platform" init -input=false "-backend-config=backend.hcl" | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "terraform init falló" }

    $step = "plan"
    if ($Kind -eq "pause") {
        $vars = @("-var=schedule_enabled=false")
        if ($StopCdc) { $vars += "-var=enable_cdc=false" }
        terraform "-chdir=$Platform" plan -input=false @vars -out=tfplan-stop | Out-Host
    } else {
        terraform "-chdir=$Platform" plan -input=false -destroy -out=tfplan-stop | Out-Host
    }
    if ($LASTEXITCODE -ne 0) { throw "terraform plan falló" }
    $planFile = "tfplan-stop"

    $what = if ($StopCdc) { "pausar el pipeline y apagar el CDC (Cloud SQL, VM, Datastream)" } elseif ($PauseOnly) { "pausar las ejecuciones programadas" } else { "DESTRUIR la plataforma" }
    $answer = Read-Host "¿Confirmas $what? (s/N)"
    if ($answer -notin "s", "S", "si", "sí") {
        Write-Host "Cancelado."
        $outcome = "cancelled"
        return
    }

    $step = "apply"
    terraform "-chdir=$Platform" apply -input=false tfplan-stop | Out-Host
    if ($LASTEXITCODE -ne 0) { throw "terraform apply falló" }
    $outcome = "success"
}
catch {
    $failure = $_
    $outcome = "failed"
    Write-Host "`nERROR en '$step': $($_.Exception.Message)" -ForegroundColor Red
}
finally {
    Stop-Transcript | Out-Null
    $recordArgs = @(
        "$Root/scripts/deploy_record.py",
        "--deployment-id", $DeployId,
        "--kind", $Kind,
        "--status", $outcome,
        "--started-at", $Started.ToString("o"),
        "--tf-dir", $Platform,
        "--log-file", $LogFile
    )
    if ($planFile) { $recordArgs += @("--plan-file", $planFile) }
    if ($outcome -eq "failed") { $recordArgs += @("--failed-step", $step, "--error", "$($failure.Exception.Message)") }
    python @recordArgs
}
if ($failure) { throw $failure }
