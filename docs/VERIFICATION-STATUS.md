# Estado de verificación (sé honesto con tu yo del futuro)

Leyenda: ✅ ejecutado y funcionando en la sesión de referencia (manualmente) · 🧪 probado offline en este repo · ⚠️ nuevo / sin ejecutar contra un cluster

| Pieza | Estado | Notas |
|---|---|---|
| OpenLDAP + Keycloak (`deploy-auth.sh`, `setup-keycloak.py`, `fix-ldap-guid.sh`) | ✅ | Cambios: rutas de estado (`.state/`), `serviceAccountsEnabled=true` desde el inicio, redirect URIs con las rutas previstas ⚠️ |
| `deploy_operator.py` (interactivo) | ✅ | Aquí se usa `--silent` ⚠️ (plantilla validada 🧪 con los validadores de IBM; nunca ejecutada en silent) |
| `prerequisites.py gather` (interactivo) | ✅ | Aquí `--silent` ⚠️ (plantilla 🧪). Respuestas equivalentes: Premium AU, OCP, LDAP+IDP, PostgreSQL sin SSL, LDAP sin SSL, CPE/BAN/TM/GraphQL/CSS, WDU+MG con CNPG/Redis de IBM, KVP con watsonx |
| `prerequisites.py generate` | ✅ | `--silent` ⚠️ |
| Rellenado de property files (`fill-properties.py`) | ✅ / 🧪 | Ahora sin preguntas y con `toml_set.py`; pruebas con archivos sintéticos. Las **secciones** reales de algunos TOML (`ccx-identity_provider`, `ccx-wdu`…) no se vieron todas: se usa comodín `*` ⚠️ |
| PostgreSQL de contenido + `load-content-db.sh` | ✅ | Una sola vez |
| Aplicación de secretos/ssl/configmaps/métricas/CRs con `oc` | ✅ | Orden de la sesión: secretos → CR Content → métricas → MG+WDU. Aquí se aplican las métricas antes del CR ⚠️ (inocuo) |
| License Service manual | ✅ | Idéntico |
| Model Gateway: login, tenant, provider, model, patch-secret | ✅ (interactivo) | Aquí vía `model-gateway.py` no interactivo + `tools/mgw.py` (responde "" a la pregunta de Project ID) ⚠️; estructura de `admins.json` leída con búsqueda genérica de `apikey` ⚠️ |
| AI Services CR aplicado **después** de patch-secret | ⚠️ | En la sesión el orden exacto fue distinto; es el orden lógico (el secreto ya tiene el model id) |
| Paquete de AI Services: metadatos + truststore + JAR en `/opt/ibm/plugins` | ✅ | Automatizado en `ai-metadata.sh` ⚠️ (el truststore se hacía a mano con la cadena de la ruta de CPE) |
| Registro del plug-in, add-on de texto persistente | ✅ (manual) | Sin automatizar a propósito |
| Esperas (`wait_until`, nombres de pods `ccx-content-pg-1`, `ibm-pg-cluster-mg-1`, `ccx-wdu-pg-1`, `ibm-pg-pooler-wdu-*`, `ibm-reasoning-service-deploy`, detección de Redis/Model Gateway por nombre) | ⚠️ | Nombres tomados de salidas de la sesión; si alguno difiere, la fase falla con tiempo agotado y se corrige el prefijo en el script |
| Sintaxis bash, ShellCheck, `py_compile`, `toml_set`, fase 00 con `oc` falso | 🧪 | `bash tests/run-tests.sh` |

## Primera ejecución real (TechZone, OCP 4.21.24, 5 workers 32 vCPU/128 GB, ODF)
- Fases 00, 01 (tras corregir PATH de Helm), 02, 03 y 04 ✅ (en 04 hubo que reintentar el pooler de WDU por el webhook de PG: ver TROUBLESHOOTING #22; ahora automatizado con `apply_retry`).
- Fases 05 (Content Ready), 06 (Model Gateway + AI Services, Reasoning Service listo) y 07 (metadatos + JAR en Navigator) ✅ en esa misma ejecución.
- Fase 07: falso positivo del detector de errores (`SETTABLE_ONLY_ON_CREATE` coincidía con `E_[A-Z_]+`); corregido y con marcas por paso (TROUBLESHOOTING #23).
- Observado en la tabla de la fase 08: rutas con 404 en `/` (normal), `model-gateway` 503 (ruta externa, ver #5) y `legal-hold-mcp-server-route` 503 (sin investigar).
- Pasos manuales (add-on de texto persistente en ACCE, plug-in y layout *Ask AI agents* en Navigator) y prueba funcional ✅ confirmados por el usuario.
- Sin investigar: 503 de `legal-hold-mcp-server-route` (no afectó al resto). Revisar `oc get pods -n ibm-content | grep -i legal` y los logs si se necesita ese MCP.
- Una sola ejecución en un solo cluster: no hay datos de repetibilidad ni de otras versiones de OCP.

## Dimensionamiento observado
Referencia usada: 5 workers de 32 vCPU / 128 GB (ODF). Es una configuración **holgada**: no se midió el consumo real.
Tras una instalación, ejecuta `oc adm top nodes` y `oc describe nodes | grep -A8 "Allocated resources"` y anota aquí los valores
para ajustar (p. ej. probar con 4 workers del mismo tamaño; 3 workers no se recomiendan con ODF).
- Medición: _pendiente_

## Cómo cerrar los ⚠️
Ejecuta en un cluster **desechable** de TechZone y anota en un issue cada fase que necesite ajuste. Orden de riesgo (de mayor a menor):
fase 04 (nombres de pods/readiness), fase 06 (MG: readiness y `admins.json`), fase 03 (`--silent`), fase 05 (property files reales).
