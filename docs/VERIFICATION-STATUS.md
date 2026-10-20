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

## Cómo cerrar los ⚠️
Ejecuta en un cluster **desechable** de TechZone y anota en un issue cada fase que necesite ajuste. Orden de riesgo (de mayor a menor):
fase 04 (nombres de pods/readiness), fase 06 (MG: readiness y `admins.json`), fase 03 (`--silent`), fase 05 (property files reales).
