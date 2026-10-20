#!/usr/bin/env python3
"""Imprime el API key de administrador del Model Gateway (secreto model-gateway-admins-secret/admins.json).

Lo usa phases/06-model-gateway.sh:  TOKEN="$(python3 tools/mg-admin-token.py)"
Si no se encuentra una clave, sale con código 1 (sin imprimir el contenido del secreto).
Uso:  OC=oc NS=ibm-content python3 tools/mg-admin-token.py
"""
import base64
import json
import os
import subprocess
import sys

oc = os.environ.get("OC", "oc")
ns = os.environ.get("NS", "ibm-content")
out = subprocess.run([oc, "get", "secret", "model-gateway-admins-secret", "-n", ns, "-o", "json"],
                     capture_output=True, text=True)
if out.returncode:
    sys.exit("No se pudo leer model-gateway-admins-secret")
raw = base64.b64decode(json.loads(out.stdout)["data"]["admins.json"])
doc = json.loads(raw)


def find(node):
    """Devuelve el primer valor cuyo nombre de campo sea apikey/api_key/apiKey/key/token."""
    if isinstance(node, dict):
        for k, v in node.items():
            if isinstance(v, str) and k.lower().replace("_", "") in ("apikey", "key", "token", "adminkey"):
                return v
        for v in node.values():
            r = find(v)
            if r:
                return r
    elif isinstance(node, list):
        for v in node:
            r = find(v)
            if r:
                return r
    return None


tok = find(doc)
if not tok:
    sys.exit("admins.json no contiene un campo apikey reconocible (revisa la estructura con: oc get secret ... | base64 -d)")
print(tok)
