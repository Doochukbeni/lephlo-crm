#!/usr/bin/env bash
# Outside-in security check of the production server. Run from your laptop
# (not the server, which would see its own internal ports):
#
#   lephlo/deploy/security-check.sh <server-ip> [crm-domain] [sign-domain]
#
# Defaults: crm.lephlo.com and sign.lephlo.com. Checks:
#   - only 22, 80 and 443 answer (databases, Redis, the CRM's own port and
#     Docker's API must not), over IPv4 and, when the domain has one, IPv6.
#     With nmap installed it also scans all 65535 TCP ports.
#   - http:// redirects to https://, the certificate is valid
#   - TLS 1.0/1.1 are refused, TLS 1.2+ accepted
#   - the security headers from caddy/Caddyfile are present, Server is hidden
# Exits non-zero on any failure. Run it after the first install and after
# any change to the firewall, compose ports or Caddyfile.
# `check && pass … || fail …` is safe here: pass and fail always return 0.
# shellcheck disable=SC2015
set -uo pipefail

IP="${1:?Usage: $0 <server-ip> [crm-domain] [sign-domain]}"
CRM="${2:-crm.lephlo.com}"
SIGN="${3:-sign.lephlo.com}"
ALLOWED=(22 80 443)
# Ports worth naming: mail, databases, Redis, Docker API, the CRM and
# Documenso containers, common dev ports.
PROBE=(21 23 25 53 110 143 465 587 993 995 2020 2375 2376 3000 3001 3306 5432 5433 6379 8000 8080 8443 9000 9090 11211 27017)

failures=0
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; failures=$((failures + 1)); }
section() { printf '\n\033[1m%s\033[0m\n' "$1"; }

port_open() {
  if [[ "$(uname)" == Darwin ]]; then nc -z -G 3 "$1" "$2" > /dev/null 2>&1; else nc -z -w 3 "$1" "$2" > /dev/null 2>&1; fi
}

scan() {
  local host="$1" label="$2" port closed=0 extra
  for port in "${ALLOWED[@]}"; do
    # Closed is fine too, e.g. SSH limited with create-server.sh --ssh-from.
    port_open "$host" "$port" && pass "$label: $port open (expected)" || pass "$label: $port closed from here"
  done
  for port in "${PROBE[@]}"; do
    if port_open "$host" "$port"; then fail "$label: $port open"; else closed=$((closed + 1)); fi
  done
  (( closed == ${#PROBE[@]} )) && pass "$label: all ${#PROBE[@]} risky ports closed"
  if command -v nmap > /dev/null; then
    extra="$(nmap -Pn -p- --min-rate 2000 -oG - "$host" 2> /dev/null | grep -o '[0-9]*/open' | cut -d/ -f1 \
      | grep -v -x -E '22|80|443' | tr '\n' ' ')"
    [[ -z "$extra" ]] && pass "$label: nmap, all 65535 TCP ports: nothing else open" || fail "$label: nmap found open: $extra"
  fi
}

section "Open ports"
scan "$IP" "IPv4 $IP"
IP6="$(dig +short AAAA "$CRM" | tail -1)"
[[ -n "$IP6" ]] && scan "$IP6" "IPv6 $IP6"

section "HTTPS"
for domain in "$CRM" "$SIGN"; do
  location="$(curl -sS -o /dev/null -w '%{redirect_url}' -m 10 "http://$domain/")"
  [[ "$location" == https://* ]] && pass "$domain: http redirects to https" || fail "$domain: http doesn't redirect to https (${location:-no redirect})"
  curl -fsS -o /dev/null -m 10 "https://$domain/" && pass "$domain: certificate valid" || fail "$domain: HTTPS request failed (certificate?)"
  for version in tls1 tls1_1; do
    label="TLS 1.${version#tls1_}"; [[ "$version" == tls1 ]] && label="TLS 1.0"
    # SECLEVEL=0: OpenSSL 3 refuses old TLS on the client side by default,
    # which would make this pass whatever the server does.
    if openssl s_client -connect "$domain:443" -servername "$domain" "-$version" -cipher 'DEFAULT@SECLEVEL=0' \
      < /dev/null > /dev/null 2>&1; then
      fail "$domain: accepts $label"
    else
      pass "$domain: refuses $label"
    fi
  done
  openssl s_client -connect "$domain:443" -servername "$domain" -tls1_2 < /dev/null > /dev/null 2>&1 \
    && pass "$domain: TLS 1.2 accepted" || fail "$domain: TLS 1.2 refused"
done

section "Security headers"
check_headers() {
  local domain="$1"; shift
  local headers name
  headers="$(curl -sS -D - -o /dev/null -m 10 "https://$domain/" | tr -d '\r' | tr '[:upper:]' '[:lower:]')"
  for name in "$@"; do
    grep -q "^$name:" <<< "$headers" && pass "$domain: $name" || fail "$domain: missing $name"
  done
  grep -q "^server:" <<< "$headers" && fail "$domain: Server header shows $(grep '^server:' <<< "$headers" | cut -d' ' -f2-)" || pass "$domain: Server header hidden"
  local max_age
  max_age="$(sed -n 's/^strict-transport-security:.*max-age=\([0-9]*\).*/\1/p' <<< "$headers")"
  (( ${max_age:-0} >= 31536000 )) && pass "$domain: HSTS max-age at least a year" || fail "$domain: HSTS max-age ${max_age:-missing}, under a year"
}
check_headers "$CRM" strict-transport-security x-content-type-options referrer-policy \
  content-security-policy x-frame-options permissions-policy
check_headers "$SIGN" strict-transport-security x-content-type-options referrer-policy

echo
if (( failures == 0 )); then
  printf '\033[32m✔ All checks passed\033[0m\n'
else
  printf '\033[31m✖ %d check(s) failed\033[0m\n' "$failures"
  exit 1
fi
