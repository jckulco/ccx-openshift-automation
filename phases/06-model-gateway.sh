#!/usr/bin/env bash
# Fase 06: Model Gateway (tenant + proveedor watsonx.ai + modelo) -> patch-secret -> AI Services CR.
#   La ruta externa del Model Gateway devolvía 503 en la sesión de referencia, así que se administra con
#   'oc port-forward' (https://localhost:8443) usando el CLI oficial scripts/model-gateway.py.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."
activate_venv
export OC NS

title "Fase 06 - Model Gateway + AI Services"
GEN="$IBM_SCRIPTS/generatedFiles/$NS"
MG_TENANT="${MG_TENANT:-ccx}"; MG_PROVIDER="${MG_PROVIDER:-watsonx}"

mg_ready() {
  oc_ get svc model-gateway-service -n "$NS" >/dev/null 2>&1 || return 1
  local n
  n="$(oc_ get pods -n "$NS" --no-headers 2>/dev/null | grep -i gateway | grep -v -i operator | grep -v -i -E "pg-cluster|redis" | wc -l)"
  [ "$n" -ge 1 ] || return 1
  ! oc_ get pods -n "$NS" --no-headers 2>/dev/null | grep -i gateway | grep -v -i -E "operator|pg-cluster|redis|Completed" \
      | awk '{split($2,a,"/"); if (a[1]!=a[2] || $3!="Running") print}' | grep -q .
}
wait_until "Model Gateway desplegado y listo" 1800 15 mg_ready || { oc_ get modelgateway -n "$NS" || true; die "Model Gateway no está listo (ver TROUBLESHOOTING #5)."; }

# --- port-forward ---------------------------------------------------------------------------------------------------
PF_PORT="${MG_LOCAL_PORT:-8443}"
oc_ port-forward -n "$NS" svc/model-gateway-service "$PF_PORT:8080" >/dev/null 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
port_open() { curl -sk -o /dev/null --max-time 5 "https://localhost:$PF_PORT/" ; }
wait_until "port-forward activo" 60 2 port_open || die "No se pudo abrir el port-forward al Model Gateway."

cd "$IBM_SCRIPTS"
MGW=(python model-gateway.py)
"${MGW[@]}" config url "https://localhost:$PF_PORT" >/dev/null
"${MGW[@]}" config insecure true >/dev/null

TOKEN="$(python3 "$ROOT/tools/mg-admin-token.py")" || die "No pude leer la API key de administrador del Model Gateway."
"${MGW[@]}" login -t "$TOKEN" | tail -2
unset TOKEN
[ -f .mgw/state.json ] && chmod 600 .mgw/state.json || true

MGX=(python "$ROOT/tools/mgw.py")
state_has() { python3 - "$1" <<'PY'
import json, sys
try: st = json.load(open(".mgw/state.json"))
except Exception: sys.exit(1)
sys.exit(0 if st.get("tenant", {}).get("apikey") and (sys.argv[1] != "provider" or st.get("providers")) else 1)
PY
}

if state_has tenant; then ok "Tenant '$MG_TENANT' ya existe (estado local)"
else
  log "Creando tenant '$MG_TENANT'"
  "${MGX[@]}" tenant create "$MG_TENANT" | tail -3
fi
chmod 600 .mgw/state.json 2>/dev/null || true

if state_has provider; then ok "Proveedor ya registrado"
else
  log "Registrando proveedor watsonx.ai ($WXAI_URL, space $WXAI_SPACE_ID)"
  WATSONXAI_API_KEY="$WXAI_API_KEY" WATSONXAI_BASE_URL="$WXAI_URL" WATSONXAI_SPACE_ID="$WXAI_SPACE_ID" \
    WATSONXAI_PROJECT_ID="${WXAI_PROJECT_ID:-}" "${MGX[@]}" provider create watsonxai "$MG_PROVIDER" | tail -3
  PUUID="$(python3 -c 'import json; st=json.load(open(".mgw/state.json")); print(st["providers"]["'"$MG_PROVIDER"'"]["uuid"])')"
  log "Registrando modelo $WXAI_MODEL_ID"
  "${MGX[@]}" model add "$PUUID" "$WXAI_MODEL_ID" | tail -3
fi

# --- patch-secret: escribe el model id real del gateway en ibm-providers-config-secret ------------------------
umask 077
oc_ get secret ibm-providers-config-secret -n "$NS" -o yaml > "$STATE_DIR/ibm-providers-config-secret.bak.yaml" 2>/dev/null || true
umask 022
log "model-gateway.py patch-secret"
"${MGX[@]}" patch-secret -n "$NS" | tail -5

kill $PF_PID 2>/dev/null || true; trap - EXIT

# --- AI Services CR ----------------------------------------------------------------------------------------------
log "Aplicando AI Services CR"
oc_ apply -n "$NS" -f "$GEN/ibm_ai_services_cr_production.yaml"
rs_ready() { pods_ready_by_prefix "$NS" ibm-reasoning-service-deploy; }
wait_until "Reasoning Service listo" 1800 15 rs_ready || { oc_ get pods -n "$NS" | grep -v -E "Running|Completed" || true; die "Reasoning Service no está listo."; }
mark_done 06-model-gateway
