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

## 5. Verificación funcional (la que se hizo en la referencia)
1. Login en Navigator con `ccxadmin` (redirige a Keycloak → LDAP).
2. Subir un PDF pequeño al repositorio `osrepo`; esperar unos segundos y buscar por contenido.
3. Abrir *Ask AI agents*, elegir el agente y pedir "lista las carpetas", "crea una carpeta AgentTest" y "resume el documento X".
Si el agente responde 500, ver TROUBLESHOOTING #6.

## 6. Al terminar (higiene)
- Rota la API key de watsonx.ai y la entitlement key si se expusieron; el token de `oc login` caduca solo.
- `chmod 600` / borrado de `.state/`, `scripts/.mgw/state.json`, copias `*.orig` de property files (contienen contraseñas).
- Las reservas de TechZone caducan: exporta lo que necesites.
