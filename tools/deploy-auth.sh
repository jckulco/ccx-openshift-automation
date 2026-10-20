#!/usr/bin/env bash
# Despliega OpenLDAP + Keycloak (modo laboratorio) en OpenShift para Content Cortex.
# Lo invoca phases/02-auth.sh. Uso manual (sesión de oc iniciada como cluster-admin):
#   OC=oc bash tools/deploy-auth.sh
# Genera las contraseñas en .state/auth-secrets.env (chmod 600). No las pegues en ningún chat.
set -euo pipefail

OC="${OC:-oc}"
NS="${NS:-ibm-auth}"
KC_IMAGE="${KC_IMAGE:-quay.io/keycloak/keycloak:26.4}"      # si el tag no existe, usa el más reciente de quay.io/keycloak/keycloak
LDAP_IMAGE="${LDAP_IMAGE:-docker.io/osixia/openldap:1.5.0}"
BASE_DN="dc=example,dc=org"
STATE_DIR="${CCX_STATE_DIR:-$(cd "$(dirname "$0")/.." && pwd)/.state}"
mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
SECRETS_FILE="$STATE_DIR/auth-secrets.env"

gen() { openssl rand -base64 18 | tr -d '=+/' | cut -c1-16; }

echo ">> Comprobando sesión de oc..."
$OC whoami >/dev/null

APPS_DOMAIN="$($OC get ingresses.config/cluster -o jsonpath='{.spec.domain}')"
KC_HOST="keycloak-${NS}.${APPS_DOMAIN}"
echo ">> Dominio de apps: ${APPS_DOMAIN}"
echo ">> Host de Keycloak: ${KC_HOST}"

# --- Contraseñas (se reutilizan si ya existen) ---
if [[ -f "$SECRETS_FILE" ]]; then
  echo ">> Reutilizando contraseñas de $SECRETS_FILE"
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
else
  LDAP_ADMIN_PW="$(gen)"; KC_ADMIN_PW="$(gen)"
  PW_CCXADMIN="$(gen)"; PW_ALICE="$(gen)"; PW_BOB="$(gen)"
  umask 077
  cat > "$SECRETS_FILE" <<EOF
LDAP_ADMIN_PW='${LDAP_ADMIN_PW}'
KC_ADMIN_PW='${KC_ADMIN_PW}'
PW_CCXADMIN='${PW_CCXADMIN}'
PW_ALICE='${PW_ALICE}'
PW_BOB='${PW_BOB}'
EOF
  chmod 600 "$SECRETS_FILE"
  echo ">> Contraseñas guardadas en $SECRETS_FILE (chmod 600)"
fi

# --- Namespace y SCC ---
$OC get ns "$NS" >/dev/null 2>&1 || $OC create namespace "$NS"
$OC -n "$NS" create serviceaccount openldap --dry-run=client -o yaml | $OC apply -f -
# osixia/openldap necesita correr como root: se permite SOLO a esta cuenta de servicio
$OC adm policy add-scc-to-user anyuid -z openldap -n "$NS"

# --- Secretos ---
$OC -n "$NS" create secret generic ldap-admin \
  --from-literal=password="$LDAP_ADMIN_PW" --dry-run=client -o yaml | $OC apply -f -
$OC -n "$NS" create secret generic keycloak-admin \
  --from-literal=password="$KC_ADMIN_PW" --dry-run=client -o yaml | $OC apply -f -

# --- LDIF de usuarios y grupos de prueba ---
cat <<EOF | $OC -n "$NS" apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: ldap-seed
data:
  50-seed.ldif: |
    dn: ou=users,${BASE_DN}
    objectClass: organizationalUnit
    ou: users

    dn: ou=groups,${BASE_DN}
    objectClass: organizationalUnit
    ou: groups

    dn: uid=ccxadmin,ou=users,${BASE_DN}
    objectClass: inetOrgPerson
    uid: ccxadmin
    cn: CCX Admin
    sn: Admin
    mail: ccxadmin@example.org
    userPassword: ${PW_CCXADMIN}

    dn: uid=alice,ou=users,${BASE_DN}
    objectClass: inetOrgPerson
    uid: alice
    cn: Alice Test
    sn: Test
    mail: alice@example.org
    userPassword: ${PW_ALICE}

    dn: uid=bob,ou=users,${BASE_DN}
    objectClass: inetOrgPerson
    uid: bob
    cn: Bob Test
    sn: Test
    mail: bob@example.org
    userPassword: ${PW_BOB}

    dn: cn=ccxadmins,ou=groups,${BASE_DN}
    objectClass: groupOfNames
    cn: ccxadmins
    member: uid=ccxadmin,ou=users,${BASE_DN}

    dn: cn=ccxusers,ou=groups,${BASE_DN}
    objectClass: groupOfNames
    cn: ccxusers
    member: uid=ccxadmin,ou=users,${BASE_DN}
    member: uid=alice,ou=users,${BASE_DN}
    member: uid=bob,ou=users,${BASE_DN}
EOF

# --- OpenLDAP ---
cat <<EOF | $OC -n "$NS" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ldap-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: ldap-config
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 1Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: openldap
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: openldap}
  template:
    metadata:
      labels: {app: openldap}
    spec:
      serviceAccountName: openldap
      containers:
        - name: openldap
          image: ${LDAP_IMAGE}
          args: ["--copy-service"]
          env:
            - {name: LDAP_ORGANISATION, value: "Example Org"}
            - {name: LDAP_DOMAIN, value: "example.org"}
            - {name: LDAP_TLS, value: "false"}
            - name: LDAP_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: ldap-admin, key: password}}
          ports:
            - {containerPort: 389, name: ldap}
          readinessProbe:
            tcpSocket: {port: 389}
            initialDelaySeconds: 10
            periodSeconds: 5
          volumeMounts:
            - {name: data, mountPath: /var/lib/ldap}
            - {name: config, mountPath: /etc/ldap/slapd.d}
            - {name: seed, mountPath: /container/service/slapd/assets/config/bootstrap/ldif/custom}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: ldap-data}
        - name: config
          persistentVolumeClaim: {claimName: ldap-config}
        - name: seed
          configMap: {name: ldap-seed}
---
apiVersion: v1
kind: Service
metadata:
  name: openldap
spec:
  selector: {app: openldap}
  ports:
    - {name: ldap, port: 389, targetPort: 389}
EOF

# --- Keycloak (modo start-dev, base H2 en PVC; solo laboratorio) ---
cat <<EOF | $OC -n "$NS" apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: keycloak-data
spec:
  accessModes: [ReadWriteOnce]
  resources:
    requests:
      storage: 2Gi
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: keycloak
spec:
  replicas: 1
  strategy:
    type: Recreate
  selector:
    matchLabels: {app: keycloak}
  template:
    metadata:
      labels: {app: keycloak}
    spec:
      containers:
        - name: keycloak
          image: ${KC_IMAGE}
          args: ["start-dev"]
          env:
            - {name: KC_BOOTSTRAP_ADMIN_USERNAME, value: "admin"}
            - name: KC_BOOTSTRAP_ADMIN_PASSWORD
              valueFrom: {secretKeyRef: {name: keycloak-admin, key: password}}
            - {name: KC_HOSTNAME, value: "https://${KC_HOST}"}
            - {name: KC_HTTP_ENABLED, value: "true"}
            - {name: KC_PROXY_HEADERS, value: "xforwarded"}
          ports:
            - {containerPort: 8080, name: http}
          readinessProbe:
            tcpSocket: {port: 8080}
            initialDelaySeconds: 20
            periodSeconds: 10
          resources:
            requests: {cpu: 500m, memory: 1Gi}
            limits: {memory: 2Gi}
          volumeMounts:
            - {name: data, mountPath: /opt/keycloak/data}
      volumes:
        - name: data
          persistentVolumeClaim: {claimName: keycloak-data}
---
apiVersion: v1
kind: Service
metadata:
  name: keycloak
spec:
  selector: {app: keycloak}
  ports:
    - {name: http, port: 8080, targetPort: 8080}
---
apiVersion: route.openshift.io/v1
kind: Route
metadata:
  name: keycloak
spec:
  host: ${KC_HOST}
  to: {kind: Service, name: keycloak}
  port: {targetPort: http}
  tls:
    termination: edge
    insecureEdgeTerminationPolicy: Redirect
EOF

echo ">> Esperando a que arranquen los pods (puede tardar unos minutos)..."
$OC -n "$NS" rollout status deploy/openldap --timeout=300s
$OC -n "$NS" rollout status deploy/keycloak --timeout=420s

echo
echo "=============================================================="
echo " Listo."
echo " Keycloak:   https://${KC_HOST}   (usuario admin; contraseña en $SECRETS_FILE)"
echo " LDAP (interno): ldap://openldap.${NS}.svc.cluster.local:389"
echo " Base DN:        ${BASE_DN}"
echo " Bind DN admin:  cn=admin,${BASE_DN}"
echo " Usuarios:       ccxadmin, alice, bob (contraseñas en $SECRETS_FILE)"
echo " Grupos:         ccxadmins, ccxusers"
echo "=============================================================="
