#!/usr/bin/env bash
# Pruebas OFFLINE (no tocan ningún cluster): sintaxis, shellcheck (si existe), py_compile, toml_set,
# fill-properties con property files sintéticos y validación de las plantillas silent con los validadores de IBM.
#   tests/run-tests.sh            (el repo de IBM se clona a .work si no existe, para validar las plantillas)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
PASS=0; FAIL=0
t() { local name="$1"; shift; if "$@" >/tmp/ccx-test.out 2>&1; then PASS=$((PASS+1)); echo "  ok   $name"; else FAIL=$((FAIL+1)); echo "  FAIL $name"; sed 's/^/       /' /tmp/ccx-test.out | tail -15; fi; }

echo "== sintaxis"
for f in install.sh uninstall.sh lib/common.sh phases/*.sh tools/*.sh tests/*.sh; do t "bash -n $f" bash -n "$f"; done
for f in tools/*.py; do t "py_compile $f" python3 -m py_compile "$f"; done
if command -v shellcheck >/dev/null; then
  t "shellcheck" shellcheck -x -S warning install.sh uninstall.sh lib/common.sh phases/*.sh tools/*.sh
else echo "  (shellcheck no instalado: se omite)"; fi

echo "== toml_set"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/a.toml" <<'T'
TOP = "<Required>"
[S1]
K = """<Required>"""
L = ["""<Required>"""]
[S2]
K = "<Required>"
# K = "comentario"
T
echo '{"":{"TOP":"x"},"S1":{"K":"pw","L":["u1","u2"]},"S2":{"K":true}}' | python3 tools/toml_set.py "$TMP/a.toml" -
t "toml_set valores" bash -c "grep -q '^TOP = \"x\"' $TMP/a.toml && grep -q 'K = \"\"\"pw\"\"\"' $TMP/a.toml && grep -q 'L = \[\"u1\", \"u2\"\]' $TMP/a.toml && grep -q '^K = true' $TMP/a.toml && grep -q '# K = \"comentario\"' $TMP/a.toml"
t "toml_set clave inexistente => rc 3" bash -c "! echo '{\"\":{\"NOPE\":1}}' | python3 tools/toml_set.py $TMP/a.toml - 2>/dev/null; [ \${PIPESTATUS[1]} -eq 3 ]"

echo "== fill-properties (property files sintéticos)"
mkdir -p "$TMP/state" "$TMP/prop"
cat > "$TMP/state/config.env" <<'T'
NS='ibm-content'
AUTH_NS='ibm-auth'
APPS_DOMAIN='apps.example.com'
FILE_SC='ocs-storagecluster-cephfs'
WXAI_SPACE_ID='00000000-0000-0000-0000-000000000000'
WXAI_MODEL_ID='openai/gpt-oss-120b'
T
printf "WXAI_API_KEY='dummy-key'\n" > "$TMP/state/secrets.env"
printf "LDAP_ADMIN_PW='a'\nPW_CCXADMIN='b'\nPW_ALICE='c'\nPW_BOB='d'\nKC_ADMIN_PW='e'\n" > "$TMP/state/auth-secrets.env"
printf "IDP_CLIENT_ID='ccx'\nIDP_CLIENT_SECRET='s3cr3t'\n" > "$TMP/state/ccx-idp.env"
cat > "$TMP/prop/content_db_server.toml" <<'T'
DATABASE_TYPE = "postgresql"
[GCD]
DATABASE_SERVERNAME = "<Required>"
DATABASE_NAME = "<Required>"
DATABASE_USERNAME = """<Required>"""
DATABASE_PASSWORD = "<Required>"
[OS]
DATABASE_SERVERNAME = "<Required>"
DATABASE_NAME = "<Required>"
DATABASE_USERNAME = """<Required>"""
DATABASE_PASSWORD = "<Required>"
[ICN]
DATABASE_SERVERNAME = "<Required>"
DATABASE_NAME = "<Required>"
DATABASE_USERNAME = """<Required>"""
DATABASE_PASSWORD = "<Required>"
T
cat > "$TMP/prop/content_ldap_server.toml" <<'T'
[LDAP]
LDAP_SERVER = "<Required>"
LDAP_BASE_DN = "<Required>"
LDAP_GROUP_BASE_DN = "<Required>"
LDAP_BIND_DN = """<Required>"""
LDAP_BIND_DN_PASSWORD = "<Required>"
T
printf '[IDP]\nCLIENT_ID = "<Required>"\nCLIENT_SECRET = "<Required>"\n' > "$TMP/prop/ccx-identity_provider.toml"
printf 'NAVIGATOR_EXTERNAL_URL = "<Required>"\n' > "$TMP/prop/aiservices_integration.toml"
printf 'ADMIN_PASSWORD = "<Required>"\n' > "$TMP/prop/ccx-model-gateway.toml"
printf 'VAULT_URL = "<Required>"\nVAULT_ROLE = "<Required>"\nSLOW_FILE_STORAGE_CLASSNAME = "<Required>"\nMEDIUM_FILE_STORAGE_CLASSNAME = "<Required>"\nFAST_FILE_STORAGE_CLASSNAME = "<Required>"\n' > "$TMP/prop/ccx-deployment.toml"
printf 'KEYSTORE_PASSWORD = "<Required>"\nLTPA_PASSWORD = "<Required>"\nFNCM_LOGIN_USER = """<Required>"""\nFNCM_LOGIN_PASSWORD = "<Required>"\nICN_LOGIN_USER = """<Required>"""\nICN_LOGIN_PASSWORD = "<Required>"\nGCD_ADMIN_USER_NAME = ["""<Required>"""]\nGCD_ADMIN_GROUPS_NAME = ["""<Required>"""]\nCPE_OBJ_STORE_OS_ADMIN_USER_GROUPS = ["""<Required>"""]\n' > "$TMP/prop/content_user_group.toml"
printf '[wxai]\nWXAI_API_KEY = "<Required>"\nWXAI_KVP_MODEL_ID = "<Required>"\nWXAI_KVP_SPACE_ID = """<Required>"""\nWXAI_SEMANTIC_KVP_MODEL_ID = "<Required>"\nWXAI_SEMANTIC_KVP_SPACE_ID = """<Required>"""\nWXAI_IMAGE_DESCRIPTION_MODEL_ID = "<Required>"\nWXAI_IMAGE_DESCRIPTION_SPACE_ID = """<Required>"""\n' > "$TMP/prop/ccx-wdu.toml"
t "fill-properties no deja <Required>" python3 tools/fill-properties.py "$TMP/prop" "$TMP/state"
t "valores correctos" bash -c "grep -q 'ccx-content-pg-rw.ibm-content.svc.cluster.local' $TMP/prop/content_db_server.toml && grep -q 'navigator-ibm-content.apps.example.com\"' $TMP/prop/aiservices_integration.toml && grep -q 'cn=admin,dc=example,dc=org' $TMP/prop/content_ldap_server.toml && ! grep -q Required $TMP/prop/*.toml"
t "permisos 600 en secretos" bash -c "[ \$(stat -c %a $TMP/state/ccx-content-secrets.env) = 600 ]"
t "idempotente" python3 tools/fill-properties.py "$TMP/prop" "$TMP/state"

echo "== fase 00 con oc/helm falsos (modo no interactivo)"
t "00-configure no interactivo" env PATH="$ROOT/tests/fake-bin:$PATH" OC="$ROOT/tests/fake-bin/oc" CCX_STATE_DIR="$TMP/st00" \
  CCX_NONINTERACTIVE=1 CCX_ASSUME_YES=1 CCX_ACCEPT_LICENSE=yes CCX_ENTITLEMENT_KEY=dummy CCX_WXAI_API_KEY=dummy \
  CCX_WXAI_SPACE_ID=11111111-1111-1111-1111-111111111111 bash phases/00-configure.sh
t "00 guarda config y secretos 600" bash -c "grep -q \"WXAI_MODEL_ID='openai/gpt-oss-120b'\" $TMP/st00/config.env && [ \$(stat -c %a $TMP/st00/secrets.env) = 600 ] && ! grep -q dummy $TMP/st00/config.env"
t "install.sh status" env PATH="$ROOT/tests/fake-bin:$PATH" OC="$ROOT/tests/fake-bin/oc" CCX_STATE_DIR="$TMP/st00" bash install.sh status

echo "== plantillas silent vs validadores de IBM"
if [ ! -d .work/ibm-content-cortex-containers ]; then
  mkdir -p .work && git clone -q --depth 1 --branch "${IBM_REPO_REF:-26.0.1}" https://github.com/ibm-ecm/ibm-content-cortex-containers.git .work/ibm-content-cortex-containers || echo "  (sin acceso a GitHub: se omite)"
fi
if [ -d .work/ibm-content-cortex-containers ]; then
  python3 -c "import pydantic, toml" 2>/dev/null || pip install -q pydantic toml rich typer questionary 2>/dev/null || true
  t "silent_install_* validan con pydantic de IBM" python3 tests/validate_silent_templates.py
fi
echo
echo "Resultado: $PASS ok, $FAIL fallos"
[ "$FAIL" -eq 0 ]
