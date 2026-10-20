#!/usr/bin/env python3
"""Configura Keycloak (laboratorio) para IBM Content Cortex.

Crea, de forma idempotente:
  1. realm "ccx"
  2. federación LDAP (OpenLDAP de ibm-auth) + mapper de grupos + sincronización
  3. cliente OIDC confidencial "ccx" con claim "groups"
  4. archivo ./ccx-idp.env (chmod 600) con discovery URL, client ID y client secret
  5. prueba de login de "alice" contra el realm

Uso (lo invoca phases/02-auth.sh; requiere .state/auth-secrets.env y sesión de oc iniciada):
  OC=oc python3 setup-keycloak.py "https://cpe-ibm-content.apps.../*" "https://navigator-ibm-content.apps.../*"
    (los argumentos son los redirect URIs del cliente; si el cliente ya existe, los actualiza)

Solo biblioteca estándar de Python (3.9+). No imprime contraseñas ni secretos.
"""
import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

OC = os.environ.get("OC", "oc")
NS = os.environ.get("NS", "ibm-auth")
REALM = os.environ.get("REALM", "ccx")
CLIENT_ID = os.environ.get("CLIENT_ID", "ccx")
BASE_DN = "dc=example,dc=org"
LDAP_URL = "ldap://openldap.%s.svc.cluster.local:389" % NS
STATE_DIR = os.environ.get("CCX_STATE_DIR", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".state"))
SECRETS_FILE = os.path.join(STATE_DIR, "auth-secrets.env")
OUT_FILE = os.path.join(STATE_DIR, "ccx-idp.env")

CTX = ssl._create_unverified_context()  # la ruta usa la CA del ingress de OpenShift (laboratorio)


def load_env(path):
    values = {}
    with open(path) as fh:
        for line in fh:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, val = line.split("=", 1)
            values[key] = val.strip().strip("'").strip('"')
    return values


def http(method, url, token=None, data=None, form=None):
    headers = {}
    body = None
    if token:
        headers["Authorization"] = "Bearer " + token
    if form is not None:
        body = urllib.parse.urlencode(form).encode()
        headers["Content-Type"] = "application/x-www-form-urlencoded"
    elif data is not None:
        body = json.dumps(data).encode()
        headers["Content-Type"] = "application/json"
    elif method in ("POST", "PUT"):
        body = b""
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, context=CTX) as resp:
            raw = resp.read().decode()
            hdrs = {k.lower(): v for k, v in resp.headers.items()}
            payload = None
            if raw:
                try:
                    payload = json.loads(raw)
                except ValueError:
                    payload = raw
            return resp.status, hdrs, payload
    except urllib.error.HTTPError as err:
        raw = err.read().decode(errors="replace")
        return err.code, {k.lower(): v for k, v in err.headers.items()}, raw


def fail(msg, detail=None):
    print("ERROR: " + msg)
    if detail:
        print(str(detail)[:500])
    sys.exit(1)


def main():
    redirect_args = sys.argv[1:]
    secrets = load_env(SECRETS_FILE)
    host = subprocess.check_output(
        [OC, "-n", NS, "get", "route", "keycloak", "-o", "jsonpath={.spec.host}"]
    ).decode().strip()
    base = "https://" + host
    print(">> Keycloak: " + base)

    # --- Token de administrador ---
    st, _, tok = http(
        "POST", base + "/realms/master/protocol/openid-connect/token",
        form={"client_id": "admin-cli", "grant_type": "password",
              "username": "admin", "password": secrets["KC_ADMIN_PW"]},
    )
    if st != 200:
        fail("no se pudo obtener el token de admin (HTTP %s)" % st, tok)
    token = tok["access_token"]
    admin = base + "/admin/realms"

    # --- 1. Realm ---
    st, _, realm = http("GET", "%s/%s" % (admin, REALM), token)
    if st == 404:
        st, _, body = http("POST", admin, token, data={
            "realm": REALM, "enabled": True, "displayName": "Content Cortex"})
        if st not in (200, 201):
            fail("no se pudo crear el realm (HTTP %s)" % st, body)
        print(">> Realm '%s' creado" % REALM)
        st, _, realm = http("GET", "%s/%s" % (admin, REALM), token)
    elif st == 200:
        print(">> Realm '%s' ya existía" % REALM)
    else:
        fail("consulta del realm (HTTP %s)" % st, realm)
    realm_id = realm["id"]

    # --- 2. Federación LDAP ---
    st, _, comps = http(
        "GET", "%s/%s/components?parent=%s&type=org.keycloak.storage.UserStorageProvider"
        % (admin, REALM, realm_id), token)
    ldap_id = None
    if st == 200:
        for comp in comps:
            if comp.get("name") == "openldap":
                ldap_id = comp["id"]
    if not ldap_id:
        st, hdrs, body = http("POST", "%s/%s/components" % (admin, REALM), token, data={
            "name": "openldap",
            "providerId": "ldap",
            "providerType": "org.keycloak.storage.UserStorageProvider",
            "parentId": realm_id,
            "config": {
                "enabled": ["true"], "priority": ["0"], "editMode": ["READ_ONLY"],
                "vendor": ["other"], "authType": ["simple"],
                "connectionUrl": [LDAP_URL],
                "bindDn": ["cn=admin," + BASE_DN],
                "bindCredential": [secrets["LDAP_ADMIN_PW"]],
                "usersDn": ["ou=users," + BASE_DN],
                "usernameLDAPAttribute": ["uid"], "rdnLDAPAttribute": ["uid"],
                "uuidLDAPAttribute": ["entryUUID"],
                "userObjectClasses": ["inetOrgPerson"],
                "searchScope": ["1"], "importEnabled": ["true"],
                "syncRegistrations": ["false"], "pagination": ["true"],
                "batchSizeForSync": ["1000"], "cachePolicy": ["DEFAULT"],
                "fullSyncPeriod": ["-1"], "changedSyncPeriod": ["-1"],
            },
        })
        if st not in (200, 201):
            fail("no se pudo crear la federación LDAP (HTTP %s)" % st, body)
        ldap_id = hdrs["location"].rstrip("/").split("/")[-1]
        print(">> Federación LDAP creada")
    else:
        print(">> Federación LDAP ya existía")

    # Mapper de grupos
    st, _, mappers = http(
        "GET", "%s/%s/components?parent=%s&type=org.keycloak.storage.ldap.mappers.LDAPStorageMapper"
        % (admin, REALM, ldap_id), token)
    group_mapper_id = None
    if st == 200:
        for comp in mappers:
            if comp.get("name") == "groups":
                group_mapper_id = comp["id"]
    if not group_mapper_id:
        st, hdrs, body = http("POST", "%s/%s/components" % (admin, REALM), token, data={
            "name": "groups",
            "providerId": "group-ldap-mapper",
            "providerType": "org.keycloak.storage.ldap.mappers.LDAPStorageMapper",
            "parentId": ldap_id,
            "config": {
                "groups.dn": ["ou=groups," + BASE_DN],
                "group.name.ldap.attribute": ["cn"],
                "group.object.classes": ["groupOfNames"],
                "preserve.group.inheritance": ["false"],
                "ignore.missing.groups": ["false"],
                "membership.ldap.attribute": ["member"],
                "membership.attribute.type": ["DN"],
                "membership.user.ldap.attribute": ["uid"],
                "groups.ldap.filter": [""],
                "mode": ["READ_ONLY"],
                "user.roles.retrieve.strategy": ["LOAD_GROUPS_BY_MEMBER_ATTRIBUTE"],
                "mapped.group.attributes": [""],
                "drop.non.existing.groups.during.sync": ["false"],
            },
        })
        if st not in (200, 201):
            fail("no se pudo crear el mapper de grupos (HTTP %s)" % st, body)
        group_mapper_id = hdrs["location"].rstrip("/").split("/")[-1]
        print(">> Mapper de grupos creado")

    # Sincronización de usuarios y grupos
    st, _, body = http(
        "POST", "%s/%s/user-storage/%s/sync?action=triggerFullSync" % (admin, REALM, ldap_id), token)
    print(">> Sincronización de usuarios: HTTP %s %s" % (st, body if st != 200 else ""))
    st, _, body = http(
        "POST", "%s/%s/user-storage/%s/mappers/%s/sync?direction=fedToKeycloak"
        % (admin, REALM, ldap_id, group_mapper_id), token)
    print(">> Sincronización de grupos: HTTP %s %s" % (st, body if st != 200 else ""))

    # --- 3. Cliente OIDC ---
    st, _, found = http("GET", "%s/%s/clients?clientId=%s" % (admin, REALM, CLIENT_ID), token)
    if st != 200:
        fail("consulta de clientes (HTTP %s)" % st, found)
    if found:
        client_uuid = found[0]["id"]
        print(">> Cliente '%s' ya existía" % CLIENT_ID)
        if redirect_args:
            st, _, rep = http("GET", "%s/%s/clients/%s" % (admin, REALM, client_uuid), token)
            rep["redirectUris"] = redirect_args
            rep["webOrigins"] = ["+"]
            rep["serviceAccountsEnabled"] = True
            st, _, body = http("PUT", "%s/%s/clients/%s" % (admin, REALM, client_uuid), token, data=rep)
            print(">> Redirect URIs actualizados: HTTP %s" % st)
    else:
        redirects = redirect_args or ["https://localhost/*"]
        st, hdrs, body = http("POST", "%s/%s/clients" % (admin, REALM), token, data={
            "clientId": CLIENT_ID, "name": "IBM Content Cortex",
            "protocol": "openid-connect", "enabled": True,
            "publicClient": False, "clientAuthenticatorType": "client-secret",
            "standardFlowEnabled": True, "directAccessGrantsEnabled": True,
            "serviceAccountsEnabled": True,   # necesario para el Reasoning Service / MCP (client credentials)
            "redirectUris": redirects, "webOrigins": ["+"],
        })
        if st not in (200, 201):
            fail("no se pudo crear el cliente (HTTP %s)" % st, body)
        client_uuid = hdrs["location"].rstrip("/").split("/")[-1]
        print(">> Cliente '%s' creado" % CLIENT_ID)

    # Claim "groups" en los tokens
    st, _, body = http(
        "POST", "%s/%s/clients/%s/protocol-mappers/models" % (admin, REALM, client_uuid), token, data={
            "name": "groups", "protocol": "openid-connect",
            "protocolMapper": "oidc-group-membership-mapper",
            "config": {"claim.name": "groups", "full.path": "false",
                       "id.token.claim": "true", "access.token.claim": "true",
                       "userinfo.token.claim": "true"},
        })
    if st in (200, 201):
        print(">> Claim 'groups' añadido")
    elif st == 409:
        print(">> Claim 'groups' ya existía")
    else:
        print(">> AVISO: claim 'groups' (HTTP %s)" % st)

    # --- 4. Credenciales del cliente ---
    st, _, sec = http("GET", "%s/%s/clients/%s/client-secret" % (admin, REALM, client_uuid), token)
    if st != 200:
        fail("no se pudo leer el client secret (HTTP %s)" % st, sec)
    discovery = "%s/realms/%s/.well-known/openid-configuration" % (base, REALM)
    old_umask = os.umask(0o077)
    with open(OUT_FILE, "w") as fh:
        fh.write("IDP_DISCOVERY_URL='%s'\n" % discovery)
        fh.write("IDP_ISSUER='%s/realms/%s'\n" % (base, REALM))
        fh.write("IDP_CLIENT_ID='%s'\n" % CLIENT_ID)
        fh.write("IDP_CLIENT_SECRET='%s'\n" % sec["value"])
    os.umask(old_umask)
    os.chmod(OUT_FILE, 0o600)
    print(">> Credenciales guardadas en %s (chmod 600)" % OUT_FILE)

    # --- 5. Pruebas ---
    st, _, _ = http("GET", discovery)
    print(">> Discovery URL: HTTP %s" % st)
    st, _, tokresp = http(
        "POST", "%s/realms/%s/protocol/openid-connect/token" % (base, REALM),
        form={"grant_type": "password", "client_id": CLIENT_ID,
              "client_secret": sec["value"], "username": "alice",
              "password": secrets["PW_ALICE"], "scope": "openid"})
    if st == 200:
        print(">> Login de prueba con 'alice' (LDAP -> Keycloak): OK")
    else:
        print(">> AVISO: login de prueba con 'alice' falló (HTTP %s): %s" % (st, str(tokresp)[:300]))

    print("\nListo. Discovery URL: " + discovery)
    print("Client ID: " + CLIENT_ID + "  (el client secret está en " + OUT_FILE + ")")


if __name__ == "__main__":
    main()
