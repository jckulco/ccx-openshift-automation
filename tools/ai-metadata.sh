#!/usr/bin/env bash
# Prepara y ejecuta el script de metadatos de Content Cortex AI Services (ccx_ai_metadata.sh) contra el
# object store de CPE, y copia el plug-in de Navigator (genaiAgentPlugin.jar) al pod de Navigator.
#
# Entrada: ruta del paquete ICCXAIST_26.0.1_ML.zip (Passport Advantage M17SQML, descarga manual).
# Uso:     tools/ai-metadata.sh /ruta/ICCXAIST_26.0.1_ML.zip        (lo invoca phases/07-ai-package.sh)
#
# Pasos (todos verificados manualmente en la sesión de referencia):
#  1) descomprime el paquete en .work/ccxaitools
#  2) rellena data/ECMPopulation.properties (copia .orig, chmod 600)
#  3) crea un truststore PKCS12 con la cadena de certificados de la ruta de CPE (CA interna del operador)
#  4) ./ccx_ai_metadata.sh create CE_metadata.xml  y  insert MessageLoader.xml   (desde ccx-ai-services-metadata/)
#  5) copia genaiAgentPlugin.jar a /opt/ibm/plugins del pod de Navigator
# NOTA: ccx_ai_metadata.sh devuelve exit 0 aunque haya una excepción Java: aquí se revisa la salida.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."

ZIP="${1:-}"
[ -f "$ZIP" ] || die "Indica la ruta del paquete ICCXAIST_26.0.1_ML.zip"
need_cmd unzip openssl keytool java

DEST="$WORK_DIR/ccxaitools"
mkdir -p "$DEST"
if [ -z "$(find "$DEST" -name ccx_ai_metadata.sh -print -quit 2>/dev/null)" ]; then
  log "Descomprimiendo $ZIP"
  unzip -oq "$ZIP" -d "$DEST"
  # el zip puede contener otro zip/tar con el contenido real
  for inner in $(find "$DEST" -maxdepth 2 \( -name '*.zip' -o -name '*.tar.gz' \) | head -5); do
    case "$inner" in *.zip) unzip -oq "$inner" -d "$DEST" ;; *.tar.gz) tar -xzf "$inner" -C "$DEST" ;; esac
  done
fi
META_SH="$(find "$DEST" -name ccx_ai_metadata.sh -print -quit)"
[ -n "$META_SH" ] || die "No encuentro ccx_ai_metadata.sh dentro del paquete."
META_DIR="$(dirname "$META_SH")"
JAR="$(find "$DEST" -name genaiAgentPlugin.jar -print -quit)"
[ -n "$JAR" ] || die "No encuentro genaiAgentPlugin.jar dentro del paquete."
PROPS="$(find "$DEST" -name ECMPopulation.properties -print -quit)"
[ -n "$PROPS" ] || die "No encuentro ECMPopulation.properties."
chmod u+x "$META_SH"

APPS="$(apps_domain)"
HOST="cpe-${NS}.${APPS}"
OBJSTORE="${OBJECT_STORE_SYMNAME:-os}"
DOMAIN_NAME="${P8_DOMAIN:-P8DOMAIN}"

# --- 2) ECMPopulation.properties -------------------------------------------------------------
[ -f "$PROPS.orig" ] || cp -p "$PROPS" "$PROPS.orig"
export PW_CCXADMIN
python3 - "$PROPS" "$META_DIR" "$HOST" "$DOMAIN_NAME" "$OBJSTORE" <<'PY'
import os, re, sys
path, base, host, domain, objstore = sys.argv[1:6]
vals = {
    "psi.URI": "https://%s/wsi/FNCEWS40MTOM/" % host,
    "psi.UserName": "ccxadmin",
    "psi.Password": os.environ["PW_CCXADMIN"],
    "psi.ObjectStoreName": objstore,
    "psi.DomainName": domain,
    "rs.CP.javascriptFile": os.path.join(os.path.dirname(path), "RsChangePreprocessor.js"),
}
out, done = [], set()
for line in open(path).read().splitlines():
    m = re.match(r"^\s*#?\s*([A-Za-z0-9_.]+)\s*=", line)
    if m and m.group(1) in vals and m.group(1) not in done:
        out.append("%s=%s" % (m.group(1), vals[m.group(1)])); done.add(m.group(1)); continue
    out.append(line)
for k, v in vals.items():
    if k not in done:
        out.append("%s=%s" % (k, v))
open(path, "w").write("\n".join(out) + "\n")
print("claves escritas:", ", ".join(sorted(vals)))
PY
chmod 600 "$PROPS"
ok "ECMPopulation.properties preparado (contraseña no mostrada)"

# --- 3) truststore con la cadena de la ruta de CPE ---------------------------------------------
TS="$DEST/ccx-truststore.p12"
if [ ! -f "$TS" ]; then
  log "Creando truststore con la cadena de https://$HOST"
  TMP="$(mktemp -d)"
  openssl s_client -connect "$HOST:443" -servername "$HOST" -showcerts </dev/null 2>/dev/null \
    | awk -v d="$TMP" '/BEGIN CERTIFICATE/{n++; f=1} f{print > (d "/c" n ".pem")} /END CERTIFICATE/{f=0}'
  ls "$TMP"/c*.pem >/dev/null 2>&1 || die "No pude obtener certificados de $HOST:443"
  i=0
  for c in "$TMP"/c*.pem; do
    i=$((i + 1))
    keytool -importcert -noprompt -trustcacerts -alias "cpe-chain-$i" -file "$c" \
      -keystore "$TS" -storetype PKCS12 -storepass changeit >/dev/null
  done
  rm -rf "$TMP"
  ok "Truststore creado ($i certificados)"
fi

# --- 4) metadatos --------------------------------------------------------------------------------
JH="$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")"
export JAVA_HOME="${JAVA_HOME:-$JH}"
export JAVA_OPTS="-Djavax.net.ssl.trustStore=$TS -Djavax.net.ssl.trustStorePassword=changeit -Djavax.net.ssl.trustStoreType=PKCS12"
run_meta() { # run_meta create CE_metadata.xml
  local log_file; log_file="$(mktemp)"
  ( cd "$META_DIR" && ./ccx_ai_metadata.sh "$@" ) 2>&1 | tee "$log_file" | mask | tail -40
  if grep -q -E "Exception|PKIX|FNRCE|E_[A-Z_]+|ERROR" "$log_file" && ! grep -q "already exists" "$log_file"; then
    err "La salida contiene errores (ver arriba). El script de IBM devuelve 0 aunque falle."
    rm -f "$log_file"; return 1
  fi
  rm -f "$log_file"
}
log "ccx_ai_metadata.sh create CE_metadata.xml"
run_meta create CE_metadata.xml
log "ccx_ai_metadata.sh insert MessageLoader.xml"
run_meta insert MessageLoader.xml
ok "Metadatos de AI Services creados en el object store '$OBJSTORE'"

# --- 5) plug-in de Navigator -----------------------------------------------------------------------
log "Copiando genaiAgentPlugin.jar a /opt/ibm/plugins del pod de Navigator"
oc_ exec -n "$NS" deploy/content-navigator-deploy -c content-navigator-deploy -- mkdir -p /opt/ibm/plugins
oc_ exec -i -n "$NS" deploy/content-navigator-deploy -c content-navigator-deploy -- \
  sh -c 'cat > /opt/ibm/plugins/genaiAgentPlugin.jar' < "$JAR"
oc_ exec -n "$NS" deploy/content-navigator-deploy -c content-navigator-deploy -- ls -l /opt/ibm/plugins/genaiAgentPlugin.jar
ok "Plug-in copiado. Registra el plug-in en Navigator (ver docs/MANUAL-STEPS.md, sección 2)."
