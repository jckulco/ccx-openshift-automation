# IBM Content Cortex 26.0.1 (Premium) en Red Hat OpenShift — instalación automatizada

Repositorio para **recrear, en minutos de trabajo propio y ~1–2 h de espera**, el ambiente de referencia de
IBM Content Cortex v26.0.1 Premium que se montó y verificó de punta a punta en un cluster de TechZone
(OpenShift 4.21, ODF): **Content Platform Engine, Navigator, GraphQL, Content Search, Task Manager,
AI Services (Reasoning Service, MCP, agente de Navigator), Enhanced Extraction (WDU) y Model Gateway con watsonx.ai**.

> ⚠️ **Estado de verificación.** Cada comando de este repo proviene de pasos que funcionaron en la sesión de
> referencia, pero **el orquestador completo (`install.sh`) aún no se ha ejecutado de extremo a extremo contra un cluster**.
> Lo que sí está probado offline: sintaxis, ShellCheck, `toml_set`/`fill-properties` con archivos sintéticos, y que las
> plantillas del modo `--silent` de IBM pasan los validadores pydantic de IBM. Detalle en
> [`docs/VERIFICATION-STATUS.md`](docs/VERIFICATION-STATUS.md). Espera ajustar algún detalle en la primera ejecución;
> todas las fases son idempotentes y retoman donde quedaron.

## Lo único que tienes que escribir

| Dato | Dónde se obtiene |
|---|---|
| **IBM Entitlement Key** | <https://myibm.ibm.com/products-services/containerlibrary> |
| **API key de IBM Cloud** para watsonx.ai | IBM Cloud → IAM → API keys (de un Service ID, ver [PREREQUISITES](docs/PREREQUISITES.md)) |
| **URL/región de watsonx.ai** | p. ej. `https://us-south.ml.cloud.ibm.com` |
| **Space ID** del deployment space | watsonx.ai → Deployments → tu space → Manage → *Space GUID* |
| **Model ID** | p. ej. `openai/gpt-oss-120b` |
| **Aceptar la licencia de IBM** | tú decides; el instalador nunca la acepta por su cuenta |

Todo lo demás (namespaces, contraseñas, LDAP, Keycloak, bases de datos, certificados, CRs, tenant del Model Gateway…) se
decide y se genera automáticamente. Las claves se piden sin eco, se guardan en `.state/` con permisos `600` y **nunca**
se imprimen ni se suben a Git (`.gitignore`).

## Inicio rápido

```bash
# En el bastión RHEL 9 con acceso al cluster (oc login como cluster-admin)
git clone https://github.com/<tu-usuario>/ccx-openshift-automation.git
cd ccx-openshift-automation
oc login --token=... --server=https://api....:6443

./install.sh                 # pregunta lo anterior y ejecuta las fases 00 → 08
```

Sin preguntas (CI / repetición): copia `config/config.env.example` a `config/config.env`, rellénalo y ejecuta
`set -a; . config/config.env; set +a; ./install.sh --non-interactive`.

### Fases

| # | Fase | Qué hace | Tiempo aprox. |
|---|---|---|---|
| 00 | `configure` | Pide los datos clave, valida el cluster, la entitlement key (login a `cp.icr.io`) y la API key contra watsonx.ai | 1 min |
| 01 | `bootstrap` | Instala Python 3.12, Helm 4, Java 21, podman…; clona el repo de IBM (rama `26.0.1` = tag `v26.1.0`); venv + `kubectl→oc` | 3 min |
| 02 | `auth` | OpenLDAP + Keycloak (ns `ibm-auth`), usuarios `ccxadmin/alice/bob`, atributo `ibm-entryUuid`, cliente OIDC `ccx` | 5 min |
| 03 | `operators` | `deploy_operator.py --silent` (7 operadores) + License Service manual | 5 min |
| 04 | `infra` | `prerequisites.py --silent gather`; PostgreSQL de contenido, PG+Redis de Model Gateway, PG+pooler de WDU | 10 min |
| 05 | `content` | Rellena property files, `generate`, crea BD (una vez), secretos/CRs, espera a Content `Ready`, aplica MG y WDU | 30–60 min |
| 06 | `model-gateway` | Port-forward, tenant `ccx`, proveedor watsonx, modelo, `patch-secret`, AI Services CR | 10 min |
| 07 | `ai-package` | Metadatos de AI Services en CPE + copia del plug-in a Navigator. **Requiere descarga manual del paquete** | 5 min |
| 08 | `finish` | URLs, comprobaciones HTTP y checklist de pasos manuales | 1 min |

```bash
./install.sh status                  # fases hechas y pods con problemas
./install.sh reconfigure             # cambiar API key / space / modelo (vuelve a preguntar)
./install.sh --from 05               # retomar desde una fase
./install.sh --only 07               # una sola fase
CCX_AI_PACKAGE=/ruta/ICCXAIST_26.0.1_ML.zip ./install.sh --only 07
./install.sh credentials             # contraseñas de ccxadmin/alice/bob (explícito)
tools/status.sh                      # CRs, pods no listos (incluye 0/1 Running), rutas
./uninstall.sh [--local]             # eliminar todo (destructivo, pide confirmación)
bash tests/run-tests.sh              # pruebas offline
```

## Lo que NO se puede automatizar (ver [`docs/MANUAL-STEPS.md`](docs/MANUAL-STEPS.md))

1. **Descargar el paquete de AI Services** de Passport Advantage (`M17SQML`, `ICCXAIST_26.0.1_ML.zip`): requiere tu IBMid y aceptar su licencia.
2. **ACCE**: instalar el add-on *5.6.0 Persistent Text Extract Extensions* y activar *Persistent Text Extracts* en la clase `Document`.
3. **Navigator (admin)**: *Upload File Path*, registrar el plug-in *IBM Content Cortex AI Agents*, habilitar el layout *Ask AI agents*.
4. **IBM Cloud**: plan de pago de watsonx.ai y Service ID como colaborador del deployment space.

## Estructura

```
install.sh · uninstall.sh          orquestador
phases/00..08-*.sh                 fases idempotentes (marcas en .state/done)
lib/common.sh                      utilidades (prompts, espera, estado, enmascarado)
tools/                             deploy-auth.sh, setup-keycloak.py, fix-ldap-guid.sh, load-content-db.sh,
                                   fill-properties.py, toml_set.py, mgw.py, mg-admin-token.py, ai-metadata.sh,
                                   test-wxai-key.py, swap-wxai-key.py, reset-gcd.sh, status.sh
templates/                         CR de PostgreSQL de contenido + especificaciones de los TOML silent de IBM
docs/                              PREREQUISITES · ARCHITECTURE · MANUAL-STEPS · TROUBLESHOOTING · SECURITY ·
                                   VERIFICATION-STATUS · SESSION-NOTES
tests/                             pruebas offline (también corren en GitHub Actions)
```

## Qué es "de laboratorio" y qué no

OpenLDAP (osixia) y Keycloak en modo `start-dev` (H2) son **solo para laboratorio**; para producción usa tu LDAP/IdP y
rellena los property files de IBM a mano ([ARCHITECTURE](docs/ARCHITECTURE.md#producción)). Lo mismo aplica a
PostgreSQL de 1 instancia, Redis sin HA y TLS con las CAs por defecto del cluster.

## Licencia

Scripts y documentación: MIT (ver `LICENSE`). **IBM Content Cortex y sus artefactos son de IBM** y se rigen por su
licencia; este proyecto no está afiliado a IBM.
