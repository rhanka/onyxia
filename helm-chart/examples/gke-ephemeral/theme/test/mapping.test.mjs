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
    }
  }
};

// `foundation.font` is a sibling export in @sentropic/design-system-themes,
// not part of TenantTheme. The mapper takes it as a separate argument.
const fontFoundation = {
  sans: '"Inter", system-ui, sans-serif',
  display: '"Inter", system-ui, sans-serif',
  mono: '"SFMono-Regular", Consolas, monospace'
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
  const font = toOnyxiaFont(fontFoundation, { version: 'v0.5.0' });
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
