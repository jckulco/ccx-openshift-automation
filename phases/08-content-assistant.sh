#!/usr/bin/env bash
# Fase 08: IBM Content Assistant Client Managed Software 1.0.4 (ICACMS) - OpenSearch, operador, CASCluster,
#          usuario de servicio, proveedores de IA (CLI ibmca) y comprobaciones.
#
# Pasos (cada uno idempotente, con marca en .state/done):
#   1  licencia de Content Assistant (la aceptas TÚ; este script nunca la acepta por su cuenta)
#   2  repo de IBM (content-assistant) + venv de sus scripts
#   3  OpenSearch 3.6.0 (chart comunitario, 1 nodo) en 2 etapas: instalación -> TLS propio (CA estricta, SAN, PKCS#8)
#   4  usuario genai-service-user y roles ibm-genai-* en OpenSearch (equivale al job de IBM, que sólo existe para CP4BA)
#   5  operador + CASCluster 'casdeploy' (deploy_operator.py / prerequisites.py en modo --silent, aplicado con oc)
#   6  comprobación del gateway (LLM y embeddings por la ruta externa) y CLI ibmca (login, proveedores, LLM/embeddings)
# Pendiente de ti (no automatizable, ver docs/MANUAL-STEPS.md §5-§7): add-on "26.0.0 Gen AI Extensions" y activación en
#   ACCE, plug-in "IBM Content Assistant" en Navigator, suscripción "Document-Vector Index".
# Código de salida 10 = falta el paquete ICACMS (ibmca) -> descarga manual, ver mensaje.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."
need_cmd helm openssl curl git python3
export OC NS
# shellcheck source=../tools/os-api.sh
source "$ROOT/tools/os-api.sh"

title "Fase 08 - IBM Content Assistant (ICACMS 1.0.4)"
phase_done 05-content && phase_done 06-model-gateway || die "Primero deben estar hechas las fases 05 y 06."

CAS_REPO_URL="${CAS_REPO_URL:-https://github.com/ibm-ecm/ibm-content-assistant-client-managed-software.git}"
CAS_REPO_REF="${CAS_REPO_REF:-v1.0.4}"
CAS_DIR="$WORK_DIR/ibm-content-assistant"; CAS_SCRIPTS="$CAS_DIR/scripts"; CAS_VENV="$WORK_DIR/cas-venv"
IBMCA_VENV="$WORK_DIR/ibmca-venv"
OS_CERTS="$STATE_DIR/os-certs"
OS_CHART_VERSION="${OS_CHART_VERSION:-3.6.0}"
CAS_LLM_MODEL="${CAS_LLM_MODEL:-meta-llama/llama-3-3-70b-instruct}"
CAS_EMBED_MODEL="${CAS_EMBED_MODEL:-intfloat/multilingual-e5-large}"
export CAS_LLM_MODEL CAS_EMBED_MODEL

# --- 1) licencia ------------------------------------------------------------------------------------------------------
if [ "${CAS_ACCEPT_LICENSE:-}" != "yes" ]; then
  log "Licencia de Content Assistant: https://ibm.biz/CAS_License_1_0_0   Avisos: https://ibm.biz/CAS_Notices_1_0_0"
  if [ "${CCX_ACCEPT_CAS_LICENSE:-}" = "yes" ]; then CAS_ACCEPT_LICENSE=yes
  elif [ "${CCX_NONINTERACTIVE:-0}" = 1 ]; then die "Para ejecutar sin preguntas exporta CCX_ACCEPT_CAS_LICENSE=yes (aceptas la licencia de IBM Content Assistant)."
  else
    read -r -p "¿Aceptas la licencia de IBM Content Assistant? (escribe 'yes'): " a
    [ "$a" = "yes" ] || die "Licencia no aceptada. No se puede continuar."
    CAS_ACCEPT_LICENSE=yes
  fi
  set_env "$CONFIG_FILE" CAS_ACCEPT_LICENSE yes
fi
[ -n "${ENTITLEMENT_KEY:-}" ] || die "Falta la entitlement key (.state/secrets.env, fase 00)."

# --- 2) repo de IBM y venv ---------------------------------------------------------------------------------------------
if [ ! -d "$CAS_DIR/.git" ]; then
  log "Clonando $CAS_REPO_URL ($CAS_REPO_REF)"
  git clone --depth 1 --branch "$CAS_REPO_REF" "$CAS_REPO_URL" "$CAS_DIR" 2>&1 | tail -2
fi
[ -f "$CAS_SCRIPTS/prerequisites.py" ] || die "El repo de Content Assistant no tiene scripts/prerequisites.py ($CAS_DIR)."
if [ ! -f "$CAS_VENV/bin/activate" ]; then
  python3.12 -m venv "$CAS_VENV" 2>/dev/null || python3 -m venv "$CAS_VENV"
  # shellcheck disable=SC1091
  . "$CAS_VENV/bin/activate"; pip install -q --upgrade pip; pip install -q -r "$CAS_SCRIPTS/requirements.txt" pyyaml
  # los scripts de IBM llaman a 'kubectl': en OpenShift se usa 'oc' mediante un envoltorio (igual que en la fase 01)
  printf '#!/bin/sh\nexec %s "$@"\n' "$OC" > "$CAS_VENV/bin/kubectl"; chmod +x "$CAS_VENV/bin/kubectl"
else
  # shellcheck disable=SC1091
  . "$CAS_VENV/bin/activate"
fi
ok "Repo y venv de Content Assistant listos"

# --- 3) OpenSearch -----------------------------------------------------------------------------------------------------
# Contraseña de admin: >=12 caracteres con mayúscula, minúscula, número y símbolo. Sólo en .state (chmod 600).
if [ -z "${OS_ADMIN_PASSWORD:-}" ]; then
  OS_ADMIN_PASSWORD="$(gen_pw)Aa1!"; set_env "$CONTENT_SECRETS_FILE" OS_ADMIN_PASSWORD "$OS_ADMIN_PASSWORD"
fi
if ! oc_ get secret opensearch-admin -n "$NS" >/dev/null 2>&1; then
  oc_ create secret generic opensearch-admin -n "$NS" --from-literal=username=admin --from-literal=password="$OS_ADMIN_PASSWORD" >/dev/null
fi
VALUES="$STATE_DIR/opensearch-values.yaml"
write_os_values() { # write_os_values demo|tls
  umask 077
  cat > "$VALUES" <<YAML
clusterName: opensearch-cluster
nodeGroup: master
singleNode: true
replicas: 1
image:
  tag: "$OS_CHART_VERSION"
opensearchJavaOpts: "-Xms1g -Xmx1g"
resources:
  requests: { cpu: "500m", memory: "2Gi" }
  limits:   { cpu: "2",    memory: "2Gi" }
persistence:
  enabled: true
  storageClass: $BLOCK_SC
  size: 30Gi
  enableInitChown: false      # sin initContainer root (OpenShift)
sysctlInit:
  enabled: false              # sin privilegios; en un nodo no hace falta max_map_count
securityContext: null         # el SCC de OpenShift asigna el UID
podSecurityContext: null
extraEnvs:
YAML
  [ "$1" = tls ] && printf '  - name: DISABLE_INSTALL_DEMO_CONFIG\n    value: "true"\n' >> "$VALUES"
  cat >> "$VALUES" <<'YAML'
  - name: OPENSEARCH_INITIAL_ADMIN_PASSWORD
    valueFrom:
      secretKeyRef: { name: opensearch-admin, key: password }
YAML
  if [ "$1" = tls ]; then cat >> "$VALUES" <<'YAML'
secretMounts:
  - name: opensearch-tls
    secretName: opensearch-tls
    path: /usr/share/opensearch/config/certs
config:
  opensearch.yml: |
    cluster.name: opensearch-cluster
    network.host: 0.0.0.0
    plugins.security.ssl.transport.pemcert_filepath: certs/tls.crt
    plugins.security.ssl.transport.pemkey_filepath: certs/tls.key
    plugins.security.ssl.transport.pemtrustedcas_filepath: certs/ca.crt
    plugins.security.ssl.transport.enforce_hostname_verification: false
    plugins.security.ssl.http.enabled: true
    plugins.security.ssl.http.pemcert_filepath: certs/tls.crt
    plugins.security.ssl.http.pemkey_filepath: certs/tls.key
    plugins.security.ssl.http.pemtrustedcas_filepath: certs/ca.crt
    plugins.security.allow_default_init_securityindex: true
    plugins.security.restapi.roles_enabled: ["all_access", "security_rest_api_access"]
    plugins.security.system_indices.enabled: true
YAML
  fi
}
os_rollout() { oc_ -n "$NS" rollout status sts/opensearch-cluster-master --timeout=900s >/dev/null; }
os_health_demo() { # etapa 1: certificados de demo (aún sin CA propia montada)
  oc_ -n "$NS" exec opensearch-cluster-master-0 -c opensearch -- sh -c \
    'curl -sk -u "admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD" https://localhost:9200/_cluster/health' 2>/dev/null | grep -q '"status":"\(green\|yellow\)"'
}
os_health_tls() { os_api GET _cluster/health </dev/null | grep -q '"status":"\(green\|yellow\)"'; }

if ! phase_done 08-os-install; then
  log "Instalando OpenSearch $OS_CHART_VERSION (chart comunitario, etapa 1: certificados de demo)"
  helm repo add opensearch https://opensearch-project.github.io/helm-charts/ --force-update >/dev/null; helm repo update >/dev/null
  write_os_values demo
  helm upgrade --install opensearch opensearch/opensearch --version "$OS_CHART_VERSION" -n "$NS" -f "$VALUES" >/dev/null
  os_rollout
  wait_until "OpenSearch responde (etapa 1)" 600 10 os_health_demo || die "OpenSearch no responde. oc -n $NS logs opensearch-cluster-master-0"
  mark_done 08-os-install
else ok "OpenSearch (etapa 1) ya instalado"; fi

if ! phase_done 08-os-tls; then
  log "Certificados propios de OpenSearch (CA estricta, SAN del Service, llave PKCS#8)"
  bash "$ROOT/tools/gen-opensearch-certs.sh" "$OS_CERTS" "$NS"
  oc_ -n "$NS" delete secret opensearch-tls --ignore-not-found >/dev/null
  oc_ -n "$NS" create secret generic opensearch-tls \
    --from-file=ca.crt="$OS_CERTS/ca.crt" --from-file=tls.crt="$OS_CERTS/tls.crt" --from-file=tls.key="$OS_CERTS/tls.key" >/dev/null
  write_os_values tls
  helm upgrade opensearch opensearch/opensearch --version "$OS_CHART_VERSION" -n "$NS" -f "$VALUES" >/dev/null
  oc_ -n "$NS" delete pod opensearch-cluster-master-0 --wait=false >/dev/null 2>&1 || true   # fuerza la lectura de los certificados
  sleep 10; os_rollout
  wait_until "OpenSearch responde con TLS propio (CA + nombre verificados)" 600 10 os_health_tls \
    || die "OpenSearch no responde con el certificado nuevo. Rollback: helm rollback opensearch 1 -n $NS (ver TROUBLESHOOTING #27)"
  mark_done 08-os-tls
else ok "OpenSearch con TLS propio ya configurado"; fi
rm -f "$VALUES"   # contiene sólo referencias a secretos, pero se regenera siempre

# --- 4) usuario de servicio y roles en OpenSearch -----------------------------------------------------------------------
if ! phase_done 08-os-genai-user; then
  if [ -z "${GENAI_SERVICE_USER_PASSWORD:-}" ]; then
    GENAI_SERVICE_USER_PASSWORD="$(gen_pw)Aa1!"; set_env "$CONTENT_SECRETS_FILE" GENAI_SERVICE_USER_PASSWORD "$GENAI_SERVICE_USER_PASSWORD"
  fi
  log "Creando genai-service-user y los roles ibm-genai-index-manager / ibm-genai-document-manager"
  # Definiciones idénticas a descriptors/opensearch/opensearch_cluster_permission_job.yaml de IBM
  USER_JSON="$(GP="$GENAI_SERVICE_USER_PASSWORD" python3 -c 'import json,os; print(json.dumps({"password":os.environ["GP"],"attributes":{"description":"GenAI Content Assistant service user"}}))')"
  r() { grep -q -E '"status":"(CREATED|OK)"' <<<"$1" || die "OpenSearch rechazó la configuración de seguridad: $(sed -E 's/"password"[^,}]*//' <<<"$1" | head -c 300)"; }
  r "$(os_api PUT _plugins/_security/api/internalusers/genai-service-user <<<"$USER_JSON")"
  r "$(os_api PUT _plugins/_security/api/roles/ibm-genai-index-manager <<<'{"cluster_permissions":["cluster:monitor/main"],"index_permissions":[{"index_patterns":["ibm-genai-*"],"allowed_actions":["create_index","manage"]}]}')"
  r "$(os_api PUT _plugins/_security/api/roles/ibm-genai-document-manager <<<'{"index_permissions":[{"index_patterns":["ibm-genai-*"],"allowed_actions":["index","delete","read","write","indices:admin/get","indices:admin/refresh"]}]}')"
  r "$(os_api PUT _plugins/_security/api/rolesmapping/ibm-genai-index-manager <<<'{"users":["genai-service-user"]}')"
  r "$(os_api PUT _plugins/_security/api/rolesmapping/ibm-genai-document-manager <<<'{"users":["genai-service-user"]}')"
  unset USER_JSON
  mark_done 08-os-genai-user
else ok "Usuario genai-service-user ya creado"; fi

# --- 5) operador + CASCluster --------------------------------------------------------------------------------------------
# Datos del gateway: ruta externa (con destinationCA y timeout, ver fase 06) y clave del tenant
MG_HOST="$(route_host "$NS" model-gateway)"; [ -n "$MG_HOST" ] || die "No existe la ruta model-gateway en $NS."
set_env "$CONFIG_FILE" MG_ROUTE_URL "https://$MG_HOST"
MGW_STATE="$IBM_SCRIPTS/.mgw/state.json"; [ -f "$MGW_STATE" ] || die "No encuentro $MGW_STATE (fase 06)."
TENANT_KEY="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tenant"]["apikey"])' "$MGW_STATE")"
gw_call() { # gw_call chat|embeddings  -> código HTTP por la ruta externa (la clave va por stdin de curl, no por argv)
  local u b
  if [ "$1" = chat ]; then u=chat/completions; b="{\"model\":\"$CAS_LLM_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"Responde solo: OK\"}],\"max_tokens\":20}"
  else u=embeddings; b="{\"model\":\"$CAS_EMBED_MODEL\",\"input\":\"prueba\"}"; fi
  printf 'header = "Authorization: Bearer %s"\n' "$TENANT_KEY" | curl -sk -o /dev/null -w '%{http_code}' --max-time 120 -K - \
    -H 'Content-Type: application/json' -d "$b" "https://$MG_HOST/v1/$u" || echo 000
}
log "Comprobando el Model Gateway por la ruta externa (embeddings y LLM)"
[ "$(gw_call embeddings)" = 200 ] || die "El gateway no sirve embeddings ($CAS_EMBED_MODEL) por https://$MG_HOST. Revisa la fase 06 y TROUBLESHOOTING #25/#26."
[ "$(gw_call chat)" = 200 ] || warn "El gateway no respondió 200 para $CAS_LLM_MODEL (¿no está registrado? fase 06). Content Assistant no podrá resumir."

if ! phase_done 08-cas-deploy; then
  cd "$CAS_SCRIPTS"        # IMPORTANTE: version.toml se busca en el directorio padre del cwd
  S1="$CAS_SCRIPTS/silent_config/silent_install_deployoperator.toml"; S2="$CAS_SCRIPTS/silent_config/silent_install_prerequisites.toml"
  for f in "$S1" "$S2"; do [ -f "$f.orig" ] || cp -p "$f" "$f.orig"; done
  restore() { for f in "$S1" "$S2"; do [ -f "$f.orig" ] && cp -p "$f.orig" "$f"; done; }   # nunca dejar la key en el repo de IBM
  trap restore EXIT

  # 5a) operador (Helm) -----------------------------------------------------------------------------------------------
  cp -p "$S1.orig" "$S1"
  NSV="$NS" EK="$ENTITLEMENT_KEY" python3 -c 'import os,sys; print(open(sys.argv[1]).read().replace("@NS@", os.environ["NSV"]).replace("@ENTITLEMENT_KEY@", os.environ["EK"]).replace("@CAS_ACCEPT@","true"))' \
    "$ROOT/templates/cas_silent_deployoperator.set.json" | python3 "$ROOT/tools/toml_set.py" "$S1" -
  chmod 600 "$S1"
  log "deploy_operator.py --silent (operador de Content Assistant)"
  set +e; python deploy_operator.py --silent 2>&1 | mask | tee "$STATE_DIR/cas_deploy_operator.log" | tail -25; RC=${PIPESTATUS[0]}; set -e
  cp -p "$S1.orig" "$S1"
  [ "$RC" -eq 0 ] || die "deploy_operator.py (Content Assistant) terminó con código $RC (log: $STATE_DIR/cas_deploy_operator.log)"
  wait_until "Operador de Content Assistant listo" 600 10 pods_ready_by_prefix "$NS" ibm-content-assistant-operator

  # 5b) gather silencioso -> property files ---------------------------------------------------------------------------
  cp -p "$S2.orig" "$S2"
  sed -i -E 's/^#\s*(MODELGATEWAY_SSL_ENABLED\s*=)/\1/' "$S2"          # viene comentada en la plantilla de IBM
  NSV="$NS" python3 -c 'import os,sys; print(open(sys.argv[1]).read().replace("@NS@", os.environ["NSV"]))' \
    "$ROOT/templates/cas_silent_prerequisites.set.json" | python3 "$ROOT/tools/toml_set.py" "$S2" -
  log "prerequisites.py --silent gather"
  python prerequisites.py --silent gather 2>&1 | mask | tail -15 || true
  PROP="$CAS_SCRIPTS/propertyFile/$NS"
  [ -f "$PROP/cas_properties.toml" ] || die "gather no generó $PROP/cas_properties.toml (revisa la salida; ver TROUBLESHOOTING #28)."

  # 5c) certificados y valores --------------------------------------------------------------------------------------
  mkdir -p "$PROP/ssl-certs/modelgateway" "$PROP/ssl-certs/vectordb" "$PROP/ssl-certs/trusted-certs"
  # CA de OpenSearch (la de este repo) y certificado de servidor, como en la sesión de referencia
  cp "$OS_CERTS/ca.crt" "$PROP/ssl-certs/vectordb/opensearch-ca.crt"; cp "$OS_CERTS/tls.crt" "$PROP/ssl-certs/vectordb/opensearch-server.crt"
  # cadena que sirve el router para la ruta del gateway (Let's Encrypt en TechZone)
  T="$(mktemp -d)"
  openssl s_client -connect "$MG_HOST:443" -servername "$MG_HOST" -showcerts </dev/null 2>/dev/null \
    | awk -v d="$T" '/BEGIN CERTIFICATE/{n++; f=1} f{print > (d "/gw-chain-" n ".pem")} /END CERTIFICATE/{f=0}'
  ls "$T"/gw-chain-*.pem >/dev/null 2>&1 || die "No pude leer el certificado de $MG_HOST:443"
  cat "$T"/gw-chain-*.pem > "$PROP/ssl-certs/modelgateway/modelgateway-ca.crt"; rm -rf "$T"
  python3 "$ROOT/tools/cas-fill-properties.py" "$PROP" "$STATE_DIR" "$MGW_STATE"
  if grep -n 'Required' "$PROP"/cas_*.toml | grep -v -E '^\S+:\s*#'; then die "Quedan <Required> sin rellenar en $PROP"; fi

  # 5d) generate + aplicar (NO se usa 'validate': desde el bastión no resuelve *.svc; las comprobaciones se hicieron arriba) ---
  log "prerequisites.py --silent generate"
  python prerequisites.py --silent generate 2>&1 | mask | tail -15 || true
  GEN="$CAS_SCRIPTS/generatedFiles/$NS"
  CR="$(ls "$GEN"/ibm_content_assistant_cr*.yaml 2>/dev/null | head -1 || true)"; [ -n "$CR" ] || die "generate no produjo el CR de Content Assistant en $GEN"
  for d in secrets ssl configmaps metrics; do [ -d "$GEN/$d" ] && oc_ apply -n "$NS" -R -f "$GEN/$d/" | sed 's/^/   /'; done
  log "Aplicando CASCluster"
  apply_retry -n "$NS" -f "$CR"
  restore; trap - EXIT
  cas_ready() {
    oc_ get cascluster casdeploy -n "$NS" -o json 2>/dev/null | python3 -c '
import json, sys
c = {x["type"]: x["status"] for x in json.load(sys.stdin).get("status", {}).get("conditions", [])}
sys.exit(0 if c.get("Running") == "True" and c.get("PostDeployCompleted") == "True" else 1)'
  }
  wait_until "CASCluster 'casdeploy' Running y PostDeployCompleted" 1500 15 cas_ready \
    || { oc_ logs -n "$NS" deploy/ibm-content-assistant-deployment --tail=15 2>&1 | cut -c1-200 || true; die "Content Assistant no arrancó (ver TROUBLESHOOTING #27)."; }
  mark_done 08-cas-deploy
else ok "Content Assistant ya desplegado"; fi
CAS_HOST="$(route_host "$NS" cas)"; [ -n "$CAS_HOST" ] || die "No existe la ruta 'cas'."
set_env "$CONFIG_FILE" CAS_URL "https://$CAS_HOST"
[ "$(curl -sk -o /dev/null -w '%{http_code}' --max-time 15 "https://$CAS_HOST/")" = 200 ] && ok "Ruta cas: https://$CAS_HOST (HTTP 200)" || warn "La ruta cas no devuelve 200 todavía."

# --- 6) CLI ibmca: proveedores de IA ---------------------------------------------------------------------------------------
WHL="${CCX_IBMCA_WHL:-}"
if [ ! -f "$IBMCA_VENV/bin/ibmca" ]; then
  if [ -z "$WHL" ] || [ ! -f "$WHL" ]; then
    ZIP="${CCX_ICA_PACKAGE:-}"; [ -n "$ZIP" ] && [ -f "$ZIP" ] || ZIP="$(ls "$WORK_DIR"/ICACMS*.zip 2>/dev/null | head -1 || true)"
    if [ -n "$ZIP" ] && [ -f "$ZIP" ]; then
      T="$(mktemp -d)"; unzip -q -o "$ZIP" '*ibmca-*.whl' -d "$T" 2>/dev/null || true
      WHL="$(find "$T" -name 'ibmca-*.whl' | head -1)"; [ -n "$WHL" ] && { mkdir -p "$WORK_DIR/icacms"; cp "$WHL" "$WORK_DIR/icacms/"; WHL="$WORK_DIR/icacms/$(basename "$WHL")"; }; rm -rf "$T"
    fi
  fi
  if [ -z "$WHL" ] || [ ! -f "$WHL" ]; then
    warn "Falta el paquete de Content Assistant (ibmca-1.0.4-py3-none-any.whl). Descarga ICACMS_1.0.4_ML.zip (Passport Advantage / ver"
    warn "docs/MANUAL-STEPS.md §5) y ejecuta:  CCX_ICA_PACKAGE=/ruta/ICACMS_1.0.4_ML.zip ./install.sh --only 08"
    warn "Content Assistant ya está desplegado; sólo faltan los proveedores de IA (CLI ibmca)."
    exit 10
  fi
  PY="$(command -v python3.13 || command -v python3.12 || command -v python3)"
  "$PY" -m venv "$IBMCA_VENV"; "$IBMCA_VENV/bin/pip" install -q --upgrade pip; "$IBMCA_VENV/bin/pip" install -q "$WHL"
fi
export PATH="$IBMCA_VENV/bin:$PATH"
ibmca config url "$CAS_URL" >/dev/null
[ -n "${GENAI_SERVICE_USER_PASSWORD:-}" ] || die "Falta GENAI_SERVICE_USER_PASSWORD en $CONTENT_SECRETS_FILE (fase 08, paso 4)."
ibmca login -u genai-service-user -p "$GENAI_SERVICE_USER_PASSWORD" >/dev/null 2>&1 || die "ibmca login falló (¿usuario genai-service-user en OpenSearch? TROUBLESHOOTING #29)."
python3 "$ROOT/tools/cas-providers.py"
mark_done 08-cas-providers

echo
ok "Content Assistant desplegado y configurado. Estado de los object stores activados (vacío hasta activar en ACCE):"
ibmca list domains 2>/dev/null | head -20 || true
cat <<TXT

${C_B}Pasos MANUALES de Content Assistant (docs/MANUAL-STEPS.md §5-§7):${C_0}
  1. ACCE > object store 'os' > Install Add-on Features > "26.0.0 Gen AI Extensions"  (Refresh del árbol).
  2. ACCE > os > Administrative > Content Assistant > GenAI Configuration: Access code = cualquier valor, Service URL = $CAS_URL,
     modelo de embeddings en blanco (queda FIJO al activar), sin proxy. Index Status debe dejar de ser "Inactive".
  3. ACCE > Data Design > Classes > Document > Actions > New subscription "Document-Vector Index" (Checkin + Update Event,
     acción "Gen AI Vector Indexing Request Event Action", habilitada, Include subclasses). Sólo indexa documentos NUEVOS.
  4. Navigator (admin): Plug-ins > New Plug-in > JAR /opt/ibm/intPlugins/genai/genaiPlugin.jar > Load > Save; desktop > Features > Ask Your Repository.
TXT
mark_done 08-content-assistant
