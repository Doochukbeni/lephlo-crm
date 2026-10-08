#!/usr/bin/env bash
# Nightly backup: both Postgres databases + Twenty's local file storage.
# provision/install.sh runs it nightly at 03:00 UTC (systemd: lephlo-backup.timer);
# deploy.sh runs it before every deploy. restore.sh restores one.
#
# Each backup is a folder in $BACKUP_DIR named by its UTC time, kept on the
# server for $BACKUP_RETENTION_DAYS days. With BACKUP_RCLONE_REMOTE set (an
# rclone crypt remote, see provision/setup-offsite.sh) it is also copied,
# encrypted, off the server:
#   daily/<stamp>    every night, the newest 7 kept
#   weekly/<stamp>   Sundays, the newest 4 kept
#   monthly/<stamp>  the 1st of the month, the newest 6 kept
#
# With HEALTHCHECKS_BACKUP_URL set it reports to healthchecks.io: /start when
# it begins, the plain URL on success, /fail (with the error) on failure.
# healthchecks.io emails when a night's ping is missing or failed.
set -Eeuo pipefail

cd "$(dirname "$0")"
set -a; source .env; set +a

KEEP_DAILY=7
KEEP_WEEKLY=4
KEEP_MONTHLY=6

ping_healthchecks() {
  [[ -n "${HEALTHCHECKS_BACKUP_URL:-}" ]] || return 0
  curl -fsS -m 10 --retry 3 -o /dev/null --data-binary "${2:-}" "$HEALTHCHECKS_BACKUP_URL$1" || true
}

# Keep stderr for the failure report. -E (errtrace) makes the ERR trap fire
# inside functions too.
log="$(mktemp)"
trap 'rm -f "$log"' EXIT
exec 2> >(tee -a "$log" >&2)
trap 'ping_healthchecks /fail "backup failed at line $LINENO: $(tail -c 2000 "$log")"' ERR

ping_healthchecks /start

stamp="$(date -u +%Y%m%dT%H%M%SZ)"
target="$BACKUP_DIR/$stamp"
mkdir -p "$target"

docker compose exec -T db pg_dump -U "$PG_DATABASE_USER" -d "$PG_DATABASE_NAME" --no-owner | gzip > "$target/lephlo-db.sql.gz"
docker compose exec -T documenso-db pg_dump -U "$DOCUMENSO_DB_USER" -d "$DOCUMENSO_DB_NAME" --no-owner | gzip > "$target/documenso-db.sql.gz"
docker compose exec -T server tar -C /app/packages/twenty-server -czf - .local-storage > "$target/server-local-storage.tar.gz"
for f in "$target"/*.gz; do gzip -t "$f"; done

# Keep the newest $2 folders under $1 and delete the rest.
prune_offsite() {
  local dir="$1" keep="$2" old
  # A tier that has no folder yet (weekly before the first Sunday) lists as
  # an error; upload problems are caught by copy and cryptcheck above.
  { rclone lsf --dirs-only "$BACKUP_RCLONE_REMOTE/$dir" 2> /dev/null || true; } | sort -r | tail -n +"$((keep + 1))" \
    | while read -r old; do rclone purge "$BACKUP_RCLONE_REMOTE/$dir/${old%/}"; done
}

offsite=""
if [[ -n "${BACKUP_RCLONE_REMOTE:-}" ]]; then
  tiers=(daily)
  [[ "$(date -u +%u)" == 7 ]] && tiers+=(weekly)
  [[ "$(date -u +%d)" == 01 ]] && tiers+=(monthly)
  for tier in "${tiers[@]}"; do
    rclone copy "$target" "$BACKUP_RCLONE_REMOTE/$tier/$stamp"
    # Checks the upload against the local files through the encryption.
    rclone cryptcheck --one-way "$target" "$BACKUP_RCLONE_REMOTE/$tier/$stamp"
  done
  prune_offsite daily "$KEEP_DAILY"
  prune_offsite weekly "$KEEP_WEEKLY"
  prune_offsite monthly "$KEEP_MONTHLY"
  offsite=", off-site: ${tiers[*]}"
fi

find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -mtime +"$BACKUP_RETENTION_DAYS" -exec rm -rf {} +

ping_healthchecks "" "backup $stamp, $(du -sh "$target" | cut -f1)$offsite"
echo "backup $stamp ok"
