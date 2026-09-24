# Deploying Lephlo CRM

One VPS (4 vCPU / 8 GB), Docker Compose. Services: Lephlo CRM server + worker, Postgres, Redis, Documenso (+ Postgres) and Caddy (TLS, rate limits on `/s/*`).

## First install

1. DNS: point `CRM_DOMAIN` and `SIGN_DOMAIN` A records at the VPS.
2. `cp .env.example .env`, then fill it in. Pin `LEPHLO_TAG` to an image built by the *Lephlo — build image* workflow, and pin `DOCUMENSO_TAG` to a Documenso release.
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
2. Wait for CI to build the image.
3. Deploy to staging with a copy of production data.
4. Bump `LEPHLO_TAG` in production, then run `docker compose pull && docker compose up -d`.

## Notes

- `LOGIC_FUNCTION_TYPE=LOCAL` is set in the compose file. Without it the production image won't run app code.
- The Documenso env var names follow its self-hosting docs. Check them against the release notes whenever you change `DOCUMENSO_TAG`.
