#!/usr/bin/env bash
# Write a production .env from .env.example with every generated secret filled
# in, then list the values that still have to come from you.
#
#   lephlo/deploy/provision/make-env.sh                  writes lephlo/deploy/.env
#   lephlo/deploy/provision/make-env.sh --out PATH       writes PATH instead
#
# The file is git-ignored and created with mode 600. Its master copy belongs in
# the password vault (one secure note, "Lephlo production .env"). Losing
# ENCRYPTION_KEY or DOCUMENSO_ENCRYPTION_KEY makes stored credentials and
# signed documents unreadable, so save the vault copy before going further.
set -euo pipefail

DEPLOY="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$DEPLOY/.env"

case "${1:-}" in
  --out) OUT="${2:?--out needs a path}" ;;
  -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit 0 ;;
  "") ;;
  *) echo "Unknown option: $1" >&2; exit 1 ;;
esac

[[ -e "$OUT" ]] && { echo "$OUT already exists. Not overwriting secrets; move it away first." >&2; exit 1; }

# Postgres passwords go into connection URLs, so letters and digits only.
password() { openssl rand -hex 24; }
key() { openssl rand -base64 32; }

# Values filled in, by variable name. A case statement rather than an
# associative array: macOS ships bash 3.2.
value_for() {
  case "$1" in
    CRM_DOMAIN) echo crm.lephlo.com ;;
    SIGN_DOMAIN) echo sign.lephlo.com ;;
    EMAIL_FROM_ADDRESS) echo noreply@lephlo.com ;;
    DOCUMENSO_FROM_ADDRESS) echo sign@lephlo.com ;;
    PG_DATABASE_PASSWORD | DOCUMENSO_DB_PASSWORD | DOCUMENSO_SIGNING_PASSPHRASE) password ;;
    ENCRYPTION_KEY | DOCUMENSO_NEXTAUTH_SECRET | DOCUMENSO_ENCRYPTION_KEY | DOCUMENSO_ENCRYPTION_SECONDARY_KEY) key ;;
    *) return 1 ;;
  esac
}

umask 077
tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
while IFS= read -r line; do
  name="${line%%=*}"
  if [[ "$line" =~ ^[A-Z0-9_]+= ]] && value="$(value_for "$name")"; then
    # Keep the example's trailing comment, swap the value.
    comment=""
    [[ "$line" =~ (\ +#.*)$ ]] && comment="${BASH_REMATCH[1]}"
    printf '%s=%s%s\n' "$name" "$value" "$comment"
  else
    printf '%s\n' "$line"
  fi
done < "$DEPLOY/.env.example" > "$tmp"
mv "$tmp" "$OUT"
chmod 600 "$OUT"

echo "Wrote $OUT (mode 600) with generated database passwords and keys."
echo
echo "Still to fill in by hand:"
required=(LEPHLO_TAG DOCUMENSO_TAG ACME_EMAIL EMAIL_SMTP_PASSWORD)
optional=(AUTH_GOOGLE_CLIENT_ID AUTH_GOOGLE_CLIENT_SECRET ANTHROPIC_API_KEY SENTRY_DSN SENTRY_FRONT_DSN HEALTHCHECKS_BACKUP_URL HEALTHCHECKS_HOST_URL)
for name in "${required[@]}" "${optional[@]}"; do
  value="$(sed -n "s/^$name=\([^ #]*\).*/\1/p" "$OUT")"
  if [[ -z "$value" || "$value" == *xxx* || "$value" == *example.com ]]; then
    kind=optional
    [[ " ${required[*]} " == *" $name "* ]] && kind=required
    printf '  %-28s %s\n' "$name" "$kind"
  fi
done
echo
echo "Then copy the whole file into the vault before running install.sh."
