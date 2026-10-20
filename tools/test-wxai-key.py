#!/usr/bin/env python3
"""Prueba una API key de IBM Cloud contra un deployment space de watsonx.ai.

No toca el cluster ni el Model Gateway: solo hace dos llamadas a IBM Cloud.
  1) Cambia la API key por un token IAM y muestra QUIÉN es (service ID y cuenta).
  2) Hace una petición mínima de chat ("Reply with the single word: OK") al space.

La API key se pide por teclado y no se muestra ni se guarda. El token IAM no se imprime.

Uso interactivo:      python3 tools/test-wxai-key.py
Uso no interactivo:   WXAI_REGION=us-south WXAI_SPACE_ID=... WXAI_MODEL_ID=... WXAI_API_KEY=... python3 tools/test-wxai-key.py
Código de salida: 0 = la clave y el space funcionan; 1 = no.
"""
import os
import base64
import getpass
import json
import urllib.error
import urllib.parse
import urllib.request


def post(url, data, headers):
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=60) as r:
            return r.status, r.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode("utf-8", "replace")
    except Exception as e:  # noqa: BLE001
        return "ERROR", repr(e)


def jwt_claims(token):
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:  # noqa: BLE001
        return {}


region = os.environ.get("WXAI_REGION") or input("Región de watsonx.ai [us-south]: ").strip() or "us-south"
space = os.environ.get("WXAI_SPACE_ID") or input("Space ID (GUID del deployment space): ").strip()
model = os.environ.get("WXAI_MODEL_ID") or input("Modelo [openai/gpt-oss-120b]: ").strip() or "openai/gpt-oss-120b"
key = os.environ.get("WXAI_API_KEY") or getpass.getpass("API key (no se muestra): ").strip()

print("\n== 1) Token IAM ==")
status, text = post(
    "https://iam.cloud.ibm.com/identity/token",
    urllib.parse.urlencode(
        {"grant_type": "urn:ibm:params:oauth:grant-type:apikey", "apikey": key}
    ).encode(),
    {"Content-Type": "application/x-www-form-urlencoded", "Accept": "application/json"},
)
del key
print("HTTP", status)
if status != 200:
    print(text[:400])
    raise SystemExit("No se pudo obtener el token: revisa que sea una API key válida.")

token = json.loads(text)["access_token"]
claims = jwt_claims(token)
print("identidad (iam_id):", claims.get("iam_id"))
print("sujeto (sub):      ", claims.get("sub"))
print("cuenta (bss):      ", (claims.get("account") or {}).get("bss"))

print("\n== 2) Petición mínima al space de watsonx.ai ==")
url = "https://%s.ml.cloud.ibm.com/ml/v1/text/chat?version=2023-05-29" % region
body = json.dumps(
    {
        "model_id": model,
        "space_id": space,
        "messages": [{"role": "user", "content": "Reply with the single word: OK"}],
        "max_tokens": 64,
    }
).encode()
status, text = post(
    url,
    body,
    {"Content-Type": "application/json", "Accept": "application/json", "Authorization": "Bearer " + token},
)
print("HTTP", status)
print(text[:500])
if status == 200:
    print("\nLa clave y el space funcionan.")
    raise SystemExit(0)
if status == 403:
    print("\n403: esa identidad aún no tiene acceso al space (añádela como colaborador del deployment space).")
raise SystemExit(1)
