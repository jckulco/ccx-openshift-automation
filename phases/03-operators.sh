#!/usr/bin/env bash
# Fase 03: operadores (Content, AI Services, WDU, Model Gateway, CNPG, Redis, Usage Metering) con el script
# oficial deploy_operator.py en modo --silent + License Service (instalación manual, ver docs/TROUBLESHOOTING.md #2).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."
[ "${ACCEPT_LICENSE:-}" = "yes" ] || die "Licencia no aceptada (ejecuta la fase 00)."
activate_venv

title "Fase 03 - Operadores"
SILENT="$IBM_SCRIPTS/silent_config/silent_install_deployoperator.toml"
[ -f "$SILENT.orig" ] || cp -p "$SILENT" "$SILENT.orig"
restore_toml() { [ -f "$SILENT.orig" ] && cp -p "$SILENT.orig" "$SILENT"; }   # nunca dejar la key en el repo de IBM
trap restore_toml EXIT

cp -p "$SILENT.orig" "$SILENT"
NSV="$NS" EK="$ENTITLEMENT_KEY" python3 -c 'import os,sys; print(open(sys.argv[1]).read().replace("@NS@", os.environ["NSV"]).replace("@ENTITLEMENT_KEY@", os.environ["EK"]))' \
  "$ROOT/templates/silent_install_deployoperator.set.json" | python3 "$ROOT/tools/toml_set.py" "$SILENT" -
chmod 600 "$SILENT"

log "Ejecutando deploy_operator.py --silent (puede tardar varios minutos)"
cd "$IBM_SCRIPTS"          # IMPORTANTE: version.toml se busca en el directorio padre del cwd
set +e
python deploy_operator.py --silent 2>&1 | mask | tee "$STATE_DIR/deploy_operator.log" | tail -60
RC=${PIPESTATUS[0]}
set -e
restore_toml; trap - EXIT
[ "$RC" -eq 0 ] || die "deploy_operator.py terminó con código $RC (log: $STATE_DIR/deploy_operator.log)"

# --- License Service (manual) --------------------------------------------------------------------------------
# Sin él, Model Gateway falla con "IBMLicensingDefinition". Se renderiza el chart y se aplican CRDs + resto.
LS_VERSION="$(grep -A4 '^\[license-service\]' "$IBM_DIR/version.toml" | sed -n 's/^VERSION = "\(.*\)"/\1/p' | head -1)"
LS_VERSION="${LS_VERSION:-4.2.24}"
if oc_ get deploy ibm-licensing-operator -n ibm-licensing >/dev/null 2>&1; then
  ok "License Service ya instalado"
else
  log "Instalando License Service $LS_VERSION en ibm-licensing"
  oc_ get ns ibm-licensing >/dev/null 2>&1 || oc_ create namespace ibm-licensing
  # el chart necesita el secreto de pull de imágenes en su namespace
  oc_ get secret ibm-entitlement-key -n "$NS" -o json \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); m=d["metadata"]; d["metadata"]={"name":m["name"],"namespace":"ibm-licensing"}; print(json.dumps(d))' \
    | oc_ apply -f - >/dev/null
  T="$(mktemp -d)"
  helm template ibm-licensing ibm-content-cortex/ibm-licensing-cluster-scoped --version "$LS_VERSION" \
    -n ibm-licensing --include-crds > "$T/rendered.yaml" 2>"$T/helm.err" \
    || { cat "$T/helm.err" >&2; die "helm template del License Service falló (versión $LS_VERSION)."; }
  python3 - "$T" <<'PY'
import sys, yaml
t = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(t + "/rendered.yaml")) if d]
crds = [d for d in docs if d["kind"] == "CustomResourceDefinition"]
rest = [d for d in docs if d["kind"] != "CustomResourceDefinition"]
yaml.safe_dump_all(crds, open(t + "/crds.yaml", "w"))
yaml.safe_dump_all(rest, open(t + "/rest.yaml", "w"))
print(len(crds), "CRDs;", len(rest), "otros recursos")
PY
  oc_ apply --server-side -f "$T/crds.yaml" >/dev/null
  oc_ wait --for=condition=Established -f "$T/crds.yaml" --timeout=90s >/dev/null
  oc_ apply -n ibm-licensing -f "$T/rest.yaml" >/dev/null
  rm -rf "$T"
  wait_until "License Service operator listo" 300 10 pods_ready_by_prefix ibm-licensing ibm-licensing-operator || true
fi

# --- Esperar a los operadores ----------------------------------------------------------------------------------
all_ops_ready() {
  oc_ get pods -n "$NS" --no-headers 2>/dev/null | awk '$1 ~ /^ibm-content-operator/' | grep -q . || return 1
  ! oc_ get pods -n "$NS" --no-headers 2>/dev/null | awk '{split($2,a,"/"); if ($3!="Completed" && (a[1]!=a[2] || $3!="Running")) print}' | grep -q .
}
wait_until "Todos los pods de operadores en Running" 900 15 all_ops_ready || { oc_ get pods -n "$NS"; die "Operadores no listos."; }
mark_done 03-operators
