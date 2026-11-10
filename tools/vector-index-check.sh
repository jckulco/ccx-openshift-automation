#!/usr/bin/env bash
# Comprueba la indexación vectorial: nº de fragmentos (chunks) por índice y últimas líneas del conector.
#   tools/vector-index-check.sh        (usa .state/config.env; no imprime contraseñas)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"; load_all_env; find_oc || die "No encuentro oc"
# shellcheck source=os-api.sh
source "$ROOT/tools/os-api.sh"
echo "== índices ibm-genai-* (docs.count = fragmentos indexados)"
"$OC" -n "$NS" exec opensearch-cluster-master-0 -c opensearch -- sh -c \
  'curl -sk --cacert /usr/share/opensearch/config/certs/ca.crt -u "admin:$OPENSEARCH_INITIAL_ADMIN_PASSWORD" "https://opensearch-cluster-master.'"$NS"'.svc:9200/_cat/indices/ibm-genai-*?v&h=index,docs.count,store.size"'
echo "== conector (últimas operaciones de indexado; el log está en UTC)"
"$OC" -n "$NS" logs deploy/ibm-content-assistant-deployment --since="${1:-60m}" 2>/dev/null \
  | grep -E 'PUT /index/docs|split into|Successfully indexed|DELETE' | cut -c1-200 | tail -15 || true
