#!/usr/bin/env bash
# Undo the last deploy.sh: put the previous image back and restore the backup
# taken just before that deploy. Run from your laptop.
#
#   lephlo/deploy/rollback.sh deploy@<server-ip>
#
# Database migrations only go forward, so the old image alone can't run on a
# migrated database: the restore is what makes the rollback safe. It also
# means anything entered in the CRM since that deploy is lost, so the script
# asks you to type the domain before it touches anything.
set -euo pipefail

REMOTE_DIR=/opt/lephlo/deploy
HOST="${1:-}"
[[ "$HOST" == *@* ]] || { echo "Usage: $0 deploy@<server-ip>" >&2; exit 1; }

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=accept-new)
[[ -f "$HOME/.ssh/lephlo_deploy" ]] && ssh_opts+=(-i "$HOME/.ssh/lephlo_deploy")
# shellcheck disable=SC2029
remote() { ssh "${ssh_opts[@]}" "$HOST" "$@"; }

step "Last deploy"
last="$(remote "tail -1 $REMOTE_DIR/deploys.log 2> /dev/null")" || true
[[ -n "$last" ]] || fail "No deploys.log on $HOST: nothing to roll back."
IFS=$'\t' read -r when from to backup <<< "$last"
current="$(remote "sed -n 's/^LEPHLO_TAG=\([^ #]*\).*/\1/p' $REMOTE_DIR/.env")"
domain="$(remote "sed -n 's/^CRM_DOMAIN=\([^ #]*\).*/\1/p' $REMOTE_DIR/.env")"
[[ "$current" == "$to" ]] || fail "The server runs $current, but the last logged deploy was $to. Sort this out by hand."
[[ "$from" != rollback:* ]] || fail "The last entry is already a rollback."
echo "Deployed: $when, $from → $to"
echo "Restore:  $backup"
remote "test -s $backup/lephlo-db.sql.gz" || fail "Backup $backup is missing on the server."

echo
echo "This puts $from back and restores the CRM database and files from"
echo "$backup. Everything entered in the CRM since $when is lost."
read -r -p "Type $domain to continue: " answer
[[ "$answer" == "$domain" ]] || fail "Cancelled."

step "Restore"
remote "cd $REMOTE_DIR && sed -i 's/^LEPHLO_TAG=[^ #]*/LEPHLO_TAG=$from/' .env \
  && docker compose pull -q server worker && ./restore.sh '$backup' \
  && printf '%s\t%s\t%s\t%s\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" 'rollback:$to' '$from' '$backup' >> deploys.log"

echo "Waiting for the server to be healthy…"
state=""
for _ in $(seq 1 60); do
  state="$(remote "cd $REMOTE_DIR && docker compose ps server --format '{{.Health}}'" 2> /dev/null || true)"
  [[ "$state" == healthy ]] && break
  sleep 10
done
[[ "$state" == healthy ]] || fail "Not healthy after 10 minutes: ssh $HOST 'cd $REMOTE_DIR && docker compose logs --tail 100 server'"
curl -fsS -o /dev/null "https://$domain/healthz" || fail "https://$domain/healthz doesn't answer."

printf '\n\033[32m✔ Rolled back to %s\033[0m\n' "$from"
echo "Set LEPHLO_TAG=$from in the vault copy of .env."
