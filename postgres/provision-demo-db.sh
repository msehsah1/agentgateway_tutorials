#!/usr/bin/env bash
# Load (or reload) the demo store schema and seed data.
# Used as the postgres-provision Compose service and can be run by hand:
#   docker compose exec -T postgres-provision /bin/bash /scripts/provision-demo-db.sh
# or, against a running postgres:
#   docker compose exec -T postgres psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" \
#     -f /docker-entrypoint-initdb.d/01-schema.sql
set -euo pipefail

PGHOST="${PGHOST:-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${POSTGRES_USER:-postgres}"
PGPASSWORD="${POSTGRES_PASSWORD:?POSTGRES_PASSWORD is required}"
PGDATABASE="${POSTGRES_DB:-store}"
export PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="${SCRIPT_DIR}/init/01-schema.sql"
SEED="${SCRIPT_DIR}/init/02-seed.sql"

log() { printf 'postgres-provision: %s\n' "$*"; }

log "waiting for ${PGHOST}:${PGPORT}/${PGDATABASE}"
ready=0
for _ in $(seq 1 60); do
  if psql -v ON_ERROR_STOP=1 -c 'SELECT 1' >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[[ "${ready}" == "1" ]] || {
  log "postgres never accepted connections"
  exit 1
}

log "applying ${SCHEMA}"
psql -v ON_ERROR_STOP=1 -f "${SCHEMA}"
log "applying ${SEED}"
psql -v ON_ERROR_STOP=1 -f "${SEED}"

log "tables:"
psql -v ON_ERROR_STOP=1 -c '\dt'
log "row counts:"
psql -v ON_ERROR_STOP=1 -c "
SELECT 'categories' AS table, count(*) FROM categories
UNION ALL SELECT 'products', count(*) FROM products
UNION ALL SELECT 'orders', count(*) FROM orders
UNION ALL SELECT 'order_items', count(*) FROM order_items
UNION ALL SELECT 'reviews', count(*) FROM reviews
ORDER BY 1;
"

log "demo database ${PGDATABASE} is ready"
