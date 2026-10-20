#!/usr/bin/env bash
# Estado rápido: CRs, pods con problemas y rutas.   Uso: tools/status.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env; find_oc || die "No encuentro oc"
title "CRs"
oc_ get fncmclusters,modelgateway,ccxwduservices,ccxaiservices -n "$NS" 2>&1 | grep -v "^$" || true
title "Pods que NO están listos (incluye 0/1 Running)"
oc_ get pods -n "$NS" --no-headers | awk '{split($2,a,"/"); if ($3!="Completed" && (a[1]!=a[2]||$3!="Running")) print}' || true
title "Rutas"
oc_ get routes -n "$NS" -o custom-columns=NAME:.metadata.name,HOST:.spec.host
