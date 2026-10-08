#!/usr/bin/env bash
# Server health, every 10 minutes (systemd: lephlo-host-check.timer, installed
# by provision/install.sh). Reports to healthchecks.io via HEALTHCHECKS_HOST_URL:
# the plain URL when all is well, /fail with the list of problems otherwise.
# A server that is down sends nothing, and healthchecks.io emails about that too.
#
# Checks: disk, memory, load, every stack container running and not
# unhealthy, TLS certificates not about to expire, last backup not stale.
set -euo pipefail

cd "$(dirname "$0")"
set -a; source .env; set +a

DISK_MAX_PERCENT=80
MEM_MIN_AVAILABLE_PERCENT=10
LOAD_MAX_PER_CORE=2
CERT_MIN_DAYS=14
BACKUP_MAX_AGE_HOURS=26

problems=()

disk="$(df -P / | awk 'NR == 2 { sub("%", "", $5); print $5 }')"
(( disk < DISK_MAX_PERCENT )) || problems+=("disk ${disk}% full")

mem="$(awk '/^MemTotal:/ { t = $2 } /^MemAvailable:/ { a = $2 } END { printf "%d", a * 100 / t }' /proc/meminfo)"
(( mem >= MEM_MIN_AVAILABLE_PERCENT )) || problems+=("only ${mem}% memory available")

load="$(cut -d' ' -f3 /proc/loadavg)"
cores="$(nproc)"
awk -v l="$load" -v m="$((cores * LOAD_MAX_PER_CORE))" 'BEGIN { exit !(l <= m) }' \
  || problems+=("15-min load $load on $cores cores")

# Every service the compose file runs must be up, and not unhealthy.
running="$(docker compose ps -a --format '{{.Service}} {{.State}} {{.Health}}')"
for service in $(docker compose config --services); do
  read -r state health <<< "$(awk -v s="$service" '$1 == s { print $2, $3 }' <<< "$running")"
  if [[ "$state" != running ]]; then
    problems+=("$service ${state:-missing}")
  elif [[ "$health" == unhealthy ]]; then
    problems+=("$service unhealthy")
  fi
done

for domain in "$CRM_DOMAIN" "$SIGN_DOMAIN"; do
  end="$(openssl s_client -connect 127.0.0.1:443 -servername "$domain" < /dev/null 2> /dev/null \
    | openssl x509 -noout -enddate 2> /dev/null | cut -d= -f2)"
  if [[ -z "$end" ]]; then
    problems+=("no TLS certificate for $domain")
  else
    days=$(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
    (( days >= CERT_MIN_DAYS )) || problems+=("$domain certificate expires in $days days")
  fi
done

latest="$(find "$BACKUP_DIR" -mindepth 1 -maxdepth 1 -type d -name '20*Z' -printf '%T@\n' 2> /dev/null | sort -n | tail -1)"
if [[ -z "$latest" ]]; then
  problems+=("no backup in $BACKUP_DIR")
else
  age=$(( ($(date +%s) - ${latest%.*}) / 3600 ))
  (( age <= BACKUP_MAX_AGE_HOURS )) || problems+=("last backup is ${age}h old")
fi

summary="disk ${disk}%, memory free ${mem}%, load $load/$cores"
if (( ${#problems[@]} == 0 )); then
  [[ -z "${HEALTHCHECKS_HOST_URL:-}" ]] \
    || curl -fsS -m 10 --retry 3 -o /dev/null --data-binary "ok: $summary" "$HEALTHCHECKS_HOST_URL" || true
  echo "ok: $summary"
else
  report="$(printf '%s\n' "${problems[@]}")"
  [[ -z "${HEALTHCHECKS_HOST_URL:-}" ]] \
    || curl -fsS -m 10 --retry 3 -o /dev/null --data-binary "$report"$'\n'"$summary" "$HEALTHCHECKS_HOST_URL/fail" || true
  printf 'PROBLEM: %s\n' "${problems[@]}" >&2
  exit 1
fi
