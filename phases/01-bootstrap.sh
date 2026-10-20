#!/usr/bin/env bash
# Fase 01: herramientas del bastión (RHEL 9), repo de IBM (rama 26.0.1 == tag v26.1.0), venv de Python y repo de charts.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=../lib/common.sh
source "$ROOT/lib/common.sh"
load_all_env
find_oc || die "No encuentro 'oc'."

title "Fase 01 - Bootstrap del bastión"
HELM_VERSION="${HELM_VERSION:-v4.1.1}"          # versión usada en la sesión de referencia (se requiere Helm 4+)
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# --- paquetes del sistema ---------------------------------------------------------------------------------
missing=()
command -v python3.12 >/dev/null 2>&1 || missing+=(python3.12 python3.12-pip)
command -v git        >/dev/null 2>&1 || missing+=(git)
command -v java       >/dev/null 2>&1 || missing+=(java-21-openjdk-headless)
command -v keytool    >/dev/null 2>&1 || missing+=(java-21-openjdk-headless)
command -v unzip      >/dev/null 2>&1 || missing+=(unzip)
command -v openssl    >/dev/null 2>&1 || missing+=(openssl)
command -v curl       >/dev/null 2>&1 || missing+=(curl)
command -v podman     >/dev/null 2>&1 || missing+=(podman)
if [ "${#missing[@]}" -gt 0 ]; then
  mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
  log "Instalando paquetes: ${missing[*]}"
  if command -v dnf >/dev/null 2>&1; then $SUDO dnf install -y "${missing[@]}"
  else die "No hay dnf. Instala manualmente: ${missing[*]}"; fi
fi
ok "python3.12 / git / java / unzip / openssl / curl / podman presentes"

# --- Helm 4 ------------------------------------------------------------------------------------------------
helm_major() { helm version --template '{{.Version}}' 2>/dev/null | sed -E 's/^v([0-9]+).*/\1/'; }
if ! command -v helm >/dev/null 2>&1 || [ "$(helm_major || echo 0)" -lt 4 ]; then
  log "Instalando Helm $HELM_VERSION"
  T="$(mktemp -d)"
  curl -fsSL -o "$T/helm.tgz" "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz"
  tar -xzf "$T/helm.tgz" -C "$T"
  $SUDO install -m 0755 "$T/linux-amd64/helm" /usr/local/bin/helm
  rm -rf "$T"
  hash -r
fi
command -v helm >/dev/null 2>&1 || die "Helm no quedó en el PATH (PATH=$PATH). Revisa /usr/local/bin/helm."
HV="$(helm version --template '{{.Version}}' 2>&1)" || die "helm no funciona: $HV"
[ "$(helm_major || echo 0)" -ge 4 ] || die "Se requiere Helm 4+, encontré: $HV"
ok "helm $HV"

# oc en el PATH (algunos bastiones lo traen como /opt/oc.rhel9): los scripts de IBM y el usuario lo agradecen
if ! command -v oc >/dev/null 2>&1; then
  $SUDO ln -sf "$OC" /usr/local/bin/oc && ok "Enlace /usr/local/bin/oc -> $OC" || warn "No pude crear /usr/local/bin/oc (no es crítico)"
fi

# --- repo de IBM -----------------------------------------------------------------------------------------
if [ ! -d "$IBM_DIR/.git" ]; then
  log "Clonando $IBM_REPO_URL (rama $IBM_REPO_REF)"
  git clone --depth 1 --branch "$IBM_REPO_REF" "$IBM_REPO_URL" "$IBM_DIR"
fi
[ -f "$IBM_DIR/version.toml" ] || die "Falta version.toml en $IBM_DIR (clon incompleto)."
grep -q 'APP_VERSION = "26.0.1"' "$IBM_DIR/version.toml" || warn "version.toml no indica APP_VERSION 26.0.1; revisa IBM_REPO_REF."
ok "Repo de IBM: $(grep -m1 RELEASE "$IBM_DIR/version.toml" | tr -d '"')"

# --- venv ------------------------------------------------------------------------------------------------------
if [ ! -f "$VENV_DIR/bin/activate" ]; then
  python3.12 -m venv "$VENV_DIR"
fi
# shellcheck disable=SC1091
. "$VENV_DIR/bin/activate"
pip install -q --upgrade pip
pip install -q -r "$IBM_SCRIPTS/requirements.txt" pyyaml
# model-gateway.py de IBM llama a 'kubectl'; en OpenShift usamos 'oc' mediante un envoltorio dentro del venv.
cat > "$VENV_DIR/bin/kubectl" <<KUBECTL
#!/usr/bin/env bash
exec "$OC" "\$@"
KUBECTL
chmod +x "$VENV_DIR/bin/kubectl"
ok "Entorno virtual listo ($VENV_DIR) con envoltorio kubectl -> oc"

# --- repo de charts (para License Service) ---------------------------------------------------------------------
helm repo add ibm-content-cortex https://ibm-ecm.github.io/ibm-content-cortex-containers/charts --force-update >/dev/null
helm repo update >/dev/null
ok "Repo Helm 'ibm-content-cortex' añadido"
mark_done 01-bootstrap
