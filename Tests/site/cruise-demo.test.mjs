import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { runInNewContext } from 'node:vm';

const source = readFileSync(new URL('../../site/cruise-demo.js', import.meta.url), 'utf8');

function demo(reduced = false) {
  const fields = {};
  const timers = new Map();
  let nextTimer = 0;
  const listeners = {};
  const buttons = ['manual', 'rest', 'cruise'].map(mode => ({
    dataset: { demoMode: mode },
    setAttribute(key, value) { this[key] = value; },
    addEventListener(event, callback) { listeners[mode] = callback; },
  }));
  const scene = {
    dataset: {},
    querySelector(selector) { return fields[selector] ??= {}; },
  };
  const motion = { matches: reduced, addEventListener(event, callback) { listeners.motion = callback; } };
  const caption = {};
  const replay = { addEventListener(event, callback) { listeners.replay = callback; } };
  runInNewContext(source, {
    document: {
      querySelector: selector => ({
        '[data-cruise-demo]': scene, '[data-demo-caption]': caption, '[data-demo-replay]': replay,
      })[selector],
      querySelectorAll: () => buttons,
    },
    matchMedia: () => motion,
    setTimeout(callback) { timers.set(++nextTimer, callback); return nextTimer; },
    clearTimeout(id) { timers.delete(id); },
  });
  return {
    scene, fields, buttons, caption, timers, listeners,
    finish() { for (const [id, callback] of timers) { timers.delete(id); callback(); } },
  };
}

test('Cruise demonstrates approval and browser progress without changing real settings', () => {
  const page = demo();
  assert.equal(page.scene.dataset.mode, 'cruise');
  assert.equal(page.scene.dataset.step, '0');
  page.finish();
  assert.equal(page.scene.dataset.step, '3');
  assert.equal(page.fields['[data-task-state]'].textContent, 'Checked');
  assert.equal(page.buttons[2]['aria-pressed'], 'true');
});

test('Manual cancels the demo; Rest declines; replay starts the selected mode again', () => {
  const page = demo();
  page.listeners.manual();
  page.finish();
  assert.equal(page.scene.dataset.step, '0');
  assert.equal(page.timers.size, 0);
  assert.match(page.caption.textContent, /Nothing is pressed/);
  page.listeners.rest();
  page.finish();
  assert.equal(page.scene.dataset.step, '2');
  assert.equal(page.fields['[data-demo-receipt]'].textContent, 'Declined by Cruise Control');
  assert.equal(page.fields['[data-task-state]'].textContent, 'Waiting');
  page.listeners.replay();
  assert.equal(page.scene.dataset.mode, 'rest');
  assert.equal(page.scene.dataset.step, '0');
});

test('reduced motion presents the outcome without timers and still supports mode changes', () => {
  const page = demo(true);
  assert.equal(page.scene.dataset.step, '3');
  assert.equal(page.timers.size, 0);
  page.listeners.rest();
  assert.equal(page.scene.dataset.step, '2');
  assert.equal(page.timers.size, 0);
  page.listeners.manual();
  assert.equal(page.scene.dataset.step, '0');
});
