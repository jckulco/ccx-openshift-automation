#!/usr/bin/env bash
# Reinicia SOLO la base del GCD (gcddb) de Content Cortex en ccx-content-pg.
# Motivo: el dominio P8 se creó mientras el LDAP no devolvía ibm-entryUuid y ccxadmin no tiene
# permisos de administrador en él. Con el LDAP ya arreglado, se deja que el operador lo cree de nuevo.
#
# ES DESTRUCTIVO para gcddb (no toca osdb, icndb ni Navigator). Antes hace una copia con pg_dump.
# Pausa el operador y CPE, borra y recrea gcddb vacía (igual que createGCD.sql) y los reactiva.
# Si algo falla a mitad, restaura las réplicas originales (trap) y NO deja nada apagado.
#
# Uso:  OC=oc bash reset-gcd.sh
set -euo pipefail

OC="${OC:-oc}"
NS="${NS:-ibm-content}"
PG="${PG:-ccx-content-pg-1}"

echo "Se va a BORRAR y recrear la base gcddb (dominio P8) en $PG, namespace $NS."
read -r -p "Escribe SI para continuar: " ok
[ "$ok" = "SI" ] || { echo "Cancelado."; exit 1; }

umask 077
BK="${BACKUP_DIR:-.}/gcddb-backup-$(date +%Y%m%d-%H%M).sql"
$OC exec -n "$NS" "$PG" -- pg_dump -U postgres gcddb > "$BK"
echo ">> Copia de seguridad: $BK ($(wc -c < "$BK") bytes). Puede contener configuración del dominio: bórrala al terminar."

OPREP="$($OC get deploy ibm-content-operator -n "$NS" -o jsonpath='{.spec.replicas}')"
CPEREP="$($OC get deploy content-cpe-deploy -n "$NS" -o jsonpath='{.spec.replicas}')"
echo ">> Réplicas originales: operador=$OPREP, CPE=$CPEREP"
restore() {
  echo ">> Restaurando réplicas (CPE=$CPEREP, operador=$OPREP)"
  $OC scale deploy/content-cpe-deploy -n "$NS" --replicas="$CPEREP" >/dev/null
  $OC scale deploy/ibm-content-operator -n "$NS" --replicas="$OPREP" >/dev/null
}
trap restore EXIT

$OC scale deploy/ibm-content-operator -n "$NS" --replicas=0 >/dev/null
$OC scale deploy/content-cpe-deploy -n "$NS" --replicas=0 >/dev/null
echo ">> Esperando a que los pods de CPE y del operador terminen..."
for _ in $(seq 1 40); do
  left="$($OC get pods -n "$NS" --no-headers 2>/dev/null | grep -E 'content-cpe-deploy|ibm-content-operator' | wc -l)"
  [ "$left" = "0" ] && break
  sleep 5
done
echo "   pods restantes: $left"

SQL() { $OC exec -n "$NS" "$PG" -- psql -U postgres -v ON_ERROR_STOP=1 "$@"; }

SQL -c "ALTER DATABASE gcddb ALLOW_CONNECTIONS false" \
    -c "SELECT count(pg_terminate_backend(pid)) AS sesiones_cerradas FROM pg_stat_activity WHERE datname='gcddb' AND pid <> pg_backend_pid()" \
    -c "DROP DATABASE gcddb" \
    -c "CREATE DATABASE gcddb OWNER ccxdb TABLESPACE gcddb_tbs TEMPLATE template0 ENCODING 'UTF8'" \
    -c "REVOKE CONNECT ON DATABASE gcddb FROM PUBLIC" \
    -c "GRANT ALL PRIVILEGES ON DATABASE gcddb TO ccxdb" \
    -c "GRANT CONNECT, TEMP, CREATE ON DATABASE gcddb TO ccxdb"
$OC exec -n "$NS" "$PG" -- psql -U postgres -d gcddb -v ON_ERROR_STOP=1 \
    -c "CREATE SCHEMA IF NOT EXISTS AUTHORIZATION ccxdb" \
    -c "ALTER DATABASE gcddb SET search_path TO ccxdb"

echo "=== tablas en gcddb tras recrearla (debe ser 0) ==="
$OC exec -n "$NS" "$PG" -- psql -U postgres -d gcddb -tAc \
  "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')"
echo ">> Hecho. Al salir se reactivan CPE y el operador."
