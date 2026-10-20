# Prerrequisitos

## Cluster
- Red Hat OpenShift **4.12+**, amd64, `cluster-admin`. Referencia: 4.21.24, 3 masters + 5 workers (~31 vCPU / 120 GiB c/u; el uso real fue bajo, sin medir; ver "Dimensionamiento observado" en VERIFICATION-STATUS).
- Almacenamiento: una clase **RWX** (CephFS: `ocs-storagecluster-cephfs`) y una **RWO** de bloque (`ocs-storagecluster-ceph-rbd`).
- Salida a Internet hacia `cp.icr.io`, `icr.io`, `quay.io`, `docker.io`, `github.com`, `get.helm.sh`, `pypi.org`, `iam.cloud.ibm.com` y la región de watsonx.ai.

## Bastión
RHEL 9 con `oc` (el instalador acepta `OC=/ruta/a/oc`) y `dnf`. La fase 01 instala: Python 3.12, git, Java 21 (`java-21-openjdk-headless`),
unzip, openssl, curl, podman y **Helm ≥ 4** (referencia 4.1.1). Los scripts de IBM se ejecutan desde `scripts/`
(el `version.toml` se busca en el directorio *padre* del cwd; las fases ya lo hacen así).

## Cuentas y derechos
1. **IBM Entitlement Key** con derecho sobre Content Cortex (se valida con `helm registry login cp.icr.io`).
2. **watsonx.ai en IBM Cloud con plan de pago** (en la sesión de referencia hizo falta un plan de pago, Standard/Essentials, para poder usar la inferencia).
3. **Deployment space** de watsonx.ai y una **API key** de IBM Cloud. **El Service ID/usuario dueño de la API key debe ser colaborador del
   space** (rol Editor/Admin); si no, el agente responde `500 SYS_INTERNAL_ERROR` y el log muestra `403 SPACES0008E`.
   Comprueba antes con `python3 tools/test-wxai-key.py`.
4. Acceso a **Passport Advantage** para el paquete de AI Services (ver MANUAL-STEPS).

## Reserva en TechZone (si aplica)
Pide un entorno **Red Hat OpenShift** con ODF, amd64, y la fecha de expiración más larga posible. El token de `oc login` es una
credencial: no lo pegues en chats ni en tickets.
