#!/usr/bin/env bash
# Elimina el despliegue (DESTRUCTIVO e irreversible: bases de datos, documentos, volúmenes).
#   ./uninstall.sh            pide confirmación escribiendo el nombre del namespace
#   ./uninstall.sh --local    además borra .state y .work de este repo (secretos locales, repo de IBM, venv)
# No toca CRDs ni ClusterRoles cluster-wide que instalaron los operadores (son inocuos; ver docs/TROUBLESHOOTING.md).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env; find_oc || die "No encuentro oc"
LOCAL=0; [ "${1:-}" = "--local" ] && LOCAL=1

echo "${C_R}${C_B}Se van a ELIMINAR los namespaces: $NS, $AUTH_NS e ibm-licensing (si existen).${C_0}"
read -r -p "Para confirmar escribe el nombre del namespace de contenido ($NS): " a
[ "$a" = "$NS" ] || die "Cancelado."

for cr in "ccxaiservices.ccxaiservices.operator.ibm.com" "modelgateway.modelgateway.cpd.ibm.com" \
          "ccxwduservices.ccxwdu.operator.ibm.com" "fncmclusters.fncm.ibm.com"; do
  oc_ delete "$cr" --all -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true
done
oc_ delete clusters.pg.ibm.com --all -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true
oc_ delete rediscps.redis.ibm.com --all -n "$NS" --ignore-not-found --wait=false 2>/dev/null || true
sleep 20
if command -v helm >/dev/null 2>&1; then
  for r in $(helm list -n "$NS" -q 2>/dev/null); do helm uninstall "$r" -n "$NS" --no-hooks >/dev/null 2>&1 || true; done
fi
for n in "$NS" "$AUTH_NS" ibm-licensing; do oc_ delete namespace "$n" --ignore-not-found --wait=false; done
ok "Eliminación lanzada (los namespaces pueden tardar unos minutos en desaparecer: oc get ns)."

if [ "$LOCAL" = 1 ]; then
  rm -rf "$STATE_DIR" "$WORK_DIR"; ok "Borrados .state y .work"
else
  rm -f "$DONE_DIR"/0[2-8]-* "$DONE_DIR/05-content-db"; ok "Marcas de fases 02-08 reiniciadas (se conserva la configuración)."
fi
