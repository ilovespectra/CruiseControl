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

export async function showBinaryDownloads(element, fetcher = fetch) {
  try {
    const total = await fetchBinaryDownloads(fetcher);
    element.textContent = `${total.toLocaleString()} binary downloads on GitHub`;
  } catch (error) {
    element.textContent = 'binary download count unavailable — GitHub may be rate-limited or the repository may still be private.';
    console.error('Could not load Cruise Control binary download count:', error);
  }
}

if (typeof document !== 'undefined') {
  const element = document.getElementById('binary-downloads');
  if (element) void showBinaryDownloads(element);
}
