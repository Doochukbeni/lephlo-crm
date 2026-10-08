#!/usr/bin/env bash
# Restore the CRM from a backup made by backup.sh. Runs on the server.
#
#   ./restore.sh /var/backups/lephlo/20261008T030000Z            CRM database + files
#   ./restore.sh /var/backups/lephlo/20261008T030000Z --with-documenso
#
# Everything written after that backup is lost. rollback.sh (run from the
# laptop) calls this with the backup taken just before the last deploy.
# The CRM server and worker are stopped during the restore and started again
# at the end on whatever LEPHLO_TAG .env names.
set -euo pipefail

cd "$(dirname "$0")"
set -a; source .env; set +a

BACKUP="${1:?Usage: $0 <backup dir> [--with-documenso]}"
WITH_DOCUMENSO=false
[[ "${2:-}" == --with-documenso ]] && WITH_DOCUMENSO=true

files=(lephlo-db.sql.gz server-local-storage.tar.gz)
$WITH_DOCUMENSO && files+=(documenso-db.sql.gz)
for f in "${files[@]}"; do
  [[ -s "$BACKUP/$f" ]] || { echo "Missing or empty: $BACKUP/$f" >&2; exit 1; }
  gzip -t "$BACKUP/$f" || { echo "Corrupt: $BACKUP/$f" >&2; exit 1; }
done

# Recreate a database from a dump. FORCE ends any leftover connections.
restore_db() {
  local service="$1" user="$2" db="$3" dump="$4"
  docker compose exec -T "$service" psql -v ON_ERROR_STOP=1 -q -U "$user" -d postgres \
    -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" -c "CREATE DATABASE \"$db\""
  gunzip -c "$dump" | docker compose exec -T "$service" psql -v ON_ERROR_STOP=1 -q -U "$user" -d "$db" > /dev/null
  echo "Restored $db from $(basename "$(dirname "$dump")")."
}

echo "Stopping the CRM server and worker…"
docker compose stop server worker

restore_db db "$PG_DATABASE_USER" "$PG_DATABASE_NAME" "$BACKUP/lephlo-db.sql.gz"

# The files volume is mounted at .local-storage; replace its contents.
docker compose run --rm --no-deps -T --entrypoint sh server -c \
  'rm -rf /app/packages/twenty-server/.local-storage/* && tar -xzf - -C /app/packages/twenty-server' \
  < "$BACKUP/server-local-storage.tar.gz"
echo "Restored CRM files."

if $WITH_DOCUMENSO; then
  docker compose stop documenso
  restore_db documenso-db "$DOCUMENSO_DB_USER" "$DOCUMENSO_DB_NAME" "$BACKUP/documenso-db.sql.gz"
fi

echo "Starting the stack…"
docker compose up -d
echo "restore from $BACKUP ok"
