#!/usr/bin/env bash
# Añade el atributo ibm-entryUuid a los usuarios y grupos del OpenLDAP de laboratorio.
# Motivo: CPE y Navigator se configuraron con el tipo "IBM Security Verify Directory", que identifica
# a cada usuario/grupo por el atributo ibm-entryUuid. OpenLDAP no lo trae (usa entryUUID).
# Qué hace: (1) añade un esquema con el atributo ibm-entryUuid y una clase auxiliar,
#           (2) copia el valor de entryUUID de cada entrada a ibm-entryUuid.
# Es idempotente: se puede repetir. No imprime contraseñas.
#
# Uso:  OC=oc bash fix-ldap-guid.sh
set -euo pipefail

OC="${OC:-oc}"
NS="${NS:-ibm-auth}"

$OC exec -i -n "$NS" deploy/openldap -- sh -s <<'EOS'
set -eu
BASE="dc=example,dc=org"
ADMIN="cn=admin,$BASE"

# 1) Esquema (solo si todavía no existe)
if ldapsearch -Q -Y EXTERNAL -H ldapi:/// -b cn=schema,cn=config "(cn=*ibmentryuuid)" dn 2>/dev/null | grep -q '^dn:'; then
  echo ">> El esquema ibm-entryUuid ya existe"
else
  ldapadd -Q -Y EXTERNAL -H ldapi:/// <<'LDIF'
dn: cn=ibmentryuuid,cn=schema,cn=config
objectClass: olcSchemaConfig
cn: ibmentryuuid
olcAttributeTypes: ( 1.1.2.2.1 NAME 'ibm-entryUuid' EQUALITY caseIgnoreMatch SYNTAX 1.3.6.1.4.1.1466.115.121.1.15 SINGLE-VALUE )
olcObjectClasses: ( 1.1.2.2.2 NAME 'ibmEntryUuidAux' SUP top AUXILIARY MAY ibm-entryUuid )
LDIF
  echo ">> Esquema ibm-entryUuid añadido"
fi

# 2) Valor de ibm-entryUuid = entryUUID de cada entrada
for dn in "uid=ccxadmin,ou=users,$BASE" "uid=alice,ou=users,$BASE" "uid=bob,ou=users,$BASE" \
          "cn=ccxadmins,ou=groups,$BASE" "cn=ccxusers,ou=groups,$BASE"; do
  if ldapsearch -x -LLL -H ldap://localhost -D "$ADMIN" -w "$LDAP_ADMIN_PASSWORD" -b "$dn" -s base ibm-entryUuid | grep -qi '^ibm-entryUuid:'; then
    echo "   $dn: ya tenía ibm-entryUuid"
    continue
  fi
  u=$(ldapsearch -x -LLL -H ldap://localhost -D "$ADMIN" -w "$LDAP_ADMIN_PASSWORD" -b "$dn" -s base entryUUID | sed -n 's/^entryUUID: //p')
  if [ -z "$u" ]; then echo "   $dn: sin entryUUID, se omite"; continue; fi
  printf 'dn: %s\nchangetype: modify\nadd: objectClass\nobjectClass: ibmEntryUuidAux\n-\nadd: ibm-entryUuid\nibm-entryUuid: %s\n' "$dn" "$u" \
    | ldapmodify -x -H ldap://localhost -D "$ADMIN" -w "$LDAP_ADMIN_PASSWORD" > /dev/null
  echo "   $dn: ibm-entryUuid añadido"
done

echo "=== resultado ==="
ldapsearch -x -LLL -H ldap://localhost -D "$ADMIN" -w "$LDAP_ADMIN_PASSWORD" -b "$BASE" "(ibm-entryUuid=*)" dn ibm-entryUuid
EOS
