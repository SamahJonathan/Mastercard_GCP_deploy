#!/usr/bin/env bash
# Despliega el dashboard de Streamlit en Cloud Run.
# Cloud Run construye la imagen desde el código (buildpacks + Procfile) y escala a cero cuando nadie lo usa.
# Acceso: Identity-Aware Proxy. Cada persona entra con SU cuenta de Google y sólo pasan las de
# consultant_members, analyst_members y admin_members (iam.tf). No hay acceso público ni contraseña compartida.
# La API key de Gold la lee desde Secret Manager la cuenta paylake-dev-dashboard; nunca llega al navegador.
#
#   bash dashboard/deploy_cloudrun.sh <proyecto> [región]
set -euo pipefail

PROJECT="${1:?uso: deploy_cloudrun.sh <proyecto> [región]}"
REGION="${2:-southamerica-east1}"
cd "$(dirname "$0")"

API_URL=$(gcloud functions describe paylake-dev-api --region "$REGION" --project "$PROJECT" --format='value(serviceConfig.uri)')

gcloud run deploy paylake-dev-dashboard \
  --project "$PROJECT" \
  --region "$REGION" \
  --source . \
  --service-account "paylake-dev-dashboard@${PROJECT}.iam.gserviceaccount.com" \
  --set-env-vars "GOLD_API_URL=${API_URL}" \
  --set-secrets "GOLD_API_KEY=paylake-dev-api-key:latest" \
  --no-allow-unauthenticated \
  --iap \
  --max-instances 2 \
  --memory 1Gi \
  --quiet

echo "Dashboard: $(gcloud run services describe paylake-dev-dashboard --region "$REGION" --project "$PROJECT" --format='value(status.url)')"
