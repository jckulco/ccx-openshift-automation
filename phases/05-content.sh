#!/usr/bin/env bash
# Fase 05: property files -> 'generate' -> BD de contenido -> secretos/CRs -> Content, Model Gateway y WDU.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."
activate_venv
export OC NS

title "Fase 05 - Content Platform Engine, Navigator, GraphQL, CSS, Task Manager + MG/WDU"
PROP="${PROP_DIR:-}"; [ -d "$PROP" ] || die "Falta PROP_DIR (ejecuta la fase 04)."
GEN="$IBM_SCRIPTS/generatedFiles/$NS"

# 1) property files --------------------------------------------------------------------------------------------
log "Rellenando property files"
if ! python3 "$ROOT/tools/fill-properties.py" "$PROP" "$STATE_DIR"; then
  die "Quedan propiedades <Required> sin rellenar (lista arriba). Revísalas en $PROP"
fi

# 2) certificado(s) del IdP (Keycloak) -----------------------------------------------------------------------------
KC_HOST="$(route_host "$AUTH_NS" keycloak)"
mkdir -p "$PROP/ssl-certs/idp"
if ! ls "$PROP"/ssl-certs/idp/*.pem >/dev/null 2>&1; then
  log "Guardando la cadena de certificados de https://$KC_HOST"
  T="$(mktemp -d)"
  openssl s_client -connect "$KC_HOST:443" -servername "$KC_HOST" -showcerts </dev/null 2>/dev/null \
    | awk -v d="$T" '/BEGIN CERTIFICATE/{n++; f=1} f{print > (d "/keycloak-chain-" n ".pem")} /END CERTIFICATE/{f=0}'
  ls "$T"/keycloak-chain-*.pem >/dev/null 2>&1 || die "No pude leer el certificado de $KC_HOST:443"
  cp "$T"/keycloak-chain-*.pem "$PROP/ssl-certs/idp/"; rm -rf "$T"
fi
ok "Certificados del IdP: $(ls "$PROP/ssl-certs/idp" | tr '\n' ' ')"

# 3) generate ------------------------------------------------------------------------------------------------------------
cd "$IBM_SCRIPTS"
log "prerequisites.py --silent generate"
python prerequisites.py --silent generate 2>&1 | mask | tail -30
[ -f "$GEN/ibm_content_cr_production.yaml" ] || die "generate no produjo ibm_content_cr_production.yaml"

# 4) bases de datos de contenido (UNA sola vez) ---------------------------------------------------------------------------
if phase_done 05-content-db; then
  ok "Bases de datos de contenido ya creadas"
else
  log "Creando gcddb / osdb / icndb"
  NS="$NS" OC="$OC" SQL_DIR="$GEN/database" bash "$ROOT/tools/load-content-db.sh"
  mark_done 05-content-db
fi

# 5) secretos, certificados, configmaps y métricas (equivale a 'validate --apply' sin validación) ----------------------------
log "Aplicando secretos, certificados, configmaps y métricas"
for d in secrets ssl configmaps; do
  [ -d "$GEN/$d" ] && oc_ apply -n "$NS" -f "$GEN/$d/" | sed 's/^/   /'
done
# Las métricas (IBMServiceMeterDefinition) requieren permisos que el operador no tiene; se aplican aquí.
# Se aplican todas (CPE y GraphQL, todas las métricas de licencia): es lo mismo que hace el script de IBM.
for d in metrics/cpe metrics/graphql; do
  [ -d "$GEN/$d" ] && oc_ apply -n "$NS" -f "$GEN/$d/" >/dev/null || warn "No se pudieron aplicar las métricas de $d"
done

# 6) CRs ------------------------------------------------------------------------------------------------------------------------
log "Aplicando Content CR"
oc_ apply -n "$NS" -f "$GEN/ibm_content_cr_production.yaml"
# El operador de Content no tiene permiso sobre los CRDs de MG/WDU/AI Services -> se aplican desde aquí.
log "Aplicando Model Gateway y WDU CR"
oc_ apply -n "$NS" -f "$GEN/ibm_model_gateway_cr_production.yaml" -f "$GEN/ibm_wdu_cr_production.yaml"

# 7) esperar a Content ----------------------------------------------------------------------------------------------------------
content_ready() {
  oc_ get fncmcluster content -n "$NS" -o json 2>/dev/null | python3 -c '
import json, sys
s = json.load(sys.stdin).get("status", {})
sys.exit(0 if any(c.get("type") == "Ready" and c.get("status") == "True" for c in s.get("conditions", [])) else 1)'
}
log "Esperando a que Content Cortex termine (inicialización de dominio, object store y Navigator; 20-60 min)..."
START="$(date +%s)"
while ! content_ready; do
  [ $(( $(date +%s) - START )) -lt 5400 ] || { oc_ get pods -n "$NS" | grep -v -E "Running|Completed" || true; die "Content no llegó a Ready en 90 min. Ver docs/TROUBLESHOOTING.md"; }
  printf '.'; sleep 30
done
echo; ok "FNCMCluster 'content' en estado Ready"
mark_done 05-content
