#!/usr/bin/env bash
# Fase 07: paquete "IBM Content Cortex AI Services and Tools" (metadatos en CPE + plug-in de Navigator).
#   El paquete (ICCXAIST_26.0.1_ML.zip, Passport Advantage M17SQML) es de DESCARGA MANUAL (requiere aceptar la
#   licencia de IBM con tu IBMid); no se puede automatizar. Pasa la ruta con CCX_AI_PACKAGE=/ruta/al.zip
#   o colócalo en .work/ICCXAIST_26.0.1_ML.zip.   Código de salida 10 = pendiente de descarga manual.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."
export OC NS PW_CCXADMIN

title "Fase 07 - Paquete de AI Services (metadatos + plug-in de Navigator)"
ZIP="${CCX_AI_PACKAGE:-}"
[ -n "$ZIP" ] && [ -f "$ZIP" ] || ZIP="$(ls "$WORK_DIR"/ICCXAIST*.zip 2>/dev/null | head -1 || true)"
if [ -z "$ZIP" ] || [ ! -f "$ZIP" ]; then
  warn "Falta el paquete de AI Services. Descárgalo (ver docs/MANUAL-STEPS.md, sección 1) y vuelve a ejecutar:"
  warn "    CCX_AI_PACKAGE=/ruta/ICCXAIST_26.0.1_ML.zip ./install.sh --only 07"
  exit 10
fi
bash "$ROOT/tools/ai-metadata.sh" "$ZIP"
mark_done 07-ai-package
