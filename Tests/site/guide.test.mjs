import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';

const guide = readFileSync(new URL('../../site/docs.html', import.meta.url), 'utf8');

test('guide shares the landing page shell without decorative brand illustrations', () => {
  for (const stylesheet of ['brand.css', 'facelift.css', 'guide.css']) {
    assert.ok(guide.includes(`href="${stylesheet}"`));
  }
  assert.match(guide, /class="wordmark"/);
  assert.match(guide, /class="landing-footer"/);
  assert.doesNotMatch(guide, /<img\b|data-brand-art|blue-rest\.jpg/);
});

test('1.1.2 guide keeps existing deep links and separates guide version from published release', () => {
  for (const id of ['content', 'start', 'tasks', 'modes', 'ollama', 'vscode', 'storage',
    'appearance', 'updates', 'safety', 'stop', 'privacy', 'troubleshooting', 'source']) {
    assert.ok(guide.includes(`id="${id}"`), `Missing existing anchor: ${id}`);
  }
  assert.match(guide, /The guide \/ 1\.1\.2/);
  assert.match(guide, /Latest published:/);
  assert.match(guide, /class="latest-version" aria-live="polite">See releases/);
});

test('documents task opt-ins, held approvals, and actual stop controls', () => {
  for (const text of ['Manual is not an all-off switch', 'Auto-bump', 'Build, branches &amp; finishing',
    'Saved record', 'review queue', 'not a security boundary', 'Already-running agents must be stopped']) {
    assert.ok(guide.includes(text), `Missing guidance: ${text}`);
  }
});
