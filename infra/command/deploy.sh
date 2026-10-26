#!/usr/bin/env bash
# Versión bash de deploy.ps1, para Cloud Shell o Linux/macOS: tests -> fmt -> plan -> apply -> pipeline.
#
#   bash infra/command/deploy.sh               # pide confirmación antes del apply
#   bash infra/command/deploy.sh --auto        # sin confirmación
#   bash infra/command/deploy.sh --pipeline    # además ejecuta el pipeline y espera el resultado
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PLATFORM="$ROOT/infra/platform"
AUTO=false
PIPELINE=false
for arg in "$@"; do
  case "$arg" in
    --auto) AUTO=true ;;
    --pipeline) PIPELINE=true ;;
    *) echo "opción desconocida: $arg" >&2; exit 2 ;;
  esac
done

step() { printf '\n==> %s\n' "$1"; }

step "1/5 Tests de Python"
python3 -m pip install -q -r "$ROOT/requirements-dev.txt"
(cd "$ROOT" && python3 -m pytest -q)

step "2/5 Formato de Terraform"
terraform fmt -check -recursive "$ROOT/infra"

step "3/5 Init + validate"
terraform -chdir="$PLATFORM" init -input=false -backend-config=backend.hcl
terraform -chdir="$PLATFORM" validate

step "4/5 Plan"
set +e
terraform -chdir="$PLATFORM" plan -input=false -detailed-exitcode -out=tfplan
PLAN_EXIT=$?
set -e
[ "$PLAN_EXIT" -eq 1 ] && { echo "terraform plan falló" >&2; exit 1; }

if [ "$PLAN_EXIT" -eq 2 ]; then
  step "5/5 Apply"
  if [ "$AUTO" != true ]; then
    read -r -p "¿Aplicar estos cambios en Google Cloud? (s/N) " answer
    [[ "$answer" =~ ^[sS] ]] || { echo "Cancelado."; exit 0; }
  fi
  terraform -chdir="$PLATFORM" apply -input=false tfplan
else
  echo "Sin cambios de infraestructura."
fi

if [ "$PIPELINE" = true ]; then
  step "Smoke test: pipeline en Cloud Workflows"
  PROJECT=$(terraform -chdir="$PLATFORM" output -raw project_id)
  REGION=$(sed -n 's/^region *= *"\(.*\)"/\1/p' "$PLATFORM/project.auto.tfvars")
  EXEC=$(gcloud workflows run "$(terraform -chdir="$PLATFORM" output -raw pipeline_workflow)" \
    --location="${REGION:-southamerica-east1}" --project="$PROJECT" --data='{"generate": true}' --format=json)
  STATUS=$(printf '%s' "$EXEC" | python3 -c 'import json,sys; print(json.load(sys.stdin)["state"])')
  echo "estado: $STATUS"
  if [ "$STATUS" != "SUCCEEDED" ]; then
    printf '%s' "$EXEC" | python3 "$ROOT/scripts/workflow_failure_reason.py" >&2
    exit 1
  fi
fi
echo "Listo. API: $(terraform -chdir="$PLATFORM" output -raw api_url)"
