#!/usr/bin/env python3
"""Sustituye la API key (y el space) de watsonx.ai en el secreto de WDU y en ccx-wdu.toml.

Actualiza también los campos *space_id del secreto y las líneas WXAI_*_SPACE_ID del TOML con WXAI_SPACE_ID de
.state/config.env (hallazgo de la sesión: al cambiar de cuenta de watsonx.ai hay que cambiar clave Y space).

Antes de tocar nada, comprueba que la clave NUEVA puede acceder a tu space/project.
La clave se pide por teclado (no se muestra) y nunca se imprime ni se pasa como argumento.

Uso (desde la raíz del repo, con el venv activo porque usa PyYAML):
  source .work/venv/bin/activate && python3 tools/swap-wxai-key.py
(Cambia la clave en el secreto de WDU. Para el Model Gateway usa tools/mgw.py provider ... )
"""
import base64
import getpass
import json
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

import os

import yaml

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
STATE = os.environ.get("CCX_STATE_DIR", os.path.join(ROOT, ".state"))


def _env(path):
    out = {}
    if os.path.exists(path):
        for line in open(path):
            if "=" in line and not line.startswith("#"):
                k, v = line.strip().split("=", 1)
                out[k] = v.strip("'\"")
    return out


CFG = _env(os.path.join(STATE, "config.env"))
OC = os.environ.get("OC", "oc")
NS = CFG.get("NS", "ibm-content")
SECRET = "ibm-ccx-wdu-wxai-secret"
DATA_KEY = "wxai_vars.yaml"
SPACE = CFG.get("WXAI_SPACE_ID", "")
PROJECT = CFG.get("WXAI_PROJECT_ID", "")
TOML = os.path.join(ROOT, ".work", "ibm-content-cortex-containers", "scripts", "propertyFile", NS, "ccx-wdu.toml")
API = "https://api.dataplatform.cloud.ibm.com"
if not SPACE:
    sys.exit("Falta WXAI_SPACE_ID en .state/config.env (ejecuta ./install.sh configure).")


def http(method, url, data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        resp = urllib.request.urlopen(req, timeout=60)
        raw = resp.read()
        return resp.status, (json.loads(raw) if raw else {})
    except urllib.error.HTTPError as err:
        return err.code, {}


new = getpass.getpass("Nueva API key de IBM Cloud (no se muestra): ").strip()
if not new:
    sys.exit("No se introdujo ninguna clave.")

# --- 1) Probar la clave nueva ---
st, tok = http("POST", "https://iam.cloud.ibm.com/identity/token",
               urllib.parse.urlencode({"grant_type": "urn:ibm:params:oauth:grant-type:apikey",
                                       "apikey": new}).encode(),
               {"Content-Type": "application/x-www-form-urlencoded"})
print("token IAM: HTTP", st)
if st != 200:
    sys.exit("La clave no es válida. No se ha cambiado nada.")
payload = tok["access_token"].split(".")[1]
payload += "=" * (-len(payload) % 4)
claims = json.loads(base64.urlsafe_b64decode(payload))
print("identidad:", claims.get("iam_id"), "| cuenta:", (claims.get("account") or {}).get("bss"))

auth = {"Authorization": "Bearer " + tok["access_token"]}
space_ok = http("GET", API + "/v2/spaces/" + SPACE, headers=auth)[0]
project_ok = http("GET", API + "/v2/projects/" + PROJECT, headers=auth)[0] if PROJECT else 0
print("acceso al space: HTTP", space_ok, "| al project: HTTP", project_ok)
if space_ok != 200 and project_ok != 200:
    sys.exit("La clave nueva tampoco llega al space ni al project. No se ha cambiado nada.")
print("OK: la clave nueva tiene acceso.\n")

# --- 2) Secreto de WDU ---
out = subprocess.run([OC, "get", "secret", SECRET, "-n", NS, "-o", "json"],
                     capture_output=True, text=True)
if out.returncode:
    sys.exit("No se pudo leer el secreto: " + out.stderr.strip())
secret = json.loads(out.stdout)
doc = yaml.safe_load(base64.b64decode(secret["data"][DATA_KEY]))
changed = []


def walk(node, path=""):
    if isinstance(node, dict):
        for k in list(node):
            p = path + "/" + str(k)
            if isinstance(node[k], (dict, list)):
                walk(node[k], p)
            elif re.search(r"api[_-]?key", str(k), re.I):
                node[k] = new
                changed.append(p)
            elif re.search(r"space[_-]?id", str(k), re.I) and isinstance(node[k], str):
                node[k] = SPACE
                changed.append(p)
    elif isinstance(node, list):
        for i, v in enumerate(node):
            walk(v, path + "[%d]" % i)


walk(doc)
if not changed:
    print("No encontré ninguna clave tipo 'api key' en", DATA_KEY, ". Estructura (solo nombres):")
    print(json.dumps(doc, default=lambda o: "<valor>", indent=1)[:600])
    sys.exit("No se ha cambiado nada.")
secret["data"][DATA_KEY] = base64.b64encode(yaml.safe_dump(doc).encode()).decode()
rep = subprocess.run([OC, "replace", "-f", "-"], input=json.dumps(secret),
                     capture_output=True, text=True)
print("secreto", SECRET, "->", (rep.stdout or rep.stderr).strip(), "| campos cambiados:", changed)

# --- 3) ccx-wdu.toml (para que coincida si se vuelve a generar) ---
if not os.path.exists(TOML):
    print("(No existe %s: se omite)" % TOML)
    sys.exit(0)
txt = open(TOML).read()
txt2, n = re.subn(r'^(WXAI_API_KEY\s*=\s*)("""|")?.*$', lambda m: m.group(1) + '"' + new + '"',
                  txt, flags=re.M)
open(TOML, "w").write(txt2)
# Los *_SPACE_ID (imagen, KVP, KVP semántico) usan comillas triples: se conserva el estilo de cada línea
txt3, n2 = re.subn(r'^(WXAI_\w*SPACE_ID\s*=\s*)("""|")?[^"\n]*("""|")?\s*$',
                   lambda m: m.group(1) + (m.group(2) or '"') + SPACE + (m.group(2) or '"'), txt2, flags=re.M)
open(TOML, "w").write(txt3)
print("ccx-wdu.toml: %d línea(s) de clave y %d de space actualizadas" % (n, n2))
print("Reinicia los deployments wdu-* para que lean el secreto:  for d in $(oc get deploy -n %s -o name | grep wdu-); do oc rollout restart $d -n %s; done" % (NS, NS))
