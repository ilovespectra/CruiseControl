'use strict';
let token = '', selected = localStorage.getItem('cruise-build') || '', offset = 0, busy = false;
const $ = id => document.getElementById(id);
async function request(path, options) {
  const response = await fetch(path, options);
  const result = await response.json();
  if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
  return result;
}
function select(id) {
  selected = id; offset = 0; $('log').textContent = '';
  localStorage.setItem('cruise-build', id);
}
async function refresh() {
  if (busy) return;
  busy = true;
  try {
    const state = await request('/api/status');
    token = state.token;
    $('connection').textContent = 'Local console connected';
    $('repository').textContent = state.repository;
    const running = state.jobs.some(job => ['queued', 'running'].includes(job.status));
    $('commit').disabled = $('preview').disabled = $('draft').disabled = running;
    if (!selected && state.jobs.length) select(state.jobs[0].id);
    $('jobs').replaceChildren(...state.jobs.map(job => {
      const button = document.createElement('button');
      button.className = `job${job.id === selected ? ' selected' : ''}`;
      button.textContent = `${job.mode} · ${job.status}\n${new Date(job.created * 1000).toLocaleString()}\n${job.source_commit.slice(0, 12)}`;
      button.onclick = () => { select(job.id); refresh(); };
      return button;
    }));
    const job = state.jobs.find(item => item.id === selected);
    if (job) {
      $('build-title').textContent = `Compilation logs · ${job.status}`;
      $('build-detail').textContent = `Exact source: ${job.source_commit} · ${job.mode} · exit: ${job.exit_code ?? 'pending'}`;
      const log = await request(`/api/log?id=${selected}&offset=${offset}`);
      $('log').textContent += log.text; offset = log.offset;
      const version = $('log').textContent.match(/Selected next version: (v[\d.]+)/);
      $('version').textContent = version ? `Next version: ${version[1]}` : 'Version preflight pending';
      if ($('follow').checked) $('log').scrollTop = $('log').scrollHeight;
    }
  } catch (error) {
    $('connection').textContent = `Disconnected · retrying: ${error.message}`;
  } finally { busy = false; }
}
async function build(mode) {
  if (mode === 'draft' && !confirm('Build and upload an unpublished GitHub draft? Owner/admin authentication is verified by GitHub CLI. This does not publish.')) return;
  $('error').textContent = '';
  $('preview').disabled = $('draft').disabled = true;
  try {
    const result = await request('/api/build', {
      method: 'POST', headers: {'Content-Type': 'application/json', 'X-Console-Token': token},
      body: JSON.stringify({mode})
    });
    select(result.id);
  } catch (error) { $('error').textContent = error.message; }
  await refresh();
}
$('preview').onclick = () => build('preview');
$('draft').onclick = () => build('draft');
$('commit').onclick = async () => {
  if (!confirm('Commit all currently staged changes? Unstaged files are not included. With an empty message, local Ollama drafts the subject.')) return;
  $('error').textContent = '';
  $('commit').disabled = true;
  try {
    const result = await request('/api/commit', {
      method:'POST', headers:{'Content-Type':'application/json','X-Console-Token':token},
      body:JSON.stringify({message:$('message').value})
    });
    select(result.id);
  } catch (error) { $('error').textContent = error.message; }
  await refresh();
};
refresh();
setInterval(refresh, 1200);
