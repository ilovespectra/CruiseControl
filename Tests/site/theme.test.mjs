import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, existsSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const site = new URL('../../site/', import.meta.url);
const source = readFileSync(new URL('theme.js', site), 'utf8');
const css = readFileSync(new URL('brand.css', site), 'utf8');

function browser({ saved = null, dark = false, blockedStorage = false } = {}) {
  const events = {};
  const controls = Object.fromEntries(['palette', 'appearance'].map((field) => [field, {
    value: '', addEventListener: (name, callback) => { events[`${field}:${name}`] = callback; },
  }]));
  const images = ['gauge', 'rest'].map((kind) => ({ dataset: { brandArt: kind }, src: '' }));
  const icon = {};
  const meta = {};
  const root = { dataset: {} };
  const warnings = [];
  let stored = saved;
  const system = { matches: dark, addEventListener: (name, callback) => { events[`system:${name}`] = callback; } };
  const document = {
    documentElement: root,
    querySelectorAll: () => images,
    querySelector: (selector) => ({
      'link[rel="icon"]': icon, 'meta[name="theme-color"]': meta,
      '[data-theme-palette]': controls.palette, '[data-theme-appearance]': controls.appearance,
    })[selector],
    addEventListener: (name, callback) => { events[name] = callback; },
  };
  runInNewContext(source, {
    document, window: { matchMedia: () => system },
    console: { warn: (...args) => warnings.push(args) },
    localStorage: {
      getItem: () => { if (blockedStorage) throw new Error('Storage disabled'); return stored; },
      setItem: (key, value) => { if (blockedStorage) throw new Error('Storage disabled'); stored = value; },
    },
  });
  events.DOMContentLoaded();
  return {
    root, images, icon, meta, controls, system, warnings,
    get saved() { return stored; },
    select(field, value) { controls[field].value = value; events[`${field}:change`](); },
    changeSystem(dark) { system.matches = dark; events['system:change'](); },
  };
}

test('defaults to blue and follows system appearance, including subsequent changes', () => {
  const page = browser();
  assert.equal(page.root.dataset.palette, 'blue');
  assert.equal(page.root.dataset.appearance, 'system');
  assert.equal(page.meta.content, '#f5f7fc');
  page.changeSystem(true);
  assert.equal(page.meta.content, '#0c111b');
});

test('all palettes update both marks and favicon and persist between pages', () => {
  for (const palette of ['blue', 'green', 'red', 'yellow']) {
    const page = browser();
    page.select('palette', palette);
    page.select('appearance', 'dark');
    assert.equal(page.images[0].src, `assets/brand/${palette}-gauge.jpg`);
    assert.equal(page.images[1].src, `assets/brand/${palette}-rest.jpg`);
    assert.equal(page.icon.href, page.images[0].src);
    const next = browser({ saved: page.saved });
    assert.equal(next.controls.palette.value, palette);
    assert.equal(next.controls.appearance.value, 'dark');
    assert.equal(next.meta.content, '#0c111b');
  }
});

test('explicit appearance overrides system and switching back restores it', () => {
  const page = browser({ dark: true });
  page.select('appearance', 'light');
  assert.equal(page.meta.content, '#f5f7fc');
  page.changeSystem(false);
  page.changeSystem(true);
  assert.equal(page.meta.content, '#f5f7fc');
  page.select('appearance', 'system');
  assert.equal(page.meta.content, '#0c111b');
});

test('malformed, null, and unrecognized stored values retain valid defaults', () => {
  for (const saved of ['{', 'null', '"yellow"', '{"palette":"purple","appearance":"broken"}']) {
    const page = browser({ saved });
    assert.equal(page.root.dataset.palette, 'blue');
    assert.equal(page.root.dataset.appearance, 'system');
  }
  const page = browser({ saved: '{"palette":"green","appearance":"broken"}' });
  assert.equal(page.root.dataset.palette, 'green');
  assert.equal(page.root.dataset.appearance, 'system');
  page.select('palette', '../private');
  assert.equal(page.root.dataset.palette, 'green');
});

test('unavailable storage is reported and does not prevent live theme selection', () => {
  const page = browser({ blockedStorage: true });
  page.select('palette', 'red');
  assert.equal(page.root.dataset.palette, 'red');
  assert.equal(page.warnings.length, 2);
});

test('both pages share branding, working local links, headings and release controls', () => {
  for (const name of ['index.html', 'docs.html']) {
    const html = readFileSync(new URL(name, site), 'utf8');
    assert.equal((html.match(/<h1(?:\s[^>]*)?>/g) || []).length, 1);
    assert.match(html, /href="brand.css"/);
    assert.match(html, /src="theme.js"/);
    assert.match(html, /data-theme-palette/);
    assert.match(html, /data-theme-appearance/);
    assert.match(html, /class="skip-link"/);
    assert.match(html, /data-latest-installer/);
    assert.match(html, /class="latest-version"/);
    for (const [, value] of html.matchAll(/(?:href|src)="([^"]+)"/g)) {
      if (/^(https?:|mailto:)/.test(value)) continue;
      const target = new URL(value, new URL(name, site));
      assert.ok(existsSync(target), `${name}: missing ${value}`);
      if (target.hash) {
        const content = readFileSync(new URL(target.pathname, 'file:'), 'utf8');
        assert.ok(content.includes(`id="${target.hash.slice(1)}"`), `${name}: missing anchor ${value}`);
      }
    }
  }
  for (const palette of ['blue', 'green', 'red', 'yellow']) {
    for (const kind of ['gauge', 'rest']) assert.ok(existsSync(new URL(`assets/brand/${palette}-${kind}.jpg`, site)));
  }
});

function luminance(hex) {
  const rgb = hex.slice(1).match(/../g).map((value) => parseInt(value, 16) / 255)
    .map((value) => value <= .04045 ? value / 12.92 : ((value + .055) / 1.055) ** 2.4);
  return rgb[0] * .2126 + rgb[1] * .7152 + rgb[2] * .0722;
}
function contrast(a, b) {
  const values = [luminance(a), luminance(b)].sort((a, b) => b - a);
  return (values[0] + .05) / (values[1] + .05);
}
function variables(selector) {
  const block = css.slice(css.indexOf(selector) + selector.length).match(/^\s*\{([^}]+)\}/);
  assert.ok(block, `Missing selector ${selector}`);
  return Object.fromEntries([...block[1].matchAll(/--([\w-]+):\s*(#[0-9a-f]{6})\s*;/g)].map(([, key, value]) => [key, value]));
}

test('all eight light/dark palettes meet WCAG AA normal-text contrast', () => {
  const base = variables(':root');
  for (const dark of [false, true]) {
    for (const palette of ['blue', 'green', 'red', 'yellow']) {
      const colors = {
        ...base,
        ...(palette === 'blue' ? {} : variables(`:root[data-palette="${palette}"]`)),
        ...(dark ? variables(':root[data-appearance="dark"]') : {}),
        ...(dark && palette !== 'blue' ? variables(`:root[data-appearance="dark"][data-palette="${palette}"]`) : {}),
      };
      for (const background of ['paper', 'surface', 'raised', 'accent-soft']) {
        for (const foreground of ['ink', 'muted', 'accent']) {
          const ratio = contrast(colors[foreground], colors[background]);
          assert.ok(ratio >= 4.5, `${palette}/${dark ? 'dark' : 'light'}: ${foreground} on ${background} = ${ratio.toFixed(2)}`);
        }
      }
      assert.ok(contrast(colors['on-accent'], colors.accent) >= 4.5);
    }
  }
});

test('keeps system dark styles, reduced motion and keyboard focus treatments', () => {
  assert.match(css, /prefers-color-scheme: dark/);
  assert.match(css, /prefers-reduced-motion: reduce/);
  assert.match(css, /:focus-visible/);
  assert.match(css, /:root:not\(\[data-appearance="light"\]\)/);
});
