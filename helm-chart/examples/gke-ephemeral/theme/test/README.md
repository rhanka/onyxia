# theme/test

Two test suites:

- `mapping.test.mjs` + `generator.test.mjs` — unit tests, run on every push (`npm test`).
- `snapshot.mjs` — manual visual smoke test (`npm run snapshot`), needs a live Onyxia URL.

## Capturing the reference

The reference PNG (`fixtures/<your-brand>-home.png`) is a 1280x800 screenshot of the main marketing site home, taken with the same browser config as `snapshot.mjs`. To capture it (no reference is committed by default — the maintainer with access to the live site recaptures locally):

```
npm install                                # installs playwright + pixelmatch + pngjs
npx playwright install chromium
mkdir -p test/fixtures
ONYXIA_URL=https://your-brand.example.com OUT=test/fixtures/your-brand-home.png \
  node test/snapshot.mjs
```

The script exits 0 on first capture (no diff to compute) and prints the path of the captured PNG. Commit that PNG if it looks right.

## Running against a deployed Onyxia

```
ONYXIA_URL=https://onyxia.example.com REFERENCE=test/fixtures/your-brand-home.png \
  npm run snapshot
```

A pass means the deployed Onyxia and the brand home are within 5% pixel difference — chrome, palette, and font all match closely enough. A fail prints the diff PNG to `test/last-diff.png` for review.

## Why not run in CI?

We'd need a deployed Onyxia URL reachable from `ubuntu-latest`. Not impossible but out of scope for v1; v2 can wire it into the GHA workflow after the `tofu apply` succeeds.
