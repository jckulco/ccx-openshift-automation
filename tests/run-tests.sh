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
t "permisos 600 en secretos" bash -c "[ \$(stat -f %Lp $TMP/state/ccx-content-secrets.env 2>/dev/null || stat -c %a $TMP/state/ccx-content-secrets.env) = 600 ]"
t "idempotente" python3 tools/fill-properties.py "$TMP/prop" "$TMP/state"

echo "== fase 00 con oc/helm falsos (modo no interactivo)"
t "00-configure no interactivo" env PATH="$ROOT/tests/fake-bin:$PATH" OC="$ROOT/tests/fake-bin/oc" CCX_STATE_DIR="$TMP/st00" \
  CCX_NONINTERACTIVE=1 CCX_ASSUME_YES=1 CCX_ACCEPT_LICENSE=yes CCX_ENTITLEMENT_KEY=dummy CCX_WXAI_API_KEY=dummy \
  CCX_WXAI_SPACE_ID=11111111-1111-1111-1111-111111111111 bash phases/00-configure.sh
t "00 guarda config y secretos 600" bash -c "grep -q \"WXAI_MODEL_ID='openai/gpt-oss-120b'\" $TMP/st00/config.env && [ \$(stat -f %Lp $TMP/st00/secrets.env 2>/dev/null || stat -c %a $TMP/st00/secrets.env) = 600 ] && ! grep -q dummy $TMP/st00/config.env"
t "install.sh status" env PATH="$ROOT/tests/fake-bin:$PATH" OC="$ROOT/tests/fake-bin/oc" CCX_STATE_DIR="$TMP/st00" bash install.sh status

echo "== apply_retry (webhook de PG intermitente)"
cat > "$TMP/flaky-oc" <<'F'
#!/usr/bin/env bash
# falla con error de webhook las 2 primeras veces; si FLAKY_HARD=1 falla siempre con un error no transitorio
n="$(cat "$FLAKY_CNT" 2>/dev/null || echo 0)"; echo $((n+1)) > "$FLAKY_CNT"
if [ "${FLAKY_HARD:-0}" = 1 ]; then echo 'Error: invalid spec' >&2; exit 1; fi
if [ "$n" -lt 2 ]; then echo 'failed calling webhook "vpooler.pg.ibm.com": connection refused' >&2; exit 1; fi
echo "pooler created"
F
chmod +x "$TMP/flaky-oc"
t "apply_retry reintenta ante webhook y termina OK" bash -c "export FLAKY_CNT=$TMP/c1 APPLY_RETRY_DELAY=0 CCX_STATE_DIR=$TMP/st-ar OC=$TMP/flaky-oc; source lib/common.sh; apply_retry -f x && [ \$(cat $TMP/c1) = 3 ]"
t "apply_retry no reintenta errores no transitorios" bash -c "export FLAKY_CNT=$TMP/c2 FLAKY_HARD=1 APPLY_RETRY_DELAY=0 CCX_STATE_DIR=$TMP/st-ar OC=$TMP/flaky-oc; source lib/common.sh; ! apply_retry -f x 2>/dev/null && [ \$(cat $TMP/c2) = 1 ]"
t "PATH incluye /usr/local/bin tras cargar common.sh" bash -c "PATH=/usr/bin:/bin CCX_STATE_DIR=$TMP/st-ar; source lib/common.sh; case \":\$PATH:\" in *:/usr/local/bin:*) true;; *) false;; esac"

echo "== Content Assistant (fase 08): certificados, property files y proveedores"
t "gen-opensearch-certs: CA estricta, SAN, PKCS#8" bash -c "bash tools/gen-opensearch-certs.sh $TMP/oscerts ibm-content >/dev/null && cd $TMP/oscerts \
  && openssl x509 -in ca.crt -noout -ext keyUsage,basicConstraints | grep -q -E 'Certificate Sign' && openssl x509 -in ca.crt -noout -ext basicConstraints | grep -q 'CA:TRUE' \
  && openssl x509 -in tls.crt -noout -ext subjectAltName | grep -q 'opensearch-cluster-master.ibm-content.svc' && head -1 tls.key | grep -q 'BEGIN PRIVATE KEY' \
  && openssl verify -x509_strict -CAfile ca.crt tls.crt >/dev/null && [ \$(stat -f %Lp tls.key 2>/dev/null || stat -c %a tls.key) = 600 ]"
t "gen-opensearch-certs idempotente (no regenera)" bash -c "h1=\$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],\"rb\").read()).hexdigest())' $TMP/oscerts/tls.crt); bash tools/gen-opensearch-certs.sh $TMP/oscerts ibm-content | grep -q 'ya existentes'; [ \"\$h1\" = \"\$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],\"rb\").read()).hexdigest())' $TMP/oscerts/tls.crt)\" ]"
mkdir -p "$TMP/cas/prop" "$TMP/cas/state" "$TMP/cas/mgw"
printf '[MODELGATEWAY]\nURL = "<Required>"\nAPI_KEY = """<Required>"""\nSSL_ENABLED = true\n' > "$TMP/cas/prop/cas_properties.toml"
printf '[VECTORDB]\nDATABASE_URL = "<Required>"\nDATABASE_USERNAME = """<Required>"""\nDATABASE_USER_PASSWORD = "<Required>"\nDATABASE_SSL_ENABLED = true\n' > "$TMP/cas/prop/cas_vector_database.toml"
printf 'CAS_VERSION = "1.0.4"\nSLOW_FILE_STORAGE_CLASSNAME = "<Required>"\nFIPS_SUPPORT = false\n' > "$TMP/cas/prop/cas_deployment.toml"
printf "NS='ibm-content'\nFILE_SC='ocs-storagecluster-cephfs'\nMG_ROUTE_URL='https://model-gateway-ibm-content.apps.example.com'\n" > "$TMP/cas/state/config.env"
printf "OS_ADMIN_PASSWORD='Pw-Test-12345Aa1!'\n" > "$TMP/cas/state/ccx-content-secrets.env"
echo '{"tenant":{"apikey":"tenant-key-xyz","name":"ccx","uuid":"u"}}' > "$TMP/cas/mgw/state.json"
t "cas-fill-properties rellena y no deja <Required>" bash -c "python3 tools/cas-fill-properties.py $TMP/cas/prop $TMP/cas/state $TMP/cas/mgw/state.json && ! grep -q Required $TMP/cas/prop/*.toml \
  && grep -q 'opensearch-cluster-master.ibm-content.svc:9200' $TMP/cas/prop/cas_vector_database.toml && grep -q 'ocs-storagecluster-cephfs' $TMP/cas/prop/cas_deployment.toml \
  && grep -q 'tenant-key-xyz' $TMP/cas/prop/cas_properties.toml && [ \$(stat -f %Lp $TMP/cas/prop/cas_vector_database.toml 2>/dev/null || stat -c %a $TMP/cas/prop/cas_vector_database.toml) = 600 ]"
t "cas-fill-properties idempotente" python3 tools/cas-fill-properties.py "$TMP/cas/prop" "$TMP/cas/state" "$TMP/cas/mgw/state.json"
t "plantillas silent de Content Assistant son JSON válido" bash -c "sed -e 's/@CAS_ACCEPT@/true/' -e 's/@NS@/ibm-content/' -e 's/@ENTITLEMENT_KEY@/k/' templates/cas_silent_deployoperator.set.json | python3 -m json.tool >/dev/null \
  && sed 's/@NS@/ibm-content/' templates/cas_silent_prerequisites.set.json | python3 -m json.tool >/dev/null"
printf '# MODELGATEWAY_SSL_ENABLED = false\nNAMESPACE = "<Namespace>"\nLICENSE = "Essentials"\nPLATFORM = 1\nFIPS_SUPPORT = false\nGENERATE_NETWORK_POLICIES = false\nAI_PROVIDER_COUNT = 1\nAI_PROVIDER_TYPE = 1\n[VECTORDB]\nDATABASE_TYPE = 1\nDATABASE_AUTH_TYPE = 2\nDATABASE_SSL_ENABLE = false\n' > "$TMP/cas/silent.toml"
t "toml_set aplica la plantilla silent de Content Assistant" bash -c "python3 -c 'import sys; p=sys.argv[1]; data=open(p).read(); open(p,\"w\").write(data.replace(\"# MODELGATEWAY_SSL_ENABLED\", \"MODELGATEWAY_SSL_ENABLED\"))' $TMP/cas/silent.toml && sed 's/@NS@/ibm-content/' templates/cas_silent_prerequisites.set.json | python3 tools/toml_set.py $TMP/cas/silent.toml - \
  && grep -q '^AI_PROVIDER_TYPE = 3' $TMP/cas/silent.toml && grep -q '^LICENSE = \"Premium\"' $TMP/cas/silent.toml && grep -q '^DATABASE_AUTH_TYPE = 1' $TMP/cas/silent.toml && grep -q '^MODELGATEWAY_SSL_ENABLED = true' $TMP/cas/silent.toml"
mkdir -p "$TMP/cas/ibmca"
python3 - "$TMP/cas/ibmca" <<'PY'
import json, sys
d = sys.argv[1]
llm = lambda n, df: {"name": n, "context_window_size": 131072, "summary_input_size": 24576, "is_default": df}
json.dump({"name": "modelgateway_openai", "is_default": False,
           "llms": [llm("openai/gpt-oss-120b", True), llm("openai/gpt-5.4", False), llm("openai/gpt-5.4-mini", False)],
           "embedding_models": [{"name": "openai/text-embedding-3-large", "dimensions": 1024, "is_default": True}]}, open(d + "/modelgateway_openai.json", "w"))
json.dump({"name": "watsonxprod", "is_default": True, "llms": [],
           "embedding_models": [{"name": "intfloat/multilingual-e5-large", "dimensions": 1024, "max_input_tokens": 512, "min_knn_threshold": 0.646,
                                 "max_knn_threshold": 0.741, "min_ann_threshold": 1.748, "max_ann_threshold": 1.824, "is_default": True}]}, open(d + "/watsonxprod.json", "w"))
PY
t "cas-providers: Llama por defecto, gpt-oss alterno, e5, gateway por defecto" env PATH="$ROOT/tests/fake-bin:$PATH" FAKE_IBMCA_DIR="$TMP/cas/ibmca" python3 tools/cas-providers.py
t "cas-providers resultado correcto" python3 - "$TMP/cas/ibmca" <<'PY'
import json, sys
d = sys.argv[1]
p = json.load(open(d + "/modelgateway_openai.updated.json"))
names = {l["name"]: l["is_default"] for l in p["llms"]}
assert names == {"meta-llama/llama-3-3-70b-instruct": True, "openai/gpt-oss-120b": False}, names
e = p["embedding_models"]
assert len(e) == 1 and e[0]["name"] == "intfloat/multilingual-e5-large" and e[0]["min_knn_threshold"] == 0.646 and e[0]["is_default"], e
assert p["is_default"] is True
assert json.load(open(d + "/watsonxprod.updated.json"))["is_default"] is False
PY
t "cas-providers idempotente" env PATH="$ROOT/tests/fake-bin:$PATH" FAKE_IBMCA_DIR="$TMP/cas/ibmca" python3 tools/cas-providers.py
t "fases: install.sh conoce 08-content-assistant y 09-finish" bash -c "grep -q '08-content-assistant 09-finish' install.sh && test -f phases/08-content-assistant.sh && test -f phases/09-finish.sh && ! test -f phases/08-finish.sh"

echo "== plantillas silent vs validadores de IBM"
if [ ! -d .work/ibm-content-cortex-containers ]; then
  mkdir -p .work && git clone -q --depth 1 --branch "${IBM_REPO_REF:-26.0.1}" https://github.com/ibm-ecm/ibm-content-cortex-containers.git .work/ibm-content-cortex-containers || echo "  (sin acceso a GitHub: se omite)"
fi
if [ -d .work/ibm-content-cortex-containers ]; then
  if python3 -c "import pydantic, toml" 2>/dev/null; then
    t "silent_install_* validan con pydantic de IBM" python3 tests/validate_silent_templates.py
  else
    echo "  (pydantic/toml no disponibles en python3: se omite validación con IBM)"
  fi
fi
echo
echo "Resultado: $PASS ok, $FAIL fallos"
[ "$FAIL" -eq 0 ]
