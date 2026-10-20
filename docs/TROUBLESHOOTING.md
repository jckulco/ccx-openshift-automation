# Solución de problemas (todos ocurrieron en la sesión de referencia)

Antes de nada: `tools/status.sh` (muestra también pods `0/1 Running`, que `grep -v Running` oculta).

| # | Síntoma | Causa | Solución |
|---|---|---|---|
| 1 | `WARNING version.toml not found` y versión 26.0.0 | Los scripts de IBM buscan `version.toml` en el directorio **padre** del cwd | Ejecutar siempre desde `scripts/` (las fases ya lo hacen) |
| 2 | Model Gateway: error `IBMLicensingDefinition` | Falta el License Service (CRDs) | Fase 03 lo instala (`helm template --include-crds` → aplicar CRDs, esperar `Established`, aplicar el resto en `ibm-licensing` con el secreto `ibm-entitlement-key` copiado) |
| 3 | ccxadmin sin permisos de admin en el dominio P8 (`E_ACCESS_DENIED`); el operador reintenta "Create Content Process Engine P8 Domain" | El dominio se creó cuando el LDAP no devolvía `ibm-entryUuid` | Prevención: la fase 02 aplica `fix-ldap-guid.sh` **antes** de Content. Reparación: `tools/reset-gcd.sh` (borra `gcddb`, con respaldo; pide escribir `SI`) |
| 4 | `403 Forbidden` al aplicar métricas/CR de AI Services, MG o WDU desde el operador | La SA `ibm-content-operator-sa` no tiene permisos sobre esos CRDs | No usar `validate --apply`; la fase 05/06 aplica con `oc` (cluster-admin) |
| 5 | Ruta de Model Gateway → 503 / `model-gateway.py` no conecta | La ruta externa no responde | Port-forward: `oc port-forward svc/model-gateway-service 8443:8080 -n <ns>`; `model-gateway.py config url https://localhost:8443` y `config insecure true` (la fase 06 lo hace) |
| 6 | Agente: `500 SYS_INTERNAL_ERROR`; en el log del Reasoning Service `403 SPACES0008E` | El Service ID de la API key no es colaborador del deployment space | Añadirlo (rol Editor). **No** hace falta cambiar nada en el gateway. Probar con `tools/test-wxai-key.py`. Para cambiar la clave de WDU: `tools/swap-wxai-key.py` |
| 7 | `PKIX path building failed` al correr `ccx_ai_metadata.sh` | Java no confía en la CA interna de CPE | Truststore PKCS12 con la cadena de la ruta de CPE + `JAVA_OPTS=-Djavax.net.ssl.trustStore=...` (lo hace `tools/ai-metadata.sh`) |
| 8 | `case.dir (and config.dir) not set` | `ccx_ai_metadata.sh` ejecutado fuera de `ccx-ai-services-metadata/` | Ejecutarlo desde esa carpeta (el script lo hace) |
| 9 | Rutas `/navigator/navigator/...` o validación `NAVIGATOR_EXTERNAL_URL must be the base URL` | URL con sufijo | `NAVIGATOR_EXTERNAL_URL=https://navigator-<ns>.<apps>` (sin `/navigator`). Si la ruta real difiere, la fase 08 avisa |
| 10 | El plug-in no encuentra el Reasoning Service | Server URL vacía/no guardada o con `/rsn` | Reguardar la URL en el plug-in, **sin** `/rsn` |
| 11 | Scripts con `set -euo pipefail` se detienen sin mensaje | `grep` sin coincidencias devuelve 1 | Usar `\|\| true` o quitar `pipefail` en esos pipes (ya aplicado en las herramientas) |
| 12 | `prerequisites.py validate` no resuelve DNS del cluster desde el bastión | El bastión no resuelve `*.svc.cluster.local` | Es opcional: si lo necesitas, ejecútalo dentro del pod del operador (copiar `scripts/`, `pip install -r requirements.txt` en `/tmp`, y **borrar** después los archivos copiados porque llevan contraseñas) |
| 13 | `ccx_ai_metadata.sh` devuelve 0 con una excepción Java | El script de IBM no propaga errores | `tools/ai-metadata.sh` revisa la salida y falla si hay excepciones |
| 14 | Login de Navigator falla con Keycloak / `invalid_client` | Cliente OIDC sin `serviceAccountsEnabled` o redirect URIs incorrectos | `tools/setup-keycloak.py "<redirect-uri>/*" ...` (idempotente, actualiza el cliente) |
| 15 | El IdP deja de ser de confianza (≈ 2027-01) | Caduca el certificado Let's Encrypt de la ruta de Keycloak | Borrar `ssl-certs/idp/*.pem`, volver a extraer la cadena (fase 05) y reaplicar `ssl/` |
| 16 | `CREATE ROLE ... already exists` al recargar la BD | `load-content-db.sh` no es idempotente | Se ejecuta una sola vez (marca `05-content-db`); para rehacer: `reset-gcd.sh` o recrear el cluster PG |
| 17 | `model-gateway.py patch-secret`: `FileNotFoundError: 'kubectl'` | OpenShift sin `kubectl` | La fase 01 crea un envoltorio `kubectl→oc` dentro del venv |
| 18 | ACCE en blanco | Caché/sesión del navegador | Ventana privada |
| 19 | El add-on de texto persistente no se aplica | A veces el primer *Install Add-on* no persiste | Repetir y verificar (clases `TxeTextExtractAnnotation` presentes) |
| 20 | `ImagePullBackOff` en operadores | Entitlement key inválida o sin derecho | `echo $KEY \| helm registry login cp.icr.io --username cp --password-stdin`; recrea el secreto `ibm-entitlement-key` |

## Diagnóstico útil
```bash
oc get fncmcluster content -n ibm-content -o json | jq '.status.conditions'
oc logs deploy/ibm-content-operator -n ibm-content --since=30m | grep -E "TASK|failed|FAIL" | tail -40
oc logs deploy/ibm-reasoning-service-deploy -n ibm-content --since=15m | grep -v "GET /health" | tail -60
oc get pods -n ibm-content | awk 'NR>1{split($2,a,"/"); if (a[1]!=a[2]) print}'
```
