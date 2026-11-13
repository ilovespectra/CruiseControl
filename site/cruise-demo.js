(() => {
  const demo = document.querySelector('[data-cruise-demo]');
  if (!demo) return;
  const buttons = [...document.querySelectorAll('[data-demo-mode]')];
  const caption = document.querySelector('[data-demo-caption]');
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  const captions = {
    manual: 'Manual leaves the prompt for you. Nothing is pressed.',
    rest: 'Rest answers “Not now.” Clicky stays parked.',
    cruise: 'Cruise answers the drive prompt. Clicky gets back to work.',
  };
  let timers = [];
  let observer;

  function step(value) {
    demo.dataset.step = String(value);
    const cruise = demo.dataset.mode === 'cruise';
    demo.querySelector('[data-demo-receipt]').textContent = value < 2
      ? 'Drive request detected'
      : cruise ? (value === 3 ? 'Browser check complete' : 'Approved by Cruise Control') : 'Declined by Cruise Control';
    demo.querySelector('[data-task-state]').textContent = cruise && value >= 2
      ? (value === 3 ? 'Checked' : 'Checking…') : 'Waiting';
    demo.querySelector('[data-task-check]').textContent = cruise && value === 3 ? '✓' : '·';
  }

  function play(mode) {
    if (!Object.hasOwn(captions, mode)) return;
    observer?.disconnect();
    timers.forEach(clearTimeout);
    timers = [];
    demo.dataset.mode = mode;
    demo.querySelector('[data-mode-indicator]').textContent = mode.toUpperCase();
    buttons.forEach(button => button.setAttribute('aria-pressed', String(button.dataset.demoMode === mode)));
    caption.textContent = captions[mode];
    step(0);
    if (mode === 'manual') return;
    if (reducedMotion.matches) {
      step(mode === 'cruise' ? 3 : 2);
      return;
    }
    timers.push(setTimeout(() => step(1), 900), setTimeout(() => step(2), 2200));
    if (mode === 'cruise') timers.push(setTimeout(() => step(3), 3900));
  }

  buttons.forEach(button => button.addEventListener('click', () => play(button.dataset.demoMode)));
  document.querySelector('[data-demo-replay]').addEventListener('click', () => play(demo.dataset.mode));
  reducedMotion.addEventListener('change', () => play(demo.dataset.mode));
  if (typeof IntersectionObserver === 'function' && !reducedMotion.matches) {
    observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) play(demo.dataset.mode);
    }, { threshold: 0.4 });
    observer.observe(demo);
  } else {
    play('cruise');
  }
})();
