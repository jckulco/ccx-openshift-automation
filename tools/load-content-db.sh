#!/usr/bin/env bash
# Crea las bases de datos de Content Cortex (GCD, object store y Navigator) en ccx-content-pg.
# Ejecutar DESPUÉS de "prerequisites.py generate" (usa los SQL de generatedFiles/<ns>/database). Lo invoca phases/05-content.sh.
# Ejecutar UNA sola vez: CREATE ROLE / CREATE DATABASE no son idempotentes.
# Si falla a medias, no lo repitas: pégame el error.
#
# Uso:  OC=oc bash load-content-db.sh
set -euo pipefail

OC="${OC:-oc}"
NS="${NS:-ibm-content}"
POD="${POD:-ccx-content-pg-1}"
SQL_DIR="${SQL_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.work/ibm-content-cortex-containers/scripts/generatedFiles/${NS}/database}"

for f in createGCD.sql createos.sql createICN.sql; do
  [ -f "$SQL_DIR/$f" ] || { echo "Falta $SQL_DIR/$f"; exit 1; }
done

pg() { $OC exec -i -n "$NS" "$POD" -- "$@"; }

# --- Dónde guardar los tablespaces: dentro del volumen de datos del pod ---
PGDATA="$($OC exec -n "$NS" "$POD" -- printenv PGDATA 2>/dev/null | tr -d '\r')"
[ -n "$PGDATA" ] || { echo "No pude leer PGDATA del pod $POD"; exit 1; }
MOUNT="$($OC exec -n "$NS" "$POD" -- df --output=target "$PGDATA" 2>/dev/null | tail -1 | tr -d '\r')"
echo ">> PGDATA=$PGDATA   volumen de datos montado en: $MOUNT"
if [ -z "$MOUNT" ] || [ "$MOUNT" = "/" ] || [ "$MOUNT" = "$PGDATA" ]; then
  echo "No hay una ruta segura para los tablespaces (volumen=$MOUNT). Detenido: pégame esta salida."
  exit 1
fi
TS="$MOUNT/tablespaces"

echo ">> Creando directorios de tablespaces en $TS"
$OC exec -n "$NS" "$POD" -- sh -c \
  "mkdir -p '$TS/gcddb' '$TS/osdb/data' '$TS/osdb/index' '$TS/icndb' && \
   chmod 700 '$TS/gcddb' '$TS/osdb/data' '$TS/osdb/index' '$TS/icndb'"

# --- Ejecutar los SQL (las rutas /pgsqldata/ se sustituyen por $TS/) ---
# El rol ccxdb es el mismo en los tres: solo se crea en el primer script.
echo ">> createGCD.sql"
sed "s|/pgsqldata/|$TS/|g" "$SQL_DIR/createGCD.sql" | pg psql -v ON_ERROR_STOP=1 -U postgres -q -f -
for f in createos.sql createICN.sql; do
  echo ">> $f"
  sed -e "s|/pgsqldata/|$TS/|g" -e '/^CREATE ROLE/d' "$SQL_DIR/$f" | pg psql -v ON_ERROR_STOP=1 -U postgres -q -f -
done

echo
echo "=== Bases de datos creadas ==="
pg psql -U postgres -tA -c "\l" | grep -E "^(gcddb|osdb|icndb)\|" | cut -d'|' -f1,2
echo "=== Parámetros ==="
pg psql -U postgres -tA -c "SHOW max_prepared_transactions" -c "SHOW max_connections" -c "SHOW server_version"
