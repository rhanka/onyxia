// MUI's `colorManipulator` (used by Onyxia) only understands hex / rgb(a) /
// hsl(a) / color() — not oklch(). The sentropic palette uses oklch for its
// accent colors, so we lower any oklch(...) string to #rrggbb before handing
// it to Onyxia's PALETTE_OVERRIDE_* env vars.
//
// Math: Björn Ottosson's Oklab spec — oklch → oklab → linear sRGB → sRGB → hex.
// Out-of-gamut channels are clamped to [0,1] (sRGB destination).

const OKLCH_RE = /^\s*oklch\(\s*([\d.+-]+)(%?)\s+([\d.+-]+)(%?)\s+([\d.+-]+)(?:\s*\/\s*([\d.+-]+%?))?\s*\)\s*$/i;

export function isOklch(value) {
  return typeof value === 'string' && OKLCH_RE.test(value);
}

export function oklchToHex(value) {
  const m = OKLCH_RE.exec(value);
  if (!m) throw new Error(`oklchToHex: not an oklch() value: ${value}`);
  const L = m[2] === '%' ? parseFloat(m[1]) / 100 : parseFloat(m[1]);
  // Chroma may be given as % (0..100 → 0..0.4) or as a number (0..0.4).
  const C = m[4] === '%' ? (parseFloat(m[3]) / 100) * 0.4 : parseFloat(m[3]);
  const H = parseFloat(m[5]);

  const hRad = (H * Math.PI) / 180;
  const a = C * Math.cos(hRad);
  const b = C * Math.sin(hRad);

  // oklab → LMS (cube)
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.2914855480 * b;

  const l3 = l_ * l_ * l_;
  const m3 = m_ * m_ * m_;
  const s3 = s_ * s_ * s_;

  // LMS → linear sRGB
  let r = +4.0767416621 * l3 - 3.3077115913 * m3 + 0.2309699292 * s3;
  let g = -1.2684380046 * l3 + 2.6097574011 * m3 - 0.3413193965 * s3;
  let bl = -0.0041960863 * l3 - 0.7034186147 * m3 + 1.7076147010 * s3;

  // linear → sRGB gamma
  r = srgbGamma(r);
  g = srgbGamma(g);
  bl = srgbGamma(bl);

  return rgbToHex(clamp01(r), clamp01(g), clamp01(bl));
}

function srgbGamma(c) {
  return c <= 0.0031308 ? 12.92 * c : 1.055 * Math.pow(c, 1 / 2.4) - 0.055;
}

function clamp01(x) {
  return x < 0 ? 0 : x > 1 ? 1 : x;
}

function rgbToHex(r, g, b) {
  const to = (x) => Math.round(x * 255).toString(16).padStart(2, '0');
  return `#${to(r)}${to(g)}${to(b)}`;
}

// Walk a value (string / array / plain object) and convert any oklch() string.
export function normalizeColorsDeep(value) {
  if (typeof value === 'string') {
    return isOklch(value) ? oklchToHex(value) : value;
  }
  if (Array.isArray(value)) {
    return value.map(normalizeColorsDeep);
  }
  if (value && typeof value === 'object') {
    const out = {};
    for (const [k, v] of Object.entries(value)) out[k] = normalizeColorsDeep(v);
    return out;
  }
  return value;
}
