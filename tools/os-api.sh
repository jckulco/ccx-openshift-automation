#!/usr/bin/env bash
# Llama a la API de OpenSearch DESDE DENTRO del pod (el bastión no resuelve *.svc ni confía en la CA propia).
# La contraseña de admin la lee el propio pod de su variable de entorno: no aparece en pantalla ni en el historial.
#   source tools/os-api.sh ; os_api METODO ruta [cuerpo_json_por_stdin]
#   os_api GET _cluster/health
#   echo '{...}' | os_api PUT _plugins/_security/api/roles/x
# Requiere: OC (ruta de oc), NS.
os_api() {
  local method="$1" path="$2"
  "$OC" -n "$NS" exec -i opensearch-cluster-master-0 -c opensearch -- sh -c \
    'curl -s --cacert /usr/share/opensearch/config/certs/ca.crt -u "admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD" -H "Content-Type: application/json" -X '"$method"' "https://opensearch-cluster-master.'"$NS"'.svc:9200/'"$path"'" -d @-' 2>/dev/null
}
