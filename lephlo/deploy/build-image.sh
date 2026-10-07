#!/usr/bin/env bash
# Build, scan and (optionally) push the Lephlo CRM image.
#
# GitHub Actions is off on this account, so the image is built from a
# workstation. It replaces .github/workflows/lephlo-build-image.yaml.
#
#   lephlo/deploy/build-image.sh                    build + scan, keep it local
#   lephlo/deploy/build-image.sh --push             build + scan + push to GHCR
#   lephlo/deploy/build-image.sh --release 1.2.0 --push
#                                                   also tag lephlo-v1.2.0
#                                                   (HEAD must carry the git
#                                                   tag lephlo/v1.2.0)
#   lephlo/deploy/build-image.sh --builder lephlo-amd64 --push
#                                                   build on a remote amd64
#                                                   machine (see README)
#   lephlo/deploy/build-image.sh --scan-only <image>
#                                                   scan an existing image
#   lephlo/deploy/build-image.sh --dry-run [...]    run the checks, print the
#                                                   tags, build nothing
#
# Tags pushed: sha-<12 chars> always, lephlo-vX.Y.Z with --release.
# Production pins one of those; nothing moving like `latest` is pushed.
#
# The Trivy scan fails the build on CRITICAL vulnerabilities that have a fix.
# The report and an SPDX SBOM land in lephlo/deploy/out/ (git-ignored).
set -euo pipefail

IMAGE=ghcr.io/doochukbeni/lephlo-crm
PLATFORM=linux/amd64
# Pinned by digest: Trivy's own release channel was compromised in 2026.
# Bump deliberately, to a release that has been out for a few weeks.
TRIVY=aquasec/trivy:0.74.0@sha256:62b1e65e8869bc4b4c6aa4fa2b21595256c7c2f6018a9d9ad61caf87187c1969

ROOT="$(git -C "$(dirname "$0")" rev-parse --show-toplevel)"
OUT="$ROOT/lephlo/deploy/out"

PUSH=false
RELEASE=""
BUILDER=""
SCAN_ONLY=""
DRY_RUN=false

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; exit "${1:-0}"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push) PUSH=true ;;
    --release) RELEASE="${2:?--release needs a version like 1.2.0}"; shift ;;
    --builder) BUILDER="${2:?--builder needs a buildx builder name}"; shift ;;
    --dry-run) DRY_RUN=true ;;
    --scan-only) SCAN_ONLY="${2:?--scan-only needs an image reference}"; shift ;;
    -h|--help) usage ;;
    *) echo "Unknown option: $1" >&2; usage 1 ;;
  esac
  shift
done

step() { printf '\n\033[1m▶ %s\033[0m\n' "$1"; }
fail() { printf '\033[31m✖ %s\033[0m\n' "$1" >&2; exit 1; }

# Pushing to GHCR needs the write:packages scope on the gh token. Ask for it
# once (browser sign-in) instead of failing after a long build.
ensure_ghcr_scope() {
  command -v gh > /dev/null || fail "The GitHub CLI (gh) is required to push."
  if gh api -i user 2> /dev/null | grep -i '^x-oauth-scopes:' | grep -q 'write:packages'; then
    echo "GitHub token can push packages."
    return
  fi
  [[ -t 0 ]] || fail "The gh token can't push packages. Run: gh auth refresh -h github.com -s write:packages"
  echo "The gh token can't push packages yet. Adding the write:packages scope (one-time browser sign-in)."
  gh auth refresh -h github.com -s write:packages
  gh api -i user 2> /dev/null | grep -i '^x-oauth-scopes:' | grep -q 'write:packages' \
    || fail "Still no write:packages scope on the gh token."
}

# GitHub has no API to change package visibility, so only point at the page.
remind_if_private() {
  local visibility
  visibility="$(gh api /user/packages/container/lephlo-crm -q .visibility 2> /dev/null || true)"
  if [[ "$visibility" == "private" ]]; then
    echo
    echo "The GHCR package is private, so the server would need a login to pull it."
    echo "Make it public (the fork is public under the AGPL anyway):"
    echo "  https://github.com/users/Doochukbeni/packages/container/lephlo-crm/settings"
    echo "  → Danger Zone → Change visibility → Public"
  fi
}

scan() {
  local ref="$1" name="$2"
  mkdir -p "$OUT"

  step "Trivy: vulnerability report"
  # The Docker socket lets the Trivy container read the local image store.
  # The cache volume keeps the vulnerability database between runs.
  local trivy=(docker run --rm
    -v /var/run/docker.sock:/var/run/docker.sock
    -v lephlo-trivy-cache:/root/.cache/trivy
    -v "$OUT:/out"
    "$TRIVY" image --quiet)

  "${trivy[@]}" --scanners vuln --severity HIGH,CRITICAL --format table \
    --output "/out/$name.trivy.txt" "$ref"
  echo "Report: lephlo/deploy/out/$name.trivy.txt"

  step "Trivy: SBOM (SPDX)"
  "${trivy[@]}" --format spdx-json \
    --output "/out/$name.sbom.spdx.json" "$ref"
  echo "SBOM:   lephlo/deploy/out/$name.sbom.spdx.json"

  step "Trivy: fail on fixable CRITICAL"
  "${trivy[@]}" --scanners vuln --severity CRITICAL --ignore-unfixed --exit-code 1 --table-mode detailed \
    --format table "$ref" \
    || fail "Fixable CRITICAL vulnerabilities in $ref (see above). Not pushing."
}

if [[ -n "$SCAN_ONLY" ]]; then
  name="$(sed 's|.*/||; s|[:@]|-|g' <<< "$SCAN_ONLY" | cut -c1-80)"
  scan "$SCAN_ONLY" "$name"
  printf '\n\033[32m✔ Scan passed\033[0m\n'
  exit 0
fi

cd "$ROOT"

step "Checks"
command -v docker > /dev/null || fail "Docker is required."
docker buildx version > /dev/null || fail "docker buildx is required."
# The image is tagged by commit, so it must be exactly that commit.
[[ -z "$(git status --porcelain)" ]] \
  || fail "The working tree has uncommitted changes. Commit or stash them first."

SHA="$(git rev-parse HEAD)"
SHORT="${SHA:0:12}"
TWENTY_TAG="$(git describe --tags --match 'twenty/v*' --abbrev=0 HEAD)"
TWENTY_VERSION="${TWENTY_TAG#twenty/v}"
TAGS=("$IMAGE:sha-$SHORT")

if [[ -n "$RELEASE" ]]; then
  [[ "$RELEASE" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail "--release must look like 1.2.0"
  git tag --points-at HEAD | grep -qx "lephlo/v$RELEASE" \
    || fail "HEAD isn't tagged lephlo/v$RELEASE. Run: git tag lephlo/v$RELEASE && git push origin lephlo/v$RELEASE"
  TAGS+=("$IMAGE:lephlo-v$RELEASE")
fi

if $PUSH; then
  # A pushed image must come from a commit that exists on GitHub, so its
  # sha tag and source label lead somewhere.
  git branch -r --contains "$SHA" | grep -q . \
    || fail "Commit $SHORT isn't on GitHub yet. Push it first."
  ensure_ghcr_scope
fi

echo "Commit:  $SHORT ($(git rev-parse --abbrev-ref HEAD))"
echo "Twenty:  $TWENTY_VERSION"
echo "Tags:    ${TAGS[*]}"
echo "Builder: ${BUILDER:-current ($(docker buildx inspect | awk '/^Name:/{print $2; exit}'))}"

if [[ "$(uname -m)" != "x86_64" && -z "$BUILDER" ]]; then
  echo
  echo "Note: building $PLATFORM under emulation on $(uname -m). The front-end"
  echo "build needs about 8 GB of memory and can take over an hour this way."
  echo "A remote amd64 builder is much faster (see README, 'Building the image')."
fi

if $DRY_RUN; then
  printf '\n\033[32m✔ Dry run: checks passed, nothing built\033[0m\n'
  exit 0
fi

step "Build $PLATFORM"
build=(docker buildx build
  --platform "$PLATFORM"
  --file packages/twenty-docker/twenty/Dockerfile
  --target twenty
  --build-arg "APP_VERSION=$TWENTY_VERSION-lephlo"
  --label "org.opencontainers.image.title=Lephlo CRM"
  --label "org.opencontainers.image.description=Lephlo build of Twenty $TWENTY_VERSION (server + frontend)"
  --label "org.opencontainers.image.licenses=AGPL-3.0"
  --label "org.opencontainers.image.source=https://github.com/Doochukbeni/lephlo-crm"
  --label "org.opencontainers.image.revision=$SHA"
  --label "org.opencontainers.image.version=${RELEASE:-sha-$SHORT}"
  --load)
[[ -n "$BUILDER" ]] && build+=(--builder "$BUILDER")
for tag in "${TAGS[@]}"; do build+=(--tag "$tag"); done
"${build[@]}" .

scan "${TAGS[0]}" "sha-$SHORT"

if $PUSH; then
  step "Push to GHCR"
  gh auth token | docker login ghcr.io -u "$(gh api user -q .login)" --password-stdin > /dev/null \
    || fail "GHCR login failed. Run: gh auth refresh -h github.com -s write:packages"
  for tag in "${TAGS[@]}"; do docker push --quiet "$tag"; done
  digest="$(docker inspect --format '{{index .RepoDigests 0}}' "${TAGS[0]}")"
  echo
  echo "Pushed. Pin production to one of:"
  for tag in "${TAGS[@]}"; do echo "  LEPHLO_TAG=${tag#"$IMAGE:"}"; done
  echo "Digest: $digest"
  remind_if_private
else
  echo
  echo "Built and scanned locally. Add --push to publish."
fi

printf '\n\033[32m✔ Done\033[0m\n'
