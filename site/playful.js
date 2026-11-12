const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
const frames = [...document.querySelectorAll('[data-demo-frame]')];

async function installVerifiedClip(frame) {
  const video = frame.querySelector('[data-demo-video]');
  const fallback = frame.querySelector('.recording-placeholder');
  const source = video?.dataset.demoVideo;
  if (!video || !fallback || !source) return;

  try {
    const response = await fetch(source, { method: 'HEAD', cache: 'no-store' });
    if (!response.ok || !response.headers.get('content-type')?.startsWith('video/')) return;
    video.src = source;
    video.hidden = false;
    fallback.hidden = true;
    video.addEventListener('error', () => {
      video.hidden = true;
      fallback.hidden = false;
    }, { once: true });
  } catch {
    // Missing capture files remain explicitly marked as pending; never invent a preview.
  }
}

for (const frame of frames) void installVerifiedClip(frame);

// Decorate the harmless road doodle only; the app footage itself stays unaltered.
if (reducedMotion.matches) document.documentElement.classList.add('reduced-motion');
reducedMotion.addEventListener?.('change', (event) => {
  document.documentElement.classList.toggle('reduced-motion', event.matches);
});
