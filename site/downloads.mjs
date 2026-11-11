const releasesEndpoint = 'https://api.github.com/repos/ilovespectra/CruiseControl/releases';

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
  const element = document.getElementById('binary-downloads');
  if (element) void showBinaryDownloads(element);
}
