#!/usr/bin/env bash
# ============================================================
#  demo.sh — Démo live Envoy Solo
#  Usage : ./demo.sh
#  Prérequis : Envoy installé, Python 3 + Flask, curl, jq
# ============================================================

set -euo pipefail

# ---------- Configuration ----------
DEMO_DIR="${HOME}/envoy-solo-demo"
ENVOY_BIN="${ENVOY_BIN:-/usr/local/bin/envoy}"
ENVOY_CFG="${DEMO_DIR}/envoy.yaml"
ENVOY_LOG="${DEMO_DIR}/envoy.log"
FLASK1_PORT=5001
FLASK2_PORT=5002
ENVOY_PORT=8080
ADMIN_PORT=9901

# ---------- Couleurs ----------
if [[ -t 1 ]]; then
  RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'
  BLUE=$'\033[0;34m'; MAGENTA=$'\033[0;35m'; CYAN=$'\033[0;36m'
  BOLD=$'\033[1m'; RESET=$'\033[0m'
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; BOLD=""; RESET=""
fi

# ---------- Helpers ----------
banner() {
  echo
  echo "${BOLD}${BLUE}════════════════════════════════════════════════════════════${RESET}"
  echo "${BOLD}${BLUE}  $*${RESET}"
  echo "${BOLD}${BLUE}════════════════════════════════════════════════════════════${RESET}"
  echo
}

step() { echo; echo "${BOLD}${GREEN}▶ $*${RESET}"; echo; }
info() { echo "${CYAN}ℹ  $*${RESET}"; }
warn() { echo "${YELLOW}⚠  $*${RESET}"; }
err()  { echo "${RED}✖  $*${RESET}" >&2; }
pause(){ echo; read -rp "${MAGENTA}[Entrée pour continuer...]${RESET}" _ || true; }

cleanup() {
  banner "🧹 Nettoyage"
  pkill -f "envoy -c ${ENVOY_CFG}" 2>/dev/null || true
  pkill -f "python3 ${DEMO_DIR}/app1.py" 2>/dev/null || true
  pkill -f "python3 ${DEMO_DIR}/app2.py" 2>/dev/null || true
  pkill -f "python3 ${DEMO_DIR}/app1bis.py" 2>/dev/null || true
  rm -f /dev/shm/envoy_shared_memory_* 2>/dev/null || true
  info "Processus arrêtés."
}

trap 'echo; warn "Interruption détectée."; cleanup; exit 0' INT

# ---------- Vérifications préalables ----------
preflight() {
  banner "🔎 Vérification de l'environnement"

  if ! command -v "${ENVOY_BIN}" &>/dev/null; then
    err "Envoy introuvable (${ENVOY_BIN})"
    err "Installez-le ou définissez ENVOY_BIN=/chemin/vers/envoy"
    exit 1
  fi
  info "Envoy : $("${ENVOY_BIN}" --version | head -n1)"

  if ! command -v python3 &>/dev/null; then
    err "python3 introuvable"; exit 1
  fi
  info "Python : $(python3 --version)"

  if ! python3 -c "import flask" 2>/dev/null; then
    warn "Flask non installé. Tentative d'installation..."
    pip install --user flask || { err "Échec install Flask"; exit 1; }
  fi
  info "Flask : OK"

  command -v curl &>/dev/null || { err "curl requis"; exit 1; }
  command -v jq   &>/dev/null || warn "jq absent (certaines commandes admin l'utilisent)"

  mkdir -p "${DEMO_DIR}"
  info "Répertoire de travail : ${DEMO_DIR}"
}

# ---------- Génération des fichiers ----------
generate_apps() {
  step "📝 Génération des applications Flask"

  cat > "${DEMO_DIR}/app1.py" <<'PY'
from flask import Flask
app = Flask(__name__)

@app.route('/')
@app.route('/app1')
def hello():
    return "Hello from Application 1!\n"

@app.route('/healthz')
def health():
    return "ok", 200

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5001)
PY

  cat > "${DEMO_DIR}/app2.py" <<'PY'
from flask import Flask
app = Flask(__name__)

@app.route('/')
@app.route('/app2')
def hello():
    return "Hello from Application 2!\n"

@app.route('/healthz')
def health():
    return "ok", 200

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5002)
PY

  # App1 "bis" pour la démo de load balancing
  cat > "${DEMO_DIR}/app1bis.py" <<'PY'
from flask import Flask
app = Flask(__name__)

@app.route('/')
@app.route('/app1')
def hello():
    return "Hello from Application 1 BIS!\n"

@app.route('/healthz')
def health():
    return "ok", 200

if __name__ == '__main__':
    app.run(host='127.0.0.1', port=5003)
PY

  info "app1.py, app2.py, app1bis.py créés."
}

generate_envoy_config() {
  # $1 = mode : "base" ou "lb"
  local mode="${1:-base}"

  local cluster_app1_endpoints
  if [[ "${mode}" == "lb" ]]; then
    cluster_app1_endpoints='
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5001 }
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5003 }'
  else
    cluster_app1_endpoints='
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5001 }'
  fi

  cat > "${ENVOY_CFG}" <<EOF
admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: ${ADMIN_PORT} }

static_resources:
  listeners:
  - name: listener_0
    address:
      socket_address: { address: 0.0.0.0, port_value: ${ENVOY_PORT} }
    filter_chains:
    - filters:
      - name: envoy.filters.network.http_connection_manager
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.filters.network.http_connection_manager.v3.HttpConnectionManager
          stat_prefix: ingress_http
          access_log:
          - name: envoy.access_loggers.stdout
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.access_loggers.stream.v3.StdoutAccessLog
              log_format:
                text_format: "[%START_TIME%] %REQ(:METHOD)% %REQ(X-ENVOY-ORIGINAL-PATH?:PATH)% -> %RESPONSE_CODE% (%DURATION%ms) upstream=%UPSTREAM_HOST%\n"
          route_config:
            name: local_route
            virtual_hosts:
            - name: local_service
              domains: ["*"]
              routes:
              - match: { prefix: "/app1" }
                route: { cluster: app1_cluster }
              - match: { prefix: "/app2" }
                route: { cluster: app2_cluster }
              - match: { prefix: "/healthz" }
                route: { cluster: app1_cluster }
          http_filters:
          - name: envoy.filters.http.router
            typed_config:
              "@type": type.googleapis.com/envoy.extensions.filters.http.router.v3.Router

  clusters:
  - name: app1_cluster
    connect_timeout: 2s
    type: STRICT_DNS
    load_assignment:
      cluster_name: app1_cluster
      endpoints:
      - lb_endpoints:${cluster_app1_endpoints}

  - name: app2_cluster
    connect_timeout: 2s
    type: STRICT_DNS
    load_assignment:
      cluster_name: app2_cluster
      endpoints:
      - lb_endpoints:
        - endpoint:
            address:
              socket_address: { address: 127.0.0.1, port_value: 5002 }
EOF

  info "Config Envoy générée : ${ENVOY_CFG} (mode=${mode})"
}

# ---------- Démarrage ----------
start_apps() {
  step "🚀 Démarrage des applications Flask"
  python3 "${DEMO_DIR}/app1.py"    > "${DEMO_DIR}/app1.log"    2>&1 &
  python3 "${DEMO_DIR}/app2.py"    > "${DEMO_DIR}/app2.log"    2>&1 &
  sleep 1
  curl -sf "http://127.0.0.1:${FLASK1_PORT}/healthz" >/dev/null \
    && info "Flask 1 (port ${FLASK1_PORT}) : OK" \
    || { err "Flask 1 KO"; exit 1; }
  curl -sf "http://127.0.0.1:${FLASK2_PORT}/healthz" >/dev/null \
    && info "Flask 2 (port ${FLASK2_PORT}) : OK" \
    || { err "Flask 2 KO"; exit 1; }
}

start_app1bis() {
  step "🚀 Démarrage de Flask 1bis (pour le load balancing)"
  python3 "${DEMO_DIR}/app1bis.py" > "${DEMO_DIR}/app1bis.log" 2>&1 &
  sleep 1
  curl -sf "http://127.0.0.1:5003/healthz" >/dev/null \
    && info "Flask 1bis (port 5003) : OK" \
    || { err "Flask 1bis KO"; exit 1; }
}

start_envoy() {
  step "🚀 Démarrage d'Envoy"
  "${ENVOY_BIN}" -c "${ENVOY_CFG}" --base-id 1 > "${ENVOY_LOG}" 2>&1 &
  sleep 2
  curl -sf "http://127.0.0.1:${ADMIN_PORT}/ready" >/dev/null \
    && info "Envoy prêt (port ${ENVOY_PORT}, admin ${ADMIN_PORT})" \
    || { err "Envoy KO — voir ${ENVOY_LOG}"; tail -20 "${ENVOY_LOG}"; exit 1; }
}

reload_envoy() {
  info "Rechargement d'Envoy (hot restart via SIGUSR1)..."
  pkill -USR1 -f "envoy -c ${ENVOY_CFG}" 2>/dev/null || true
  sleep 1
  info "Rechargement effectué sans coupure."
}

# ---------- Scénarios ----------
demo_routing() {
  banner "🎬 DÉMO 1 — Routage de base"
  echo "On interroge Envoy sur :8080, qui route vers deux backends."
  echo
  echo "\$ curl http://localhost:${ENVOY_PORT}/app1"
  curl -s "http://localhost:${ENVOY_PORT}/app1"
  echo
  echo "\$ curl http://localhost:${ENVOY_PORT}/app2"
  curl -s "http://localhost:${ENVOY_PORT}/app2"
  echo
  info "Un seul point d'entrée, deux backends."
}

demo_admin() {
  banner "🎬 DÉMO 2 — L'interface d'administration"
  echo "L'admin Envoy expose tout ce qui se passe."
  echo

  echo "\$ curl -s http://localhost:${ADMIN_PORT}/clusters | head -20"
  curl -s "http://localhost:${ADMIN_PORT}/clusters" | head -20
  echo

  echo "\$ curl -s http://localhost:${ADMIN_PORT}/stats | grep downstream_rq_total"
  curl -s "http://localhost:${ADMIN_PORT}/stats" | grep "downstream_rq_total" || true
  echo

  info "Faites un curl et relancez la commande stats : les compteurs bougent."
}

demo_path_rewrite() {
  banner "🎬 DÉMO 3 — Réécriture de chemin"
  echo "Envoy transmet le chemin tel quel par défaut."
  echo "Nos Flask ont été codées pour répondre à / ET /app1."
  echo "Si on retirait la route /app1 côté Flask, il faudrait un prefix_rewrite."
  echo
  echo "Démonstration avec /app1 : Flask reçoit bien /app1 et répond."
  curl -s "http://localhost:${ENVOY_PORT}/app1"
  echo
  info "Voir le code Flask : app1.py"
}

demo_load_balancing() {
  banner "🎬 DÉMO 4 — Load Balancing"

  warn "Rechargement de la config avec un 2e backend pour app1..."
  start_app1bis
  generate_envoy_config "lb"
  reload_envoy

  echo "Maintenant app1_cluster a DEUX backends : :5001 et :5003."
  echo "Envoy alterne en round-robin."
  echo
  echo "\$ for i in {1..8}; do curl -s localhost:${ENVOY_PORT}/app1; done"
  for _ in {1..8}; do
    curl -s "http://localhost:${ENVOY_PORT}/app1"
  done
  echo
  info "Vous voyez 'Application 1' et 'Application 1 BIS' alterner."
}

demo_summary() {
  banner "📊 Récapitulatif"
  echo "État final :"
  echo "  - Envoy écoute sur :${ENVOY_PORT}"
  echo "  - Admin Envoy : http://127.0.0.1:${ADMIN_PORT}"
  echo "  - Flask 1 : :5001"
  echo "  - Flask 1bis : :5003"
  echo "  - Flask 2 : :5002"
  echo
  echo "Commandes utiles :"
  echo "  curl http://localhost:${ENVOY_PORT}/app1"
  echo "  curl http://localhost:${ADMIN_PORT}/clusters"
  echo "  curl http://localhost:${ADMIN_PORT}/config_dump | jq ."
  echo
  echo "Logs Envoy : ${ENVOY_LOG}"
}

# ---------- Orchestration ----------
main() {
  banner "🛡️  Envoy Solo — Démo Live"

  preflight
  pause
  generate_apps
  generate_envoy_config "base"
  pause
  start_apps
  start_envoy
  pause

  demo_routing
  pause
  demo_admin
  pause
  demo_path_rewrite
  pause
  demo_load_balancing
  pause

  demo_summary
  echo
  warn "Pour tout arrêter : appuyez sur Ctrl+C, ou lancez : pkill envoy"
  warn "Ou laissez tourner et explorez par vous-même."
}

main "$@"