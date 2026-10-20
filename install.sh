#!/usr/bin/env bash
# IBM Content Cortex 26.0.1 (Premium) en Red Hat OpenShift - instalador automatizado.
#
#   ./install.sh                 ejecuta todas las fases pendientes (pregunta sólo los datos clave)
#   ./install.sh reconfigure     borra la configuración guardada y vuelve a preguntar todo
#   ./install.sh configure       sólo la fase 00 (pide entitlement key, API key/space/modelo de watsonx.ai, licencia)
#   ./install.sh --from 04       desde la fase 04 hasta el final
#   ./install.sh --only 07       sólo la fase 07
#   ./install.sh --force         ignora las marcas de "hecho" (.state/done) y repite las fases
#   ./install.sh status          estado de fases y de los pods
#   ./install.sh credentials     muestra las contraseñas de los usuarios de prueba (explícito)
#   ./install.sh --yes | --non-interactive   sin preguntas (ver README: variables CCX_*)
#
# Fases:  00 configure | 01 bootstrap | 02 auth | 03 operators | 04 infra | 05 content | 06 model-gateway |
#         07 ai-package (manual: descarga) | 08 finish
set -euo pipefail
ROOT="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

PHASES=(00-configure 01-bootstrap 02-auth 03-operators 04-infra 05-content 06-model-gateway 07-ai-package 08-finish)
FROM=""; ONLY=""; FORCE=0; CMD="all"; RECONF=0

usage() { sed -n "2,15p" "$0" | sed 's/^# \{0,1\}//'; }
while [ $# -gt 0 ]; do
  case "$1" in
    configure|status|credentials|all) CMD="$1" ;;
    reconfigure) CMD=configure; RECONF=1 ;;
    --from)  FROM="$2"; shift ;;
    --only)  ONLY="$2"; shift ;;
    --force) FORCE=1 ;;
    --yes|-y) export CCX_ASSUME_YES=1 ;;
    --non-interactive) export CCX_NONINTERACTIVE=1 CCX_ASSUME_YES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) err "Argumento desconocido: $1"; usage; exit 2 ;;
  esac
  shift
done

if [ "$CMD" = status ]; then
  load_all_env; find_oc || die "No encuentro oc"
  for p in "${PHASES[@]}"; do
    if phase_done "$p"; then printf '  %s✔%s %s  (%s)\n' "$C_G" "$C_0" "$p" "$(cat "$DONE_DIR/$p")"; else printf '  ·  %s\n' "$p"; fi
  done
  oc_ get pods -n "${NS:-ibm-content}" --no-headers 2>/dev/null | awk '{split($2,a,"/"); if ($3!="Completed" && (a[1]!=a[2]||$3!="Running")) print "  pod con problema:", $1, $2, $3}' || true
  exit 0
fi
if [ "$CMD" = credentials ]; then
  [ -f "$AUTH_SECRETS_FILE" ] || die "Aún no hay credenciales (.state/auth-secrets.env)."
  echo "Usuarios de prueba (LDAP) - NO compartas esta salida:"
  # shellcheck disable=SC1090
  ( . "$AUTH_SECRETS_FILE"; echo "  ccxadmin : $PW_CCXADMIN"; echo "  alice    : $PW_ALICE"; echo "  bob      : $PW_BOB"
    echo "  Keycloak admin : $KC_ADMIN_PW"; echo "  LDAP admin     : $LDAP_ADMIN_PW" )
  exit 0
fi
if [ "$CMD" = configure ]; then
  ONLY="00"; FORCE=1
  if [ "$RECONF" = 1 ]; then rm -f "$CONFIG_FILE" "$SECRETS_FILE"; fi
fi

run_phase() {
  local p="$1" rc=0
  if [ "$FORCE" = 0 ] && phase_done "$p" && [ "$p" != 08-finish ]; then
    ok "Fase $p ya completada (usa --force para repetirla)"; return 0
  fi
  bash "$ROOT/phases/$p.sh" || rc=$?
  if [ "$rc" -eq 10 ]; then warn "Fase $p pendiente de un paso manual (ver mensaje)."; return 10; fi
  [ "$rc" -eq 0 ] || { err "La fase $p falló (código $rc). Corrige y vuelve a ejecutar ./install.sh (retoma donde quedó)."; exit "$rc"; }
}

started=0; PENDING=0
for p in "${PHASES[@]}"; do
  n="${p%%-*}"
  [ -n "$ONLY" ] && [ "$n" != "$ONLY" ] && continue
  if [ -n "$FROM" ] && [ "$started" = 0 ]; then [ "$n" = "$FROM" ] || continue; started=1; fi
  rc=0; run_phase "$p" || rc=$?
  [ "$rc" -eq 10 ] && PENDING=1
done
[ "$PENDING" = 1 ] && warn "Instalación casi completa: falta el paquete de AI Services (fase 07)."
exit 0
