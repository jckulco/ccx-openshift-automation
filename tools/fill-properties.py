#!/usr/bin/env python3
"""Rellena los archivos de propiedades de Content Cortex (scripts/propertyFile/<ns>/) SIN preguntas.

Toma los valores de .state/ (config.env, secrets.env, auth-secrets.env, ccx-idp.env) y genera las
contraseñas que falten en .state/ccx-content-secrets.env (chmod 600). Es idempotente.
No imprime contraseñas ni secretos.

Uso:  python3 fill-properties.py <dir_propertyFile/ns> <dir_state>
"""
import os
import re
import secrets
import shutil
import string
import sys

PROP_DIR, STATE = sys.argv[1], sys.argv[2]


def load_env(name):
    values = {}
    path = os.path.join(STATE, name)
    if os.path.exists(path):
        with open(path) as fh:
            for line in fh:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    values[k] = v.strip().strip("'").strip('"')
    return values


def gen(n=20):
    return "".join(secrets.choice(string.ascii_letters + string.digits) for _ in range(n))


cfg = load_env("config.env")
sec = load_env("secrets.env")
auth = load_env("auth-secrets.env")
idp = load_env("ccx-idp.env")

NS = cfg.get("NS", "ibm-content")
AUTH_NS = cfg.get("AUTH_NS", "ibm-auth")
APPS = cfg["APPS_DOMAIN"]
FILE_SC = cfg.get("FILE_SC", "ocs-storagecluster-cephfs")
PG_HOST = "ccx-content-pg-rw.%s.svc.cluster.local" % NS
LDAP_HOST = "openldap.%s.svc.cluster.local" % AUTH_NS
BASE_DN = "dc=example,dc=org"

cpath = os.path.join(STATE, "ccx-content-secrets.env")
content = load_env("ccx-content-secrets.env")
changed = False
for key in ("DB_PW", "KEYSTORE_PW", "LTPA_PW", "MG_ADMIN_PW"):
    if key not in content:
        content[key] = gen()
        changed = True
if changed:
    old = os.umask(0o077)
    with open(cpath, "w") as fh:
        for k, v in content.items():
            fh.write("%s='%s'\n" % (k, v))
    os.umask(old)
    os.chmod(cpath, 0o600)
    print(">> Contraseñas generadas guardadas en .state/ccx-content-secrets.env (chmod 600)")

DB = {"DATABASE_USERNAME": "ccxdb", "DATABASE_PASSWORD": content["DB_PW"], "DATABASE_SERVERNAME": PG_HOST}
MAP = {
    "content_db_server.toml": {
        "GCD": dict(DB, DATABASE_NAME="gcddb"),
        "OS": dict(DB, DATABASE_NAME="osdb"),
        "ICN": dict(DB, DATABASE_NAME="icndb"),
    },
    "content_ldap_server.toml": {"LDAP": {
        "LDAP_SERVER": LDAP_HOST, "LDAP_BASE_DN": BASE_DN, "LDAP_GROUP_BASE_DN": BASE_DN,
        "LDAP_BIND_DN": "cn=admin," + BASE_DN, "LDAP_BIND_DN_PASSWORD": auth["LDAP_ADMIN_PW"]}},
    "ccx-identity_provider.toml": {"*": {
        "CLIENT_ID": idp["IDP_CLIENT_ID"], "CLIENT_SECRET": idp["IDP_CLIENT_SECRET"]}},
    "content_user_group.toml": {"*": {
        "KEYSTORE_PASSWORD": content["KEYSTORE_PW"], "LTPA_PASSWORD": content["LTPA_PW"],
        "FNCM_LOGIN_USER": "ccxadmin", "FNCM_LOGIN_PASSWORD": auth["PW_CCXADMIN"],
        "ICN_LOGIN_USER": "ccxadmin", "ICN_LOGIN_PASSWORD": auth["PW_CCXADMIN"],
        "GCD_ADMIN_USER_NAME": ["ccxadmin"], "GCD_ADMIN_GROUPS_NAME": ["ccxadmins"],
        "CPE_OBJ_STORE_OS_ADMIN_USER_GROUPS": ["ccxadmins"]}},
    "ccx-deployment.toml": {"*": {
        "SLOW_FILE_STORAGE_CLASSNAME": FILE_SC, "MEDIUM_FILE_STORAGE_CLASSNAME": FILE_SC,
        "FAST_FILE_STORAGE_CLASSNAME": FILE_SC, "VAULT_URL": "none", "VAULT_ROLE": "none"}},
    "aiservices_integration.toml": {"*": {
        # SOLO la URL base, sin /navigator (si no, la ruta queda /navigator/navigator/...)
        "NAVIGATOR_EXTERNAL_URL": "https://navigator-%s.%s" % (NS, APPS)}},
    "ccx-model-gateway.toml": {"*": {"ADMIN_PASSWORD": content["MG_ADMIN_PW"]}},
}
model = cfg["WXAI_MODEL_ID"]
space = cfg["WXAI_SPACE_ID"]
MAP["ccx-wdu.toml"] = {"*": {
    "WXAI_API_KEY": sec["WXAI_API_KEY"],
    "WXAI_KVP_MODEL_ID": cfg.get("WXAI_KVP_MODEL_ID", model), "WXAI_KVP_SPACE_ID": space,
    "WXAI_SEMANTIC_KVP_MODEL_ID": cfg.get("WXAI_SEMANTIC_MODEL_ID", model), "WXAI_SEMANTIC_KVP_SPACE_ID": space,
    "WXAI_IMAGE_DESCRIPTION_MODEL_ID": cfg.get("WXAI_IMAGE_MODEL_ID", model),
    "WXAI_IMAGE_DESCRIPTION_SPACE_ID": space,
}}

here = os.path.dirname(os.path.abspath(__file__))
import json
import subprocess

rc_any = 0
for fname, spec in MAP.items():
    path = os.path.join(PROP_DIR, fname)
    if not os.path.exists(path):
        print("!! No existe %s (se omite)" % fname)
        continue
    if not os.path.exists(path + ".orig"):
        shutil.copy2(path, path + ".orig")
        os.chmod(path + ".orig", 0o600)
    rc = subprocess.run([sys.executable, os.path.join(here, "toml_set.py"), path, "-", "--lenient"],
                        input=json.dumps(spec), text=True).returncode
    os.chmod(path, 0o600)
    print(">> %s: actualizado" % fname)
    rc_any |= rc

print("\n>> Propiedades que SIGUEN con <Required> (revisar):")
pending = 0
for fname in sorted(os.listdir(PROP_DIR)):
    if fname.endswith(".toml"):
        with open(os.path.join(PROP_DIR, fname)) as fh:
            section = ""
            for num, line in enumerate(fh, 1):
                m = re.match(r"^\s*\[([^\[\]]+)\]\s*$", line)
                if m:
                    section = m.group(1)
                if "<Required>" in line and not line.lstrip().startswith("#"):
                    print("   %s:%d  [%s] %s" % (fname, num, section, line.split("=", 1)[0].strip()))
                    pending += 1
if not pending:
    print("   (ninguna)")
sys.exit(1 if pending else 0)
