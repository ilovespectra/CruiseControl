const releasesEndpoint = 'https://api.github.com/repos/ilovespectra/CruiseControl/releases';
const latestReleaseEndpoint = `${releasesEndpoint}/latest`;
const releasesPage = 'https://github.com/ilovespectra/CruiseControl/releases/latest';
const latestInstaller = `${releasesPage}/download/CruiseControl.pkg`;

export function latestPublishedRelease(release) {
  if (!release || typeof release !== 'object' || release.draft || release.prerelease
      || typeof release.tag_name !== 'string' || typeof release.html_url !== 'string'
      || !Array.isArray(release.assets)) throw new Error('Invalid latest GitHub release response.');
  const version = release.tag_name.replace(/^v/, '');
  if (!/^\d+\.\d+\.\d+(?:[-+][0-9A-Za-z.-]+)?$/.test(version)) {
    throw new Error('Latest GitHub release has an invalid version tag.');
  }
  const packageAsset = release.assets.find((asset) => asset.name === 'CruiseControl.pkg')
    ?? release.assets.find((asset) => /^CruiseControl-\d+\.\d+\.\d+\.pkg$/.test(asset.name ?? ''));
  if (!packageAsset || typeof packageAsset.browser_download_url !== 'string') {
    throw new Error('Latest GitHub release has no Cruise Control installer.');
  }
  const releaseUrl = new URL(release.html_url);
  const installerUrl = new URL(packageAsset.browser_download_url);
  if (releaseUrl.protocol !== 'https:' || releaseUrl.hostname !== 'github.com'
      || installerUrl.protocol !== 'https:' || installerUrl.hostname !== 'github.com') {
    throw new Error('Latest GitHub release returned an unexpected link.');
  }
  return { version: release.tag_name.startsWith('v') ? release.tag_name : `v${release.tag_name}`,
    releaseUrl: releaseUrl.href, installerUrl: installerUrl.href };
}

export async function fetchLatestRelease(fetcher = fetch) {
  const response = await fetcher(latestReleaseEndpoint, {
    headers: { Accept: 'application/vnd.github+json' },
    signal: AbortSignal.timeout(15000),
  });
  if (!response.ok) throw new Error(`GitHub latest-release lookup failed (${response.status}).`);
  return latestPublishedRelease(await response.json());
}

export function applyLatestRelease(release, root = globalThis.document) {
  for (const element of root?.querySelectorAll?.('.latest-version') ?? []) element.textContent = release.version;
  for (const element of root?.querySelectorAll?.('.latest-release-link') ?? []) element.href = release.releaseUrl;
  for (const element of root?.querySelectorAll?.('[data-latest-installer]') ?? []) element.href = release.installerUrl;
}

export async function showLatestRelease(fetcher = fetch, root = globalThis.document) {
  try {
    const release = await fetchLatestRelease(fetcher);
    applyLatestRelease(release, root);
    return release;
  } catch (error) {
    for (const element of root?.querySelectorAll?.('.latest-version') ?? []) element.textContent = 'See GitHub Releases';
    for (const element of root?.querySelectorAll?.('.latest-release-link') ?? []) element.href = releasesPage;
    for (const element of root?.querySelectorAll?.('[data-latest-installer]') ?? []) element.href = latestInstaller;
    console.error('Could not load the latest Cruise Control release:', error);
    return null;
  }
}

export function countBinaryDownloads(releases) {
  if (!Array.isArray(releases)) throw new Error('Invalid GitHub releases response.');
  return releases.reduce((total, release) => {
    if (release.draft) return total;
    if (!Array.isArray(release.assets)) throw new Error('Invalid GitHub release assets.');
    return total + release.assets.reduce((downloads, asset) => {
      if (!/^CruiseControl(?:-\d+\.\d+\.\d+)?\.pkg$/.test(asset.name)) return downloads;
      if (!Number.isSafeInteger(asset.download_count) || asset.download_count < 0) {
        throw new Error('Invalid GitHub download count.');
      }
      return downloads + asset.download_count;
    }, 0);
  }, 0);
}

export async function fetchBinaryDownloads(fetcher = fetch) {
  let total = 0;
  for (let page = 1; ; page += 1) {
    const response = await fetcher(`${releasesEndpoint}?per_page=100&page=${page}`, {
      headers: { Accept: 'application/vnd.github+json' },
      signal: AbortSignal.timeout(15000),
    });
    if (!response.ok) throw new Error(`GitHub release lookup failed (${response.status}).`);
    const releases = await response.json();
    total += countBinaryDownloads(releases);
    if (releases.length < 100) return total;
  }
}

const DOWNLOAD_CACHE_KEY = 'cruise-control.release-binary-downloads.v1';
const DOWNLOAD_CACHE_TTL_MS = 5 * 60 * 1000;

function readCachedDownloads() {
  try {
    const cached = JSON.parse(globalThis.localStorage?.getItem(DOWNLOAD_CACHE_KEY) || 'null');
    if (cached && Number.isSafeInteger(cached.total) && cached.total >= 0
        && Number.isFinite(cached.savedAt) && cached.savedAt > 0 && cached.savedAt <= Date.now()) return cached;
  } catch {}
  return null;
}

function cacheAge(savedAt) {
  const minutes = Math.max(0, Math.floor((Date.now() - savedAt) / 60000));
  return minutes < 1 ? 'under a minute' : `${minutes} min`;
}

export async function showBinaryDownloads(element, fetcher = fetch) {
  const cached = readCachedDownloads();
  if (cached && Date.now() - cached.savedAt < DOWNLOAD_CACHE_TTL_MS) {
    element.textContent = `${cached.total.toLocaleString()} binary downloads on GitHub`;
    return;
  }
  if (cached) element.textContent = `${cached.total.toLocaleString()} binary downloads on GitHub · refreshing`;

  try {
    const total = await fetchBinaryDownloads(fetcher);
    try { globalThis.localStorage?.setItem(DOWNLOAD_CACHE_KEY, JSON.stringify({ total, savedAt: Date.now() })); } catch {}
    element.textContent = `${total.toLocaleString()} binary downloads on GitHub`;
  } catch (error) {
    element.textContent = cached
      ? `${cached.total.toLocaleString()} binary downloads on GitHub · last checked ${cacheAge(cached.savedAt)} ago`
      : 'binary download count unavailable — GitHub may be rate-limited or the repository may still be private.';
    console.error('Could not load Cruise Control binary download count:', error);
  }
}

if (typeof document !== 'undefined') {
  void showLatestRelease();
  const element = document.getElementById('binary-downloads');
  if (element) void showBinaryDownloads(element);
}
