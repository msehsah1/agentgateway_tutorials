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
starts the stack, seeds Postgres, and verifies health. It does not
create a Droplet and does not SSH to another host.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" || "${1:-}" == "help" ]]; then
  usage
  exit 0
fi

if [[ "$(id -u)" -ne 0 ]]; then
  log "Re-running with sudo (needed for packages, Docker, and UFW)"
  exec sudo --preserve-env=REPO_URL,APP_DIR,DROPLET_USER env \
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

log "Step 6 — host firewall (SSH only; 4000 and 5432 stay local)"
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
ls "${APP_DIR}/compose.yaml" "${APP_DIR}/agentgateway/config.yaml" "${APP_DIR}/.env.example" \
  "${APP_DIR}/mcp/postgres-mcp/Dockerfile" "${APP_DIR}/postgres/init/01-schema.sql" \
  "${APP_DIR}/postgres/init/02-seed.sql" "${APP_DIR}/postgres/provision-demo-db.sh" \
  "${APP_DIR}/observability/otel-collector-config.yaml" "${APP_DIR}/keycloak/provision-mcp-realm.sh"

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

wait_healthy() {
  local timeout_s="$1"
  shift
  local deadline=$((SECONDS + timeout_s))
  local svc status
  while (( SECONDS < deadline )); do
    local all_ok=1
    for svc in "$@"; do
      status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$svc" 2>/dev/null || echo missing)"
      if [[ "$status" != "healthy" ]]; then
        all_ok=0
        break
      fi
    done
    if [[ "$all_ok" -eq 1 ]]; then
      return 0
    fi
    sleep 5
  done
  return 1
}

log "Step 9 — start Postgres, seed tables, then the rest of the stack"
cd "$APP_DIR"
docker compose build

log "starting Postgres"
docker compose up -d postgres
wait_healthy 120 postgres || {
  docker compose ps --all
  docker compose logs --tail=80 postgres || true
  die "postgres never became healthy"
}

log "applying demo schema and seed data"
docker compose up -d postgres-provision
provision_deadline=$((SECONDS + 120))
while (( SECONDS < provision_deadline )); do
  provision_status="$(docker inspect -f '{{.State.Status}}' postgres-provision 2>/dev/null || echo missing)"
  if [[ "${provision_status}" == "exited" ]]; then
    break
  fi
  sleep 2
done
provision_db_rc="$(docker inspect -f '{{.State.ExitCode}}' postgres-provision 2>/dev/null || echo missing)"
[[ "${provision_db_rc}" == "0" ]] || {
  docker compose logs --tail=80 postgres-provision postgres || true
  die "postgres-provision exit ${provision_db_rc}, expected 0"
}

log "starting remaining services"
if ! docker compose up -d; then
  docker compose ps --all
  docker compose logs --tail=80 postgres postgres-mcp keycloak agentgateway || true
  die "docker compose up failed after Postgres was seeded. See service logs above."
fi

healthy_svcs=(postgres postgres-mcp keycloak)
wait_healthy 300 "${healthy_svcs[@]}" || true
docker compose ps
for svc in "${healthy_svcs[@]}"; do
  status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$svc")"
  [[ "$status" == "healthy" ]] || {
    docker compose logs --tail=80 "$svc" || true
    die "${svc} is ${status}, expected healthy"
  }
done
docker inspect -f '{{.State.Status}}' agentgateway | grep -qx running \
  || die "agentgateway is not running"

# Compose interpolates .env; source it so the psql checks use the same user/db.
set -a
# shellcheck disable=SC1091
. "${APP_DIR}/.env"
set +a

log "Step 10 — verify on this machine"
log "demo tables and row counts"
docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-store}" -c '\dt'
docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-store}" -c "
SELECT 'categories' AS table, count(*) FROM categories
UNION ALL SELECT 'products', count(*) FROM products
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'reviews', count(*) FROM reviews
ORDER BY 1;
"
table_count="$(docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-store}" -Atc \
  "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'")"
[[ "${table_count}" == "5" ]] || die "expected 5 public tables, got ${table_count}"
product_count="$(docker compose exec -T postgres psql -U "${POSTGRES_USER:-postgres}" -d "${POSTGRES_DB:-store}" -Atc \
  "SELECT count(*) FROM products")"
[[ "${product_count}" == "8" ]] || die "expected 8 products, got ${product_count}"
echo "demo store has 5 tables and 8 products"

log "waiting for keycloak-provision"
kc_deadline=$((SECONDS + 180))
while (( SECONDS < kc_deadline )); do
  kc_status="$(docker inspect -f '{{.State.Status}}' keycloak-provision 2>/dev/null || echo missing)"
  if [[ "${kc_status}" == "exited" ]]; then
    break
  fi
  sleep 2
done
provision_rc="$(docker inspect -f '{{.State.ExitCode}}' keycloak-provision 2>/dev/null || echo missing)"
[[ "${provision_rc}" == "0" ]] || {
  docker compose logs --tail=80 keycloak-provision keycloak || true
  die "keycloak-provision exit ${provision_rc}, expected 0"
}

init_body='{
  "jsonrpc": "2.0",
  "id": 1,
  "method": "initialize",
  "params": {
    "protocolVersion": "2025-03-26",
    "capabilities": {},
    "clientInfo": { "name": "curl", "version": "0.0.1" }
  }
}'

unauth_initialize() {
  local path="$1"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
    -X POST "http://127.0.0.1:4000${path}" \
    -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' \
    -d "${init_body}")"
  [[ "${code}" == "401" ]] || die "expected 401 from ${path} without a token, got ${code}"
  echo "unauthenticated initialize ${path} returned 401"
}

unauth_initialize /mcp
unauth_initialize /postgres/mcp

token_json="$(curl -sS --max-time 20 -X POST \
  http://127.0.0.1:8080/realms/mcp/protocol/openid-connect/token \
  -d grant_type=password -d client_id=agentgateway \
  -d username=mcpuser -d password=mcppassword -d scope=openid)"
TOKEN="$(python3 -c 'import json,sys; print(json.load(sys.stdin)["access_token"])' <<<"${token_json}")"
[[ -n "${TOKEN}" && "${TOKEN}" != "None" ]] || {
  printf '%s\n' "${token_json}" >&2
  die "password grant did not return an access_token"
}

headers="$(mktemp)"
curl -sS -D "$headers" --max-time 20 http://127.0.0.1:4000/mcp \
  -H "Authorization: Bearer ${TOKEN}" \
  -H 'Content-Type: application/json' \
  -H 'Accept: application/json, text/event-stream' \
  -d "${init_body}" >/dev/null
grep -qi '^mcp-session-id:' "$headers" || {
  cat "$headers" >&2
  rm -f "$headers"
  die "authenticated initialize on /mcp did not return mcp-session-id"
}
echo "authenticated /mcp initialize returned mcp-session-id"
rm -f "$headers"

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

  ssh -N -L 4000:127.0.0.1:4000 -L 8080:127.0.0.1:8080 -L 5432:127.0.0.1:5432 ${DROPLET_USER}@THIS_DROPLET_IP

Copilot / VS Code use http://localhost:4000/mcp and must sign in at
http://localhost:8080 as mcpuser / mcppassword. Unauthenticated Initialize
on /mcp is 401. The UI playground talks to the same URL and cannot log in.
EOF
