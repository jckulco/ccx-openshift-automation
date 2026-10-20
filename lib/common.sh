#!/usr/bin/env bash
# Funciones comunes para install.sh y las fases. Se carga con:  source lib/common.sh
# No ejecutar directamente.

[ -n "${CCX_COMMON_LOADED:-}" ] && return 0
CCX_COMMON_LOADED=1

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="${CCX_STATE_DIR:-$REPO_ROOT/.state}"          # estado + secretos locales (git-ignorado)
WORK_DIR="${CCX_WORK_DIR:-$REPO_ROOT/.work}"             # clon del repo de IBM, venv, paquete de AI Services
CONFIG_FILE="$STATE_DIR/config.env"                       # valores NO secretos
SECRETS_FILE="$STATE_DIR/secrets.env"                     # entitlement key, API key de watsonx (chmod 600)
AUTH_SECRETS_FILE="$STATE_DIR/auth-secrets.env"           # contraseñas de LDAP/Keycloak/usuarios de prueba
CONTENT_SECRETS_FILE="$STATE_DIR/ccx-content-secrets.env" # contraseñas generadas (BD, keystore, LTPA, MG admin)
IDP_FILE="$STATE_DIR/ccx-idp.env"                         # discovery URL, client id/secret de Keycloak
DONE_DIR="$STATE_DIR/done"                                # marcas de fases completadas

IBM_REPO_URL="${IBM_REPO_URL:-https://github.com/ibm-ecm/ibm-content-cortex-containers.git}"
IBM_REPO_REF="${IBM_REPO_REF:-26.0.1}"                    # rama 26.0.1 == tag v26.1.0 (charts 26.1.0, app 26.0.1)
IBM_DIR="$WORK_DIR/ibm-content-cortex-containers"
# shellcheck disable=SC2034  # usado por las fases
IBM_SCRIPTS="$IBM_DIR/scripts"
VENV_DIR="$WORK_DIR/venv"

# En algunos bastiones (TechZone) /usr/local/bin no está en el PATH de root: Helm y oc se instalan ahí.
case ":$PATH:" in *":/usr/local/bin:"*) ;; *) PATH="/usr/local/bin:$PATH"; export PATH ;; esac

mkdir -p "$STATE_DIR" "$DONE_DIR" "$WORK_DIR"
chmod 700 "$STATE_DIR" 2>/dev/null || true

# ---------------------------------------------------------------- salida
if [ -t 1 ]; then C_B=$'\e[1m'; C_R=$'\e[31m'; C_G=$'\e[32m'; C_Y=$'\e[33m'; C_C=$'\e[36m'; C_0=$'\e[0m'
else C_B=""; C_R=""; C_G=""; C_Y=""; C_C=""; C_0=""; fi
log()   { printf '%s>>%s %s\n' "$C_C" "$C_0" "$*"; }
ok()    { printf '%s✔%s  %s\n' "$C_G" "$C_0" "$*"; }
warn()  { printf '%s!!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
err()   { printf '%sERROR:%s %s\n' "$C_R" "$C_0" "$*" >&2; }
die()   { err "$*"; exit 1; }
title() { printf '\n%s== %s ==%s\n' "$C_B" "$*" "$C_0"; }

# ---------------------------------------------------------------- estado
# load_env FILE  -> exporta las variables KEY='valor' (sin imprimirlas)
load_env() {
  local f="$1"
  [ -f "$f" ] || return 0
  set -a
  # shellcheck disable=SC1090
  . "$f"
  set +a
}
# set_env FILE KEY VALUE -> escribe/actualiza KEY='VALUE' (chmod 600)
set_env() {
  local f="$1" k="$2" v="$3" tmp
  ( umask 077; touch "$f" )
  tmp="$(mktemp "$STATE_DIR/.tmp.XXXXXX")"
  grep -v -E "^${k}=" "$f" > "$tmp" || true
  printf "%s='%s'\n" "$k" "${v//\'/\'\\\'\'}" >> "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"; chmod 600 "$f"
}
phase_done()  { [ -f "$DONE_DIR/$1" ]; }
mark_done()   { date -u +%FT%TZ > "$DONE_DIR/$1"; }
clear_done()  { rm -f "$DONE_DIR/$1"; }

load_all_env() {
  load_env "$CONFIG_FILE"; load_env "$SECRETS_FILE"; load_env "$AUTH_SECRETS_FILE"
  load_env "$CONTENT_SECRETS_FILE"; load_env "$IDP_FILE"
  : "${NS:=ibm-content}"; : "${AUTH_NS:=ibm-auth}"
  export NS AUTH_NS
}

# ---------------------------------------------------------------- oc
find_oc() {
  if [ -n "${OC:-}" ] && command -v "$OC" >/dev/null 2>&1; then return 0; fi
  for c in oc /opt/oc.rhel9 /usr/local/bin/oc; do
    if command -v "$c" >/dev/null 2>&1; then OC="$(command -v "$c")"; export OC; return 0; fi
  done
  return 1
}
oc_() { "$OC" "$@"; }

# apply_retry <args de 'oc apply'>   (no admite '-f -': usa un archivo)
# El servicio ibm-pg-webhook-service de IBM incluye en su selector a los pods de PostgreSQL (que no escuchan en 9443),
# así que ~3 de cada 4 intentos fallan con "failed calling webhook ... connection refused". Se reintenta sólo
# ante ese tipo de errores transitorios; cualquier otro error falla de inmediato.
apply_retry() {
  local i out max="${APPLY_RETRIES:-40}" delay="${APPLY_RETRY_DELAY:-3}"
  for i in $(seq 1 "$max"); do
    if out="$(oc_ apply "$@" 2>&1)"; then printf '%s\n' "$out"; return 0; fi
    if printf '%s' "$out" | grep -qiE 'failed calling webhook|connection refused|context deadline exceeded|i/o timeout|no endpoints available'; then
      [ "$i" -eq 1 ] && warn "webhook no disponible (reintentando hasta $max veces)..."
      sleep "$delay"; continue
    fi
    printf '%s\n' "$out" >&2; return 1
  done
  printf '%s\n' "$out" >&2; err "apply agotó $max reintentos"; return 1
}

apps_domain() { oc_ get ingresses.config/cluster -o jsonpath='{.spec.domain}'; }

# ---------------------------------------------------------------- preguntas
# ask VAR "texto" [defecto]   (respeta variables ya definidas en el entorno)
ask() {
  local var="$1" prompt="$2" def="${3:-}" cur="${!1:-}" ans
  if [ -n "$cur" ]; then return 0; fi
  if [ "${CCX_NONINTERACTIVE:-0}" = 1 ]; then
    [ -n "$def" ] || die "Falta $var (modo no interactivo)."
    printf -v "$var" '%s' "$def"; export "${var?}"; return 0
  fi
  if [ -n "$def" ]; then read -r -p "$prompt [$def]: " ans; ans="${ans:-$def}"
  else read -r -p "$prompt: " ans; fi
  [ -n "$ans" ] || die "Valor requerido: $var"
  printf -v "$var" '%s' "$ans"; export "${var?}"
}
# ask_optional VAR "texto"  (puede quedar vacío)
ask_optional() {
  local var="$1" prompt="$2" ans
  if [ -n "${!1:-}" ] || [ "${CCX_NONINTERACTIVE:-0}" = 1 ]; then return 0; fi
  read -r -p "$prompt (Enter para omitir): " ans
  printf -v "$var" '%s' "$ans"; export "${var?}"
}
# ask_secret VAR "texto"  (no se muestra, no se guarda en el historial)
ask_secret() {
  local var="$1" prompt="$2" cur="${!1:-}" ans
  if [ -n "$cur" ]; then return 0; fi
  [ "${CCX_NONINTERACTIVE:-0}" = 1 ] && die "Falta $var (modo no interactivo)."
  read -r -s -p "$prompt (no se muestra): " ans; echo
  [ -n "$ans" ] || die "Valor requerido: $var"
  printf -v "$var" '%s' "$ans"; export "${var?}"
}
# confirm "texto" [y|n]  -> 0 si sí
confirm() {
  local prompt="$1" def="${2:-n}" ans hint="[y/N]"
  [ "$def" = y ] && hint="[Y/n]"
  if [ "${CCX_ASSUME_YES:-0}" = 1 ]; then return 0; fi
  if [ "${CCX_NONINTERACTIVE:-0}" = 1 ]; then [ "$def" = y ]; return; fi
  read -r -p "$prompt $hint " ans; ans="${ans:-$def}"
  [[ "$ans" =~ ^[YySs] ]]
}

# ---------------------------------------------------------------- utilidades
gen_pw() { openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20; }

need_cmd() {
  local c
  for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "Falta el comando '$c'. Ejecuta la fase 01 (bootstrap) o instálalo."; done
}

activate_venv() {
  [ -f "$VENV_DIR/bin/activate" ] || die "No existe el entorno virtual ($VENV_DIR). Ejecuta la fase 01."
  # shellcheck disable=SC1091
  . "$VENV_DIR/bin/activate"
}

# wait_until "descripción" TIMEOUT_S INTERVALO_S comando...   (reintenta hasta que el comando devuelva 0)
wait_until() {
  local desc="$1" timeout="$2" step="$3"; shift 3
  local t0 now; t0="$(date +%s)"
  while true; do
    if "$@" >/dev/null 2>&1; then ok "$desc"; return 0; fi
    now="$(date +%s)"
    if [ $((now - t0)) -ge "$timeout" ]; then err "Tiempo agotado esperando: $desc"; return 1; fi
    printf '.'; sleep "$step"
  done
}

# Todos los pods cuyo nombre empieza por PREFIJO están listos (y hay al menos uno)
pods_ready_by_prefix() {
  local ns="$1" prefix="$2" out
  out="$(oc_ get pods -n "$ns" --no-headers 2>/dev/null | awk -v p="^$prefix" '$1 ~ p {print $2" "$3}')"
  [ -n "$out" ] || return 1
  while read -r ready status; do
    [ "$status" = "Running" ] || [ "$status" = "Completed" ] || return 1
    [ "$status" = "Completed" ] && continue
    [ "${ready%/*}" = "${ready#*/}" ] || return 1
  done <<< "$out"
}

# Enmascara secretos conocidos en una salida (por si se vuelca algo a un log)
mask() {
  sed -E "s/(ENTITLEMENT_KEY|API_KEY|PASSWORD|SECRET|TOKEN|PW)[A-Za-z_]*([=:'\" ]+)[^ ]+/\1\2<oculto>/Ig"
}

route_host() { # route_host NS NAME
  oc_ get route "$2" -n "$1" -o jsonpath='{.spec.host}' 2>/dev/null
}
