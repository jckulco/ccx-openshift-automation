#!/usr/bin/env bash
# Fase 02: OpenLDAP + Keycloak de laboratorio (namespace ibm-auth), atributo ibm-entryUuid y cliente OIDC "ccx".
#   OJO: es un servicio de LABORATORIO (Keycloak start-dev con H2). Para producción usa tu LDAP/IdP corporativo
#   y rellena los property files a mano (ver docs/ARCHITECTURE.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."
export OC CCX_STATE_DIR="$STATE_DIR"
CONTENT_NS="$NS"      # NS de las herramientas de laboratorio = namespace de autenticación (se pasa sólo por comando)

title "Fase 02 - OpenLDAP + Keycloak"
NS="$AUTH_NS" bash "$ROOT/tools/deploy-auth.sh"

# Atributo ibm-entryUuid: CPE/Navigator usan el tipo "IBM Security Verify Directory", que identifica
# usuarios/grupos por ese atributo. HAY QUE HACERLO ANTES de crear el dominio P8 (si no, ccxadmin no
# queda como administrador y habría que ejecutar tools/reset-gcd.sh).
log "Añadiendo ibm-entryUuid a los usuarios/grupos de OpenLDAP"
NS="$AUTH_NS" bash "$ROOT/tools/fix-ldap-guid.sh" | tail -8

# Cliente OIDC con redirect URIs de las rutas previstas de Content Cortex
load_env "$AUTH_SECRETS_FILE"
HOSTS=(cpe cpe-stless graphql navigator tm reasoning-service model-gateway)
URIS=()
for h in "${HOSTS[@]}"; do URIS+=("https://${h}-${CONTENT_NS}.${APPS_DOMAIN}/*"); done
log "Configurando Keycloak (realm ccx, federación LDAP, cliente OIDC)"
NS="$AUTH_NS" python3 "$ROOT/tools/setup-keycloak.py" "${URIS[@]}"
load_env "$IDP_FILE"
[ -n "${IDP_DISCOVERY_URL:-}" ] || die "setup-keycloak.py no generó ccx-idp.env"
ok "IdP listo: $IDP_DISCOVERY_URL"
mark_done 02-auth
