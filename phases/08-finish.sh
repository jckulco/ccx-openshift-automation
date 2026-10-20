#!/usr/bin/env bash
# Fase 08: resumen, URLs, comprobaciones de salud y lista de pasos MANUALES pendientes.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."

title "Fase 08 - Resumen"
OUT="$STATE_DIR/ENDPOINTS.md"
{
  echo "# Content Cortex 26.0.1 - endpoints ($(date -u +%FT%TZ))"
  echo
  echo "| Componente | URL | HTTP |"
  echo "|---|---|---|"
  for r in $(oc_ get routes -n "$NS" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}'); do
    h="$(route_host "$NS" "$r")"
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$h/" || echo ---)"
    echo "| $r | https://$h | $code |"
  done
  kc="$(route_host "$AUTH_NS" keycloak)"
  echo "| keycloak | https://$kc | $(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$kc/" || echo ---) |"
  echo
  echo "Usuarios de prueba (LDAP): ccxadmin (administrador), alice, bob. Contraseñas: ./install.sh credentials"
  echo "ACCE: https://$(route_host "$NS" cpe 2>/dev/null || echo "cpe-$NS.$APPS_DOMAIN")/acce   (usa una ventana privada si sale en blanco)"
  echo "Navigator: https://$(route_host "$NS" navigator 2>/dev/null || echo "navigator-$NS.$APPS_DOMAIN")/navigator"
} > "$OUT"
cat "$OUT"

NAV_EXPECTED="navigator-$NS.$APPS_DOMAIN"
NAV_REAL="$(route_host "$NS" navigator 2>/dev/null || true)"
if [ -n "$NAV_REAL" ] && [ "$NAV_REAL" != "$NAV_EXPECTED" ]; then
  warn "La ruta real de Navigator ($NAV_REAL) no coincide con NAVIGATOR_EXTERNAL_URL usado ($NAV_EXPECTED)."
  warn "Corrige aiservices_integration.toml, regenera y reaplica el ConfigMap (docs/TROUBLESHOOTING.md #9)."
fi

echo
echo "${C_B}Pasos MANUALES que quedan (docs/MANUAL-STEPS.md):${C_0}"
phase_done 07-ai-package || echo "  1. Descargar el paquete de AI Services y ejecutar:  CCX_AI_PACKAGE=/ruta.zip ./install.sh --only 07"
cat <<'TXT'
  2. ACCE: instalar el add-on "5.6.0 Persistent Text Extract Extensions" y marcar "Persistent Text Extracts enabled"
     en la clase Document del object store 'os' (sólo afecta a documentos NUEVOS).
  3. Navigator (admin desktop): Settings > General > Upload File Path = /opt/ibm/plugins; Plug-ins > New Plug-in con
     la ruta /opt/ibm/plugins/genaiAgentPlugin.jar; Server URL = https://reasoning-service-<ns>.<dominio-apps> (SIN /rsn).
  4. Navigator desktop: Layout > "Ask AI agents"; repositorio por defecto 'osrepo'.
  5. IBM Cloud: el Service ID de la API key debe ser colaborador del deployment space (si no: 403 SPACES0008E).
TXT
mark_done 08-finish
