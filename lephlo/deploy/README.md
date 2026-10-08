# Deploying Lephlo CRM

One VPS (4 vCPU / 8 GB), Docker Compose. Services: Lephlo CRM server + worker, Postgres, Redis, Documenso (+ Postgres) and Caddy (TLS, rate limits on `/s/*`).

## First install

Everything below runs from your laptop. Scripts live in `provision/`.

### 0. What you need first (owner)

| Item | Where | Used for |
|---|---|---|
| Hetzner Cloud project + API token (read & write) | console.hetzner.com → project → Security → API tokens | `hcloud context create lephlo` (asks for it; stored in `~/.config/hcloud/cli.toml`, never in a repo) |
| `hcloud` CLI | `brew install hcloud` | `create-server.sh` |
| Deploy SSH key | `ssh-keygen -t ed25519 -f ~/.ssh/lephlo_deploy -C lephlo-deploy` (with a passphrase) | the `deploy` user; root login is off |
| Two A records | Namecheap → lephlo.com → Advanced DNS: `crm` and `sign` → the server IP | Caddy's TLS certificates. Nothing else in the zone changes |
| Resend API key + verified `lephlo.com` sender | resend.com → Domains (adds SPF/DKIM TXT records at Namecheap) | invite, verification and signing emails (`EMAIL_SMTP_PASSWORD`) |
| Google OAuth client, type **Internal** | Google Cloud console → APIs & Services → Credentials; redirect URIs `https://crm.lephlo.com/auth/google/redirect` and `https://crm.lephlo.com/auth/google-apis/get-access-token` | Google login + Gmail/Calendar sync (optional on day one) |
| Password vault | 1Password / Bitwarden | master copy of `.env`, the Documenso certificate, the deploy key |

### 1. Create the server

```bash
lephlo/deploy/provision/create-server.sh --dry-run   # checks token, key, type
lephlo/deploy/provision/create-server.sh             # cpx31, fsn1, daily backups
```

It uploads the SSH key, creates the `lephlo-web` firewall (in: 22, 80, 443, ping) and the server from `provision/cloud-init.yaml`, turns on Hetzner backups, waits for first boot and prints the IP. What the server gets on first boot is:
- Docker with Compose
- a `deploy` user (key-only login)
- root and password login switched off
- ufw and fail2ban
- daily security updates, with a 04:00 reboot when a kernel update needs one
- 4 GB swap
- capped Docker logs

Then add the two A records at Namecheap.

### 2. Make the `.env`

```bash
lephlo/deploy/provision/make-env.sh    # writes lephlo/deploy/.env (mode 600, git-ignored)
```

It generates every database password and encryption key and lists what you still need to fill in:
- `LEPHLO_TAG`: an image pushed by `build-image.sh`
- `DOCUMENSO_TAG`: a Documenso release, never `latest`
- `ACME_EMAIL`
- the Resend key
- optional: Google, Anthropic, Sentry

**Copy the finished file into the vault before going on.**

### 3. Install

```bash
lephlo/deploy/provision/install.sh deploy@<server-ip>
```

It refuses to start if:
- `.env` is incomplete
- the image isn't publicly pullable
- the domains don't resolve to the server yet (Let's Encrypt rate-limits failed attempts)

Then it does the following:
- copies the stack to `/opt/lephlo/deploy`
- creates the Documenso signing certificate on the server
- starts everything and waits for the CRM to be healthy (the first start runs the database migrations)
- installs the nightly backup timer (03:00 UTC)
- checks that `https://crm.lephlo.com` answers with the Lephlo title

### 4. Set up the workspace (by hand, once)

1. Open `https://crm.lephlo.com` and sign up. The first account creates the workspace and becomes its admin. The compose file then limits workspace creation to server admins.
2. Settings → General: workspace name **Lephlo**, upload `lephlo/brand/lephlo-mark.svg` as the logo.
3. Settings → Security: turn on 2FA for the admin and limit sign-up to invited `@lephlo.com` addresses. Settings → Roles: everyone else gets the restricted member role.
4. Settings → Accounts: connect Google (login + Gmail/Calendar sync) once the OAuth client is in `.env`.
5. Tidy the sidebar: remove Opportunities, Notes, Dashboards and Workflows (Lephlo's Deals, Home and Onboarding replace them).
6. Run the first backup and **one restore test**:
   ```bash
   ssh deploy@<ip> 'sudo systemctl start lephlo-backup && journalctl -u lephlo-backup -n 5'
   ```
7. Save `secrets/documenso-cert.p12` from the server into the vault, next to `.env`.

### Secrets inventory

| Secret | Lives in | Rotate |
|---|---|---|
| `.env` (DB passwords, `ENCRYPTION_KEY`, Documenso keys, SMTP/Google/Anthropic keys) | server `/opt/lephlo/deploy/.env` (600) + vault | SMTP/Google/Anthropic keys yearly or on staff change. `ENCRYPTION_KEY`: only via `FALLBACK_ENCRYPTION_KEY` (set the old one there, restart, then remove). DB passwords: change in Postgres first, then `.env` |
| Documenso signing certificate + passphrase | server `secrets/documenso-cert.p12` + vault | Before it expires (10 years). Old signed PDFs stay valid |
| Deploy SSH key | your laptop `~/.ssh/lephlo_deploy` + vault | On laptop change. Add the new key to `~deploy/.ssh/authorized_keys` before removing the old one |
| Hetzner API token | `~/.config/hcloud/cli.toml` + vault | Yearly, or when a laptop is lost |
| GHCR push token | your `gh` login (`write:packages` scope) | Follows your GitHub login |

Never put any of these in a repo or a chat. The fork is public.

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
