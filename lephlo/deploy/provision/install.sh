#!/usr/bin/env bash
# First install of the Lephlo stack on a server made by create-server.sh.
# Run from your laptop:
#
#   lephlo/deploy/provision/install.sh deploy@<server-ip>
#   lephlo/deploy/provision/install.sh deploy@<server-ip> --skip-dns-check
#   lephlo/deploy/provision/install.sh deploy@<server-ip> --env FILE
#                               another .env than lephlo/deploy/.env (staging.sh)
#
# It checks .env and DNS, copies the stack to /opt/lephlo/deploy, creates the
# Documenso signing certificate (once), starts everything, installs the
# nightly backup timer and checks https://$CRM_DOMAIN answers.
#
# Later releases go through deploy.sh (backup first), not this script.
set -euo pipefail

DEPLOY="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DIR=/opt/lephlo/deploy
IMAGE_REPO=doochukbeni/lephlo-crm

HOST="" SKIP_DNS=false ENV_FILE="$DEPLOY/.env"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-dns-check) SKIP_DNS=true ;;
    --env) ENV_FILE="${2:?--env needs a file}"; shift ;;
    *@*) HOST="$1" ;;
    *) HOST="" ; break ;;
  esac
  shift
done
[[ -n "$HOST" ]] || { echo "Usage: $0 deploy@<server-ip> [--skip-dns-check] [--env FILE]" >&2; exit 1; }

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=accept-new)
[[ -f "$HOME/.ssh/lephlo_deploy" ]] && ssh_opts+=(-i "$HOME/.ssh/lephlo_deploy")
# Arguments expand here on purpose (REMOTE_DIR and friends are local values).
# shellcheck disable=SC2029
remote() { ssh "${ssh_opts[@]}" "$HOST" "$@"; }

step "Checks"
[[ -f "$ENV_FILE" ]] || fail "No $ENV_FILE. Create it with lephlo/deploy/provision/make-env.sh"
[[ "$(stat -f %Lp "$ENV_FILE" 2> /dev/null || stat -c %a "$ENV_FILE")" == 600 ]] \
  || fail "$ENV_FILE should be mode 600: chmod 600 $ENV_FILE"

env_value() { sed -n "s/^$1=\([^ #]*\).*/\1/p" "$ENV_FILE"; }
for name in LEPHLO_TAG DOCUMENSO_TAG CRM_DOMAIN SIGN_DOMAIN ACME_EMAIL EMAIL_SMTP_PASSWORD \
  PG_DATABASE_PASSWORD ENCRYPTION_KEY DOCUMENSO_SIGNING_PASSPHRASE; do
  value="$(env_value "$name")"
  [[ -n "$value" && "$value" != *xxx* && "$value" != *example.com ]] || fail "$name is empty in .env"
done
LEPHLO_TAG="$(env_value LEPHLO_TAG)"
CRM_DOMAIN="$(env_value CRM_DOMAIN)"
SIGN_DOMAIN="$(env_value SIGN_DOMAIN)"
[[ "$(env_value DOCUMENSO_TAG)" != latest ]] || fail "Pin DOCUMENSO_TAG to a release, not latest."

# The server pulls without logging in, so the image must be public.
token="$(curl -fsS "https://ghcr.io/token?scope=repository:$IMAGE_REPO:pull" | jq -r .token)"
curl -fsS -o /dev/null -H "Authorization: Bearer $token" \
  -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
  "https://ghcr.io/v2/$IMAGE_REPO/manifests/$LEPHLO_TAG" \
  || fail "ghcr.io/$IMAGE_REPO:$LEPHLO_TAG can't be pulled anonymously. Push it with build-image.sh and make the package public."
echo "Image:  ghcr.io/$IMAGE_REPO:$LEPHLO_TAG (public)"

remote 'test -f /var/lib/lephlo-provisioned' \
  || fail "$HOST isn't a provisioned Lephlo server (no /var/lib/lephlo-provisioned)."
# Hetzner gives the server its public IPv4 directly (no NAT); the default
# route's source address is it (hostname -I would also list Docker's bridge).
SERVER_IP="$(remote "ip -4 -o route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p'")"
echo "Server: $HOST ($SERVER_IP)"

# Caddy asks Let's Encrypt for certificates on start. Wrong DNS means failed
# challenges and, after a few tries, an hour-long rate limit.
if ! $SKIP_DNS; then
  for domain in "$CRM_DOMAIN" "$SIGN_DOMAIN"; do
    resolved="$(dig +short A "$domain" @1.1.1.1 | tail -1)"
    [[ "$resolved" == "$SERVER_IP" ]] \
      || fail "$domain resolves to '${resolved:-nothing}', not $SERVER_IP. Add the Namecheap A record and wait, or pass --skip-dns-check."
    echo "DNS:    $domain → $resolved"
  done
fi

step "Copy the stack to $REMOTE_DIR"
remote "mkdir -p $REMOTE_DIR/secrets && chmod 700 $REMOTE_DIR/secrets"
# tar rather than rsync: macOS now ships openrsync, whose filter rules differ.
COPYFILE_DISABLE=1 tar -C "$DEPLOY" -czf - docker-compose.yml backup.sh restore.sh host-check.sh caddy \
  | remote "tar -xzf - -C $REMOTE_DIR"
remote "umask 077 && cat > $REMOTE_DIR/.env" < "$ENV_FILE"
echo "Copied docker-compose.yml, caddy/, backup.sh, restore.sh, host-check.sh and .env."

step "Documenso signing certificate"
# Made on the server so the private key never leaves it. -legacy keeps the
# .p12 readable by Documenso's signer (node-forge). The container runs as a
# non-root user, so the file is world-readable inside a 700 directory.
remote bash -s <<'EOF'
set -euo pipefail
cd /opt/lephlo/deploy
if [[ -f secrets/documenso-cert.p12 ]]; then
  echo "Already there; keeping it."
  exit 0
fi
passphrase="$(sed -n 's/^DOCUMENSO_SIGNING_PASSPHRASE=\([^ #]*\).*/\1/p' .env)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
openssl req -x509 -newkey rsa:4096 -keyout "$work/key.pem" -out "$work/cert.pem" \
  -days 3650 -nodes -subj "/CN=Lephlo Signing" 2> /dev/null
openssl pkcs12 -export -legacy -out secrets/documenso-cert.p12 \
  -inkey "$work/key.pem" -in "$work/cert.pem" -passout "pass:$passphrase"
chmod 644 secrets/documenso-cert.p12
echo "Created secrets/documenso-cert.p12 (valid 10 years). Back it up to the vault."
EOF

step "Start the stack"
remote "cd $REMOTE_DIR && docker compose build --pull -q caddy && docker compose pull -q --ignore-buildable && docker compose up -d"
echo "Waiting for the CRM server to report healthy (database migrations run on first start)…"
for _ in $(seq 1 90); do
  state="$(remote "cd $REMOTE_DIR && docker compose ps server --format '{{.Health}}'" 2> /dev/null || true)"
  [[ "$state" == healthy ]] && break
  sleep 10
done
[[ "$state" == healthy ]] \
  || fail "The server isn't healthy after 15 minutes. Look at: ssh $HOST 'cd $REMOTE_DIR && docker compose logs --tail 100 server'"
remote "cd $REMOTE_DIR && docker compose ps --format 'table {{.Service}}\t{{.Status}}'"

step "Timers: nightly backup (03:00 UTC), host check (every 10 minutes)"
remote sudo bash -s <<'EOF'
set -euo pipefail
cat > /etc/systemd/system/lephlo-backup.service <<'UNIT'
[Unit]
Description=Lephlo nightly backup (both databases + CRM files)
After=docker.service

[Service]
Type=oneshot
User=deploy
ExecStart=/opt/lephlo/deploy/backup.sh
UNIT
cat > /etc/systemd/system/lephlo-backup.timer <<'UNIT'
[Unit]
Description=Run the Lephlo backup every night

[Timer]
OnCalendar=*-*-* 03:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
UNIT
cat > /etc/systemd/system/lephlo-host-check.service <<'UNIT'
[Unit]
Description=Lephlo host check (disk, memory, containers, certificates, backups)
After=docker.service

[Service]
Type=oneshot
User=deploy
ExecStart=/opt/lephlo/deploy/host-check.sh
UNIT
cat > /etc/systemd/system/lephlo-host-check.timer <<'UNIT'
[Unit]
Description=Run the Lephlo host check every 10 minutes

[Timer]
OnBootSec=5min
OnUnitActiveSec=10min

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl enable --now lephlo-backup.timer lephlo-host-check.timer
systemctl list-timers 'lephlo-*' --no-pager | head -3
EOF

step "Public check"
for _ in $(seq 1 30); do
  curl -fsS -o /dev/null "https://$CRM_DOMAIN/healthz" 2> /dev/null && break
  sleep 10
done
curl -fsS -o /dev/null "https://$CRM_DOMAIN/healthz" \
  || fail "https://$CRM_DOMAIN/healthz doesn't answer yet. Caddy may still be getting certificates: ssh $HOST 'cd $REMOTE_DIR && docker compose logs caddy'"
title="$(curl -fsS "https://$CRM_DOMAIN/" | sed -n 's:.*<title>\(.*\)</title>.*:\1:p' | head -1)"
echo "https://$CRM_DOMAIN → $title"
[[ "$title" == *Lephlo* ]] || echo "Warning: the page title isn't Lephlo's. Is LEPHLO_TAG a Lephlo build?"

printf '\n\033[32m✔ Lephlo is running at https://%s\033[0m\n' "$CRM_DOMAIN"
cat <<EOF

Next (by hand, see lephlo/deploy/README.md → First install):
  - Sign up at https://$CRM_DOMAIN: the first account creates the workspace and is its admin.
  - Settings → General: name "Lephlo", upload the logo. Settings → Security: 2FA.
  - Run the first backup now and do a restore test:
      ssh $HOST 'sudo systemctl start lephlo-backup.service && journalctl -u lephlo-backup -n 5'
  - Turn on the encrypted off-site copy: lephlo/deploy/provision/setup-offsite.sh $HOST <storage-box-user>
  - Set up the alerts (README → Monitoring and alerts).
  - Save .env and secrets/documenso-cert.p12 to the vault.
EOF
