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
| Hetzner Storage Box (BX11), SSH support on | Hetzner console → Storage Boxes | encrypted off-site backups (see Off-site backups) |
| healthchecks.io, UptimeRobot, Sentry (free) | sign up with the owner's email | alerts (see Monitoring and alerts) |

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
| Storage Box user + password | vault (and the server's rclone config, obscured) | Yearly: change it in the Hetzner console, then rerun `setup-offsite.sh … --recover` |
| Off-site encryption password + salt | vault only | Never. Changing them makes the existing off-site backups unreadable |
| healthchecks.io ping URLs | `.env` | Only if leaked (they can only report, not read) |

Never put any of these in a repo or a chat. The fork is public.

## Deploying a new image

```bash
lephlo/deploy/build-image.sh --push                       # prints sha-<commit>
lephlo/deploy/deploy.sh deploy@<server-ip> sha-<commit>
```

`deploy.sh` does the following:
- checks the tag is pinned and publicly pullable
- reads the Twenty version from both images' labels
- copies the current compose file and scripts to the server
- **runs a backup**
- switches `LEPHLO_TAG`, then pulls and restarts the server and worker
- waits for the server to be healthy
- smoke-checks `https://crm…/healthz`, the Lephlo page title and `https://sign…`

Each deploy is a line in `/opt/lephlo/deploy/deploys.log` (time, old tag, new tag, backup). Afterwards, update `LEPHLO_TAG` in the vault copy of `.env`.

**Upgrading Twenty** (merging an upstream release, see `../../LEPHLO_PATCHES.md`) changes the Twenty minor version, and its database migrations only go forward. So:
1. Upgrade one minor version at a time. `deploy.sh` refuses a skipped or reversed minor version.
2. Test the new image on staging with a copy of production data: `staging.sh up <tag>`.
3. Deploy with `--staged`, which `deploy.sh` requires whenever the Twenty minor version changes.

## Staging

A throwaway copy of production on its own Hetzner server, for testing a Twenty upgrade or a risky change on real data. It costs a few cents an hour.

```bash
export LEPHLO_PROD=deploy@<prod-ip>
lephlo/deploy/staging.sh up sha-<candidate>   # or no tag: production's image only
lephlo/deploy/staging.sh status
lephlo/deploy/staging.sh down                 # always, the same day
```

`up` does the following:
1. Creates `lephlo-staging` with no Hetzner backups.
2. Copies last night's production backup to it, streamed through your laptop and never written to its disk.
3. Installs production's current image on `https://crm-<ip>.sslip.io`, which gets TLS with no DNS change.
4. Restores the backup.
5. With a tag, deploys the candidate through `deploy.sh`, which runs the real migrations.

Log in with your production account and test.

**Staging holds client data and production's keys**, so `up` locks it down before copying anything:
- Outbound traffic to the production server is rejected from the host and from containers. The restored Documenso settings, app variables and webhooks still point at production, and they must not reach it. `up` proves the block from inside a container first.
- Outbound SMTP is rejected and the SMTP host points nowhere, so no email reaches a client.
- Google login and Gmail/Calendar sync are off. Backups stay on the box, never in the off-site store.
- It powers itself off after 24 hours. A powered-off server still costs money and holds data until `down`, and `up` refuses while one exists.
- Its Documenso starts empty, so signing on staging only works with a test document.

Never share the sslip.io URL.

## Monthly restore test

Backups are only real if they restore. On the first Monday of each month (a calendar reminder; there's no cron because Actions is off), run:

```bash
LEPHLO_PROD=deploy@<prod-ip> lephlo/deploy/staging.sh restore-test
```

It brings staging up from last night's backup and prints row counts for the CRM's main tables and the app's tables, production next to the restored copy. It **fails** if a table that has rows in production comes back empty, or if fewer than 90% of the rows came back. Then it deletes staging, pass or fail. Each result is appended to `lephlo/deploy/out/restore-tests.log`.

Targets: data loss at most 24 hours (nightly backup), back online within 4 hours (new server + restore).

## Off-site backups

The nightly backup also goes, **encrypted**, to a Hetzner Storage Box in another data centre. rclone crypt encrypts file names and contents on the server, so Hetzner only ever holds ciphertext. The Storage Box keeps the newest 7 daily, 4 weekly (Sundays) and 6 monthly (the 1st) copies. Each upload is verified against the local files through the encryption before old copies are pruned.

**Once:**
1. Order a Storage Box (BX11, about EUR 4/month, in a different location from the server).
2. Turn on **SSH support** in its settings.
3. Run:

```bash
lephlo/deploy/provision/setup-offsite.sh deploy@<server-ip> u123456
```

It asks for the Storage Box password, writes the rclone config for the `deploy` user (with the Storage Box host key pinned), proves a round trip, and turns the copy on in `.env`. It **prints two encryption passwords once**. Put them in the vault immediately: without them nobody can read the off-site backups, including you.

Hetzner's own daily server backups (turned on by `create-server.sh`) are a second, separate layer.

## Monitoring and alerts

Every alert goes to the owner's email. All of these are on free tiers.

| What | Service | Set up |
|---|---|---|
| The nightly backup ran and succeeded | healthchecks.io check **lephlo-backup**: period 1 day, grace 2 hours | Put its ping URL in `HEALTHCHECKS_BACKUP_URL`. `backup.sh` pings `/start`, then success or `/fail` with the error |
| Server health | healthchecks.io check **lephlo-host**: period 10 minutes, grace 20 minutes | Put its ping URL in `HEALTHCHECKS_HOST_URL`. `host-check.sh` runs every 10 minutes and reports `/fail` with the list of problems: disk over 80%, under 10% memory free, 15-minute load over 2 per core, any container stopped or unhealthy, a TLS certificate under 14 days, or the last backup over 26 hours old. A dead server sends nothing, which alerts as well |
| Reachable from the internet | UptimeRobot (or Better Stack): HTTP monitors every 5 minutes on `https://crm.lephlo.com/healthz`, a keyword monitor for "Lephlo" on `https://crm.lephlo.com/`, and `https://sign.lephlo.com/` | In their dashboard |
| Errors in the CRM | Sentry (free): one project for the server, one for the front end | `EXCEPTION_HANDLER_DRIVER=SENTRY`, `SENTRY_DSN`, `SENTRY_FRONT_DSN`, then `deploy.sh` (or `docker compose up -d`) |

After editing `.env` on the server, `docker compose up -d` picks up the Sentry values. The two healthchecks URLs are read by the scripts on their next run. Staging blanks both URLs, so it can never report on production's behalf.

**Check the alerts work, once:**
- `ssh deploy@<ip> 'sudo systemctl stop lephlo-host-check.timer'`: the "lephlo-host" email arrives within 30 minutes. Start the timer again afterwards.
- Stop the server in the Hetzner console: UptimeRobot emails.

## Security check

From your laptop, after the first install and after any change to the firewall, compose ports or `caddy/Caddyfile`:

```bash
lephlo/deploy/security-check.sh <server-ip>      # crm.lephlo.com / sign.lephlo.com by default
```

It checks the following:
- Only 22, 80 and 443 answer over IPv4 and IPv6. It probes database, Redis, Docker API and container ports, and runs a full 65535-port scan when `nmap` is installed.
- http redirects to https, and the certificates are valid.
- TLS 1.0 and 1.1 are refused.
- Caddy's security headers are present (HSTS for a year, nosniff, referrer policy, a small CSP, frame and permissions policies), and the `Server` header is hidden.

What the headers do is explained in `caddy/Caddyfile`. The CSP is deliberately small, so it doesn't break Twenty. If you tighten it, test the whole app first, including the front components.

## Disaster recovery (the server is gone)

Targets: data loss at most 24 hours, back online within 4 hours.

1. `provision/create-server.sh`, then point the Namecheap A records at the new IP.
2. Get `.env` from the vault into `lephlo/deploy/.env`, then run `provision/install.sh deploy@<new-ip>`. It starts an empty CRM.
3. `provision/setup-offsite.sh deploy@<new-ip> u123456 --recover`: it asks for the two encryption passwords from the vault.
4. Fetch the newest backup and restore it:
   ```bash
   ssh deploy@<new-ip>
   rclone lsf --dirs-only lephlo-offsite:daily | tail -1          # newest stamp
   rclone copy lephlo-offsite:daily/<stamp> /var/backups/lephlo/<stamp>
   cd /opt/lephlo/deploy && ./restore.sh /var/backups/lephlo/<stamp> --with-documenso
   ```
5. Put `secrets/documenso-cert.p12` back from the vault, so Documenso signs with the same certificate, then run `docker compose up -d documenso`.

If Hetzner's server backup still exists, restoring that whole server in the console is faster. Use the steps above when it doesn't.

## Rolling back

```bash
lephlo/deploy/rollback.sh deploy@<server-ip>
```

It puts the previous image back **and** restores the backup that `deploy.sh` took just before the deploy. The old image can't run on a migrated database, so the restore is required. Anything entered in the CRM since that deploy is lost, so it asks you to type the domain first. Documenso is untouched because a CRM deploy doesn't change it.

## Restoring a backup

On the server, from `/opt/lephlo/deploy`:

```bash
ls /var/backups/lephlo                                    # one folder per backup
./restore.sh /var/backups/lephlo/<stamp>                  # CRM database + files
./restore.sh /var/backups/lephlo/<stamp> --with-documenso # also the signing database
```

It checks the backup files, stops the CRM, recreates the database from the dump, replaces the files volume and starts everything again.

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
