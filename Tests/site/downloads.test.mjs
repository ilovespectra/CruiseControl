import { test } from 'node:test';
import assert from 'node:assert/strict';
import { countBinaryDownloads, fetchBinaryDownloads, showBinaryDownloads } from '../../site/downloads.mjs';

test('counts installer downloads, including updates, but not metadata or drafts', () => {
  assert.equal(countBinaryDownloads([
    { assets: [
      { name: 'CruiseControl.pkg', download_count: 12 },
      { name: 'release.json', download_count: 99 },
      { name: 'SHA256SUMS', download_count: 88 },
    ] },
    { assets: [{ name: 'CruiseControl-1.0.1.pkg', download_count: 5 }] },
    { draft: true, assets: [{ name: 'CruiseControl.pkg', download_count: 7 }] },
  ]), 17);
  assert.equal(countBinaryDownloads([]), 0);
});

test('fetches every page before presenting a total', async () => {
  const calls = [];
  const total = await fetchBinaryDownloads(async (url) => {
    calls.push(url);
    return {
      ok: true,
      json: async () => calls.length === 1
        ? Array.from({ length: 100 }, () => ({ assets: [{ name: 'CruiseControl.pkg', download_count: 1 }] }))
        : [{ assets: [{ name: 'CruiseControl.pkg', download_count: 9 }] }],
    };
  });
  assert.equal(total, 109);
  assert.equal(calls.length, 2);
  assert.match(calls[1], /page=2$/);
});

test('fails explicitly for private repos, rate limits and malformed counts', async () => {
  for (const status of [404, 403, 429]) {
    await assert.rejects(fetchBinaryDownloads(async () => ({ ok: false, status })));
  }
  assert.throws(() => countBinaryDownloads({}));
  assert.throws(() => countBinaryDownloads([{ assets: [{ name: 'CruiseControl.pkg', download_count: -1 }] }]));
});

test('renders a real zero rather than a placeholder', async () => {
  const element = { textContent: '' };
  await showBinaryDownloads(element, async () => ({ ok: true, json: async () => [] }));
  assert.equal(element.textContent, '0 binary downloads on GitHub');
});
