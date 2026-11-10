#!/usr/bin/env python3
"""Rellena los property files de Content Assistant (scripts/propertyFile/<ns>/cas_*.toml) SIN preguntas.

Valores tomados de .state/ (no se imprimen secretos):
  cas_deployment.toml       SLOW_FILE_STORAGE_CLASSNAME  <- FILE_SC
  cas_properties.toml       [MODELGATEWAY] URL (ruta externa del gateway), API_KEY (tenant) , SSL_ENABLED
  cas_vector_database.toml  DATABASE_URL / DATABASE_USERNAME / DATABASE_USER_PASSWORD (OpenSearch)
Uso: cas-fill-properties.py <dir_propertyFile/ns> <dir_state> <ruta .mgw/state.json del repo de Content Cortex>
Es idempotente: sólo sustituye valores que YA existen en los TOML (usa tools/toml_set.py).
"""
import json
import os
import subprocess
import sys

PROP, STATE, MGW_STATE = sys.argv[1:4]
HERE = os.path.dirname(os.path.abspath(__file__))


def env(name):
    out = {}
    p = os.path.join(STATE, name)
    if os.path.exists(p):
        for line in open(p):
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                out[k] = v.strip("'\"")
    return out


cfg, content = env("config.env"), env("ccx-content-secrets.env")
ns = cfg.get("NS", "ibm-content")
tenant_key = json.load(open(MGW_STATE))["tenant"]["apikey"]
gw = cfg.get("MG_ROUTE_URL")
if not gw:
    sys.exit("Falta MG_ROUTE_URL en config.env (lo escribe la fase 06 / 08).")
if "OS_ADMIN_PASSWORD" not in content:
    sys.exit("Falta OS_ADMIN_PASSWORD en ccx-content-secrets.env (lo escribe la fase 08).")


def setvals(fname, values):
    p = subprocess.run([sys.executable, os.path.join(HERE, "toml_set.py"), os.path.join(PROP, fname), "-"],
                       input=json.dumps(values), text=True, capture_output=True)
    if p.returncode:
        sys.exit("toml_set falló en %s: %s" % (fname, p.stderr.strip()))
    os.chmod(os.path.join(PROP, fname), 0o600)


setvals("cas_deployment.toml", {"": {"SLOW_FILE_STORAGE_CLASSNAME": cfg.get("FILE_SC", "ocs-storagecluster-cephfs")}})
setvals("cas_properties.toml", {"*": {"URL": gw, "API_KEY": tenant_key, "SSL_ENABLED": True}})
setvals("cas_vector_database.toml", {"*": {
    "DATABASE_URL": "https://opensearch-cluster-master.%s.svc:9200" % ns,
    "DATABASE_USERNAME": "admin",
    "DATABASE_USER_PASSWORD": content["OS_ADMIN_PASSWORD"]}})
print("OK: property files de Content Assistant rellenados (valores no impresos)")
