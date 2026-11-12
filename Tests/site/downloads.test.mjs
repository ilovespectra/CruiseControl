import { test } from 'node:test';
import assert from 'node:assert/strict';
import { applyLatestRelease, countBinaryDownloads, fetchBinaryDownloads, fetchLatestRelease, latestPublishedRelease, showBinaryDownloads } from '../../site/downloads.mjs';

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

test('uses a five-minute cache and retains the last verified total on API errors', async () => {
  const values = new Map();
  const localStorage = {
    getItem: (key) => values.get(key) || null,
    setItem: (key, value) => values.set(key, String(value)),
  };
  const priorDescriptor = Object.getOwnPropertyDescriptor(globalThis, 'localStorage');
  Object.defineProperty(globalThis, 'localStorage', { configurable: true, value: localStorage });

  try {
    let requests = 0;
    const first = { textContent: '' };
    await showBinaryDownloads(first, async () => {
      requests += 1;
      return { ok: true, json: async () => [{ assets: [{ name: 'CruiseControl.pkg', download_count: 14 }] }] };
    });
    assert.equal(first.textContent, '14 binary downloads on GitHub');

    const fresh = { textContent: '' };
    await showBinaryDownloads(fresh, async () => {
      requests += 1;
      return { ok: false, status: 403 };
    });
    assert.equal(fresh.textContent, '14 binary downloads on GitHub');
    assert.equal(requests, 1);

    const cache = JSON.parse(values.get('cruise-control.release-binary-downloads.v1'));
    cache.savedAt = Date.now() - 10 * 60 * 1000;
    values.set('cruise-control.release-binary-downloads.v1', JSON.stringify(cache));
    const stale = { textContent: '' };
    await showBinaryDownloads(stale, async () => {
      requests += 1;
      return { ok: false, status: 403 };
    });
    assert.match(stale.textContent, /14 binary downloads on GitHub · last checked \d+ min ago/);
    assert.equal(requests, 2);
  } finally {
    if (priorDescriptor) Object.defineProperty(globalThis, 'localStorage', priorDescriptor);
    else delete globalThis.localStorage;
  }
});

test('reads the latest published GitHub release and links its matching installer asset', async () => {
  const calls = [];
  const release = await fetchLatestRelease(async (url, options) => {
    calls.push({ url, options });
    return { ok: true, json: async () => ({
      tag_name: 'v1.2.3', draft: false, prerelease: false,
      html_url: 'https://github.com/ilovespectra/CruiseControl/releases/tag/v1.2.3',
      assets: [
        { name: 'release.json', browser_download_url: 'https://github.com/ilovespectra/CruiseControl/releases/download/v1.2.3/release.json' },
        { name: 'CruiseControl.pkg', browser_download_url: 'https://github.com/ilovespectra/CruiseControl/releases/download/v1.2.3/CruiseControl.pkg' },
      ],
    }) };
  });
  assert.equal(release.version, 'v1.2.3');
  assert.equal(release.installerUrl, 'https://github.com/ilovespectra/CruiseControl/releases/download/v1.2.3/CruiseControl.pkg');
  assert.match(calls[0].url, /repos\/ilovespectra\/CruiseControl\/releases\/latest$/);
  assert.equal(calls[0].options.headers.Accept, 'application/vnd.github+json');
});

test('rejects a draft, prerelease, missing installer, or non-GitHub download URL', () => {
  const base = {
    tag_name: 'v1.2.3', html_url: 'https://github.com/ilovespectra/CruiseControl/releases/tag/v1.2.3',
    assets: [{ name: 'CruiseControl.pkg', browser_download_url: 'https://github.com/ilovespectra/CruiseControl/releases/download/v1.2.3/CruiseControl.pkg' }],
  };
  assert.throws(() => latestPublishedRelease({ ...base, draft: true }));
  assert.throws(() => latestPublishedRelease({ ...base, prerelease: true }));
  assert.throws(() => latestPublishedRelease({ ...base, assets: [] }));
  assert.throws(() => latestPublishedRelease({ ...base, assets: [{ name: 'CruiseControl.pkg', browser_download_url: 'https://example.com/pkg' }] }));
});

test('applies GitHub-derived version and release URLs to every matching page control', () => {
  const makeElements = () => [{ textContent: '', href: '' }, { textContent: '', href: '' }];
  const versions = makeElements();
  const releaseLinks = makeElements();
  const installers = makeElements();
  applyLatestRelease({ version: 'v2.0.0', releaseUrl: 'https://github.com/ilovespectra/CruiseControl/releases/tag/v2.0.0', installerUrl: 'https://github.com/ilovespectra/CruiseControl/releases/download/v2.0.0/CruiseControl.pkg' }, {
    querySelectorAll: (selector) => ({ '.latest-version': versions, '.latest-release-link': releaseLinks, '[data-latest-installer]': installers })[selector],
  });
  assert.deepEqual(versions.map((element) => element.textContent), ['v2.0.0', 'v2.0.0']);
  assert.ok(releaseLinks.every((element) => element.href.endsWith('/v2.0.0')));
  assert.ok(installers.every((element) => element.href.endsWith('/v2.0.0/CruiseControl.pkg')));
});
