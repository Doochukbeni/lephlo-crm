# Lephlo patch set

This repository is a fork of [twentyhq/twenty](https://github.com/twentyhq/twenty), used to run **Lephlo CRM**. It carries only a small branding and operations patch set. All product features live in a separate Twenty app (`lephlo-os`) built on the SDK.

**Rules**

- No features and no schema changes in this repo. They belong in the app. Fork-only upgrade commands inside upstream's version folders get silently skipped.
- Every changed upstream file is listed below. If you touch a new upstream file, add it here in the same PR.
- New Lephlo-only files go in `lephlo/` or `packages/twenty-front/src/lephlo/` so merges rarely conflict.
- GitHub Actions is **disabled** on this repository (billing). The upstream workflows below stay in the tree only to keep merges clean; they never run. Checks and image builds run locally.

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
| `packages/twenty-front/public/images/icons/**` (112 PNGs) | The Lephlo mark on the kit's light surface (`#F2F5F6`) with ¼ clearspace, generated from `lephlo/brand/lephlo-mark.svg` by `lephlo/scripts/generate-icons.sh` |
| `packages/twenty-front/src/index.tsx` | One import: `./lephlo/lephlo-theme.css` (accent scale from the brand palette: aqua highlights, AA-safe deep teal `#467A80` for filled controls) |
| `packages/twenty-front/src/utils/title-utils.ts` (+ `__tests__/title-utils.test.ts`) | Default page title |
| `packages/twenty-front/src/pages/not-found/NotFound.tsx` | Page title |
| `packages/twenty-front/src/pages/auth/SignInUp.tsx` | "Welcome to Lephlo" |
| `packages/twenty-front/src/modules/auth/components/Logo.tsx` | Default auth logo → Lephlo lockup (`src/lephlo/LephloLockup.tsx`); the workspace badge is dropped (single workspace) |
| `packages/twenty-front/src/modules/auth/components/Title.tsx` | Auth and onboarding titles use `--lephlo-font-heading` (Poppins Bold) |
| `packages/twenty-front/src/modules/ui/layout/page/components/HeaderIdentifier.tsx` | Record-page title (`lg` size only) uses `--lephlo-font-heading` (Poppins Bold); side-panel titles stay Inter |
| `packages/twenty-front/src/modules/settings/data-model/constants/SettingsFieldCurrencyCodes.ts` | AED uses `src/lephlo/IconCurrencyUaeDirham.tsx` (the 2025 UAE dirham symbol) instead of Tabler's "د.إ" icon, which read as "⅃⁾" |
| `packages/twenty-front/public/images/integrations/twenty-logo.svg` | Content replaced by the Lephlo mark on a square tile with ¼ clearspace (the file name stays so its four users need no patch: loading pulse, onboarding header, app-connection header, import badge) |
| `packages/twenty-front/src/modules/activities/timeline-activities/utils/getTimelineActivityAuthorFullName.ts` (+ test) | System actor in timelines: "Twenty" → "Lephlo" |
| `packages/twenty-front/src/modules/navigation-menu-item/edit/hooks/useNavigationMenuItemAddOptions.tsx` | New sidebar link defaults to Lephlo / lephlo.com |
| `packages/twenty-front/src/modules/spreadsheet-import/steps/components/MatchColumnsStep/components/ColumnGrid.tsx` | "Lephlo fields" |
| `packages/twenty-front/src/pages/settings/ai/components/{SettingsAiModelsTab,SettingsAiModelTiersPreview}.tsx` | AI settings copy says Lephlo |
| `packages/twenty-front/src/pages/settings/communications/SettingsWorkspaceCommunicationGroupChannelDetail.tsx` | "Lephlo checks them automatically" |
| `packages/twenty-front/src/modules/auth/sign-in-up/components/FooterNote.tsx` | Twenty's legal links replaced by "Powered by Twenty · Source code" (AGPL §13) |
| `packages/twenty-front/src/modules/auth/sign-in-up/components/SignInUpStandardContent.tsx` | Drops the removed `secondaryAgreement` prop |
| `packages/twenty-front/src/modules/ui/navigation/navigation-drawer/constants/DefaultWorkspaceLogo.ts` | Self-hosted default logo |
| `packages/twenty-front/src/modules/settings/hooks/useSettingsNavigationItems.tsx` | Hides Community and Documentation |
| `packages/twenty-emails/src/components/{Logo,Footer,BaseHead,WhatIsTwenty}.tsx` | Email logo, footer, title, invite blurb |
| `packages/twenty-emails/src/constants/DefaultWorkspaceLogo.ts` | Email default logo |
| `packages/twenty-emails/src/emails/{send-invite-link,password-update-notify,send-email-verification-link}.email.tsx` | Product name in copy |
| `packages/twenty-server/src/engine/core-modules/email-verification/services/email-verification.service.ts` | Email subject |
| `packages/twenty-server/src/engine/core-modules/workspace-invitation/services/workspace-invitation.service.ts` | Invite subject and sender name |
| `packages/twenty-server/src/engine/core-modules/approved-access-domain/services/approved-access-domain.service.ts` | Sender name "(via Lephlo)" |

**Kept on purpose (not branding):** "Powered by Twenty · Source code" (AGPL §13); MCP and CLI names and setup copy (they name the real Twenty MCP server and CLI); the standard-application description; billing, enterprise, DPA and community copy (not shown on a self-hosted install).

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
| `packages/twenty-client-sdk/src/metadata/generated/types.ts` | One regenerated type index (`completeAppTarballUpload` 76 → 78). The tag's generated SDK client is stale, which fails CI's codegen check. Drop it when upstream regenerates. |

## Lephlo-only files
- `lephlo/brand/`: SVG masters from the Lephlo Brand Guidelines v1.0 (mark, horizontal lockup and wordmark, light and dark) plus the email logo PNG. Never recolour, rotate or add effects to the mark. The full kit lives in the `lephlo-os` repo under `brand/`.
- `lephlo/scripts/generate-icons.sh`: regenerates every app icon from the logo
- `lephlo/deploy/`: production Docker Compose (CRM + Documenso + Caddy), env template, backup script
- `packages/twenty-front/src/lephlo/`: brand theme CSS (accent scale, lockup dark-mode switch, Poppins `@font-face`), `LephloLockup.tsx`, `IconCurrencyUaeDirham.tsx`, source-code URL constant
- `packages/twenty-front/public/images/lephlo/`: lockup SVGs (light and reversed)
- `packages/twenty-front/public/fonts/lephlo/`: Poppins Bold + its OFL licence
- `lephlo/deploy/provision/`: Hetzner server creation (`create-server.sh`, `cloud-init.yaml`), `.env` generator (`make-env.sh`) and first install (`install.sh`), all run from a laptop
- `lephlo/deploy/deploy.sh`, `rollback.sh`, `restore.sh`: deploy an image with a backup first, undo the last deploy (previous image + pre-deploy backup), restore any backup on the server
- `lephlo/deploy/staging.sh`: on-demand staging from the latest backup, cut off from production and email; `restore-test` for the monthly backup proof
- `lephlo/deploy/build-image.sh`: builds, scans (Trivy + SBOM) and pushes `ghcr.io/doochukbeni/lephlo-crm` from a workstation

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
