#!/usr/bin/env bash
# Nightly backup: both Postgres databases + Twenty's local file storage.
# Install on the host, e.g. `0 3 * * * /opt/lephlo/deploy/backup.sh >> /var/log/lephlo-backup.log 2>&1`
# Restore test (do one before go-live):
#   gunzip -c lephlo-db.sql.gz | docker compose exec -T db psql -U "$PG_DATABASE_USER" -d "$PG_DATABASE_NAME"
set -euo pipefail

cd "$(dirname "$0")"
set -a; source .env; set +a

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$BACKUP_DIR/$stamp"
mkdir -p "$target"

docker compose exec -T db pg_dump -U "$PG_DATABASE_USER" -d "$PG_DATABASE_NAME" --no-owner | gzip > "$target/lephlo-db.sql.gz"
docker compose exec -T documenso-db pg_dump -U "$DOCUMENSO_DB_USER" -d "$DOCUMENSO_DB_NAME" --no-owner | gzip > "$target/documenso-db.sql.gz"
docker compose exec -T server tar -C /app/packages/twenty-server -czf - .local-storage > "$target/server-local-storage.tar.gz"

if [[ -n "${BACKUP_RCLONE_REMOTE:-}" ]]; then
  rclone copy "$target" "$BACKUP_RCLONE_REMOTE/$stamp"
fi

find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} +

echo "backup $stamp ok"
