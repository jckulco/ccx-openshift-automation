#!/usr/bin/env bash
# Fase 00: pide los datos clave (lo único interactivo) y comprueba el cluster.
#   Secretos -> .state/secrets.env (chmod 600).  No secretos -> .state/config.env.
# Variables que se pueden pasar por entorno para ejecutar sin preguntas (CCX_NONINTERACTIVE=1):
#   CCX_ENTITLEMENT_KEY CCX_WXAI_API_KEY CCX_WXAI_URL CCX_WXAI_SPACE_ID CCX_WXAI_PROJECT_ID CCX_WXAI_MODEL_ID
#   CCX_ACCEPT_LICENSE=yes  NS AUTH_NS LICENSE_METRIC BLOCK_SC FILE_SC
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env

title "Fase 00 - Configuración"
find_oc || die "No encuentro el comando 'oc'. Instálalo o exporta OC=/ruta/a/oc."
oc_ whoami >/dev/null 2>&1 || die "No hay sesión de oc. Ejecuta primero:  oc login --token=... --server=..."
log "Cluster: $(oc_ whoami --show-server)  (usuario: $(oc_ whoami))"
oc_ auth can-i '*' '*' --all-namespaces >/dev/null 2>&1 || die "Se necesita cluster-admin."
OCP_VER="$(oc_ get clusterversion version -o jsonpath='{.status.desired.version}' 2>/dev/null || echo '?')"
log "OpenShift $OCP_VER"
case "$OCP_VER" in 4.1[2-9]*|4.[2-9][0-9]*|[5-9]*) ;; *) warn "Versión de OpenShift no verificada ($OCP_VER). Se necesita 4.12 o superior." ;; esac

# --- parámetros no secretos -------------------------------------------------------------------------
: "${NS:=ibm-content}"; : "${AUTH_NS:=ibm-auth}"
: "${LICENSE_METRIC:=CCx.Pre.AU}"       # Premium - Authorized User. Otras: CCx.Pre.EP, CCx.Pre.PE (ver README)
DEF_SC="$(oc_ get sc -o jsonpath='{range .items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")]}{.metadata.name}{end}' 2>/dev/null || true)"
ask NS "Namespace de Content Cortex" "$NS"
ask AUTH_NS "Namespace de OpenLDAP + Keycloak (laboratorio)" "$AUTH_NS"
ask LICENSE_METRIC "Métrica de licencia" "$LICENSE_METRIC"
ask BLOCK_SC "StorageClass de bloque (RWO, bases de datos)" "${BLOCK_SC:-${DEF_SC:-ocs-storagecluster-ceph-rbd}}"
ask FILE_SC "StorageClass de archivos (RWX, volúmenes compartidos)" "${FILE_SC:-ocs-storagecluster-cephfs}"
for sc in "$BLOCK_SC" "$FILE_SC"; do
  oc_ get sc "$sc" >/dev/null 2>&1 || die "La StorageClass '$sc' no existe en el cluster (oc get sc)."
done
APPS_DOMAIN="$(apps_domain)"; [ -n "$APPS_DOMAIN" ] || die "No pude leer el dominio de apps del cluster."

# --- watsonx.ai ----------------------------------------------------------------------------------------
echo
log "Datos de watsonx.ai (IBM Cloud). Requisitos: plan de pago (Standard/Essentials) y que el Service ID"
log "de la API key sea colaborador del deployment space. Ver docs/PREREQUISITES.md"
ask WXAI_URL "URL de watsonx.ai" "${CCX_WXAI_URL:-https://us-south.ml.cloud.ibm.com}"
ask WXAI_SPACE_ID "Space ID del deployment space (GUID)" "${CCX_WXAI_SPACE_ID:-}"
ask_optional WXAI_PROJECT_ID "Project ID de watsonx.ai (opcional)"
ask WXAI_MODEL_ID "Model ID" "${CCX_WXAI_MODEL_ID:-openai/gpt-oss-120b}"
[ -n "${CCX_WXAI_API_KEY:-}" ] && WXAI_API_KEY="$CCX_WXAI_API_KEY"
ask_secret WXAI_API_KEY "API key de IBM Cloud para watsonx.ai"
[ -n "${CCX_ENTITLEMENT_KEY:-}" ] && ENTITLEMENT_KEY="$CCX_ENTITLEMENT_KEY"
ask_secret ENTITLEMENT_KEY "IBM Entitlement Key (myibm.ibm.com/products-services/containerlibrary)"
WXAI_PROJECT_ID="${WXAI_PROJECT_ID:-}"
WXAI_REGION="$(echo "$WXAI_URL" | sed -E 's#https?://([^.]+)\..*#\1#')"

# --- licencia (decisión del usuario, nunca se acepta por defecto) -----------------------------------
echo
log "Licencia: https://ibm.biz/CPE_CCx_License_26_0_1   Avisos: https://ibm.biz/CCx_Notices"
log "Al aceptar se habilita por defecto el envío de datos de uso (IBM Software Central)."
if [ "${CCX_ACCEPT_LICENSE:-}" = "yes" ]; then ACCEPT_LICENSE=yes
elif [ "${ACCEPT_LICENSE:-}" != "yes" ]; then
  [ "${CCX_NONINTERACTIVE:-0}" = 1 ] && die "Para ejecutar sin preguntas exporta CCX_ACCEPT_LICENSE=yes (aceptas la licencia de IBM)."
  read -r -p "¿Aceptas el IBM International Program License Agreement de Content Cortex? (escribe 'yes'): " a
  [ "$a" = "yes" ] || die "Licencia no aceptada. No se puede continuar."
  ACCEPT_LICENSE=yes
fi

# --- comprobaciones previas (no destructivas) -----------------------------------------------------------
if command -v helm >/dev/null 2>&1; then
  if printf '%s' "$ENTITLEMENT_KEY" | helm registry login cp.icr.io --username cp --password-stdin >/dev/null 2>&1; then
    ok "La entitlement key es válida (login a cp.icr.io)"
  else
    die "La entitlement key no es válida o no tiene derecho sobre Content Cortex (helm registry login cp.icr.io falló)."
  fi
else
  warn "helm aún no está instalado: la entitlement key se validará en la fase 03."
fi

log "Probando la API key de watsonx.ai contra el space y el modelo..."
set +e
WX_OUT="$(WXAI_REGION="$WXAI_REGION" WXAI_SPACE_ID="$WXAI_SPACE_ID" WXAI_MODEL_ID="$WXAI_MODEL_ID" WXAI_API_KEY="$WXAI_API_KEY" \
          python3 "$ROOT/tools/test-wxai-key.py" 2>&1)"
WX_RC=$?
set -e
printf '%s\n' "$WX_OUT" | mask | tail -8
if [ "$WX_RC" -ne 0 ]; then
  warn "La API key NO puede usar ese space/modelo. El agente fallará (403 SPACES0008E) hasta que añadas el"
  warn "Service ID de la key como colaborador del deployment space. Puedes continuar y corregirlo después."
  confirm "¿Continuar de todas formas?" n || die "Abortado por el usuario."
else
  ok "watsonx.ai responde con esa clave, space y modelo"
fi

# --- guardar ----------------------------------------------------------------------------------------------
for kv in NS AUTH_NS LICENSE_METRIC BLOCK_SC FILE_SC APPS_DOMAIN WXAI_URL WXAI_REGION WXAI_SPACE_ID WXAI_PROJECT_ID WXAI_MODEL_ID ACCEPT_LICENSE; do
  set_env "$CONFIG_FILE" "$kv" "${!kv}"
done
set_env "$SECRETS_FILE" ENTITLEMENT_KEY "$ENTITLEMENT_KEY"
set_env "$SECRETS_FILE" WXAI_API_KEY "$WXAI_API_KEY"
ok "Configuración guardada en $STATE_DIR (secretos con chmod 600)"
mark_done 00-configure
