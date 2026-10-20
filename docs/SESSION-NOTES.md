# Notas de cierre de la sesión de referencia

## Resultado
Content Cortex 26.0.1 Premium instalado y verificado de extremo a extremo en OpenShift 4.21.24 (TechZone, ODF, 3 masters + 5 workers amd64):
login por Keycloak/LDAP, subida de documentos, búsqueda por contenido, y el agente de Navigator (lista carpetas, crea una carpeta, resume un PDF nuevo) usando
Model Gateway → watsonx.ai (`openai/gpt-oss-120b`).

## Componentes y sitios
| | |
|---|---|
| Namespaces | `ibm-content` (todo), `ibm-auth` (OpenLDAP + Keycloak), `ibm-licensing` |
| Rutas | `cpe-`, `cpe-stless-`, `graphql-`, `navigator-`, `tm-`, `model-gateway-`, `reasoning-service-` `ibm-content.<apps>`; `keycloak-ibm-auth.<apps>` |
| Usuarios LDAP | `ccxadmin` (admin), `alice`, `bob`; grupos `ccxadmins`, `ccxusers`; base `dc=example,dc=org` |
| Realm Keycloak | `ccx`, cliente confidencial `ccx` (service account + claim `groups`) |
| BD | `ccx-content-pg` (gcddb/osdb/icndb, usuario `ccxdb`), `ibm-pg-cluster-mg`, `ccx-wdu-pg` + pooler, Redis `ibm-redis-mg` |
| MG | tenant `ccx`, proveedor `watsonxai` "watsonx", modelo `openai/gpt-oss-120b` |
| Dominio/Object store | `P8DOMAIN` / `os` (repositorio Navigator `osrepo`) |

## Cronología resumida
1. Cluster y herramientas (Helm 4.1.1, Python 3.12, rama `26.0.1`) → 2. `deploy_operator.py` (7 operadores en ~1,5 min) → 3. OpenLDAP + Keycloak →
4. `gather` / infraestructura CNPG+Redis / `generate` → 5. BD de contenido → 6. License Service manual → 7. `ibm-entryUuid` + reinicio del GCD →
8. Content `Ready` → 9. Model Gateway (tenant/proveedor/modelo/patch-secret) → 10. AI Services CR → 11. paquete de AI Services (metadatos, plug-in) →
12. ACCE (texto persistente) → 13. registro del plug-in en Navigator → 14. corrección del acceso al space de watsonx.ai → 15. verificación del agente.

## Lecciones (resumen; detalle en TROUBLESHOOTING)
- Ejecutar los scripts de IBM desde `scripts/`.
- Preparar el LDAP (`ibm-entryUuid`) **antes** de dejar que el operador cree el dominio.
- El operador no puede aplicar los CRs de MG/WDU/AI Services ni las métricas → `oc apply` desde el bastión.
- El agente depende de que el Service ID de la API key sea colaborador del deployment space.
- `grep -v Running` esconde pods `0/1 Running`.
- La licencia y la descarga del paquete de AI Services son decisiones/acciones del usuario.
