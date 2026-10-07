# Deploying Lephlo CRM

One VPS (4 vCPU / 8 GB), Docker Compose. Services: Lephlo CRM server + worker, Postgres, Redis, Documenso (+ Postgres) and Caddy (TLS, rate limits on `/s/*`).

## First install

1. DNS: point `CRM_DOMAIN` and `SIGN_DOMAIN` A records at the VPS.
2. `cp .env.example .env`, then fill it in. Pin `LEPHLO_TAG` to an image pushed by `build-image.sh` (see below), and pin `DOCUMENSO_TAG` to a Documenso release.
3. Documenso signing certificate:
   ```bash
   mkdir -p secrets
   openssl req -x509 -newkey rsa:4096 -keyout secrets/key.pem -out secrets/cert.pem -days 3650 -nodes -subj "/CN=Lephlo Signing"
   openssl pkcs12 -export -out secrets/documenso-cert.p12 -inkey secrets/key.pem -in secrets/cert.pem -passout pass:"$DOCUMENSO_SIGNING_PASSPHRASE"
   rm secrets/key.pem
   ```
4. `docker compose up -d`, then open `https://$CRM_DOMAIN` and create the workspace. Set the workspace name to **Lephlo** and upload the logo under Settings → General.
5. Install the backup cron job from `backup.sh` and **do one restore test**.

## Upgrading

The server runs `upgrade` on start, so upgrade one Twenty minor version at a time:

1. Merge the upstream release into `lephlo` (see `../../LEPHLO_PATCHES.md`).
2. Build and push the image with `build-image.sh` (below).
3. Deploy to staging with a copy of production data.
4. Bump `LEPHLO_TAG` in production, then run `docker compose pull && docker compose up -d`.

## Building the image

GitHub Actions is off on this account, so the image is built from a workstation:

```bash
lephlo/deploy/build-image.sh --dry-run          # checks only: clean tree, tags
lephlo/deploy/build-image.sh                    # build + scan, keep it local
lephlo/deploy/build-image.sh --push             # build + scan + push sha-<commit>
git tag lephlo/v1.0.0 && git push origin lephlo/v1.0.0
lephlo/deploy/build-image.sh --release 1.0.0 --push   # also push lephlo-v1.0.0
```

- The build runs from a clean, committed tree. A pushed commit must already be on GitHub, so every image traces back to its source.
- **Trivy** (pinned by digest) writes a HIGH/CRITICAL report and an SPDX SBOM to `lephlo/deploy/out/`, and stops before pushing if a CRITICAL vulnerability has a fix. `--scan-only <image>` rescans an existing image, for example the one in production after a new CVE.
- Pushing needs the `write:packages` scope on your `gh` login. On the first `--push` the script notices it's missing and opens the GitHub sign-in to add it, before the build starts. After a push it tells you if the GHCR package is still private (GitHub has no API for that switch, so it prints the settings link).
- Production pins `LEPHLO_TAG` to a `sha-…` or `lephlo-v…` tag. Nothing like `latest` is pushed.

**Build machine.** The image is `linux/amd64`, and the front-end build needs about 8 GB of memory. On an Apple Silicon Mac it runs under emulation and can take more than an hour, or fail for lack of memory. A temporary amd64 box is faster:

```bash
hcloud server create --name lephlo-builder --type cpx41 --image docker-ce --location fsn1 --ssh-key <key>
docker buildx create --name lephlo-amd64 --driver docker-container ssh://root@<builder-ip>
lephlo/deploy/build-image.sh --builder lephlo-amd64 --push
docker buildx rm lephlo-amd64 && hcloud server delete lephlo-builder   # about EUR 0.05 per build
```

Don't build on the production server: the build competes with the running CRM for memory.

## Notes

- `LOGIC_FUNCTION_TYPE=LOCAL` is set in the compose file. Without it the production image won't run app code.
- The Documenso env var names follow its self-hosting docs. Check them against the release notes whenever you change `DOCUMENSO_TAG`.
