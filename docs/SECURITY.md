# Seguridad

- **Nunca** pegues en chats, issues o commits: entitlement key, API keys de IBM Cloud, tokens de `oc login`, contenido de `.state/`.
- `.state/` (700) y sus archivos (600) contienen: entitlement key, API key de watsonx.ai, contraseñas de LDAP/Keycloak/usuarios, client secret OIDC,
  contraseñas de BD/keystore/LTPA/MG. Está en `.gitignore`. `./uninstall.sh --local` lo borra.
- El instalador **no acepta la licencia por ti** y **no imprime secretos** (las salidas de scripts de IBM pasan por `mask`).
- `deploy_operator.py --silent` necesita la entitlement key en un TOML: se escribe en el clon de IBM con `chmod 600` y se **restaura el original al terminar** (también si falla).
- Pasa los JSON de configuración por stdin (no por argv) para que los secretos no aparezcan en `ps`.
- Queda en el repo de IBM clonado (`.work/`): `propertyFile/<ns>/*.toml` y `generatedFiles/<ns>/secrets/*.yaml` con contraseñas (600). Bórralos al terminar.
- OpenLDAP/Keycloak son de **laboratorio**: SCC `anyuid` sólo para la SA `openldap`, Keycloak `start-dev`, sin TLS interno.
- Rota la API key de watsonx.ai y la entitlement key al terminar una demo. El Model Gateway usa la API key de watsonx.ai (ahora en el secreto del proveedor).
- El Usage Metering envía datos de uso a IBM Software Central si aceptas la licencia en modo conectado (`softwareCentral.enable: true`).
- **Content Assistant (fase 08)**: `OS_ADMIN_PASSWORD` y `GENAI_SERVICE_USER_PASSWORD` se guardan en `.state/ccx-content-secrets.env` (600); las llaves privadas
  de OpenSearch (`.state/os-certs/ca.key`, `tls.key`) están en `.state` (borra `ca.key` al terminar). `silent_install_deployoperator.toml` y `silent_install_prerequisites.toml`
  del repo de IBM se restauran al terminar; `propertyFile/<ns>/cas_*.toml` y `generatedFiles/<ns>/` conservan contraseñas y la API key del tenant (600) → bórralos.
- `ibmca login -p` expone la contraseña de `genai-service-user` en `ps` mientras corre (limitación de la CLI); el host es de laboratorio.
- Content Assistant se conecta a OpenSearch como `admin` (como en la referencia). Lo recomendable es `genai-service-user` (permisos sólo sobre `ibm-genai-*`): cámbialo en `cas_vector_database.toml` y regenera.
- OpenSearch queda con los **usuarios de demostración** del índice de seguridad (p. ej. `kibanaserver`) con contraseñas por defecto; el servicio es `ClusterIP` (sin Route). No apto para producción.
