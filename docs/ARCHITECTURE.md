# Arquitectura y decisiones

## Versiones (de `version.toml` de IBM, rama `26.0.1` == tag `v26.1.0`)
| Componente | Chart | App |
|---|---|---|
| Content Operator / AI Services Operator / WDU Operator | 26.1.0 | 26.0.1 |
| Model Gateway Operator | 13.0.6 | 13.0.6 |
| IBM CNPG (PostgreSQL) Operator | 28.4.3 | 28.4.3 |
| Redis Operator | 1.4.0 | 1.4.0 |
| Usage Metering | 1.0.7 | 1.0.7 |
| License Service | 4.2.24 | 4.2.0 |

El producto "26.0.1" se instala con los **charts 26.1.0** (los charts "26.0.1" son anteriores y apuntan a staging).

## Topología
```
                         ┌──────────────── ns ibm-auth (laboratorio) ────────────────┐
 usuarios ──► Routes ──► │ Keycloak (realm ccx, cliente OIDC "ccx") ◄── OpenLDAP     │
                         └───────────────────────────────────────────────────────────┘
 ┌──────────────────────────────────── ns ibm-content ──────────────────────────────────────────┐
 │ Operadores: content · ai-services · wdu · model-gateway · cnpg · redis · usage-metering     │
 │ CPE (+ stateless) · Navigator · GraphQL · CSS · Task Manager     ◄─► ccx-content-pg (gcddb/osdb/icndb)
 │ Reasoning Service · Core MCP · Navigator AI Agent ──► Model Gateway ──► watsonx.ai (SaaS)  │
 │ WDU (extracción) ──► ccx-wdu-pg (+pooler) · watsonx.ai          MG ──► ibm-pg-cluster-mg · Redis │
 └───────────────────────────────────────────────────────────────────────────────────────────────┘
 ns ibm-licensing: License Service (instalado a mano, ver TROUBLESHOOTING #2)
```
Rutas: `cpe-`, `cpe-stless-`, `graphql-`, `navigator-`, `tm-`, `model-gateway-`, `reasoning-service-` + `<ns>.<dominio-apps>`; `keycloak-ibm-auth.<dominio>`.
Las rutas de CPE/Navigator usan la CA interna del operador ("content ICP4A Root CA"); la de Keycloak, el certificado del router.

## Decisiones de diseño (y por qué)
| Decisión | Motivo |
|---|---|
| Autenticación **LDAP + IdP** (`AUTHENTICATION=2`) con LDAP tipo *IBM Security Verify Directory* | Es lo que acepta el flujo de Navigator + AI Services con OIDC; exige el atributo `ibm-entryUuid`, que OpenLDAP no trae → `fix-ldap-guid.sh` (antes de crear el dominio P8). |
| Keycloak con `serviceAccountsEnabled=true` | El Reasoning Service/MCP usan *client credentials*; en la sesión hubo que activarlo a posteriori. |
| PostgreSQL CNPG de IBM (`pg.ibm.com/v1 Cluster`), PG 17, `max_prepared_transactions=300` | FileNet usa datasources XA. Tablespaces redirigidos dentro del volumen de datos (`load-content-db.sh`, **una sola vez**). |
| `DATABASE_SSL_ENABLE=false`, `LDAP_SSL_ENABLE=false` | Tráfico interno del cluster de laboratorio; el IdP sí valida TLS (cadena de Keycloak en `ssl-certs/idp`). |
| Modo `--silent` de IBM para `deploy_operator.py` y `prerequisites.py gather/generate` | Elimina las preguntas interactivas; las plantillas se validan con los pydantic de IBM (`tests/`). |
| `validate --apply` **no** se usa; se aplican secretos/configmaps/métricas/CRs con `oc` desde el bastión | La cuenta de servicio del operador recibe **403** al crear `IBMServiceMeterDefinition`, `ccxaiservices`, `modelgateway`, `ccxwduservices`. |
| License Service instalado a mano (CRDs de `helm template --include-crds`) | Sin él, Model Gateway falla con `IBMLicensingDefinition`. |
| Model Gateway administrado por **port-forward** | La ruta externa devolvía 503. |
| Proveedor `watsonxai` con **Space ID** (sin Project) | Con la clave de un Service ID que es colaborador del space no hace falta cambiar nada en el gateway. |
| `NAVIGATOR_EXTERNAL_URL` = URL base sin `/navigator` | Si no, el ConfigMap genera `/navigator/navigator/...`. |
| Plug-in de Navigator: Server URL = ruta del Reasoning Service **sin `/rsn`** | Verificado en la tabla de configuración de ICN; con `/rsn` no funciona. |

## Producción
Sustituye lo "de laboratorio": LDAP/IdP corporativos (omite la fase 02 y rellena `content_ldap_server.toml` / `ccx-identity_provider.toml`), PostgreSQL con 3 instancias
y backups, Redis con HA, TLS en LDAP/BD, `SECRET_MANAGEMENT=vault`, Keycloak con base de datos real, NetworkPolicies, y revisar tamaños.
