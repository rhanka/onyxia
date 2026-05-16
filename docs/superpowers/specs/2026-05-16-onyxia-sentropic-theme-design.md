# Design — Align Onyxia look & feel with the `@sentropic` design system

**Status:** Brainstorm, ready for review
**Branch:** `brainstorm/sentropic-theme`
**Related work:** `helm-chart/examples/gke-ephemeral/`, sent-tech-forge main site

## Context

The sent-tech-forge main site uses the in-house `@sentropic/design-system-themes` package (npm). The Onyxia instance at `https://onyxia.sent-tech.ca` shows up with the default InseeFrLab look — incoherent next to the rest of the platform. The user wants the same palette, typography, and chrome on Onyxia.

Onyxia frontend (`inseefrlab/onyxia-web`) reads a fixed set of theme env vars at boot time:

| Env var | Purpose |
|---|---|
| `HEADER_LOGO` | top-left logo URL |
| `HEADER_TEXT_BOLD` / `HEADER_TEXT_FOCUS` | the two-word title displayed in the header |
| `TAB_TITLE` | browser tab title |
| `FAVICON` | tab icon |
| `PALETTE_OVERRIDE` | JSON blob, both light + dark in one shot |
| `PALETTE_OVERRIDE_LIGHT` / `PALETTE_OVERRIDE_DARK` | split version of the above |
| `FONT` | inline JSON: `{ fontFamily, dirUrl, "400": …, "500": …, "600": …, "700": … }` |
| `BACKGROUND_ASSET` | optional decorative background |
| `TERMS_OF_SERVICES` | URL to the platform's ToS |

These are surfaced to the browser via the OIDC URL — we already see them in the Keycloak redirect. They are the official Onyxia theming surface; nothing prevents us from wiring them through.

## Goal

- Same palette, primary/secondary colors, surface colors, typography on `onyxia.sent-tech.ca` as on the sent-tech-forge home.
- Logo + header text match.
- Light + dark mode both consistent.
- Zero fork of `onyxia-web`, no custom Docker image, all driven from helm values.
- Tokens stay sourced from one place: the `@sentropic/design-system-themes` npm package. When the design system bumps, our Onyxia bumps too.

## Chosen approach: tokens-via-env-vars, generated at deploy time

A tiny Node script (`scripts/sentropic-to-onyxia-theme.mjs`) reads `@sentropic/design-system-themes` (installed once as a devDependency at example level), produces:

- a `PALETTE_OVERRIDE_LIGHT` JSON string,
- a `PALETTE_OVERRIDE_DARK` JSON string,
- a `FONT` JSON string,
- a `HEADER_LOGO` / `TAB_TITLE` / `FAVICON` triplet,

and writes them into `onyxia-private-values.local.yaml` (or its `.tmpl`). The Onyxia chart picks them up via the existing `web.env` block.

Trade-offs vs. rejected alternatives:

| | Tokens via env vars (chosen) | Fork onyxia-ui | Runtime theme loader |
|---|---|---|---|
| Time to first pixel | ~1 hour | ~1 week | weeks (upstream PR) |
| Onyxia code change | none | fork onyxia-ui + onyxia-web | upstream PR |
| Coverage | colors, fonts, logo, header strings | full component custom | full theming |
| Custom components (drawer shape, button radius, …) | no | yes | partial |
| Maintenance | redeploy when sentropic bumps | track upstream onyxia-web AND sentropic | track upstream |
| Cost / image weight | 0 | custom image | 0 |

The tokens path covers everything the user actually mentioned ("aligner le theme du site principal"). If later we need custom layout / shape, the fork path is a separable follow-up — it does not invalidate this work.

## Architecture

```
@sentropic/design-system-themes (npm)
        │
        ▼ at deploy time
┌──────────────────────────────────┐
│ scripts/sentropic-to-onyxia.mjs  │   reads tokens.light.colors, …
│                                  │   prints JSON for each Onyxia env var
└──────────────┬───────────────────┘
               │
               ▼
   onyxia-private-values.local.yaml
   (web.env.PALETTE_OVERRIDE_LIGHT = "{…}",
    web.env.PALETTE_OVERRIDE_DARK  = "{…}",
    web.env.FONT                   = "{…}",
    web.env.HEADER_LOGO            = "https://cdn.sent-tech.ca/logo.svg",
    web.env.HEADER_TEXT_BOLD       = "sent-tech",
    web.env.HEADER_TEXT_FOCUS      = "Datalab",
    web.env.TAB_TITLE              = "sent-tech · Onyxia",
    web.env.FAVICON                = "https://cdn.sent-tech.ca/favicon.svg")
               │
               ▼
       helm release onyxia upgrade
               │
               ▼
       browser: same look as sent-tech-forge
```

### Pieces

1. **`scripts/sentropic-to-onyxia.mjs`** — Node ESM script, ~80 lines. Imports tokens from `@sentropic/design-system-themes` (installed locally), maps them to the Onyxia palette shape (`focus`, `light.surfaces`, `light.text`, `light.surface`, `dark.…`, see `onyxia-ui/src/lib/Theme.tsx` of `inseefrlab/onyxia-ui` for the schema). Outputs the YAML fragment to stdout or in-place updates a values file.
2. **A tiny `npm` setup** at `helm-chart/examples/gke-ephemeral/theme/` with `package.json` declaring `@sentropic/design-system-themes` as a regular dep (so the user's `npm install` resolves it).
3. **`scripts/_load_env.sh`** — extended to call the theme generator before `tofu apply`. Optional (gated by `ENABLE_SENTROPIC_THEME=true`).
4. **`.env.local.example`** — three extra vars: `SENTROPIC_HEADER_LOGO_URL`, `SENTROPIC_HEADER_TEXT_BOLD`, `SENTROPIC_HEADER_TEXT_FOCUS`. (TAB_TITLE / FAVICON derived from them.)
5. **README** — short section "Brand it" explaining how to swap to a different design system if you don't use sentropic.

### Mapping table (Onyxia ← sentropic)

| Onyxia key | Sentropic token | Notes |
|---|---|---|
| `focus.light` | `tokens.color.brand.primary.500` | the active link/button color |
| `focus.dark` | `tokens.color.brand.primary.300` | dark mode equivalent |
| `light.surfaces` | `tokens.color.neutral.0` / `25` | page background |
| `light.surface` | `tokens.color.neutral.50` | card background |
| `light.text` | `tokens.color.neutral.900` | body text |
| `dark.surfaces` / `dark.surface` / `dark.text` | symmetric dark scale | |
| `FONT.fontFamily` | `tokens.typography.fontFamily.sans` | exact name |
| `FONT.dirUrl` | a public CDN URL under `cdn.sent-tech.ca/fonts` | hosted out of band |

The mapping table is a contract — when sentropic changes a token name, the script breaks loud (we read by path).

## Open questions

1. **Where do the font woff2 files live?** Onyxia needs them on a CDN reachable from the browser. We can either re-host on `cdn.sent-tech.ca` (preferred) or point straight at the npm package's `dist/fonts/` (only works if it's on a public CDN like jsdelivr — fine for a test instance).
2. **Logo & favicon hosting.** Same question. Default: `cdn.sent-tech.ca/onyxia-logo.svg`, supplied as a GH var (`SENTROPIC_HEADER_LOGO_URL`).
3. **Light / dark default.** Onyxia toggles based on OS preference. Are we OK with that or do we force light? Default: respect OS, just match colors.
4. **Custom component shape.** Buttons in `@sentropic` may be pill-shaped while Onyxia's are rounded squares. Tokens cover colors only — shape diffs would need the fork path. Default: live with Onyxia's default shape for v1, document the gap.
5. **CI / pre-commit check.** Should the theme generation run in CI (workflow `onyxia-gke-ephemeral.yml`)? Default yes: as part of `_load_env.sh`, with the assumption that the npm package is published and reachable.

## Cost impact

- One extra ~5 KB JSON injected into the onyxia-web pod env. No runtime cost.
- npm install at deploy time: cached after the first run.

Expected delta on the example's daily cost: **$0**.

## Acceptance criteria for the implementation plan

1. After `mode=resume` with `ENABLE_SENTROPIC_THEME=true`, `https://onyxia.<hostname>` loads with the sent-tech-forge primary color, font family, and logo.
2. Dark mode toggle keeps the sentropic palette mapping.
3. Bumping `@sentropic/design-system-themes` to a new version and re-running `mode=resume` propagates the change with no other manual step.
4. With `ENABLE_SENTROPIC_THEME=false` (default), Onyxia keeps the InseeFrLab look — no regression.

## Next step

Once approved, invoke `superpowers:writing-plans` to slice the work into:
1. `scripts/sentropic-to-onyxia.mjs` + tests (mock npm package).
2. `_load_env.sh` extension.
3. `onyxia-private-values.local.yaml.tmpl` placeholders + values pipe.
4. README "Brand it" section.
5. GHA workflow step to run the generator in `init`/`resume`.
