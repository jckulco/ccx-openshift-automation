#!/usr/bin/env bash
# Genera la CA y el certificado HTTP/transporte de OpenSearch para Content Assistant (idempotente).
#   tools/gen-opensearch-certs.sh <dir_salida> <namespace> [nombre_servicio]
# Lección de la sesión de referencia: el conector de Content Assistant (Python 3.13) verifica en MODO ESTRICTO:
#   - la CA debe declarar basicConstraints CA:TRUE + keyUsage keyCertSign (si no: "CA cert does not include key usage extension")
#   - el certificado de servidor necesita SAN con el nombre del Service, y SKI/AKI
#   - la llave del servidor debe ser PKCS#8 ("BEGIN PRIVATE KEY"), formato que exige OpenSearch
# La verificación final usa -x509_strict (mismo criterio que Python). Las llaves quedan en modo 600 (NO subir a Git).
set -euo pipefail
OUT="${1:?uso: gen-opensearch-certs.sh <dir_salida> <namespace> [servicio]}"; NS="${2:?namespace}"; SVC="${3:-opensearch-cluster-master}"
mkdir -p "$OUT"; cd "$OUT"; umask 077

if [ -f ca.crt ] && [ -f tls.crt ] && [ -f tls.key ] && openssl verify -x509_strict -CAfile ca.crt tls.crt >/dev/null 2>&1 \
   && openssl x509 -in tls.crt -noout -ext subjectAltName 2>/dev/null | grep -q "$SVC.$NS.svc"; then
  echo "Certificados de OpenSearch ya existentes y válidos en $OUT"; exit 0
fi

[ -f ca.key ] || openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out ca.key
openssl req -x509 -new -key ca.key -sha256 -days 1825 -subj "/CN=ccx-opensearch-ca/O=ccx-lab" \
  -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" \
  -addext "subjectKeyIdentifier=hash" -out ca.crt
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out tls.key          # PKCS#8
openssl req -new -key tls.key -subj "/CN=$SVC.$NS.svc/O=ccx-lab" -out tls.csr
cat > ext.cnf <<EXT
basicConstraints=critical,CA:FALSE
keyUsage=critical,digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth,clientAuth
subjectKeyIdentifier=hash
authorityKeyIdentifier=keyid,issuer
subjectAltName=DNS:$SVC,DNS:$SVC.$NS,DNS:$SVC.$NS.svc,DNS:$SVC.$NS.svc.cluster.local,DNS:$SVC-headless,DNS:$SVC-0.$SVC-headless,DNS:$SVC-0.$SVC-headless.$NS.svc,DNS:localhost,IP:127.0.0.1
EXT
openssl x509 -req -in tls.csr -CA ca.crt -CAkey ca.key -CAcreateserial -sha256 -days 825 -extfile ext.cnf -out tls.crt 2>/dev/null
openssl verify -x509_strict -CAfile ca.crt tls.crt
head -1 tls.key | grep -q 'BEGIN PRIVATE KEY' || { echo "ERROR: la llave no es PKCS#8" >&2; exit 1; }
rm -f tls.csr ext.cnf ca.srl
chmod 600 ca.key tls.key; chmod 644 ca.crt tls.crt
echo "Certificados generados en $OUT (SAN: $SVC.$NS.svc)"
