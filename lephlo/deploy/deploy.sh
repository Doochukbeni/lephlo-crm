#!/usr/bin/env bash
# Deploy a Lephlo CRM image to the server. Run from your laptop.
#
#   lephlo/deploy/deploy.sh deploy@<server-ip> sha-0123456789ab
#   lephlo/deploy/deploy.sh deploy@<server-ip> lephlo-v1.2.0 --staged
#
# Steps: check the image → back up (both databases + files) → switch
# LEPHLO_TAG → pull and restart → wait for healthy → smoke check. Every
# deploy is logged on the server in /opt/lephlo/deploy/deploys.log, which
# rollback.sh reads.
#
# A new Twenty minor version runs database migrations that only go forward,
# so it needs --staged: your word that it passed staging (staging.sh, D4).
# Skipping a minor version is refused; upgrade one minor at a time.
set -euo pipefail

DEPLOY="$(cd "$(dirname "$0")" && pwd)"
REMOTE_DIR=/opt/lephlo/deploy
IMAGE_REPO=doochukbeni/lephlo-crm

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

HOST="" TAG="" STAGED=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --staged) STAGED=true ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage 1 ;;
    *) if [[ -z "$HOST" ]]; then HOST="$1"; elif [[ -z "$TAG" ]]; then TAG="$1"; else usage 1; fi ;;
  esac
  shift
done
[[ "$HOST" == *@* && -n "$TAG" ]] || usage 1
[[ "$TAG" =~ ^(sha-[0-9a-f]{7,40}|lephlo-v[0-9]+\.[0-9]+\.[0-9]+)$ ]] \
  || { echo "Tag must be sha-… or lephlo-vX.Y.Z (pinned, never latest)." >&2; exit 1; }

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=accept-new)
[[ -f "$HOME/.ssh/lephlo_deploy" ]] && ssh_opts+=(-i "$HOME/.ssh/lephlo_deploy")
# Arguments expand here on purpose (REMOTE_DIR and friends are local values).
# shellcheck disable=SC2029
remote() { ssh "${ssh_opts[@]}" "$HOST" "$@"; }

registry_token="$(curl -fsS "https://ghcr.io/token?scope=repository:$IMAGE_REPO:pull" | jq -r .token)"
registry() {
  curl -fsSL -H "Authorization: Bearer $registry_token" \
    -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json, application/vnd.docker.distribution.manifest.list.v2+json' \
    "https://ghcr.io/v2/$IMAGE_REPO/$1"
}

# The Twenty version an image was built from, read from the label that
# build-image.sh sets ("Lephlo build of Twenty 2.42.6 (server + frontend)").
twenty_version() {
  local manifest digest config
  manifest="$(registry "manifests/$1")" || return 1
  digest="$(jq -r '.manifests // empty | map(select(.platform.architecture == "amd64"))[0].digest // empty' <<< "$manifest")"
  [[ -n "$digest" ]] && manifest="$(registry "manifests/$digest")"
  config="$(registry "blobs/$(jq -r .config.digest <<< "$manifest")")" || return 1
  jq -r '.config.Labels["org.opencontainers.image.description"] // ""' <<< "$config" \
    | sed -n 's/.*Twenty \([0-9]*\.[0-9]*\.[0-9]*\).*/\1/p'
}

step "Checks"
remote "test -f $REMOTE_DIR/.env" || fail "$HOST has no $REMOTE_DIR/.env. Run provision/install.sh first."
CURRENT="$(remote "sed -n 's/^LEPHLO_TAG=\([^ #]*\).*/\1/p' $REMOTE_DIR/.env")"
CRM_DOMAIN="$(remote "sed -n 's/^CRM_DOMAIN=\([^ #]*\).*/\1/p' $REMOTE_DIR/.env")"
SIGN_DOMAIN="$(remote "sed -n 's/^SIGN_DOMAIN=\([^ #]*\).*/\1/p' $REMOTE_DIR/.env")"
echo "Server:  $HOST ($CRM_DOMAIN)"
echo "Image:   $CURRENT → $TAG"
[[ "$CURRENT" != "$TAG" ]] || fail "$TAG is already deployed."

registry "manifests/$TAG" > /dev/null \
  || fail "ghcr.io/$IMAGE_REPO:$TAG doesn't exist or isn't public. Push it with build-image.sh."
NEW_TWENTY="$(twenty_version "$TAG" || true)"
OLD_TWENTY="$(twenty_version "$CURRENT" || true)"
echo "Twenty:  ${OLD_TWENTY:-unknown} → ${NEW_TWENTY:-unknown}"

if [[ -z "$NEW_TWENTY" || -z "$OLD_TWENTY" ]]; then
  $STAGED || fail "Can't read the Twenty version of both images. If this deploy passed staging, rerun with --staged."
elif [[ "${NEW_TWENTY%.*}" != "${OLD_TWENTY%.*}" ]]; then
  old_minor="${OLD_TWENTY#*.}"; old_minor="${old_minor%%.*}"
  new_minor="${NEW_TWENTY#*.}"; new_minor="${new_minor%%.*}"
  [[ "${NEW_TWENTY%%.*}" == "${OLD_TWENTY%%.*}" && $((new_minor - old_minor)) -eq 1 ]] \
    || fail "Twenty $OLD_TWENTY → $NEW_TWENTY skips or reverses a minor version. Upgrade one minor at a time."
  $STAGED || fail "Twenty $OLD_TWENTY → $NEW_TWENTY runs one-way database migrations. Test it on staging first, then rerun with --staged."
  echo "Minor upgrade, staged: yes."
fi

step "Sync scripts"
# Ship the current compose file and server-side scripts with the deploy; .env
# and secrets/ on the server are left alone.
COPYFILE_DISABLE=1 tar -C "$DEPLOY" -czf - docker-compose.yml backup.sh restore.sh caddy \
  | remote "tar -xzf - -C $REMOTE_DIR"
echo "Copied docker-compose.yml, caddy/, backup.sh and restore.sh."

step "Backup first"
BACKUP_LINE="$(remote "$REMOTE_DIR/backup.sh" | tail -1)"
[[ "$BACKUP_LINE" =~ ^backup\ ([0-9TZ]+)\ ok$ ]] || fail "Backup failed ($BACKUP_LINE). Nothing was changed."
BACKUP_DIR="$(remote "sed -n 's/^BACKUP_DIR=\([^ #]*\).*/\1/p' $REMOTE_DIR/.env")/${BASH_REMATCH[1]}"
echo "Backup:  $BACKUP_DIR"

step "Deploy $TAG"
remote "cd $REMOTE_DIR && sed -i 's/^LEPHLO_TAG=[^ #]*/LEPHLO_TAG=$TAG/' .env \
  && printf '%s\t%s\t%s\t%s\n' \"\$(date -u +%Y-%m-%dT%H:%M:%SZ)\" '$CURRENT' '$TAG' '$BACKUP_DIR' >> deploys.log \
  && docker compose pull -q server worker && docker compose up -d"

echo "Waiting for the server to be healthy (migrations run on start)…"
state=""
for _ in $(seq 1 90); do
  state="$(remote "cd $REMOTE_DIR && docker compose ps server --format '{{.Health}}'" 2> /dev/null || true)"
  [[ "$state" == healthy ]] && break
  sleep 10
done
rollback_hint="Roll back with: lephlo/deploy/rollback.sh $HOST (restores $BACKUP_DIR)"
[[ "$state" == healthy ]] || fail "Not healthy after 15 minutes. Logs: ssh $HOST 'cd $REMOTE_DIR && docker compose logs --tail 100 server'. $rollback_hint"
remote "cd $REMOTE_DIR && docker compose ps --format 'table {{.Service}}\t{{.Image}}\t{{.Status}}'"

step "Smoke check"
curl -fsS -o /dev/null "https://$CRM_DOMAIN/healthz" || fail "https://$CRM_DOMAIN/healthz failed. $rollback_hint"
title="$(curl -fsS "https://$CRM_DOMAIN/" | sed -n 's:.*<title>\(.*\)</title>.*:\1:p' | head -1)"
[[ "$title" == *Lephlo* ]] || fail "https://$CRM_DOMAIN/ title is '$title', not Lephlo's. $rollback_hint"
echo "https://$CRM_DOMAIN → $title"
curl -fsS -o /dev/null "https://$SIGN_DOMAIN/" || fail "https://$SIGN_DOMAIN/ doesn't answer. $rollback_hint"
echo "https://$SIGN_DOMAIN → OK"

# Keep the laptop copy in step so the vault update is a straight copy.
if [[ -f "$DEPLOY/.env" ]]; then
  sed -i '' "s/^LEPHLO_TAG=[^ #]*/LEPHLO_TAG=$TAG/" "$DEPLOY/.env" 2> /dev/null \
    || sed -i "s/^LEPHLO_TAG=[^ #]*/LEPHLO_TAG=$TAG/" "$DEPLOY/.env"
fi

printf '\n\033[32m✔ %s is live on %s\033[0m\n' "$TAG" "$CRM_DOMAIN"
echo "Update LEPHLO_TAG in the vault copy of .env to $TAG."
