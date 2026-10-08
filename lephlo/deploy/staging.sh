#!/usr/bin/env bash
# On-demand staging: a throwaway copy of production on its own Hetzner server.
# Run from your laptop.
#
#   lephlo/deploy/staging.sh up [<candidate tag>]   create it from last night's backup
#   lephlo/deploy/staging.sh status                 is one running, and for how long
#   lephlo/deploy/staging.sh down                   delete it
#   lephlo/deploy/staging.sh restore-test           monthly: up, compare row counts
#                                                   with production, down
#
# Production is given as LEPHLO_PROD=deploy@<prod-ip> (or --prod deploy@<ip>).
#
# `up` creates the server (create-server.sh --role staging --no-backups) and
# streams the newest production backup to it (through this laptop, never
# written to disk here). It installs the production image on
# crm-<ip>.sslip.io (TLS without DNS changes) and restores the backup. With a
# candidate tag it then deploys that tag with deploy.sh, which runs the real
# database migrations.
#
# Staging holds client data and production's keys, so:
#   - it can't reach production: outbound traffic to the production server
#     is rejected (Documenso, webhooks and app calls would otherwise hit it)
#   - it can't email anyone: outbound SMTP is rejected and SMTP points nowhere
#   - Google login and Gmail/Calendar sync are off, backups stay local, and
#     it never pings production's healthchecks.io checks
#   - it powers itself off after 24 hours, and `up` refuses while one exists.
#     It still costs money and holds data until `down`.
# Never share the sslip.io URL.
set -euo pipefail

DEPLOY="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR=/opt/lephlo/deploy
NAME=lephlo-staging
LIFETIME_MINUTES=1440

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

ACTION="" TAG="" PROD="${LEPHLO_PROD:-}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --prod) PROD="${2:?--prod needs deploy@<ip>}"; shift ;;
    -h|--help) usage ;;
    up|down|status|restore-test) ACTION="$1" ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) [[ "$ACTION" == up && -z "$TAG" ]] || usage 1; TAG="$1" ;;
  esac
  shift
done
[[ -n "$ACTION" ]] || usage 1

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=accept-new)
[[ -f "$HOME/.ssh/lephlo_deploy" ]] && ssh_opts+=(-i "$HOME/.ssh/lephlo_deploy")
# shellcheck disable=SC2029
on() { local host="$1"; shift; ssh "${ssh_opts[@]}" "$host" "$@"; }

command -v hcloud > /dev/null || fail "The hcloud CLI is required: brew install hcloud"
[[ -n "$(hcloud context active 2> /dev/null)" ]] || fail "No active hcloud context: hcloud context create lephlo"

# The staging .env holds production's keys; never leave it in $TMPDIR.
env_file=""
DELETE_STAGING_ON_EXIT=false
STAGING_CREATED=false
cleanup() {
  [[ -z "$env_file" ]] || rm -f "$env_file"
  # Only a server this run created; never someone's existing staging.
  if $DELETE_STAGING_ON_EXIT && $STAGING_CREATED; then
    echo "Deleting the staging server (restore test)…"
    staging_down false
  fi
}
trap cleanup EXIT

staging_servers() { hcloud server list -l app=lephlo,role=staging -o noheader -o columns=name,ipv4,created; }

need_prod() {
  [[ "$PROD" == *@* ]] || fail "Say which server is production: LEPHLO_PROD=deploy@<prod-ip> or --prod deploy@<prod-ip>"
  on "$PROD" "test -f $REMOTE_DIR/.env" || fail "$PROD has no $REMOTE_DIR/.env."
}

# Exact row counts of the CRM's main tables and the app's own tables (the
# ones whose names start with _), one "schema.table count" line each.
row_counts() {
  on "$1" "cd $REMOTE_DIR && set -a && . ./.env && set +a && docker compose exec -T db psql -U \"\$PG_DATABASE_USER\" -d \"\$PG_DATABASE_NAME\" -tA -F' ' -q" <<'SQL'
SELECT format('SELECT %L, count(*) FROM %I.%I', table_schema || '.' || table_name, table_schema, table_name)
FROM information_schema.tables
WHERE table_schema LIKE 'workspace\_%' AND table_type = 'BASE TABLE'
  AND (table_name IN ('company', 'person', 'opportunity', 'task', 'note', 'attachment') OR table_name LIKE '\_%')
ORDER BY 1
\gexec
SQL
}

staging_down() {
  local confirm="$1" servers
  servers="$(staging_servers)"
  if [[ -z "$servers" ]]; then
    echo "No staging server."
    return
  fi
  echo "$servers"
  if $confirm; then
    read -r -p "Delete it and the client data on it? Type $NAME: " answer
    [[ "$answer" == "$NAME" ]] || fail "Cancelled."
  fi
  while read -r name ip _; do
    hcloud server delete "$name" > /dev/null
    ssh-keygen -R "$ip" > /dev/null 2>&1 || true
    echo "Deleted $name ($ip)."
  done <<< "$servers"
}

staging_up() {
  local tag="$1"
  need_prod
  [[ -z "$(staging_servers)" ]] \
    || fail "A staging server already exists (staging.sh status). Delete it first: staging.sh down"

  step "Production"
  local prod_tag stamp prod_ip prod_ip6
  prod_tag="$(on "$PROD" "sed -n 's/^LEPHLO_TAG=\([^ #]*\).*/\1/p' $REMOTE_DIR/.env")"
  stamp="$(on "$PROD" "ls -1 /var/backups/lephlo | grep -E '^[0-9]{8}T[0-9]{6}Z\$' | tail -1")"
  [[ -n "$stamp" ]] || fail "No backup on production yet."
  prod_ip="$(on "$PROD" "ip -4 -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'")"
  prod_ip6="$(on "$PROD" "ip -6 -o addr show scope global | awk '{ print \$4; exit }'")"
  echo "Image:   $prod_tag"
  echo "Backup:  $stamp"
  echo "Blocked: $prod_ip ${prod_ip6:-}"

  step "Create the staging server"
  STAGING_CREATED=true
  "$DEPLOY/provision/create-server.sh" --name "$NAME" --role staging --no-backups
  local ip host domain
  ip="$(hcloud server ip "$NAME")"
  host="deploy@$ip"
  domain="${ip//./-}.sslip.io"

  step "Cut staging off from production and from email"
  # Containers' traffic goes through Docker's FORWARD chain, not ufw's OUTPUT
  # rules, so the blocks go into DOCKER-USER (and OUTPUT for the host). A
  # oneshot unit puts them back after every reboot. The IPv6 DOCKER-USER lines
  # may fail ("-") where Docker has no IPv6 chain; containers then have no
  # IPv6 route out at all.
  on "$host" "sudo tee /etc/systemd/system/lephlo-staging-egress.service > /dev/null" <<UNIT
[Unit]
Description=Staging: no traffic to production, no outbound email
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/sbin/iptables -I DOCKER-USER -d $prod_ip -j REJECT
ExecStart=/usr/sbin/iptables -I OUTPUT -d $prod_ip -j REJECT
ExecStart=/usr/sbin/iptables -I DOCKER-USER -p tcp -m multiport --dports 25,465,587,2525 -j REJECT
ExecStart=/usr/sbin/iptables -I OUTPUT -p tcp -m multiport --dports 25,465,587,2525 -j REJECT
${prod_ip6:+ExecStart=-/usr/sbin/ip6tables -I DOCKER-USER -d ${prod_ip6%/*}/64 -j REJECT}
${prod_ip6:+ExecStart=/usr/sbin/ip6tables -I OUTPUT -d ${prod_ip6%/*}/64 -j REJECT}
ExecStart=-/usr/sbin/ip6tables -I DOCKER-USER -p tcp -m multiport --dports 25,465,587,2525 -j REJECT
ExecStart=/usr/sbin/ip6tables -I OUTPUT -p tcp -m multiport --dports 25,465,587,2525 -j REJECT

[Install]
WantedBy=multi-user.target
UNIT
  on "$host" "sudo systemctl daemon-reload && sudo systemctl enable --now lephlo-staging-egress.service > /dev/null"
  # Prove it from the host and from inside a container before any data moves.
  on "$host" "! curl -fsS -m 5 -o /dev/null http://$prod_ip/ 2> /dev/null \
    && ! docker run --rm busybox:1.36 wget -q -T 5 -O /dev/null http://$prod_ip/ 2> /dev/null" \
    || fail "Staging can still reach production. Not copying data; run staging.sh down."
  echo "Production unreachable from staging (host and containers): yes"
  on "$host" "sudo shutdown -h +$LIFETIME_MINUTES 'Staging lifetime is over' 2> /dev/null"
  echo "Powers off in $((LIFETIME_MINUTES / 60)) hours."

  step "Copy backup $stamp"
  on "$PROD" "tar -C /var/backups/lephlo -cf - $stamp" | on "$host" "tar -xf - -C /var/backups/lephlo"
  echo "Copied."

  step "Install production's image on $domain"
  env_file="$(mktemp)"
  on "$PROD" "cat $REMOTE_DIR/.env" | sed -E \
    -e "s/^CRM_DOMAIN=.*/CRM_DOMAIN=crm-$domain/" \
    -e "s/^SIGN_DOMAIN=.*/SIGN_DOMAIN=sign-$domain/" \
    -e "s/^EMAIL_SMTP_HOST=.*/EMAIL_SMTP_HOST=smtp.invalid/" \
    -e "s/^(AUTH_GOOGLE_ENABLED|MESSAGING_PROVIDER_GMAIL_ENABLED|CALENDAR_PROVIDER_GOOGLE_ENABLED)=.*/\1=false/" \
    -e "s/^SENTRY_ENVIRONMENT=.*/SENTRY_ENVIRONMENT=staging/" \
    -e "s/^BACKUP_RCLONE_REMOTE=.*/BACKUP_RCLONE_REMOTE=/" \
    -e "s/^(HEALTHCHECKS_BACKUP_URL|HEALTHCHECKS_HOST_URL)=.*/\1=/" \
    > "$env_file"
  "$DEPLOY/provision/install.sh" "$host" --env "$env_file"
  rm -f "$env_file"

  step "Restore production data"
  on "$host" "cd $REMOTE_DIR && ./restore.sh /var/backups/lephlo/$stamp"
  local state=""
  for _ in $(seq 1 60); do
    state="$(on "$host" "cd $REMOTE_DIR && docker compose ps server --format '{{.Health}}'" 2> /dev/null || true)"
    [[ "$state" == healthy ]] && break
    sleep 10
  done
  [[ "$state" == healthy ]] || fail "Staging isn't healthy after the restore. Look, then: staging.sh down"
  curl -fsS -o /dev/null "https://crm-$domain/healthz" || fail "https://crm-$domain/healthz doesn't answer."

  if [[ -n "$tag" && "$tag" != "$prod_tag" ]]; then
    step "Deploy the candidate $tag"
    "$DEPLOY/deploy.sh" "$host" "$tag" --staged
  fi

  STAGING_HOST="$host"
  printf '\n\033[32m✔ Staging: https://crm-%s\033[0m (%s, production data from %s)\n' "$domain" "${tag:-$prod_tag}" "$stamp"
  echo "Log in with your production account. Don't share the URL."
  echo "Delete it when done: lephlo/deploy/staging.sh down"
}

case "$ACTION" in
  status)
    servers="$(staging_servers)"
    if [[ -z "$servers" ]]; then echo "No staging server."; exit 0; fi
    echo "$servers"
    echo "It holds client data. Delete it when you're done: staging.sh down"
    ;;
  down)
    staging_down true
    ;;
  up)
    staging_up "$TAG"
    ;;
  restore-test)
    need_prod
    started="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    # Pass or fail, the copy of client data goes away at the end.
    DELETE_STAGING_ON_EXIT=true
    staging_up ""
    step "Row counts: production now vs restored backup"
    prod_counts="$(row_counts "$PROD")"
    staging_counts="$(row_counts "$STAGING_HOST")"
    report="$(LC_ALL=C join -a 1 -e 0 -o 0,1.2,2.2 <(LC_ALL=C sort <<< "$prod_counts") <(LC_ALL=C sort <<< "$staging_counts"))"
    printf '%-60s %10s %10s\n' table production restored
    awk '{ printf "%-60s %10s %10s\n", $1, $2, $3 }' <<< "$report"
    # The backup is up to a day old, so small differences are normal; an
    # empty table that has rows in production, or a big gap, is not.
    verdict="$(awk '
      { prod += $2; restored += $3; if ($2 > 0 && $3 == 0) empty = empty " " $1 }
      END {
        if (empty != "") print "FAIL: empty after restore:" empty
        else if (prod > 0 && restored < 0.9 * prod) printf "FAIL: %d of %d rows restored\n", restored, prod
        else printf "PASS: %d of %d rows restored\n", restored, prod
      }' <<< "$report")"
    echo "$verdict"
    mkdir -p "$DEPLOY/out"
    printf '%s\t%s\n' "$started" "$verdict" >> "$DEPLOY/out/restore-tests.log"
    [[ "$verdict" == PASS* ]] || fail "Restore test failed. Logged in lephlo/deploy/out/restore-tests.log"
    printf '\n\033[32m✔ Restore test passed\033[0m (logged in lephlo/deploy/out/restore-tests.log)\n'
    ;;
esac
