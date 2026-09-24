# Lephlo patch set

This repository is a fork of [twentyhq/twenty](https://github.com/twentyhq/twenty), used to run **Lephlo CRM**. It carries only a small branding and operations patch set. All product features live in a separate Twenty app (`lephlo-os`) built on the SDK.

**Rules**

- No features and no schema changes in this repo. They belong in the app. Fork-only upgrade commands inside upstream's version folders get silently skipped.
- Every changed upstream file is listed below. If you touch a new upstream file, add it here in the same PR.
- New Lephlo-only files go in `lephlo/`, `packages/twenty-front/src/lephlo/` or `.github/workflows/lephlo-*` so merges rarely conflict.

## Branches

| Branch | Purpose |
|---|---|
| `main` | Untouched mirror of upstream `main` |
| `lephlo` (default) | Latest upstream **release tag** + this patch set; production builds come from here |
| `feat/…`, `fix/…`, `chore/upstream-vX.Y.Z` | Work branches, merged into `lephlo` by PR |

Base release: **twenty/v2.42.6** (Twenty 2.42.0).

## Changed upstream files

### Branding
| File | Change |
|---|---|
| `packages/twenty-front/index.html` | Title, description, OG tags, theme colour |
| `packages/twenty-front/public/manifest.json` | App name, theme colour |
| `packages/twenty-front/public/images/icons/**` (112 PNGs) | Regenerated from `lephlo/brand/logo.svg` by `lephlo/scripts/generate-icons.sh` |
| `packages/twenty-front/src/index.tsx` | One import: `./lephlo/lephlo-theme.css` |
| `packages/twenty-front/src/utils/title-utils.ts` | Default page title |
| `packages/twenty-front/src/pages/not-found/NotFound.tsx` | Page title |
| `packages/twenty-front/src/pages/auth/SignInUp.tsx` | "Welcome to Lephlo" |
| `packages/twenty-front/src/modules/auth/sign-in-up/components/FooterNote.tsx` | Twenty's legal links replaced by "Powered by Twenty · Source code" (AGPL §13) |
| `packages/twenty-front/src/modules/auth/sign-in-up/components/SignInUpStandardContent.tsx` | Drops the removed `secondaryAgreement` prop |
| `packages/twenty-front/src/modules/ui/navigation/navigation-drawer/constants/DefaultWorkspaceLogo.ts` | Self-hosted default logo |
| `packages/twenty-front/src/modules/settings/hooks/useSettingsNavigationItems.tsx` | Hides Community and Documentation |
| `packages/twenty-emails/src/components/{Logo,Footer,BaseHead,WhatIsTwenty}.tsx` | Email logo, footer, title, invite blurb |
| `packages/twenty-emails/src/constants/DefaultWorkspaceLogo.ts` | Email default logo |
| `packages/twenty-emails/src/emails/{send-invite-link,password-update-notify,send-email-verification-link}.email.tsx` | Product name in copy |
| `packages/twenty-server/src/engine/core-modules/email-verification/services/email-verification.service.ts` | Email subject |
| `packages/twenty-server/src/engine/core-modules/workspace-invitation/services/workspace-invitation.service.ts` | Invite subject and sender name |

Translation catalogs (`*.po`) are **not** regenerated here. Changed strings fall back to the English source text in other locales.

### CI
| File | Change |
|---|---|
| `.github/workflows/*` (24 deleted) | twentyhq-only deploys, dispatchers, Crowdin i18n sync, Claude jobs, merge queue, release creation |
| `.github/workflows/{ci-front,ci-e2e-main,ci-create-app-e2e-minimal}.yaml` | `ubuntu-latest-{4,8}-cores` → `ubuntu-latest` (paid large runners aren't available) |

### Build hygiene
| File | Change |
|---|---|
| `packages/twenty-ui/package.json` | Key order normalized to what `yarn install` writes. The v2.42.6 tag ships it unsorted, which fails CI's "no uncommitted changes after build" check. Drop this patch if upstream fixes it. |

## Lephlo-only files
- `lephlo/brand/`: logo source (placeholder monogram) and email logo PNG
- `lephlo/scripts/generate-icons.sh`: regenerates every app icon from the logo
- `lephlo/deploy/`: production Docker Compose (CRM + Documenso + Caddy), env template, backup script
- `packages/twenty-front/src/lephlo/`: brand theme CSS, source-code URL constant
- `.github/workflows/lephlo-build-image.yaml`: builds and pushes `ghcr.io/doochukbeni/lephlo-crm`

## Syncing a new upstream release

```bash
git fetch upstream --tags
git switch -c chore/upstream-v2.43.x lephlo
git merge twenty/v2.43.x          # one minor version at a time
# resolve conflicts using the table above, then:
./lephlo/scripts/generate-icons.sh        # if upstream changed icons
npx nx build twenty-shared --skip-nx-cache
npx nx typecheck twenty-front && npx nx typecheck twenty-server
```

Open a PR into `lephlo`. After CI builds the image, deploy it to staging with a copy of production data, then promote to production.
