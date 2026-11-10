# Pasos manuales (no automatizables) y verificación final

## 1. Paquete de AI Services (Passport Advantage)
1. Entra a Passport Advantage con tu IBMid → *Software download* → número de parte **M17SQML**, *IBM Content Cortex AI Services and Tools V26.0.1* → `ICCXAIST_26.0.1_ML.zip`.
2. Acepta el *eAssembly license* (decisión tuya). La página te da una URL con *ticket*; descárgala directamente al bastión con `wget` (el ticket caduca).
3. `CCX_AI_PACKAGE=/ruta/ICCXAIST_26.0.1_ML.zip ./install.sh --only 07`

La fase 07 hace lo que describe la documentación de IBM: rellena `ECMPopulation.properties`, crea un truststore con la CA interna de CPE
(sin él: `PKIX path building failed`), ejecuta `./ccx_ai_metadata.sh create CE_metadata.xml` y `insert MessageLoader.xml` **desde la carpeta
`ccx-ai-services-metadata/`**, y copia `genaiAgentPlugin.jar` a `/opt/ibm/plugins` en el pod de Navigator.

Limpieza posterior (opcional): `./ccx_ai_metadata.sh clean_data` (hilos/mensajes de prueba) o `clean_all` (¡borra las clases!).
`ECMPopulation.properties` queda con la contraseña de `ccxadmin` en texto plano → bórralo o déjalo `chmod 600` y fuera de Git.

## 2. Navigator — registrar el plug-in
Entra a `https://navigator-<ns>.<apps>/navigator/` como `ccxadmin` y abre el *admin desktop* (`?desktop=admin`).
1. **Settings → General → Upload File Path on Server** = `/opt/ibm/plugins` → *Save and Close*.
2. **Plug-ins → New Plug-in** → *JAR file path* = `/opt/ibm/plugins/genaiAgentPlugin.jar` → *Load* (si aparece el botón) → debe mostrarse el plug-in **IBM Content Cortex AI Agents**.
   **Server URL** = `https://reasoning-service-<ns>.<apps>` (**sin** `/rsn`). *Save*.
   (Si el campo no se guarda, vuelve a abrirlo y repite; en la referencia se verificó en la tabla de ICN.)
3. **Desktops → desktop1 (o el tuyo) → Layout** → habilita **Ask AI agents**; repositorio por defecto `osrepo`. *Save*.

## 3. ACCE — texto persistente (Persistent Text Extract)
`https://cpe-<ns>.<apps>/acce/` (si sale en blanco, usa una ventana privada: caché/sesión).
1. Domain *P8DOMAIN* → **Actions → Install Add-on Features** → **5.6.0 Persistent Text Extract Extensions**. Verifica que quedó instalado
   (en la referencia el primer intento no se aplicó; repite si no aparece).
2. Object store *os* → Document Class → **Persistent Text Extracts enabled** = ✔. Sólo afecta a documentos **nuevos**.

## 4. IBM Cloud
Service ID de la API key como colaborador del deployment space. Prueba: `python3 tools/test-wxai-key.py`.

## 5. Paquete de Content Assistant (ICACMS 1.0.4) — sólo para la CLI `ibmca`
La fase 08 despliega TODO sin descargas (el repo de IBM es público en GitHub y el plug-in `genaiPlugin.jar` ya viene en la imagen de Navigator).
Lo único que requiere descarga manual es la CLI `ibmca` (wheel `ibmca-1.0.4-py3-none-any.whl` dentro de `ICACMS_1.0.4_ML.zip`, Passport Advantage,
licencia de IBM con tu IBMid): `CCX_ICA_PACKAGE=/ruta/ICACMS_1.0.4_ML.zip ./install.sh --only 08` (o `CCX_IBMCA_WHL=/ruta/el.whl`).
Sin ella la fase termina con código 10 (todo lo demás ya queda hecho). **No importes los archivos CE del zip** (CPE ≥ 5.7.0 ya los trae).
La licencia de Content Assistant (https://ibm.biz/CAS_License_1_0_0) se acepta aparte: `CCX_ACCEPT_CAS_LICENSE=yes` o el prompt de la fase 08.

## 6. ACCE — add-on y activación de Content Assistant (object store `os`)
1. Object store `os` → **Actions → Install Add-on Features** → **26.0.0 Gen AI Extensions** → OK. (Instala también las *event actions*
   "Gen AI Summary Request" y "Gen AI Vector Indexing Request"). Cierra y reabre la pestaña de `os` o pulsa *Refresh*.
2. `os` → **Administrative → Content Assistant → GenAI Configuration** (se crea un objeto con *Index Status: Inactive*) → ábrelo → **Activate**:
   - *Access code*: cualquier valor no vacío (instalación local).
   - *Service URL*: la ruta `cas` (la fase 08 la imprime; **cambia el valor por defecto** `https://filenetai.saas.ibm.com/prod`).
   - *Embedding model*: en blanco → usa `intfloat/multilingual-e5-large`. **Queda fijo al activar** (`ibmca update domains` no lo cambia): decide antes.
   - Sin proxy. Al terminar, `ibmca list domains` debe mostrar `os`.
3. Clase `Document`: *CBR enabled* y *Persistent Text Extracts enabled* (ya hechos en §3).

## 7. ACCE — suscripción de indexación vectorial (sin ella NO se indexa nada)
Según el documento de IBM *Creating a document class subscription for vector indexing*:
`os` → Data Design → Classes → **Document** → pestaña **Actions** → **New subscription**:
- Name `Document-Vector Index`; *Applies to all objects of this class* (incluye subclases).
- *Subscribed events*: **Checkin Event** y **Update Event**.
- *Event action*: **Gen AI Vector Indexing Request Event Action**; habilitada; *Run synchronously*.
Comportamiento observado: sólo indexa documentos **nuevos** o con **check-out/check-in** (un cambio de título no dispara). Puede llegar en lote
unos minutos después. Los documentos anteriores necesitan un check-in o el *custom sweep job* de IBM (procedimiento **no verificado** aquí).
Comprobar: `tools/vector-index-check.sh` (líneas `PUT /index/docs`, `Docs split into N chunks`, y `docs.count` > 0).
La suscripción de borrado ("Gen AI Vector Delete Document Subscription") ya la crea el add-on.

## 7b. Navigator — plug-in de Content Assistant
Admin desktop → **Plug-ins → New Plug-in** → *JAR file path* = `/opt/ibm/intPlugins/genai/genaiPlugin.jar` → **Load** (detecta "IBM Content Assistant",
función *Ask Your Repository*) → los campos opcionales se dejan → **Save and Close** → habilítalo. Después **Desktops → tu desktop → Edit → Features →
Ask Your Repository** → guardar, cerrar sesión y volver a entrar.

## 8. Verificación funcional (la que se hizo en la referencia)
1. Login en Navigator con `ccxadmin` (redirige a Keycloak → LDAP).
2. Subir un PDF pequeño al repositorio `osrepo`; esperar unos segundos y buscar por contenido.
3. Abrir *Ask AI agents*, elegir el agente y pedir "lista las carpetas", "crea una carpeta AgentTest" y "resume el documento X".
Si el agente responde 500, ver TROUBLESHOOTING #6.
4. Content Assistant: sube un documento **nuevo**, espera 1-5 min, `tools/vector-index-check.sh` (debe haber fragmentos) y pregunta en *Ask Your Repository*.
   Usa *New chat* entre documentos distintos (el agente arrastra el primer resultado como contexto).

## 9. Al terminar (higiene)
- Rota la API key de watsonx.ai y la entitlement key si se expusieron; borra `.work/ibm-content-assistant/scripts/propertyFile/<ns>/cas_*.toml`, `generatedFiles/`, `.state/os-certs/ca.key|tls.key`; el token de `oc login` caduca solo.
- `chmod 600` / borrado de `.state/`, `scripts/.mgw/state.json`, copias `*.orig` de property files (contienen contraseñas).
- Las reservas de TechZone caducan: exporta lo que necesites.
