#!/usr/bin/env bash
# Fase 04: "gather" silencioso de IBM (property files + CRs de infraestructura) y bases de datos:
#   - PostgreSQL de contenido (ccx-content-pg, CR propio de este repo)
#   - PostgreSQL + Redis de Model Gateway, PostgreSQL + pooler de WDU (CRs generados por IBM)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."
activate_venv
[ -n "${IDP_DISCOVERY_URL:-}" ] || die "Falta .state/ccx-idp.env (fase 02)."

title "Fase 04 - Infraestructura (bases de datos y Redis)"
SILENT="$IBM_SCRIPTS/silent_config/silent_install_prerequisites.toml"
[ -f "$SILENT.orig" ] || cp -p "$SILENT" "$SILENT.orig"
cp -p "$SILENT.orig" "$SILENT"
python3 -c 'import os,sys; s=open(sys.argv[1]).read()
for k in ("NS","LICENSE_METRIC","IDP_DISCOVERY_URL","BLOCK_SC"): s=s.replace("@%s@"%k, os.environ[k])
print(s)' "$ROOT/templates/silent_install_prerequisites.set.json" | python3 "$ROOT/tools/toml_set.py" "$SILENT" -

cd "$IBM_SCRIPTS"
log "prerequisites.py --silent gather"
python prerequisites.py --silent gather 2>&1 | mask | tail -25 || true
GEN="$IBM_SCRIPTS/generatedFiles/$NS"
PROP="$(find "$IBM_SCRIPTS" -maxdepth 2 -type d -path "*propertyFile*/$NS" | head -1)"
[ -n "$PROP" ] || die "gather no generó el directorio de property files para $NS."
[ -d "$GEN/infrastructure" ] || die "gather no generó $GEN/infrastructure (¿falló el gather? revisa la salida)."
set_env "$CONFIG_FILE" PROP_DIR "$PROP"
ok "Property files: $PROP"

wait_pg() { # wait_pg <prefijo-pod>
  wait_until "pod $1 listo" 900 10 pods_ready_by_prefix "$NS" "$1"
}

# --- PostgreSQL de contenido ----------------------------------------------------------------------------------
log "Aplicando PostgreSQL de contenido (ccx-content-pg)"
sed -e "s/__NS__/$NS/g" -e "s#__BLOCK_SC__#$BLOCK_SC#g" "$ROOT/templates/ccx-content-pg.yaml" | oc_ apply -n "$NS" -f -

# --- Infraestructura generada por IBM (Model Gateway + WDU) ------------------------------------------------------
INF="$GEN/infrastructure"
[ -d "$INF/secrets" ] && oc_ apply -n "$NS" -f "$INF/secrets/"
[ -f "$INF/ibm_pg_cluster_mg_cr.yaml" ]  && oc_ apply -n "$NS" -f "$INF/ibm_pg_cluster_mg_cr.yaml"
[ -f "$INF/ibm_redis_cr.yaml" ]          && oc_ apply -n "$NS" -f "$INF/ibm_redis_cr.yaml"
[ -f "$INF/ibm_pg_cluster_wdu_cr.yaml" ] && oc_ apply -n "$NS" -f "$INF/ibm_pg_cluster_wdu_cr.yaml"

wait_pg ccx-content-pg-1
wait_pg ibm-pg-cluster-mg-1
wait_pg ccx-wdu-pg-1
# el pooler de WDU necesita el cluster ya creado
[ -f "$INF/ibm_pg_pooler_wdu_cr.yaml" ] && oc_ apply -n "$NS" -f "$INF/ibm_pg_pooler_wdu_cr.yaml"
redis_ready() { oc_ get pods -n "$NS" --no-headers 2>/dev/null | grep -i redis | grep -v -i operator | awk '{split($2,a,"/"); if ($3!="Running"||a[1]!=a[2]) bad=1; n++} END{exit !(n>0 && !bad)}'; }
wait_until "Redis de Model Gateway listo" 600 10 redis_ready
wait_pg ibm-pg-pooler-wdu
mark_done 04-infra
