#!/usr/bin/env bash
# Point the server's nightly backup at an encrypted off-site copy on a
# Hetzner Storage Box. Run from your laptop, once per server:
#
#   lephlo/deploy/provision/setup-offsite.sh deploy@<server-ip> u123456
#   lephlo/deploy/provision/setup-offsite.sh deploy@<server-ip> u123456 --recover
#
# u123456 is the Storage Box user (Hetzner console → Storage Boxes; turn on
# "SSH support" there). The script asks for the Storage Box password.
#
# It writes an rclone config for the deploy user with two remotes:
#   lephlo-storagebox  SFTP to u123456.your-storagebox.de:23, host key pinned
#   lephlo-offsite     rclone crypt on top of it, folder lephlo/: file names
#                      and contents are encrypted on the server before upload
# then proves a round trip and sets BACKUP_RCLONE_REMOTE=lephlo-offsite: in
# the server's .env (and the laptop copy).
#
# New store: it generates the two encryption passwords and prints them ONCE.
# Put them in the vault right away. Without them the off-site backups can't
# be read by anyone, you included.
# --recover (a replacement server): asks for the two passwords from the vault
# instead, so the existing backups can be read.
set -euo pipefail

DEPLOY="$(cd "$(dirname "$0")/.." && pwd)"
REMOTE_DIR=/opt/lephlo/deploy

HOST="${1:-}" BOX_USER="${2:-}" RECOVER=false
[[ "${3:-}" == --recover ]] && RECOVER=true
[[ "$HOST" == *@* && "$BOX_USER" =~ ^u[0-9]+(-sub[0-9]+)?$ ]] \
  || { echo "Usage: $0 deploy@<server-ip> u123456 [--recover]" >&2; exit 1; }
BOX_HOST="${BOX_USER%%-sub*}.your-storagebox.de"

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

ssh_opts=(-o StrictHostKeyChecking=accept-new)
[[ -f "$HOME/.ssh/lephlo_deploy" ]] && ssh_opts+=(-i "$HOME/.ssh/lephlo_deploy")
# shellcheck disable=SC2029
remote() { ssh "${ssh_opts[@]}" "$HOST" "$@"; }

remote "test -f $REMOTE_DIR/.env && command -v rclone > /dev/null" \
  || fail "$HOST needs the Lephlo stack (install.sh) and rclone (in cloud-init)."

read -r -s -p "Storage Box password for $BOX_USER: " box_password; echo
[[ -n "$box_password" ]] || fail "No password given."
if $RECOVER; then
  read -r -s -p "Off-site encryption password (vault): " crypt_password; echo
  read -r -s -p "Off-site encryption salt (vault): " crypt_salt; echo
  [[ -n "$crypt_password" && -n "$crypt_salt" ]] || fail "Both come from the vault."
else
  crypt_password="$(openssl rand -base64 32)"
  crypt_salt="$(openssl rand -base64 32)"
fi

step "Write the rclone config on the server"
# Secrets go over SSH stdin, never on a command line. rclone stores them
# obscured (not encrypted) in a file only the deploy user can read.
# bash -s reads a pipe one byte at a time, so the script's first line can
# read the three secret lines that follow it before the rest of the script.
{
  echo 'IFS= read -r box_password; IFS= read -r crypt_password; IFS= read -r crypt_salt'
  printf '%s\n%s\n%s\n' "$box_password" "$crypt_password" "$crypt_salt"
  cat <<'EOF'
set -euo pipefail
box_user="$1" box_host="$2"
conf_dir="$HOME/.config/rclone"
install -d -m 700 "$conf_dir"
ssh-keyscan -p 23 -t ed25519 "$box_host" 2> /dev/null > "$conf_dir/storagebox_known_hosts"
[[ -s "$conf_dir/storagebox_known_hosts" ]] || { echo "Can't reach $box_host:23. Is SSH support on for the Storage Box?" >&2; exit 1; }
umask 077
cat > "$conf_dir/rclone.conf" <<CONF
[lephlo-storagebox]
type = sftp
host = $box_host
user = $box_user
port = 23
pass = $(printf '%s' "$box_password" | rclone obscure -)
known_hosts_file = $conf_dir/storagebox_known_hosts

[lephlo-offsite]
type = crypt
remote = lephlo-storagebox:lephlo
password = $(printf '%s' "$crypt_password" | rclone obscure -)
password2 = $(printf '%s' "$crypt_salt" | rclone obscure -)
CONF
echo "Wrote $conf_dir/rclone.conf (mode 600)."
EOF
} | remote "bash -s -- '$BOX_USER' '$BOX_HOST'"

step "Round trip through the encryption"
remote bash -s <<'EOF'
set -euo pipefail
probe="$(mktemp -d)"
trap 'rm -rf "$probe"' EXIT
date -u > "$probe/probe.txt"
rclone mkdir lephlo-offsite:
rclone copy "$probe/probe.txt" lephlo-offsite:setup-check/
rclone cat lephlo-offsite:setup-check/probe.txt | cmp - "$probe/probe.txt"
rclone cryptcheck --one-way "$probe" lephlo-offsite:setup-check/ 2>&1 | tail -1
rclone purge lephlo-offsite:setup-check
echo "Encrypted on the Storage Box as:"
rclone lsf lephlo-storagebox:lephlo | head -3
echo "Existing off-site backups:"
for tier in daily weekly monthly; do
  printf '  %-8s %s\n' "$tier" "$(rclone lsf --dirs-only "lephlo-offsite:$tier" 2> /dev/null | wc -l)"
done
EOF

step "Turn it on for the nightly backup"
remote "sed -i 's/^BACKUP_RCLONE_REMOTE=[^ #]*/BACKUP_RCLONE_REMOTE=lephlo-offsite:/' $REMOTE_DIR/.env && grep '^BACKUP_RCLONE_REMOTE=' $REMOTE_DIR/.env"
if [[ -f "$DEPLOY/.env" ]]; then
  sed -i '' 's/^BACKUP_RCLONE_REMOTE=[^ #]*/BACKUP_RCLONE_REMOTE=lephlo-offsite:/' "$DEPLOY/.env" 2> /dev/null \
    || sed -i 's/^BACKUP_RCLONE_REMOTE=[^ #]*/BACKUP_RCLONE_REMOTE=lephlo-offsite:/' "$DEPLOY/.env"
fi

printf '\n\033[32m✔ Off-site backups on: %s → %s:lephlo (encrypted)\033[0m\n' "$HOST" "$BOX_HOST"
if ! $RECOVER; then
  cat <<EOF

Save these two in the vault NOW, as "Lephlo off-site backup encryption".
They are not stored anywhere else you can read, and without them the
off-site backups are unreadable:

  password: $crypt_password
  salt:     $crypt_salt

Also save the Storage Box user ($BOX_USER) and its password.
EOF
fi
echo
echo "Next: ssh $HOST 'sudo systemctl start lephlo-backup' to send the first copy."
