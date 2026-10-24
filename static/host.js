// Which fleet host this page talks to. Shared by index.html and plans.html.
// The pick lives in localStorage; every API call carries it as ?host=. Session
// names are only unique per host, so pages key their own state by host too.
let host = '';
try { host = localStorage.getItem('cchost') || ''; } catch {}

function api(path, opts) {
  const u = new URL(path, location.origin);
  if (host) u.searchParams.set('host', host);   // empty = server default (first registry entry)
  return fetch(u, opts);
}

// Fill <select> from /api/hosts (offline hosts greyed out), restore the saved
// pick, and call onChange after a switch. Resolves to the active host name.
async function initHostSelect(sel, onChange) {
  const hosts = await fetch('/api/hosts').then(r => r.json()).catch(() => []);
  if (!hosts.some(h => h.name === host)) host = hosts[0]?.name || '';
  sel.innerHTML = hosts.map(h =>
    `<option value="${h.name}" ${h.online ? '' : 'disabled'} ${h.name === host ? 'selected' : ''}>` +
    `${h.name}${h.online ? '' : ' · offline'}</option>`).join('');
  sel.title = hosts.map(h => `${h.name} → ${h.alias}`).join('\n');
  sel.onchange = () => {
    host = sel.value;
    try { localStorage.setItem('cchost', host); } catch {}
    onChange();
  };
  return host;
}
