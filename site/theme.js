(() => {
  const palettes = ['blue', 'green', 'red', 'yellow'];
  const appearances = ['system', 'light', 'dark'];
  const key = 'cruise-control.presentation.v1';
  let preferences = { palette: 'blue', appearance: 'system' };
  try {
    const saved = JSON.parse(localStorage.getItem(key) || '{}');
    if (palettes.includes(saved?.palette)) preferences.palette = saved.palette;
    if (appearances.includes(saved?.appearance)) preferences.appearance = saved.appearance;
  } catch (error) {
    console.warn('Cruise presentation preferences could not be read; using the default theme.', error);
  }
  const root = document.documentElement;
  const system = window.matchMedia('(prefers-color-scheme: dark)');
  function apply() {
    root.dataset.palette = preferences.palette;
    root.dataset.appearance = preferences.appearance;
    document.querySelectorAll('[data-brand-art]').forEach((image) => {
      const kind = image.dataset.brandArt;
      if (kind === 'gauge' || kind === 'rest') image.src = `assets/brand/${preferences.palette}-${kind}.jpg`;
    });
    const icon = document.querySelector('link[rel="icon"]');
    if (icon) icon.href = `assets/brand/${preferences.palette}-gauge.jpg`;
    const meta = document.querySelector('meta[name="theme-color"]');
    const dark = preferences.appearance === 'dark' || (preferences.appearance === 'system' && system.matches);
    if (meta) meta.content = dark ? '#0c111b' : '#f5f7fc';
  }
  apply();
  system.addEventListener('change', apply);
  document.addEventListener('DOMContentLoaded', () => {
    apply();
    for (const field of ['palette', 'appearance']) {
      const control = document.querySelector(`[data-theme-${field}]`);
      if (!control) continue;
      control.value = preferences[field];
      control.addEventListener('change', () => {
        const allowed = field === 'palette' ? palettes : appearances;
        if (!allowed.includes(control.value)) return;
        preferences[field] = control.value;
        apply();
        try {
          localStorage.setItem(key, JSON.stringify(preferences));
        } catch (error) {
          console.warn('Cruise presentation preferences apply to this page but could not be saved.', error);
        }
      });
    }
  });
})();
