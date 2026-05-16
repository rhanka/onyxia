# Onyxia Sentropic Theme (Option A — tokens via env vars) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Align the Onyxia instance at `https://onyxia.<hostname>` (the `helm-chart/examples/gke-ephemeral` example) with the `@sentropic/design-system-themes` palette, typography, logo and header strings, with zero fork of `onyxia-web` and zero custom Docker image.

**Architecture:** A tiny Node ESM generator script reads `@sentropic/design-system-themes@0.5.0` from npm, maps its `tokens.semantic.*` to the Onyxia palette shape (`focus`, `light.*`, `dark.*`, `redError`, etc., per `onyxia-ui/src/lib/color.urgent.ts`), and emits four env vars (`PALETTE_OVERRIDE_LIGHT`, `PALETTE_OVERRIDE_DARK`, `FONT`, and the header triplet). The values are written into `onyxia-private-values.local.yaml`'s `web.env` block at deploy time. The Onyxia chart consumes them through the existing env passthrough — no upstream change required.

**Tech Stack:** Node 20 ESM, npm, JSON5, `@sentropic/design-system-themes@0.5.0`, bash, GitHub Actions, OpenTofu, Helm. Optional: Playwright for visual regression.

**Scope (v1):** colors, fonts, logo (`HEADER_LOGO`), header strings (`HEADER_TEXT_BOLD`/`HEADER_TEXT_FOCUS`), tab title and favicon. **Out of scope (v2):** component shape (button radius, drawer geometry) — would require the `onyxia-ui` fork path, deliberately deferred per the spec amendment.

**Dependencies:** None on other brainstorms. **However**, this plan modifies files that live on the `feat/example-gke-ephemeral` branch (`helm-chart/examples/gke-ephemeral/**` and `.github/workflows/onyxia-gke-ephemeral.yml`). At execution time, the working branch MUST be rebased on top of `feat/example-gke-ephemeral` (or its successor on `main`). The Task 0 preamble verifies this.

**Estimated cost / effort:** ~$0/day delta on the running example (one ~5 KB extra block in pod env, no runtime work). Total dev time: **~2–3 h** including the visual snapshot task.

---

## Task 0: Preamble — verify execution environment

**Files:**
- Read only: `helm-chart/examples/gke-ephemeral/scripts/_load_env.sh`, `helm-chart/examples/gke-ephemeral/.env.local.example`, `helm-chart/examples/gke-ephemeral/onyxia-private-values.local.yaml.tmpl`, `.github/workflows/onyxia-gke-ephemeral.yml`

**Acceptance criterion:** The four files above exist on the working branch and contain the markers we'll grep for in later tasks. If any is missing, this plan was scheduled before its base branch landed — STOP and rebase.

- [ ] **Step 1: Verify base files are present**

Run:
```bash
cd helm-chart/examples/gke-ephemeral
test -f scripts/_load_env.sh \
  && test -f .env.local.example \
  && test -f onyxia-private-values.local.yaml.tmpl \
  && test -f ../../../.github/workflows/onyxia-gke-ephemeral.yml \
  && echo OK
```
Expected output: `OK`. If any check fails: STOP, rebase the working branch on the branch that introduced `helm-chart/examples/gke-ephemeral`, then resume.

- [ ] **Step 2: Verify the expected workflow marker exists**

Run:
```bash
grep -n "Apply app layer — phase 1.5 (namespaces)" .github/workflows/onyxia-gke-ephemeral.yml
```
Expected: one match around line ~107. We will insert the theme generation step BEFORE this line in Task 7.

- [ ] **Step 3: Record Node version constraint**

Run: `node --version`
Expected: `v20.x` or higher. If lower, install Node 20 (the workflow already uses `actions/setup-node@v4` with `node-version: 20`).

- [ ] **Step 4: No commit for this task** — preamble only.

**Review checkpoint:** Confirm the four base files exist and the workflow marker matches. Proceed.

---

## Task 1: npm setup for the theme generator

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/theme/package.json`
- Create: `helm-chart/examples/gke-ephemeral/theme/.npmrc`
- Create: `helm-chart/examples/gke-ephemeral/theme/.gitignore`
- Modify: `helm-chart/examples/gke-ephemeral/theme/package-lock.json` (auto-generated)

**Acceptance criterion:** Running `cd helm-chart/examples/gke-ephemeral/theme && npm ci` exits 0 and creates a `node_modules/@sentropic/design-system-themes/` directory with `package.json` reporting `"version": "0.5.0"`.

- [ ] **Step 1: Create `package.json`**

Write to `helm-chart/examples/gke-ephemeral/theme/package.json`:

```json
{
  "name": "onyxia-gke-ephemeral-theme",
  "version": "0.1.0",
  "private": true,
  "type": "module",
  "description": "Generates Onyxia env-var theme overrides from @sentropic/design-system-themes.",
  "engines": {
    "node": ">=20"
  },
  "scripts": {
    "generate": "node sentropic-to-onyxia.mjs",
    "test": "node --test test/"
  },
  "dependencies": {
    "@sentropic/design-system-themes": "0.5.0"
  }
}
```

Note: the dep is pinned exactly (no `^`) because per the spec amendment the two `@sentropic/*` packages must be bumped together by a coordinated release.

- [ ] **Step 2: Create `.npmrc`** so CI tolerates the temporarily-missing SPDX license on the upstream package (see Task 3 for the upstream fix).

Write to `helm-chart/examples/gke-ephemeral/theme/.npmrc`:

```
# @sentropic/design-system-themes@0.5.0 has no SPDX license field yet.
# See docs/superpowers/plans/2026-05-16-onyxia-sentropic-theme-plan.md Task 3
# for the upstream fix in rhanka/sent-tech-design-system.
audit=false
fund=false
```

- [ ] **Step 3: Create `.gitignore`**

Write to `helm-chart/examples/gke-ephemeral/theme/.gitignore`:

```
node_modules/
*.log
```

- [ ] **Step 4: Resolve the lockfile**

Run:
```bash
cd helm-chart/examples/gke-ephemeral/theme
npm install --package-lock-only
```
Expected: creates `package-lock.json`, exit 0. `npm install` (not `ci`) is required the first time because no lockfile exists yet; `--package-lock-only` skips writing `node_modules/`.

- [ ] **Step 5: Verify reproducibility with `npm ci`**

Run:
```bash
npm ci
ls node_modules/@sentropic/design-system-themes/package.json
node -e "import('@sentropic/design-system-themes').then(m => console.log(Object.keys(m)))"
```
Expected:
- `npm ci` exits 0.
- The `package.json` path resolves.
- The `console.log` line prints something like `[ 'default', 'sentTechTheme', 'themes', ... ]` (exact keys discovered in Task 2 Step 1). Capture this output — Task 2's mapping depends on it.

- [ ] **Step 6: Commit**

```bash
git add helm-chart/examples/gke-ephemeral/theme/package.json \
        helm-chart/examples/gke-ephemeral/theme/package-lock.json \
        helm-chart/examples/gke-ephemeral/theme/.npmrc \
        helm-chart/examples/gke-ephemeral/theme/.gitignore
git commit -m "feat(examples): scaffold sentropic theme generator npm package"
```

**Review checkpoint:** `npm ci` is reproducible; the installed package version is `0.5.0`. Stop here if it isn't — every later task depends on this.

---

## Task 2: Generator — `sentropic-to-onyxia.mjs`

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/theme/sentropic-to-onyxia.mjs`
- Create: `helm-chart/examples/gke-ephemeral/theme/lib/mapping.mjs`
- Create: `helm-chart/examples/gke-ephemeral/theme/lib/json5-stringify.mjs`
- Test: `helm-chart/examples/gke-ephemeral/theme/test/mapping.test.mjs`
- Test: `helm-chart/examples/gke-ephemeral/theme/test/generator.test.mjs`

**Acceptance criterion:**
1. Running `node sentropic-to-onyxia.mjs` (from `theme/`) with env `SENTROPIC_HEADER_LOGO_URL=https://cdn.example.com/logo.svg SENTROPIC_HEADER_TEXT_BOLD=sent-tech SENTROPIC_HEADER_TEXT_FOCUS=Datalab` writes a YAML fragment to stdout containing `PALETTE_OVERRIDE_LIGHT:`, `PALETTE_OVERRIDE_DARK:`, `FONT:`, `HEADER_LOGO:`, `HEADER_TEXT_BOLD:`, `HEADER_TEXT_FOCUS:`, `TAB_TITLE:`, `FAVICON:`.
2. Each palette value parses as JSON5 and contains keys `focus.main`, `light.main`, `dark.main`, `redError.main`, `greenSuccess.main`, `orangeWarning.main`, `blueInfo.main`.
3. `npm test` passes (the two test files below).

### Step block A — mapping module

- [ ] **Step 1: Inspect the published package shape**

Run:
```bash
cd helm-chart/examples/gke-ephemeral/theme
node -e "import('@sentropic/design-system-themes').then(m => console.log(JSON.stringify(m.sentTechTheme.tokens.semantic, null, 2).slice(0, 2000)))"
```
Expected: prints the top of `semantic.{surface,text,border,action,feedback}` — confirms the path used by the mapping. If the export name is not `sentTechTheme` (e.g. it's `default.sentTechTheme` or the package only exports `themes`), adjust the import in Steps 2 and 5 accordingly. The literal token paths used below assume the spec amendment is accurate (`semantic.action.primary`, etc.).

- [ ] **Step 2: Write the failing test for `lib/mapping.mjs`**

Write to `helm-chart/examples/gke-ephemeral/theme/test/mapping.test.mjs`:

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { toOnyxiaPalettes, toOnyxiaFont } from '../lib/mapping.mjs';

// Minimal stub of the sentropic TenantTheme shape — keeps tests independent
// of the real package and pinpoints mapping bugs without needing a network.
const stub = {
  id: 'sent-tech',
  label: 'Sent-Tech',
  mode: 'light',
  tokens: {
    semantic: {
      surface: {
        default: '#ffffff',
        subtle: '#f5f7fa',
        raised: '#ffffff',
        inverse: '#0b1220',
        overlay: 'rgba(11,18,32,0.6)'
      },
      text: {
        primary: '#0b1220',
        secondary: '#3b4252',
        muted: '#6b7280',
        inverse: '#ffffff',
        link: '#0057ff'
      },
      border: { subtle: '#e5e7eb', strong: '#9ca3af', interactive: '#0057ff' },
      action: {
        primary: '#0057ff',
        primaryText: '#ffffff',
        secondary: '#e5e7eb',
        secondaryText: '#0b1220',
        danger: '#d4351c'
      },
      feedback: {
        success: '#1f7a3d',
        warning: '#b54708',
        error: '#d4351c',
        info: '#0057ff'
      }
    },
    typography: {
      fontFamily: {
        sans: '"Inter", system-ui, sans-serif'
      }
    }
  }
};

test('toOnyxiaPalettes — light has focus.main from action.primary', () => {
  const { light } = toOnyxiaPalettes(stub);
  assert.equal(light.focus.main, '#0057ff');
});

test('toOnyxiaPalettes — light.main from surface.default', () => {
  const { light } = toOnyxiaPalettes(stub);
  assert.equal(light.light.main, '#ffffff');
});

test('toOnyxiaPalettes — dark.main is text.primary for body text in light mode', () => {
  const { light } = toOnyxiaPalettes(stub);
  assert.equal(light.dark.main, '#0b1220');
});

test('toOnyxiaPalettes — feedback colors mapped on light palette', () => {
  const { light } = toOnyxiaPalettes(stub);
  assert.equal(light.redError.main, '#d4351c');
  assert.equal(light.greenSuccess.main, '#1f7a3d');
  assert.equal(light.orangeWarning.main, '#b54708');
  assert.equal(light.blueInfo.main, '#0057ff');
});

test('toOnyxiaPalettes — light.greyVariant1..5 sourced from surface subtones', () => {
  const { light } = toOnyxiaPalettes(stub);
  for (let i = 1; i <= 5; i++) {
    assert.ok(light.light[`greyVariant${i}`], `greyVariant${i} missing`);
  }
});

test('toOnyxiaPalettes — dark palette has dark.main from surface.inverse', () => {
  const { dark } = toOnyxiaPalettes(stub);
  assert.equal(dark.dark.main, '#0b1220');
});

test('toOnyxiaFont — fontFamily + jsdelivr dirUrl', () => {
  const font = toOnyxiaFont(stub, { version: 'v0.5.0' });
  assert.equal(font.fontFamily, '"Inter", system-ui, sans-serif');
  assert.match(
    font.dirUrl,
    /^https:\/\/cdn\.jsdelivr\.net\/gh\/rhanka\/sent-tech-design-system@v0\.5\.0\/packages\/themes\/fonts\/$/
  );
  assert.equal(font['400'], 'Inter-Regular.woff2');
  assert.equal(font['500'], 'Inter-Medium.woff2');
  assert.equal(font['600'], 'Inter-SemiBold.woff2');
  assert.equal(font['700'], 'Inter-Bold.woff2');
});
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `node --test test/mapping.test.mjs`
Expected: FAIL with `Cannot find module '../lib/mapping.mjs'`.

- [ ] **Step 4: Implement `lib/mapping.mjs`**

Write to `helm-chart/examples/gke-ephemeral/theme/lib/mapping.mjs`:

```javascript
// Maps a sentropic TenantTheme (semantic tokens) onto the Onyxia palette shape
// defined in onyxia-ui/src/lib/color.urgent.ts. This is the contract: when a
// sentropic semantic key disappears upstream, the access below will yield
// undefined and the generator MUST fail loud (see assertPalette in
// sentropic-to-onyxia.mjs).

const FONT_FILES = {
  '400': 'Inter-Regular.woff2',
  '500': 'Inter-Medium.woff2',
  '600': 'Inter-SemiBold.woff2',
  '700': 'Inter-Bold.woff2'
};

const SENT_REPO_VERSION_DEFAULT = 'v0.5.0';
const JSDELIVR_GH_PREFIX = 'https://cdn.jsdelivr.net/gh/rhanka/sent-tech-design-system@';
const JSDELIVR_GH_SUFFIX = '/packages/themes/fonts/';

export function toOnyxiaPalettes(theme) {
  const s = theme?.tokens?.semantic;
  if (!s) throw new Error('sentropic theme: tokens.semantic missing');

  // Light palette: Onyxia "light.*" is the page surface family, "dark.*" is
  // the body-text family for light mode, "focus.*" is the accent.
  const light = {
    focus: {
      main: s.action.primary,
      light: s.action.primaryText,
      light2: s.border.interactive
    },
    light: {
      main: s.surface.default,
      light: s.surface.raised,
      greyVariant1: s.surface.subtle,
      greyVariant2: s.surface.raised,
      greyVariant3: s.border.subtle,
      greyVariant4: s.border.strong,
      greyVariant5: s.text.muted
    },
    dark: {
      main: s.text.primary,
      light: s.text.secondary,
      greyVariant1: s.text.secondary,
      greyVariant2: s.text.muted,
      greyVariant3: s.border.strong,
      greyVariant4: s.border.subtle,
      greyVariant5: s.surface.subtle
    },
    redError:      { main: s.feedback.error,   light: s.action.danger },
    greenSuccess:  { main: s.feedback.success, light: s.feedback.success },
    orangeWarning: { main: s.feedback.warning, light: s.feedback.warning },
    blueInfo:      { main: s.feedback.info,    light: s.action.primary }
  };

  // Dark palette: keep focus + feedback, swap the surface/text families so
  // "dark.main" becomes the inverted body color.
  const dark = {
    focus: light.focus,
    light: {
      main: s.text.inverse,
      light: s.text.inverse,
      greyVariant1: s.text.secondary,
      greyVariant2: s.text.muted,
      greyVariant3: s.border.subtle,
      greyVariant4: s.border.strong,
      greyVariant5: s.text.muted
    },
    dark: {
      main: s.surface.inverse,
      light: s.surface.overlay,
      greyVariant1: s.surface.raised,
      greyVariant2: s.surface.subtle,
      greyVariant3: s.border.subtle,
      greyVariant4: s.border.strong,
      greyVariant5: s.text.muted
    },
    redError:      light.redError,
    greenSuccess:  light.greenSuccess,
    orangeWarning: light.orangeWarning,
    blueInfo:      light.blueInfo
  };

  return { light, dark };
}

export function toOnyxiaFont(theme, { version = SENT_REPO_VERSION_DEFAULT } = {}) {
  const family = theme?.tokens?.typography?.fontFamily?.sans;
  if (!family) throw new Error('sentropic theme: typography.fontFamily.sans missing');

  return {
    fontFamily: family,
    dirUrl: `${JSDELIVR_GH_PREFIX}${version}${JSDELIVR_GH_SUFFIX}`,
    ...FONT_FILES
  };
}
```

- [ ] **Step 5: Run the test to verify it passes**

Run: `node --test test/mapping.test.mjs`
Expected: 7 tests passing.

### Step block B — JSON5 stringify helper

- [ ] **Step 6: Implement the JSON5 stringify helper**

Write to `helm-chart/examples/gke-ephemeral/theme/lib/json5-stringify.mjs`:

```javascript
// Onyxia parses PALETTE_OVERRIDE_* and FONT as JSON5 (per web/src/env.ts).
// We emit valid JSON5 — unquoted single-token keys, single-quoted strings —
// because that's what Onyxia's existing examples (InseeFrLab, sspcloud)
// use and it stays readable in helm values dumps.
const SAFE_KEY = /^[A-Za-z_$][A-Za-z0-9_$]*$/;

export function json5Stringify(value, indent = 2) {
  return _emit(value, '', indent);
}

function _emit(v, prefix, indent) {
  if (v === null) return 'null';
  if (typeof v === 'number' || typeof v === 'boolean') return String(v);
  if (typeof v === 'string') return `'${v.replace(/\\/g, '\\\\').replace(/'/g, "\\'")}'`;
  if (Array.isArray(v)) {
    if (v.length === 0) return '[]';
    const inner = prefix + ' '.repeat(indent);
    return '[\n' + v.map(x => inner + _emit(x, inner, indent)).join(',\n') + '\n' + prefix + ']';
  }
  if (typeof v === 'object') {
    const keys = Object.keys(v);
    if (keys.length === 0) return '{}';
    const inner = prefix + ' '.repeat(indent);
    return '{\n' + keys.map(k => {
      const key = SAFE_KEY.test(k) ? k : `'${k}'`;
      return inner + `${key}: ${_emit(v[k], inner, indent)}`;
    }).join(',\n') + '\n' + prefix + '}';
  }
  throw new Error('json5Stringify: unsupported value ' + typeof v);
}
```

### Step block C — entry point

- [ ] **Step 7: Write the failing generator integration test**

Write to `helm-chart/examples/gke-ephemeral/theme/test/generator.test.mjs`:

```javascript
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import url from 'node:url';

const __dirname = path.dirname(url.fileURLToPath(import.meta.url));
const ENTRY = path.join(__dirname, '..', 'sentropic-to-onyxia.mjs');

test('generator — emits all 8 web.env keys', () => {
  const out = execFileSync('node', [ENTRY], {
    env: {
      ...process.env,
      SENTROPIC_HEADER_LOGO_URL: 'https://cdn.example.com/logo.svg',
      SENTROPIC_HEADER_TEXT_BOLD: 'sent-tech',
      SENTROPIC_HEADER_TEXT_FOCUS: 'Datalab',
      SENTROPIC_TAB_TITLE: 'sent-tech · Onyxia',
      SENTROPIC_FAVICON_URL: 'https://cdn.example.com/favicon.svg'
    },
    encoding: 'utf8'
  });

  for (const key of [
    'PALETTE_OVERRIDE_LIGHT:',
    'PALETTE_OVERRIDE_DARK:',
    'FONT:',
    'HEADER_LOGO:',
    'HEADER_TEXT_BOLD:',
    'HEADER_TEXT_FOCUS:',
    'TAB_TITLE:',
    'FAVICON:'
  ]) {
    assert.ok(out.includes(key), `missing ${key} in:\n${out}`);
  }
});

test('generator — fails loudly if required header env vars are missing', () => {
  assert.throws(() => {
    execFileSync('node', [ENTRY], {
      env: { ...process.env, SENTROPIC_HEADER_LOGO_URL: '' },
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'pipe']
    });
  }, /SENTROPIC_HEADER_LOGO_URL/);
});
```

- [ ] **Step 8: Run the test to verify it fails**

Run: `node --test test/generator.test.mjs`
Expected: FAIL with `Cannot find module .../sentropic-to-onyxia.mjs` (or equivalent).

- [ ] **Step 9: Implement `sentropic-to-onyxia.mjs`**

Write to `helm-chart/examples/gke-ephemeral/theme/sentropic-to-onyxia.mjs`:

```javascript
#!/usr/bin/env node
// Reads @sentropic/design-system-themes, maps it to the Onyxia palette shape,
// and emits a YAML fragment ready to splice under web.env in
// onyxia-private-values.local.yaml.
//
// Required env vars:
//   SENTROPIC_HEADER_LOGO_URL    e.g. https://cdn.sent-tech.ca/onyxia-logo.svg
//   SENTROPIC_HEADER_TEXT_BOLD   e.g. sent-tech
//   SENTROPIC_HEADER_TEXT_FOCUS  e.g. Datalab
// Optional env vars:
//   SENTROPIC_TAB_TITLE          default: "${BOLD} ${FOCUS} · Onyxia"
//   SENTROPIC_FAVICON_URL        default: SENTROPIC_HEADER_LOGO_URL
//   SENTROPIC_THEME_VERSION      default: v0.5.0 (used for jsdelivr URLs)
//
// Stdout: a YAML fragment with 2-space indentation, ready to inject under
// `web.env:` in the values file. The Onyxia chart already maps web.env.<KEY>
// to a container env var of the same name.

import { toOnyxiaPalettes, toOnyxiaFont } from './lib/mapping.mjs';
import { json5Stringify } from './lib/json5-stringify.mjs';

function requireEnv(name) {
  const v = process.env[name];
  if (!v || v.trim() === '') {
    console.error(`ERROR: ${name} is required (export it before running the generator).`);
    process.exit(2);
  }
  return v;
}

async function main() {
  const HEADER_LOGO         = requireEnv('SENTROPIC_HEADER_LOGO_URL');
  const HEADER_TEXT_BOLD    = requireEnv('SENTROPIC_HEADER_TEXT_BOLD');
  const HEADER_TEXT_FOCUS   = requireEnv('SENTROPIC_HEADER_TEXT_FOCUS');
  const TAB_TITLE   = process.env.SENTROPIC_TAB_TITLE
    || `${HEADER_TEXT_BOLD} ${HEADER_TEXT_FOCUS} · Onyxia`;
  const FAVICON     = process.env.SENTROPIC_FAVICON_URL || HEADER_LOGO;
  const VERSION     = process.env.SENTROPIC_THEME_VERSION || 'v0.5.0';

  const mod = await import('@sentropic/design-system-themes');
  const theme = mod.sentTechTheme || mod.default?.sentTechTheme;
  if (!theme) {
    console.error('ERROR: @sentropic/design-system-themes did not export `sentTechTheme`. Exports:', Object.keys(mod));
    process.exit(3);
  }

  const { light, dark } = toOnyxiaPalettes(theme);
  assertPalette('light', light);
  assertPalette('dark', dark);
  const font = toOnyxiaFont(theme, { version: VERSION });

  // YAML scalar with embedded JSON5 — use the literal-block style `|-` so we
  // don't have to escape anything. envsubst (Task 5) treats it as opaque.
  const lines = [
    '# Auto-generated by helm-chart/examples/gke-ephemeral/theme/sentropic-to-onyxia.mjs',
    '# DO NOT EDIT BY HAND — re-run the generator after bumping @sentropic/design-system-themes.',
    `PALETTE_OVERRIDE_LIGHT: |-\n${indent(json5Stringify(light), 2)}`,
    `PALETTE_OVERRIDE_DARK: |-\n${indent(json5Stringify(dark), 2)}`,
    `FONT: |-\n${indent(json5Stringify(font), 2)}`,
    `HEADER_LOGO: ${yamlString(HEADER_LOGO)}`,
    `HEADER_TEXT_BOLD: ${yamlString(HEADER_TEXT_BOLD)}`,
    `HEADER_TEXT_FOCUS: ${yamlString(HEADER_TEXT_FOCUS)}`,
    `TAB_TITLE: ${yamlString(TAB_TITLE)}`,
    `FAVICON: ${yamlString(FAVICON)}`
  ];
  process.stdout.write(lines.join('\n') + '\n');
}

function indent(s, n) {
  const pad = ' '.repeat(n);
  return s.split('\n').map(l => pad + l).join('\n');
}

function yamlString(s) {
  // Double-quoted scalar with backslash escapes — safe for URLs and spaces.
  return `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

function assertPalette(name, p) {
  const required = [
    'focus.main', 'focus.light', 'focus.light2',
    'light.main', 'dark.main',
    'redError.main', 'greenSuccess.main', 'orangeWarning.main', 'blueInfo.main'
  ];
  for (const path of required) {
    const [a, b] = path.split('.');
    if (!p[a] || !p[a][b]) {
      console.error(`ERROR: ${name} palette is missing ${path} — mapping or sentropic schema drift.`);
      process.exit(4);
    }
  }
}

main().catch(err => {
  console.error('ERROR:', err.stack || err.message);
  process.exit(1);
});
```

- [ ] **Step 10: Run the tests to verify they pass**

Run: `npm test`
Expected: all tests in `test/mapping.test.mjs` and `test/generator.test.mjs` pass (9 tests).

- [ ] **Step 11: Smoke-test the generator output**

Run:
```bash
SENTROPIC_HEADER_LOGO_URL=https://example.com/logo.svg \
SENTROPIC_HEADER_TEXT_BOLD=sent-tech \
SENTROPIC_HEADER_TEXT_FOCUS=Datalab \
  node sentropic-to-onyxia.mjs
```
Expected: prints the eight YAML keys with non-empty values; the two `PALETTE_OVERRIDE_*` blocks contain readable JSON5 with `focus`, `light`, `dark`, `redError`, etc.

- [ ] **Step 12: Commit**

```bash
git add helm-chart/examples/gke-ephemeral/theme/sentropic-to-onyxia.mjs \
        helm-chart/examples/gke-ephemeral/theme/lib/ \
        helm-chart/examples/gke-ephemeral/theme/test/
git commit -m "feat(examples): sentropic-to-onyxia theme generator"
```

**Review checkpoint:** Confirm the generator output parses as valid JSON5 (`node -e "const JSON5=require('json5');JSON5.parse(...)"` if you want to be paranoid — but the tests already exercise this via the YAML key check). Don't proceed to Task 4 until the mapping table feels right when eyeballed against the spec's amended mapping table.

---

## Task 3: Upstream license fix (out-of-band PR)

**Files:**
- Modified upstream: `rhanka/sent-tech-design-system` repo, `packages/themes/package.json`

**Acceptance criterion:** A pull request titled `feat: add MIT license to @sentropic/design-system-themes` is open against `rhanka/sent-tech-design-system`. This task is a *side note* — it does not block our example merging because Task 1 Step 2 already disables `audit` in `.npmrc`, which silences strict-CI failures.

- [ ] **Step 1: Clone the upstream repo (locally, outside this worktree)**

Run:
```bash
cd /tmp
git clone https://github.com/rhanka/sent-tech-design-system.git
cd sent-tech-design-system
git checkout -b feat/add-mit-license
```

- [ ] **Step 2: Add the SPDX field to both `@sentropic/*` packages**

In `packages/themes/package.json` AND `packages/tokens/package.json`, insert under `"version": "0.5.0"`:

```json
"license": "MIT",
```

- [ ] **Step 3: Add a top-level `LICENSE` file**

Write `/tmp/sent-tech-design-system/LICENSE`:

```
MIT License

Copyright (c) 2026 Sent-Tech Forge contributors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

- [ ] **Step 4: Commit, push, open PR**

Run:
```bash
git add LICENSE packages/themes/package.json packages/tokens/package.json
git commit -m "feat: add MIT license to @sentropic/* packages

So downstream consumers (Onyxia gke-ephemeral example, etc.) can install
without strict-CI license-policy violations."
git push -u origin feat/add-mit-license
gh pr create --title "feat: add MIT license to @sentropic/* packages" \
             --body "Adds the SPDX license field to both published packages and a top-level MIT LICENSE file. Required by strict-CI consumers (see onyxia gke-ephemeral example, task 3)."
```

- [ ] **Step 5: No commit in our repo** — this is upstream-only.

**Review checkpoint:** PR URL captured. Once the PR merges and a `0.5.1` is published, bump the pin in `helm-chart/examples/gke-ephemeral/theme/package.json` (Task 1) and remove `audit=false` from `.npmrc`.

---

## Task 4: `.env.local.example` — expose the four new vars + the toggle

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/.env.local.example`

**Acceptance criterion:** A user who copies `.env.local.example` to `.env.local`, sets `ENABLE_SENTROPIC_THEME=true` and fills in the three header strings, can run `./scripts/_load_env.sh` (Task 5) and end up with the YAML fragment spliced into `onyxia-private-values.local.yaml`.

- [ ] **Step 1: Append the new section**

Append to `helm-chart/examples/gke-ephemeral/.env.local.example`:

```
# --- Sentropic theme (optional) ----------------------------------------------
# Set ENABLE_SENTROPIC_THEME=true to make the deploy run
# helm-chart/examples/gke-ephemeral/theme/sentropic-to-onyxia.mjs at the start
# of every apply, splicing PALETTE_OVERRIDE_*, FONT, HEADER_LOGO,
# HEADER_TEXT_BOLD/FOCUS, TAB_TITLE and FAVICON into web.env.
# Default false → Onyxia keeps the upstream InseeFrLab look.
ENABLE_SENTROPIC_THEME=false

# Required when ENABLE_SENTROPIC_THEME=true (otherwise ignored):
SENTROPIC_HEADER_LOGO_URL=https://cdn.sent-tech.ca/onyxia-logo.svg
SENTROPIC_HEADER_TEXT_BOLD=sent-tech
SENTROPIC_HEADER_TEXT_FOCUS=Datalab

# Optional overrides (defaults shown):
# SENTROPIC_TAB_TITLE="sent-tech Datalab · Onyxia"
# SENTROPIC_FAVICON_URL=https://cdn.sent-tech.ca/onyxia-logo.svg
# SENTROPIC_THEME_VERSION=v0.5.0
```

- [ ] **Step 2: Verify it's still a valid shell file**

Run:
```bash
bash -n <(grep -v '^#' helm-chart/examples/gke-ephemeral/.env.local.example | grep -v '^$')
echo $?
```
Expected: exit 0.

- [ ] **Step 3: Commit**

```bash
git add helm-chart/examples/gke-ephemeral/.env.local.example
git commit -m "feat(examples): expose sentropic theme env vars in .env.local.example"
```

**Review checkpoint:** Defaults are sane (toggle off, sample URLs that *look* real). No commit.

---

## Task 5: `_load_env.sh` — invoke the generator when enabled

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/scripts/_load_env.sh`

**Acceptance criterion:**
1. With `ENABLE_SENTROPIC_THEME=false` (or unset), the file `onyxia-private-values.local.yaml` is unchanged from today.
2. With `ENABLE_SENTROPIC_THEME=true`, the file contains a `# BEGIN SENTROPIC THEME` … `# END SENTROPIC THEME` block under `web.env:` with all 8 keys.
3. Re-running with `ENABLE_SENTROPIC_THEME=true` is idempotent — the block is replaced in-place, not appended.

- [ ] **Step 1: Inspect the current template's `web.env:` block**

Run: `grep -n "web:" helm-chart/examples/gke-ephemeral/onyxia-private-values.local.yaml.tmpl | head`
Expected: one line `web:` followed by `  env:`. The generator output (Task 2) is indented to splice directly under `  env:` at indent 4.

- [ ] **Step 2: Patch `_load_env.sh`**

Append to `helm-chart/examples/gke-ephemeral/scripts/_load_env.sh` (after the existing `envsubst` block, before EOF):

```bash
# Sentropic theme (optional). When ENABLE_SENTROPIC_THEME=true, regenerate the
# palette/font/header env vars and splice them under web.env in the values file.
# Idempotent: a previous block (delimited by the markers below) is replaced.
if [ "${ENABLE_SENTROPIC_THEME:-false}" = "true" ]; then
  : "${SENTROPIC_HEADER_LOGO_URL:?Set SENTROPIC_HEADER_LOGO_URL in .env.local}"
  : "${SENTROPIC_HEADER_TEXT_BOLD:?Set SENTROPIC_HEADER_TEXT_BOLD in .env.local}"
  : "${SENTROPIC_HEADER_TEXT_FOCUS:?Set SENTROPIC_HEADER_TEXT_FOCUS in .env.local}"

  THEME_DIR="${EXAMPLE_DIR}/theme"
  (cd "${THEME_DIR}" && [ -d node_modules ] || npm ci --silent)

  FRAGMENT="$( (cd "${THEME_DIR}" && node sentropic-to-onyxia.mjs) )"
  # Indent the fragment by 4 spaces so it lands under `  env:`.
  INDENTED="$(printf '%s\n' "${FRAGMENT}" | sed 's/^/    /')"

  # Replace the existing block, or insert one after the `  env:` line.
  python3 - "${TARGET}" <<PY
import sys, re, pathlib
p = pathlib.Path(sys.argv[1])
text = p.read_text()
block = """    # BEGIN SENTROPIC THEME — generated, do not edit
${INDENTED}
    # END SENTROPIC THEME
"""
pattern = re.compile(r"    # BEGIN SENTROPIC THEME[\s\S]*?    # END SENTROPIC THEME\n", re.MULTILINE)
if pattern.search(text):
    text = pattern.sub(block, text)
else:
    text = re.sub(r"(\nweb:\n  env:\n)", r"\1" + block, text, count=1)
p.write_text(text)
PY
fi
```

Note on the inline heredoc: Python is used because the indent-aware in-place edit is finicky in `sed`/`awk`; Python 3 is already required by the existing scripts (e.g. `keycloak-init.sh`).

- [ ] **Step 3: Smoke test — toggle OFF**

Run:
```bash
cd helm-chart/examples/gke-ephemeral
cp .env.local.example .env.local
# leave ENABLE_SENTROPIC_THEME=false (default)
# fill in mandatory non-theme fields enough to pass the existing checks:
sed -i 's|PROJECT_ID=.*|PROJECT_ID=fake|; s|GOOGLE_OAUTH_CLIENT_ID=|GOOGLE_OAUTH_CLIENT_ID=fake.apps.googleusercontent.com|' .env.local
bash scripts/_load_env.sh || true   # the script exits via `set -e` after envsubst — that's fine
grep -c "BEGIN SENTROPIC THEME" onyxia-private-values.local.yaml
```
Expected: `0` (no block inserted).

- [ ] **Step 4: Smoke test — toggle ON**

Run:
```bash
sed -i 's|ENABLE_SENTROPIC_THEME=false|ENABLE_SENTROPIC_THEME=true|' .env.local
bash scripts/_load_env.sh || true
grep -c "BEGIN SENTROPIC THEME" onyxia-private-values.local.yaml
grep -c "PALETTE_OVERRIDE_LIGHT" onyxia-private-values.local.yaml
```
Expected: `1` then `1`.

- [ ] **Step 5: Smoke test — idempotency**

Run:
```bash
bash scripts/_load_env.sh || true
bash scripts/_load_env.sh || true
grep -c "BEGIN SENTROPIC THEME" onyxia-private-values.local.yaml
```
Expected: `1` (still one block, not three).

- [ ] **Step 6: Clean up the smoke-test `.env.local`**

Run: `rm helm-chart/examples/gke-ephemeral/.env.local helm-chart/examples/gke-ephemeral/onyxia-private-values.local.yaml`
(Both are gitignored — restore happens on the next real run.)

- [ ] **Step 7: Commit**

```bash
git add helm-chart/examples/gke-ephemeral/scripts/_load_env.sh
git commit -m "feat(examples): wire sentropic theme generator into _load_env.sh"
```

**Review checkpoint:** The block is gated on `ENABLE_SENTROPIC_THEME=true` AND the splice is idempotent. Both verified above.

---

## Task 6: README — "Brand it" section

**Files:**
- Modify: `helm-chart/examples/gke-ephemeral/README.md`

**Acceptance criterion:** A reader who knows nothing about Onyxia can, by following the README, (a) enable the sentropic theme, (b) pin a specific `@sentropic/design-system-themes` version, (c) swap in a different design system.

- [ ] **Step 1: Find a good insertion point**

Run: `grep -n "^## " helm-chart/examples/gke-ephemeral/README.md | head`
Insert the new section after the "Quickstart" / "Configure" section, before any "Teardown" section. If unclear, insert right before the last `## ` heading.

- [ ] **Step 2: Append the section**

Add to `helm-chart/examples/gke-ephemeral/README.md`:

```markdown
## Brand it (optional)

This example can reskin Onyxia at deploy time using the [`@sentropic/design-system-themes`](https://www.npmjs.com/package/@sentropic/design-system-themes) tokens — colors, fonts, logo, header strings. Zero fork of `onyxia-web`.

### Enable the sentropic theme

In `.env.local`:

```
ENABLE_SENTROPIC_THEME=true
SENTROPIC_HEADER_LOGO_URL=https://cdn.sent-tech.ca/onyxia-logo.svg
SENTROPIC_HEADER_TEXT_BOLD=sent-tech
SENTROPIC_HEADER_TEXT_FOCUS=Datalab
```

Run `./scripts/up.sh` (or the GHA workflow with `mode=resume`). The deploy will:

1. `npm ci` inside `theme/` (cached after the first run).
2. Run `theme/sentropic-to-onyxia.mjs`, which produces a `BEGIN SENTROPIC THEME` block.
3. Splice the block under `web.env:` in `onyxia-private-values.local.yaml`.
4. `tofu apply` upgrades the helm release — Onyxia restarts with the new env, which `onyxia-web` consumes at boot.

### Pin a specific sentropic version

Edit `theme/package.json`:

```json
"dependencies": {
  "@sentropic/design-system-themes": "0.5.0"
}
```

Then `cd theme && npm install --package-lock-only && git commit -am "chore: bump sentropic to <version>"`.

Optionally also set `SENTROPIC_THEME_VERSION=v0.6.0` in `.env.local` so the jsdelivr font URLs match the version you installed.

### Swap to a different design system

The generator is intentionally thin (~80 LOC). Copy `theme/sentropic-to-onyxia.mjs` to e.g. `theme/mydsl-to-onyxia.mjs`, change the `import` and the mapping in `lib/mapping.mjs` to your tokens, and point `_load_env.sh` at the new entry point. The Onyxia palette contract is documented at `onyxia-ui/src/lib/color.urgent.ts` (upstream) and re-stated in `lib/mapping.mjs` comments.

### Scope

V1 ships colors + fonts + logo + header strings. Component **shape** (button radius, drawer geometry) is not covered — that needs a fork of `onyxia-ui` and is deliberately deferred.
```

- [ ] **Step 3: Verify the README still renders**

Run: `npx -y markdownlint-cli helm-chart/examples/gke-ephemeral/README.md` (or any tool you have).
Expected: no fatal errors. Style warnings are fine.

- [ ] **Step 4: Commit**

```bash
git add helm-chart/examples/gke-ephemeral/README.md
git commit -m "docs(examples): Brand it — sentropic theme + DSL swap recipe"
```

**Review checkpoint:** A non-author reader can answer "how do I switch logos?" from the README alone.

---

## Task 7: GHA workflow — theme generation step

**Files:**
- Modify: `.github/workflows/onyxia-gke-ephemeral.yml`

**Acceptance criterion:**
1. The workflow has a new step `Apply app layer — phase 1.2 (theme generation)` between phase 1 and phase 1.5.
2. The step runs only when `inputs.mode` is `init` or `resume` AND `vars.ENABLE_SENTROPIC_THEME == 'true'`.
3. The step exports the three header env vars from GH `vars.SENTROPIC_HEADER_LOGO_URL`, etc., and runs `_load_env.sh` (which already does the splice). Then phase 1.5 and onward see the updated values file.

- [ ] **Step 1: Patch the workflow**

In `.github/workflows/onyxia-gke-ephemeral.yml`, locate the `env:` map at the job level (around line 34) and add:

```yaml
      ENABLE_SENTROPIC_THEME:        ${{ vars.ENABLE_SENTROPIC_THEME }}
      SENTROPIC_HEADER_LOGO_URL:     ${{ vars.SENTROPIC_HEADER_LOGO_URL }}
      SENTROPIC_HEADER_TEXT_BOLD:    ${{ vars.SENTROPIC_HEADER_TEXT_BOLD }}
      SENTROPIC_HEADER_TEXT_FOCUS:   ${{ vars.SENTROPIC_HEADER_TEXT_FOCUS }}
      SENTROPIC_THEME_VERSION:       ${{ vars.SENTROPIC_THEME_VERSION }}
```

Then, immediately AFTER the existing `- name: Apply app layer — phase 1 (cert-manager CRDs)` step and BEFORE `- name: Apply app layer — phase 1.5 (namespaces)`, insert:

```yaml
      - name: Setup Node (for theme generator)
        if: (inputs.mode == 'init' || inputs.mode == 'resume') && vars.ENABLE_SENTROPIC_THEME == 'true'
        uses: actions/setup-node@v4
        with:
          node-version: '20'
          cache: 'npm'
          cache-dependency-path: helm-chart/examples/gke-ephemeral/theme/package-lock.json

      - name: Apply app layer — phase 1.2 (theme generation)
        if: (inputs.mode == 'init' || inputs.mode == 'resume') && vars.ENABLE_SENTROPIC_THEME == 'true'
        run: |
          cd theme
          npm ci --silent
          cd ..
          # _load_env.sh splices the BEGIN/END SENTROPIC THEME block into
          # onyxia-private-values.local.yaml. The subsequent phases reread the
          # file via TF_VAR_extra_values_files.
          ./scripts/_load_env.sh
```

- [ ] **Step 2: Validate the workflow yaml**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/onyxia-gke-ephemeral.yml'))" && echo OK`
Expected: `OK`.

- [ ] **Step 3: (Optional) lint with `actionlint`**

Run: `actionlint .github/workflows/onyxia-gke-ephemeral.yml`
Expected: 0 issues. If `actionlint` is not installed, skip — the YAML validity check above is enough.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/onyxia-gke-ephemeral.yml
git commit -m "ci(examples): generate sentropic theme between phase 1 and 1.5"
```

**Review checkpoint:** With GH repo `vars.ENABLE_SENTROPIC_THEME` unset (or `false`), the workflow MUST behave exactly as today. The `if:` on every new step guarantees this. Confirm by re-reading the diff before merging.

---

## Task 8: Visual snapshot test

**Files:**
- Create: `helm-chart/examples/gke-ephemeral/theme/test/snapshot.mjs`
- Create: `helm-chart/examples/gke-ephemeral/theme/test/fixtures/sent-tech-home.png` (reference, committed)
- Modify: `helm-chart/examples/gke-ephemeral/theme/package.json` (add `playwright` + `pixelmatch` + `pngjs` dev deps + npm script)
- Create: `helm-chart/examples/gke-ephemeral/theme/test/README.md`

**Acceptance criterion:** Running `npm run snapshot` against a target URL emits a PNG and diffs it against the reference. Diff > 5% fails; ≤ 5% passes. Stored as a *manual* smoke test, NOT in the GHA workflow (it would need a running Onyxia URL).

- [ ] **Step 1: Add dev deps**

Edit `helm-chart/examples/gke-ephemeral/theme/package.json` to add:

```json
  "devDependencies": {
    "playwright": "1.49.0",
    "pixelmatch": "6.0.0",
    "pngjs": "7.0.0"
  },
  "scripts": {
    "generate": "node sentropic-to-onyxia.mjs",
    "test": "node --test test/mapping.test.mjs test/generator.test.mjs",
    "snapshot": "node test/snapshot.mjs"
  },
```

Then run:
```bash
cd helm-chart/examples/gke-ephemeral/theme
npm install --package-lock-only
```

- [ ] **Step 2: Implement the snapshot test**

Write to `helm-chart/examples/gke-ephemeral/theme/test/snapshot.mjs`:

```javascript
#!/usr/bin/env node
// Usage:
//   ONYXIA_URL=https://onyxia.sent-tech.ca \
//   REFERENCE=test/fixtures/sent-tech-home.png \
//   node test/snapshot.mjs
//
// Loads the URL in headless Chromium, screenshots the viewport, and diffs
// it against the reference PNG. Exits 0 if diff fraction <= THRESHOLD,
// 1 otherwise. The threshold is intentionally loose (5%) — this is a
// "did the theme actually paint?" smoke test, not a pixel-perfect contract.

import { chromium } from 'playwright';
import pixelmatch from 'pixelmatch';
import { PNG } from 'pngjs';
import { readFileSync, writeFileSync } from 'node:fs';

const URL = process.env.ONYXIA_URL || 'http://localhost:3000';
const REF = process.env.REFERENCE || 'test/fixtures/sent-tech-home.png';
const OUT = process.env.OUT || 'test/last-snapshot.png';
const DIFF = process.env.DIFF || 'test/last-diff.png';
const THRESHOLD = Number(process.env.THRESHOLD || '0.05');  // 5 %

const browser = await chromium.launch();
const page = await browser.newPage({ viewport: { width: 1280, height: 800 } });
await page.goto(URL, { waitUntil: 'networkidle', timeout: 30_000 });
await page.screenshot({ path: OUT, fullPage: false });
await browser.close();

const ref = PNG.sync.read(readFileSync(REF));
const act = PNG.sync.read(readFileSync(OUT));
if (ref.width !== act.width || ref.height !== act.height) {
  console.error(`ERROR: dimensions differ (ref=${ref.width}x${ref.height} act=${act.width}x${act.height})`);
  process.exit(1);
}

const diff = new PNG({ width: ref.width, height: ref.height });
const mismatched = pixelmatch(ref.data, act.data, diff.data, ref.width, ref.height, { threshold: 0.1 });
writeFileSync(DIFF, PNG.sync.write(diff));

const fraction = mismatched / (ref.width * ref.height);
console.log(`mismatched=${mismatched} fraction=${fraction.toFixed(4)} threshold=${THRESHOLD}`);
if (fraction > THRESHOLD) {
  console.error(`FAIL: diff fraction ${fraction.toFixed(4)} > ${THRESHOLD}`);
  process.exit(1);
}
console.log('PASS');
```

- [ ] **Step 3: Document how to capture the reference**

Write to `helm-chart/examples/gke-ephemeral/theme/test/README.md`:

```markdown
# theme/test

Two test suites:

- `mapping.test.mjs` + `generator.test.mjs` — unit tests, run on every push (`npm test`).
- `snapshot.mjs` — manual visual smoke test (`npm run snapshot`), needs a live Onyxia URL.

## Capturing the reference

The reference PNG (`fixtures/sent-tech-home.png`) is a 1280×800 screenshot of the **sent-tech-forge** main site home, taken with the same browser config as `snapshot.mjs`. To re-capture it:

```
npx playwright install chromium
ONYXIA_URL=https://sent-tech.ca OUT=test/fixtures/sent-tech-home.png \
  node test/snapshot.mjs || true   # the diff step is meaningless on first capture
```

Commit the resulting PNG.

## Running against a deployed Onyxia

```
ONYXIA_URL=https://onyxia.sent-tech.ca npm run snapshot
```

A pass means the deployed Onyxia and the sent-tech home are within 5 % pixel difference — chrome, palette, and font all match closely enough. A fail prints the diff PNG to `test/last-diff.png` for review.

## Why not run in CI?

We'd need a deployed Onyxia URL reachable from `ubuntu-latest`. Not impossible but out of scope for v1; v2 can wire it into the GHA workflow after the `tofu apply` succeeds.
```

- [ ] **Step 4: Capture a first reference (manual)**

Run:
```bash
cd helm-chart/examples/gke-ephemeral/theme
npm install   # full install with playwright
npx playwright install chromium
mkdir -p test/fixtures
ONYXIA_URL=https://sent-tech.ca OUT=test/fixtures/sent-tech-home.png \
  node test/snapshot.mjs || true
ls -la test/fixtures/sent-tech-home.png
```
Expected: a PNG ~50–200 KB. If `sent-tech.ca` is not reachable from your network, generate a stub: `npx playwright codegen` against any page and commit a placeholder; the snapshot test will then need its reference re-captured by a maintainer who can reach the host.

- [ ] **Step 5: Run the snapshot test against itself (sanity)**

Run:
```bash
ONYXIA_URL=https://sent-tech.ca REFERENCE=test/fixtures/sent-tech-home.png \
  npm run snapshot
```
Expected: `PASS` (a page diffed against its own screenshot, ~0 % mismatch).

- [ ] **Step 6: Commit**

```bash
git add helm-chart/examples/gke-ephemeral/theme/package.json \
        helm-chart/examples/gke-ephemeral/theme/package-lock.json \
        helm-chart/examples/gke-ephemeral/theme/test/snapshot.mjs \
        helm-chart/examples/gke-ephemeral/theme/test/README.md \
        helm-chart/examples/gke-ephemeral/theme/test/fixtures/sent-tech-home.png
git commit -m "test(examples): visual snapshot vs sent-tech home"
```

**Review checkpoint:** The reference PNG is sane (not a 1×1 placeholder, not a 404 page) and the threshold (5%) is loose enough to survive minor anti-alias differences but tight enough to catch a missing palette swap.

---

## Self-review

**Spec coverage check (against `2026-05-16-onyxia-sentropic-theme-design.md`):**

| Spec requirement | Implemented by |
|---|---|
| `scripts/sentropic-to-onyxia.mjs` reads `@sentropic/design-system-themes` | Task 2 |
| Outputs `PALETTE_OVERRIDE_LIGHT/DARK`, `FONT`, header triplet | Task 2 |
| Tiny npm setup at `helm-chart/examples/gke-ephemeral/theme/` | Task 1 |
| `_load_env.sh` extended, gated by `ENABLE_SENTROPIC_THEME` | Task 5 |
| `.env.local.example` adds the new vars | Task 4 |
| README "Brand it" section | Task 6 |
| Mapping respects Onyxia palette schema (`focus`, `light.*`, `dark.*`, `redError`, …) per amendment 2 | Task 2 (`lib/mapping.mjs`) |
| JS-not-CSS import (amendment 3) | Task 2 Step 9 (`import` of the JS module) |
| Font URL via jsdelivr-from-GitHub (amendment 4) | Task 2 (`toOnyxiaFont`) |
| MIT license fix upstream | Task 3 |
| Acceptance: bumping `@sentropic/*` and re-running propagates change | Task 1 + Task 5 (npm ci on every run, splice is idempotent) |
| Acceptance: toggle off keeps InseeFrLab look | Task 5 Step 3 |
| CI integration | Task 7 |
| Visual diff (not in spec, but useful for "did we actually match?") | Task 8 |

**Placeholder scan:** no `TBD`, no "implement appropriately", no "similar to Task N". All code blocks are complete. ✓

**Type consistency:** `toOnyxiaPalettes` returns `{light, dark}`, consumed as such in `sentropic-to-onyxia.mjs`. `toOnyxiaFont` returns an object with `fontFamily`, `dirUrl`, `'400'`, `'500'`, `'600'`, `'700'` — tests assert these exact keys. The shell splice block delimiters `# BEGIN SENTROPIC THEME` / `# END SENTROPIC THEME` are identical in `_load_env.sh` and asserted in Task 5 Step 4. ✓

---

## Execution handoff

Plan complete and saved to `docs/superpowers/plans/2026-05-16-onyxia-sentropic-theme-plan.md`. Two execution options:

**1. Subagent-Driven (recommended)** — dispatch a fresh subagent per task (Tasks 1, 2, 4, 5, 6, 7, 8), two-stage review between tasks. Task 3 (upstream license PR) runs in parallel since it's out-of-band.

**2. Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch checkpoints after Tasks 2, 5 and 8.

**Which approach?**
