const tour = document.querySelector('.tour-card');
const tabs = [...document.querySelectorAll('[role="tab"]')];
const panels = [...document.querySelectorAll('[role="tabpanel"]')];
const motionToggle = document.querySelector('.motion-toggle');
const reducedMotion = window.matchMedia('(prefers-reduced-motion: reduce)');
let selectedTab = 0;
let userPaused = reducedMotion.matches;
let temporarilyPaused = false;
let tabTimer;
let stepTimer;
let modeIndex = 2;
let taskStepIndex = 0;
let storageRowIndex = 0;

function motionIsPaused() {
  return userPaused || temporarilyPaused || document.hidden || reducedMotion.matches;
}

function syncMotionButton() {
  const paused = userPaused || reducedMotion.matches;
  motionToggle.setAttribute('aria-pressed', String(paused));
  motionToggle.setAttribute('aria-label', paused ? 'Play demo motion' : 'Pause demo motion');
  motionToggle.innerHTML = paused ? '▶ <span>Play</span>' : 'Ⅱ <span>Pause</span>';
}

function activateTab(index, focus = false) {
  selectedTab = (index + tabs.length) % tabs.length;
  tabs.forEach((tab, item) => {
    const active = item === selectedTab;
    tab.classList.toggle('is-active', active);
    tab.setAttribute('aria-selected', String(active));
    tab.tabIndex = active ? 0 : -1;
    panels[item].hidden = !active;
  });
  if (focus) tabs[selectedTab].focus();
}

function setMode(mode) {
  document.querySelectorAll('[data-mode]').forEach((choice) => {
    choice.classList.toggle('is-selected', choice.dataset.mode === mode);
  });
  const copy = {
    manual: ['Manual selected', 'You answer each drive prompt yourself.'],
    rest: ['Rest selected', 'Drive prompts are automatically denied.'],
    cruise: ['Cruise selected', 'Drive prompts are automatically approved.'],
  }[mode];
  document.querySelector('[data-mode-title]').textContent = copy[0];
  document.querySelector('[data-mode-copy]').textContent = copy[1];
}

function nextAnimationStep() {
  if (motionIsPaused()) return;
  const modes = ['manual', 'rest', 'cruise'];
  modeIndex = (modeIndex + 1) % modes.length;
  setMode(modes[modeIndex]);

  const taskSteps = [...document.querySelectorAll('[data-task-step]')];
  taskSteps.forEach((step, index) => step.classList.toggle('is-current', index === taskStepIndex));
  taskStepIndex = (taskStepIndex + 1) % taskSteps.length;

  const storageRows = [...document.querySelectorAll('[data-storage-row]')];
  storageRows.forEach((row, index) => row.classList.toggle('is-current', index === storageRowIndex));
  storageRowIndex = (storageRowIndex + 1) % storageRows.length;
}

function stopTimers() {
  window.clearInterval(tabTimer);
  window.clearInterval(stepTimer);
  tabTimer = undefined;
  stepTimer = undefined;
}

function startTimers() {
  stopTimers();
  if (motionIsPaused()) return;
  tabTimer = window.setInterval(() => activateTab(selectedTab + 1), 7600);
  stepTimer = window.setInterval(nextAnimationStep, 2300);
}

for (const [index, tab] of tabs.entries()) {
  tab.addEventListener('click', () => activateTab(index));
  tab.addEventListener('keydown', (event) => {
    let target;
    if (event.key === 'ArrowRight') target = index + 1;
    else if (event.key === 'ArrowLeft') target = index - 1;
    else if (event.key === 'Home') target = 0;
    else if (event.key === 'End') target = tabs.length - 1;
    if (target === undefined) return;
    event.preventDefault();
    activateTab(target, true);
  });
}

motionToggle.addEventListener('click', () => {
  userPaused = !userPaused;
  syncMotionButton();
  startTimers();
});

tour.addEventListener('pointerenter', () => {
  temporarilyPaused = true;
  stopTimers();
});
tour.addEventListener('pointerleave', () => {
  temporarilyPaused = false;
  startTimers();
});
tour.addEventListener('focusin', () => {
  temporarilyPaused = true;
  stopTimers();
});
tour.addEventListener('focusout', (event) => {
  if (!tour.contains(event.relatedTarget)) {
    temporarilyPaused = false;
    startTimers();
  }
});
document.addEventListener('visibilitychange', startTimers);
reducedMotion.addEventListener?.('change', (event) => {
  if (event.matches) userPaused = true;
  syncMotionButton();
  startTimers();
});

activateTab(0);
setMode('cruise');
syncMotionButton();
startTimers();
