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

// `fontFoundation` is the `foundation.font` export from
// @sentropic/design-system-themes — a `{ sans, display, mono }` object.
// We pin to `sans` because Onyxia loads exactly one body font.
export function toOnyxiaFont(fontFoundation, { version = SENT_REPO_VERSION_DEFAULT } = {}) {
  const family = fontFoundation?.sans;
  if (!family) throw new Error('sentropic theme: foundation.font.sans missing');

  return {
    fontFamily: family,
    dirUrl: `${JSDELIVR_GH_PREFIX}${version}${JSDELIVR_GH_SUFFIX}`,
    ...FONT_FILES
  };
}
