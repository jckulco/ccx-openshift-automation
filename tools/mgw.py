#!/usr/bin/env python3
"""Envoltorio NO interactivo de scripts/model-gateway.py (de IBM).

El comando original pide por teclado (questionary) los valores que no vienen en variables de entorno,
p. ej. el Project ID de watsonx.ai. Este envoltorio responde "" a esas preguntas de texto para que
el flujo pueda automatizarse. Todo lo demás se pasa tal cual.

Uso (desde scripts/ del repo de IBM, con el venv activo):
  python3 <repo>/tools/mgw.py tenant create ccx
  WATSONXAI_API_KEY=... WATSONXAI_SPACE_ID=... python3 <repo>/tools/mgw.py provider create watsonxai watsonx
  python3 <repo>/tools/mgw.py model add <provider-uuid> openai/gpt-oss-120b
"""
import os
import runpy
import sys

import questionary


class _Blank:
    def ask(self):
        return ""


questionary.text = lambda *a, **k: _Blank()  # type: ignore[assignment]

script = os.path.join(os.getcwd(), "model-gateway.py")
if not os.path.exists(script):
    sys.exit("Ejecuta este envoltorio desde el directorio scripts/ del repo de IBM (no existe model-gateway.py aquí).")
sys.argv[0] = script
runpy.run_path(script, run_name="__main__")
