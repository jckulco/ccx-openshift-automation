#!/usr/bin/env python3
"""Configura los proveedores de IA de Content Assistant con la CLI `ibmca` (idempotente).

Qué deja hecho (equivale a lo que se hizo a mano en la sesión de referencia):
  - proveedor `modelgateway_openai`: ES el predeterminado; LLM predeterminado = CAS_LLM_MODEL
    (por defecto meta-llama/llama-3-3-70b-instruct) y openai/gpt-oss-120b como alterno; se podan los
    LLM que el gateway NO tiene registrados (gpt-5.4, gpt-5.4-mini...); embeddings = CAS_EMBED_MODEL
    (por defecto intfloat/multilingual-e5-large) con las dimensiones/umbrales que IBM publica en `watsonxprod`.
  - proveedor `watsonxprod`: is_default=false (no tiene API key en este despliegue).
Por qué Llama 3.3 y no gpt-oss-120b en Content Assistant: gpt-oss es un modelo de *razonamiento*; consume los
4096 tokens de salida razonando y el servicio responde "maxOutputTokens is too low". (El Reasoning Service de
Navigator sí usa gpt-oss-120b: con Llama 3.3 el agente rechazaba casi todas las preguntas.)

Requiere: `ibmca` en PATH (venv), URL configurada y sesión iniciada (`ibmca login -u genai-service-user -p ...`).
Uso: cas-providers.py [--dry-run]
Variables: CAS_LLM_MODEL, CAS_LLM_ALT_MODELS (coma), CAS_EMBED_MODEL, CAS_PROVIDER (modelgateway_openai)
"""
import json
import os
import subprocess
import sys

DRY = "--dry-run" in sys.argv
PROVIDER = os.environ.get("CAS_PROVIDER", "modelgateway_openai")
LLM = os.environ.get("CAS_LLM_MODEL", "meta-llama/llama-3-3-70b-instruct")
ALT = [m for m in os.environ.get("CAS_LLM_ALT_MODELS", "openai/gpt-oss-120b").split(",") if m]
EMB = os.environ.get("CAS_EMBED_MODEL", "intfloat/multilingual-e5-large")
# Valores de IBM (de `ibmca list ai-providers watsonxprod`, v1.0.4) por si el servicio no los devuelve
FALLBACK_EMB = {"name": "intfloat/multilingual-e5-large", "dimensions": 1024, "max_input_tokens": 512,
                "min_knn_threshold": 0.646, "max_knn_threshold": 0.741,
                "min_ann_threshold": 1.748, "max_ann_threshold": 1.824, "is_default": True}


def ibmca(*args, stdin=None):
    p = subprocess.run(["ibmca", *args], input=stdin, text=True, capture_output=True)
    if p.returncode:
        sys.exit("ibmca %s falló: %s" % (" ".join(args), (p.stderr or p.stdout).strip()[:400]))
    return p.stdout


prov = json.loads(ibmca("list", "ai-providers", PROVIDER))
ref = {}
try:
    for e in json.loads(ibmca("list", "ai-providers", "watsonxprod")).get("embedding_models", []):
        ref[e["name"]] = e
except SystemExit:
    pass

template_llm = (prov.get("llms") or [{}])[0]
wanted = [LLM] + [m for m in ALT if m != LLM]
by_name = {l["name"]: l for l in prov.get("llms", [])}
llms = []
for name in wanted:
    l = dict(by_name.get(name) or template_llm)
    l["name"] = name
    l["is_default"] = (name == LLM)
    if name not in by_name:                      # LLM nuevo: ventana de contexto prudente (128k)
        l["context_window_size"] = 131072
    llms.append(l)
emb = dict(ref.get(EMB) or FALLBACK_EMB)
emb["name"], emb["is_default"] = EMB, True

prov["llms"] = llms
prov["embedding_models"] = [emb]
prov["is_default"] = True
print("%s: LLM por defecto=%s (+%d alterno/s); embeddings=%s (%s dim); is_default=true" %
      (PROVIDER, LLM, len(llms) - 1, EMB, emb.get("dimensions")))
if DRY:
    print("(dry-run: no se aplicó nada)")
    sys.exit(0)
ibmca("update", "ai-providers", PROVIDER, stdin=json.dumps(prov))

try:
    w = json.loads(ibmca("list", "ai-providers", "watsonxprod"))
    if w.get("is_default"):
        w["is_default"] = False
        ibmca("update", "ai-providers", "watsonxprod", stdin=json.dumps(w))
        print("watsonxprod: is_default=false")
except SystemExit as e:
    print("AVISO: no se pudo ajustar watsonxprod:", e)
print("OK")
