#!/usr/bin/env bash
# Run on the Droplet after you have created it and logged in.
# Automates docs/digitalocean-droplet.md steps 3–10 and 12.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
if [[ -f "${REPO_ROOT}/compose.yaml" ]]; then
  APP_DIR="${APP_DIR:-$REPO_ROOT}"
else
  APP_DIR="${APP_DIR:-/opt/agentgateway}"
fi
REPO_URL="${REPO_URL:-https://github.com/msehsah1/agentgateway.git}"
DROPLET_USER="${DROPLET_USER:-ubuntu}"

log() { printf '\n==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Run this on the Droplet you already created and are logged into.

  sudo ./scripts/replicate-digitalocean-droplet.sh

It installs Docker Engine 29.x and Compose v2, prepares ${APP_DIR},
starts the stack, and verifies health. It does not create a Droplet
and does not SSH to another host.

Optional:
  WITH_SCRAPE=1 sudo ./scripts/replicate-digitalocean-droplet.sh
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  log "Re-running with sudo (needed for packages, Docker, and UFW)"
  exec sudo --preserve-env=WITH_SCRAPE,REPO_URL,APP_DIR,DROPLET_USER env \
    "$0" "$@"
fi

[[ -f /etc/os-release ]] || die "/etc/os-release missing"
# shellcheck disable=SC1091
. /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "expected Ubuntu, found ${ID:-unknown}"
[[ "${VERSION_ID:-}" == "24.04" ]] || die "expected Ubuntu 24.04 LTS, found ${PRETTY_NAME:-unknown}"
[[ "$(dpkg --print-architecture)" == "amd64" ]] || die "expected amd64, found $(dpkg --print-architecture)"

export DEBIAN_FRONTEND=noninteractive

log "Step 3 — update Ubuntu and install base packages"
apt-get update
apt-get install -y ca-certificates curl git ufw python3

log "Step 4 — ensure ${DROPLET_USER} exists (uid 1000)"
if ! id "$DROPLET_USER" >/dev/null 2>&1; then
  adduser --disabled-password --gecos "" "$DROPLET_USER"
fi
usermod -aG sudo "$DROPLET_USER"
install -d -m 700 -o "$DROPLET_USER" -g "$DROPLET_USER" "/home/${DROPLET_USER}/.ssh"
if [[ -f /root/.ssh/authorized_keys && ! -f "/home/${DROPLET_USER}/.ssh/authorized_keys" ]]; then
  cp /root/.ssh/authorized_keys "/home/${DROPLET_USER}/.ssh/authorized_keys"
  chown "${DROPLET_USER}:${DROPLET_USER}" "/home/${DROPLET_USER}/.ssh/authorized_keys"
  chmod 600 "/home/${DROPLET_USER}/.ssh/authorized_keys"
fi
uid="$(id -u "$DROPLET_USER")"
gid="$(id -g "$DROPLET_USER")"
[[ "$uid" == "1000" && "$gid" == "1000" ]] || die "${DROPLET_USER} is ${uid}:${gid}, expected 1000:1000"
id "$DROPLET_USER"

log "Step 5 — install Docker Engine 29.x and Compose v2"
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat >/etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${UBUNTU_CODENAME:-$VERSION_CODENAME}
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
usermod -aG docker "$DROPLET_USER"
docker version --format 'Client {{.Client.Version}}  Server {{.Server.Version}}'
docker compose version
docker info | grep -E 'Server Version|Storage Driver|Cgroup Driver|Cgroup Version|Operating System|Architecture|CPUs|Total Memory' || true
docker version --format '{{.Server.Version}}' | grep -q '^29\.' \
  || log "warning: Docker Engine is not 29.x; the verified host used 29.1.3"

log "Step 6 — host firewall (SSH only; 4000 and 3002 stay local)"
ufw allow OpenSSH
ufw --force enable
ufw status

log "Step 7 — repository at ${APP_DIR}"
if [[ -f "${APP_DIR}/compose.yaml" ]]; then
  log "using existing checkout ${APP_DIR}"
  if [[ -d "${APP_DIR}/.git" ]]; then
    git -C "$APP_DIR" rev-parse --abbrev-ref HEAD
  fi
else
  mkdir -p "$APP_DIR"
  if [[ -d "${APP_DIR}/.git" ]]; then
    git -C "$APP_DIR" pull --ff-only
  else
    if [[ -n "$(ls -A "$APP_DIR" 2>/dev/null || true)" ]]; then
      die "${APP_DIR} is not empty and has no compose.yaml"
    fi
    git clone "$REPO_URL" "$APP_DIR"
  fi
fi
chown -R "${DROPLET_USER}:${DROPLET_USER}" "$APP_DIR"
ls "${APP_DIR}/compose.yaml" "${APP_DIR}/agentgateway/config.yaml" "${APP_DIR}/.env.example" "${APP_DIR}/mcp/firecrawl-mcp/Dockerfile" "${APP_DIR}/observability/otel-collector-config.yaml"

log "Step 8 — create .env and data directory"
if [[ ! -f "${APP_DIR}/.env" ]]; then
  cp "${APP_DIR}/.env.example" "${APP_DIR}/.env"
fi
python3 - <<PY
from pathlib import Path
p = Path("${APP_DIR}/.env")
old = "replace-with-at-least-32-random-characters"
text = p.read_text()
if old in text:
    import secrets
    p.write_text(text.replace(old, secrets.token_urlsafe(32)))
    print("POSTGRES_PASSWORD set")
else:
    print("POSTGRES_PASSWORD already set")
PY
chown "${DROPLET_USER}:${DROPLET_USER}" "${APP_DIR}/.env"
chmod 600 "${APP_DIR}/.env"
mkdir -p "${APP_DIR}/agentgateway/data"
chown 1000:1000 "${APP_DIR}/agentgateway/data"

log "Step 9 — start the stack"
cd "$APP_DIR"
docker compose up -d --build
healthy_svcs=(
  firecrawl-api firecrawl-mcp firecrawl-playwright
  firecrawl-postgres firecrawl-rabbitmq firecrawl-redis playwright-mcp
)
for _ in $(seq 1 90); do
  all_ok=1
  for svc in "${healthy_svcs[@]}"; do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$svc" 2>/dev/null || echo missing)"
    if [[ "$status" != "healthy" ]]; then
      all_ok=0
      break
    fi
  done
  if [[ "$all_ok" -eq 1 ]]; then
    break
  fi
  sleep 5
done
docker compose ps
for svc in "${healthy_svcs[@]}"; do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$svc")"
  [[ "$status" == "healthy" ]] || {
    docker compose logs --tail=80 firecrawl-api || true
    die "${svc} is ${status}, expected healthy"
  }
done
docker inspect -f '{{.State.Status}}' agentgateway | grep -qx running \
  || die "agentgateway is not running"

log "Step 10 — verify on this machine"
curl --fail --silent --show-error --max-time 5 \
  http://127.0.0.1:3002/v0/health/readiness
echo
headers="$(mktemp)"
curl -sS -D "$headers" --max-time 20 http://127.0.0.1:4000/mcp \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d '{
    "jsonrpc": "2.0",
    "id": 1,
    "method": "initialize",
    "params": {
      "protocolVersion": "2025-03-26",
      "capabilities": {},
      "clientInfo": { "name": "curl", "version": "0.0.1" }
    }
  }' >/dev/null
grep -qi '^mcp-session-id:' "$headers" || {
  cat "$headers" >&2
  rm -f "$headers"
  die "initialize did not return mcp-session-id"
}
echo "mcp-session-id present"
rm -f "$headers"
if [[ "${WITH_SCRAPE:-0}" == "1" ]]; then
  curl --fail-with-body --silent --show-error --max-time 75 \
    -X POST http://127.0.0.1:3002/v2/scrape \
    -H 'Content-Type: application/json' \
    -d '{
      "url": "https://example.com",
      "formats": ["markdown"],
      "timeout": 60000
    }'
  echo
fi

log "Step 12 — confirm the host"
echo "${PRETTY_NAME} $(dpkg --print-architecture)"
nproc
free -h
docker version --format 'Engine {{.Server.Version}}'
docker compose version
git --version
docker compose images

cat <<EOF

Setup is finished on this Droplet.

On this machine:  http://127.0.0.1:4000/ui
From your laptop (step 11), in a new terminal:

  ssh -N -L 4000:127.0.0.1:4000 -L 3002:127.0.0.1:3002 ${DROPLET_USER}@THIS_DROPLET_IP

Then open http://localhost:4000/ui → MCP → Tool Playground → Initialize.
EOF
