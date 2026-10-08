#!/usr/bin/env bash
# Create a Lephlo server on Hetzner Cloud from cloud-init.yaml.
#
#   lephlo/deploy/provision/create-server.sh --dry-run    checks + plan only
#   lephlo/deploy/provision/create-server.sh              production server
#   lephlo/deploy/provision/create-server.sh --name lephlo-staging --role staging --no-backups
#
# Options:
#   --name NAME        server name (default lephlo-prod)
#   --role ROLE        label: production (default) or staging
#   --type TYPE        server type (default cpx31: 4 vCPU AMD, 8 GB, 160 GB)
#   --location LOC     fsn1 (default), nbg1 or hel1
#   --ssh-key PATH     public key for the deploy user (default ~/.ssh/lephlo_deploy.pub)
#   --ssh-from CIDR    only allow SSH from this range (default: anywhere; key-only + fail2ban)
#   --no-backups       skip Hetzner's daily server backups (+20% of the server price)
#   --dry-run          check everything, create nothing
#
# Needs: the hcloud CLI (`brew install hcloud`) with an active context
# (`hcloud context create lephlo` asks for the project's API token and keeps it
# in ~/.config/hcloud/cli.toml, outside this repo).
set -euo pipefail

NAME=lephlo-prod
ROLE=production
TYPE=cpx31
LOCATION=fsn1
SSH_KEY="$HOME/.ssh/lephlo_deploy.pub"
SSH_FROM=""
BACKUPS=true
DRY_RUN=false
IMAGE=ubuntu-24.04
FIREWALL=lephlo-web

HERE="$(cd "$(dirname "$0")" && pwd)"

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="${2:?--name needs a value}"; shift ;;
    --role) ROLE="${2:?--role needs production or staging}"; shift ;;
    --type) TYPE="${2:?--type needs a server type}"; shift ;;
    --location) LOCATION="${2:?--location needs fsn1, nbg1 or hel1}"; shift ;;
    --ssh-key) SSH_KEY="${2:?--ssh-key needs a .pub file}"; shift ;;
    --ssh-from) SSH_FROM="${2:?--ssh-from needs a CIDR like 203.0.113.4/32}"; shift ;;
    --no-backups) BACKUPS=false ;;
    --dry-run) DRY_RUN=true ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

step "Checks"
command -v hcloud > /dev/null || fail "The hcloud CLI is required: brew install hcloud"
command -v jq > /dev/null || fail "jq is required."
[[ "$ROLE" == production || "$ROLE" == staging ]] || fail "--role must be production or staging"
[[ -n "$(hcloud context active 2> /dev/null)" ]] \
  || fail "No active hcloud context. Run: hcloud context create lephlo (asks for the API token)"
echo "hcloud context: $(hcloud context active)"

[[ -f "$SSH_KEY" ]] || fail "No public key at $SSH_KEY. Create one: ssh-keygen -t ed25519 -f ${SSH_KEY%.pub} -C lephlo-deploy"
PUBLIC_KEY="$(awk '{ print $1, $2 }' "$SSH_KEY")"
[[ "$PUBLIC_KEY" =~ ^ssh-(ed25519|rsa)\ [A-Za-z0-9+/=]+$ ]] || fail "$SSH_KEY doesn't look like an SSH public key."

hcloud server describe "$NAME" > /dev/null 2>&1 \
  && fail "A server named $NAME already exists. Pick another --name, or delete it first."

type_json="$(hcloud server-type describe "$TYPE" -o json 2> /dev/null)" \
  || fail "Hetzner has no server type '$TYPE'. List them with: hcloud server-type list"
[[ "$(jq -r '.deprecation // empty' <<< "$type_json")" == "" ]] \
  || fail "Server type $TYPE is deprecated. Pick a current one: hcloud server-type list"
echo "Server:   $NAME ($ROLE), $TYPE: $(jq -r '"\(.cores) vCPU, \(.memory) GB RAM, \(.disk) GB disk"' <<< "$type_json"), $LOCATION, $IMAGE"
echo "Backups:  $BACKUPS"
echo "SSH:      deploy@ with $SSH_KEY, from ${SSH_FROM:-anywhere}"

# Hetzner keys are matched by content, so a renamed key isn't uploaded twice.
KEY_NAME="$(hcloud ssh-key list -o json | jq -r --arg k "$PUBLIC_KEY" \
  '.[] | select((.public_key | split(" ")[0:2] | join(" ")) == $k) | .name' | head -1)"

if $DRY_RUN; then
  echo "SSH key:  ${KEY_NAME:-would upload as lephlo-deploy}"
  hcloud firewall describe "$FIREWALL" > /dev/null 2>&1 \
    && echo "Firewall: $FIREWALL (exists, would be reused)" \
    || echo "Firewall: would create $FIREWALL (in: 22, 80, 443, ICMP)"
  printf '\n\033[32m✔ Dry run: checks passed, nothing created\033[0m\n'
  exit 0
fi

step "SSH key"
if [[ -z "$KEY_NAME" ]]; then
  KEY_NAME=lephlo-deploy
  hcloud ssh-key create --name "$KEY_NAME" --public-key "$PUBLIC_KEY" > /dev/null
  echo "Uploaded as $KEY_NAME."
else
  echo "Already in the project as $KEY_NAME."
fi

step "Firewall"
# Hetzner's firewall sits in front of the server, so ports stay closed even if
# something on the box (like Docker) bypasses ufw.
ssh_sources='["0.0.0.0/0", "::/0"]'
[[ -n "$SSH_FROM" ]] && ssh_sources="[\"$SSH_FROM\"]"
rules="$(mktemp)"
trap 'rm -f "$rules" "${user_data:-}"' EXIT
cat > "$rules" <<JSON
[
  { "direction": "in", "protocol": "tcp", "port": "22", "source_ips": $ssh_sources, "description": "ssh" },
  { "direction": "in", "protocol": "tcp", "port": "80", "source_ips": ["0.0.0.0/0", "::/0"], "description": "http (TLS challenge + redirect)" },
  { "direction": "in", "protocol": "tcp", "port": "443", "source_ips": ["0.0.0.0/0", "::/0"], "description": "https" },
  { "direction": "in", "protocol": "icmp", "source_ips": ["0.0.0.0/0", "::/0"], "description": "ping" }
]
JSON
if hcloud firewall describe "$FIREWALL" > /dev/null 2>&1; then
  hcloud firewall replace-rules "$FIREWALL" --rules-file "$rules" > /dev/null
  echo "Updated the rules of $FIREWALL."
else
  hcloud firewall create --name "$FIREWALL" --rules-file "$rules" --label app=lephlo > /dev/null
  echo "Created $FIREWALL."
fi

step "Server"
user_data="$(mktemp)"
sed "s|__DEPLOY_SSH_KEY__|$PUBLIC_KEY|" "$HERE/cloud-init.yaml" > "$user_data"
hcloud server create \
  --name "$NAME" \
  --type "$TYPE" \
  --image "$IMAGE" \
  --location "$LOCATION" \
  --ssh-key "$KEY_NAME" \
  --firewall "$FIREWALL" \
  --user-data-from-file "$user_data" \
  --label app=lephlo \
  --label "role=$ROLE" > /dev/null

if $BACKUPS; then
  hcloud server enable-backup "$NAME" > /dev/null
  echo "Daily Hetzner backups on (7 kept)."
fi

IPV4="$(hcloud server ip "$NAME")"
IPV6="$(hcloud server ip --ipv6 "$NAME")"
echo "IPv4: $IPV4"
echo "IPv6: $IPV6"

step "Waiting for first boot (cloud-init, a few minutes)"
ssh_opts=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=5 -i "${SSH_KEY%.pub}")
for _ in $(seq 1 60); do
  ssh "${ssh_opts[@]}" "deploy@$IPV4" true 2> /dev/null && break
  sleep 5
done
ssh "${ssh_opts[@]}" "deploy@$IPV4" 'cloud-init status --wait > /dev/null; cloud-init status --long; test -f /var/lib/lephlo-provisioned' \
  || fail "cloud-init didn't finish cleanly. Look at: ssh deploy@$IPV4 sudo cat /var/log/cloud-init-output.log"
ssh "${ssh_opts[@]}" "deploy@$IPV4" 'docker version --format "Docker {{.Server.Version}}"; docker compose version; sudo ufw status | head -1'

printf '\n\033[32m✔ %s is up at %s\033[0m\n' "$NAME" "$IPV4"
if [[ "$ROLE" == production ]]; then
  cat <<EOF

Next:
  1. Namecheap → lephlo.com → Advanced DNS: add A records
       crm   → $IPV4
       sign  → $IPV4
     (AAAA records with $IPV6 are optional.)
  2. lephlo/deploy/provision/install.sh deploy@$IPV4
EOF
fi
