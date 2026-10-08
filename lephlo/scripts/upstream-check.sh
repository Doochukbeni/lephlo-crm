#!/usr/bin/env bash
# Monthly upstream check: which Twenty releases came out since our base, and
# which one to merge next. Run from the fork; it changes nothing.
#
#   lephlo/scripts/upstream-check.sh
#
# Upgrades go one minor version at a time (database migrations only go
# forward), so the next target is the newest patch of the next minor. A
# newer patch of the current minor can be merged first and needs no staging
# sign-off from deploy.sh. The steps are in LEPHLO_PATCHES.md → Syncing a
# new upstream release.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

git fetch -q upstream --tags 2> /dev/null || git fetch -q https://github.com/twentyhq/twenty.git 'refs/tags/twenty/v*:refs/tags/twenty/v*'
BASE="$(git describe --tags --match 'twenty/v*' --abbrev=0 origin/lephlo 2> /dev/null || git describe --tags --match 'twenty/v*' --abbrev=0 lephlo)"
CURRENT="${BASE#twenty/v}"
IFS=. read -r major minor patch <<< "$CURRENT"

# Git tags, not GitHub releases: patch versions (2.42.6) only exist as tags.
releases="$(git for-each-ref --format='%(refname:short)%09%(creatordate:short)' 'refs/tags/twenty/v*' \
  | grep -E '^twenty/v[0-9]+\.[0-9]+\.[0-9]+\s')"

echo "Base:  Twenty $CURRENT ($BASE)"
echo
printf '%-10s %s\n' version tagged
newer=()
while IFS=$'\t' read -r tag date; do
  version="${tag#twenty/v}"
  IFS=. read -r a b c <<< "$version"
  if (( a > major || (a == major && b > minor) || (a == major && b == minor && c > patch) )); then
    newer+=("$version")
    printf '%-10s %s\n' "$version" "$date"
  fi
done <<< "$(sort -t$'\t' -k1,1V <<< "$releases")"

if (( ${#newer[@]} == 0 )); then
  echo "(none) Up to date."
  exit 0
fi

latest_patch="" next_minor=""
for version in "${newer[@]}"; do
  IFS=. read -r a b _ <<< "$version"
  (( a == major && b == minor )) && latest_patch="$version"
  (( a == major && b == minor + 1 )) && next_minor="$version"
done
behind=$(printf '%s\n' "${newer[@]}" | cut -d. -f1,2 | grep -v -x "$major.$minor" | sort -u | wc -l | tr -d ' ')

echo
[[ -n "$latest_patch" ]] && echo "Patch first:  $latest_patch (same minor, no new migrations to stage)"
if [[ -n "$next_minor" ]]; then
  echo "Next minor:   $next_minor"
  echo
  echo "  git fetch upstream --tags"
  echo "  git switch -c chore/upstream-v$next_minor origin/lephlo"
  echo "  git merge twenty/v$next_minor"
  echo "  # release notes: https://github.com/twentyhq/twenty/releases/tag/twenty/v${next_minor%.*}.0"
  echo "  # then LEPHLO_PATCHES.md → Syncing a new upstream release: build, staging.sh up, deploy.sh --staged"
fi
(( behind > 2 )) && echo && echo "Note: $behind minor versions behind. Each needs its own merge, staging run and deploy."
exit 0
