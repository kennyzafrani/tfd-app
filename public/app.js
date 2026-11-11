'use strict';
// TFD app front end (Phase 1: shell, sign-in, Settings, Activity Log).
const $ = s => document.querySelector(s);
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const money = c => c === null || c === undefined ? '—' : '$' + (c / 100).toFixed(2);
const pct = b => b === null || b === undefined ? '—' : (b / 100) + '%';
const when = iso => new Date(iso).toLocaleString([], { month: 'short', day: 'numeric', year: 'numeric', hour: 'numeric', minute: '2-digit' });

let S = { state: null, settings: null, users: null, section: 'platforms' };

// ---- Supabase connection (no library needed: plain REST calls) ----
const STAFF_DOMAIN = 'staff.theframedrop.local';   // staff sign in with a username; this turns it into a login id
let CFG = null;
const SESSION_KEY = 'tfd_session';
function loadSession() { try { return JSON.parse(localStorage.getItem(SESSION_KEY)); } catch { return null; } }
function saveSession(x) { try { x ? localStorage.setItem(SESSION_KEY, JSON.stringify(x)) : localStorage.removeItem(SESSION_KEY); } catch {} }
const toLogin = u => u.includes('@') ? u.trim().toLowerCase() : u.trim().toLowerCase() + '@' + STAFF_DOMAIN;

async function authCall(grant, body) {
  const r = await fetch(`${CFG.url}/auth/v1/token?grant_type=${grant}`, { method: 'POST', headers: { apikey: CFG.anonKey, 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.error_description === 'Invalid login credentials' || d.msg === 'Invalid login credentials' ? 'Wrong username or password' : (d.error_description || d.msg || 'Sign-in failed'));
  const sess = { access: d.access_token, refresh: d.refresh_token, expires: Date.now() + d.expires_in * 1000, last: Date.now() };
  saveSession(sess); return sess;
}
async function token() {
  let s = loadSession();
  if (!s) return null;
  if (S.state && S.state.me && S.state.me.role === 'admin' && Date.now() - s.last > (S.state.idle_signout_minutes || 15) * 60000) { saveSession(null); S.idleOut = true; return null; }
  if (Date.now() > s.expires - 60000) { try { s = await authCall('refresh_token', { refresh_token: s.refresh }); } catch { saveSession(null); return null; } }
  s.last = Date.now(); saveSession(s);
  return s.access;
}
async function rpc(fn, args = {}) {
  const t = await token();
  if (!t && S.state && S.state.me) { await boot(); throw new Error('Signed out'); }
  const r = await fetch(`${CFG.url}/rest/v1/rpc/${fn}`, { method: 'POST', headers: { apikey: CFG.anonKey, ...(t ? { Authorization: 'Bearer ' + t } : CFG.anonKey.startsWith('eyJ') ? { Authorization: 'Bearer ' + CFG.anonKey } : {}), 'Content-Type': 'application/json' }, body: JSON.stringify(args) });
  const d = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(d.message || 'Request failed');
  return d;
}
async function server(method, path, body) {   // the website's own server functions (/api/...)
  const t = await token();
  const r = await fetch(path, { method, headers: { 'Content-Type': 'application/json', ...(t ? { Authorization: 'Bearer ' + t } : {}) }, body: body ? JSON.stringify(body) : undefined });
  const d = await r.json().catch(() => ({}));
  if (r.status === 401 && S.state && S.state.me) { await signOut(); toast(d.error || 'Please sign in again', true); document.querySelectorAll('.modal-bg').forEach(x => x.remove()); await boot(); throw new Error(d.error || 'Signed out'); }
  if (!r.ok) throw new Error(d.error || 'Request failed');
  return d;
}
async function signOut() { const t = loadSession(); saveSession(null); S.state = null;
  if (t) fetch(`${CFG.url}/auth/v1/logout`, { method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t.access } }).catch(() => {}); }
['click', 'keydown'].forEach(ev => document.addEventListener(ev, () => { const s = loadSession(); if (s && S.state && S.state.me) { s.last = Date.now(); saveSession(s); } }, true));
setInterval(() => { if (S.state && S.state.me) token().then(t => { if (!t) boot(); }); }, 30000);

function toast(msg, bad) {
  const t = $('#toast'); t.textContent = msg; t.className = 'toast' + (bad ? ' bad' : '');
  clearTimeout(toast.t); toast.t = setTimeout(() => t.classList.add('hidden'), 3500);
}

// ---------------- boot / sign in ----------------
async function boot() {
  if (!CFG) CFG = await (await fetch('/api/config')).json();
  if (!CFG.url) throw new Error('The website is missing its Supabase settings (SUPABASE_URL / SUPABASE_ANON_KEY in Netlify).');
  S.state = null;
  if (await token()) {
    S.state = await rpc('tfd_state');
    if (S.state.me) return route();
    saveSession(null);
  }
  const st = await server('GET', '/api/users');
  if (st.setupNeeded) return renderSetup();
  renderSignIn();
}
function renderSetup() {
  $('#app').innerHTML = `<div class="center"><div class="card">
    <h1>Welcome to The Frame Drop</h1><p class="muted">Create the first admin account. You can add everyone else in Settings.</p>
    <label class="f">Your name<input id="sn" class="inp" autocomplete="off"></label><br>
    <label class="f">Email (you sign in with this)<input id="se_" class="inp" type="email" autocomplete="username"></label><br>
    <label class="f">Password (8+ characters)<input id="sp" class="inp" type="password" autocomplete="new-password"></label>
    <div class="err" id="se"></div>
    <div class="actions"><button class="btn primary" id="sb">Create admin</button></div></div></div>`;
  $('#sb').onclick = async () => {
    try {
      await server('POST', '/api/users', { name: $('#sn').value, login: $('#se_').value, password: $('#sp').value, role: 'admin' });
      await authCall('password', { email: toLogin($('#se_').value), password: $('#sp').value }); await boot();
    } catch (e) { $('#se').textContent = e.message; }
  };
}
function renderSignIn() {
  const idle = S.idleOut; S.idleOut = false;
  $('#app').innerHTML = `<div class="center"><form class="card" id="lf">
    <h1>The Frame Drop</h1>
    ${idle ? '<div class="note warn">Signed out after being idle. Sign in again to continue.</div>' : '<p class="muted">Sign in with your username (or email) and password.</p>'}
    <label class="f">Username or email<input id="lu" class="inp" autocomplete="username" autocapitalize="none"></label><br>
    <label class="f">Password<input id="lp" class="inp" type="password" autocomplete="current-password"></label>
    <div class="err" id="le"></div>
    <div class="actions"><button class="btn primary" type="submit">Sign in</button></div></form></div>`;
  $('#lu').focus();
  $('#lf').onsubmit = async e => {
    e.preventDefault();
    try { await authCall('password', { email: toLogin($('#lu').value), password: $('#lp').value }); await boot(); }
    catch (err) { $('#le').textContent = err.message; $('#lp').value = ''; }
  };
}

// ---------------- shell ----------------
const TABS = [
  { id: 'dashboard', label: 'Dashboard', phase: 4, can: p => p.dashboard !== 'none' },
  { id: 'inventory', label: 'Inventory', phase: 2, can: p => p.inventory_edit || p.cost_profit },
  { id: 'shows', label: 'Shows', phase: 3, can: p => p.live_mapping !== 'none' },
  { id: 'fulfillment', label: 'Fulfillment', phase: 5, can: p => p.fulfillment },
  { id: 'payroll', label: 'Payroll', phase: 6, can: p => p.payroll !== 'none' },
  { id: 'settings', label: 'Settings', can: p => p.settings !== 'no' },
  { id: 'activity', label: 'Activity Log', can: p => p.activity_log },
];
function route() {
  const p = S.state.perms;
  const allowed = TABS.filter(t => t.can(p));
  let id = location.hash.slice(1).split('/')[0] || allowed[0]?.id;
  if (!allowed.find(t => t.id === id)) id = allowed[0]?.id;
  $('#app').innerHTML = `<div class="top"><div class="brand">THE FRAME DROP</div>
    <nav class="tabs">${allowed.map(t => `<a href="#${t.id}" class="${t.id === id ? 'on' : ''}">${t.label}</a>`).join('')}</nav>
    <div class="who">${esc(S.state.me.name)} · ${esc(S.state.me.role)}<button id="lock">Sign out</button></div></div><main id="main"></main>`;
  $('#lock').onclick = async () => { await signOut(); await boot(); };
  const tab = TABS.find(t => t.id === id);
  if (id === 'settings') return renderSettings();
  if (id === 'activity') return renderActivity();
  if (id === 'inventory') return renderInventory();
  $('#main').innerHTML = `<div class="panel placeholder"><h1>${tab.label}</h1>
    <p class="muted">This tab is fully spec'd and gets built in Phase ${tab.phase}.</p></div>`;
}
window.addEventListener('hashchange', () => S.state && S.state.me && route());

// ---------------- settings ----------------
const SECTIONS = [
  ['platforms', 'Platforms & fees'], ['pay', 'Pay rates & overtime'], ['people', 'People'], ['roles', 'Roles & access'],
  ['pricing', 'Pricing'], ['rules', 'Rules'], ['inventory', 'Inventory'], ['values', 'Dropdown values'], ['photos', 'Packing photos'],
  ['backups', 'Backups'], ['security', 'Security'], ['whatnot', 'Whatnot export'],
];
async function renderSettings() {
  const sub = location.hash.split('/')[1];
  if (sub && SECTIONS.find(s => s[0] === sub)) S.section = sub;
  S.settings = await rpc('tfd_settings');
  $('#main').innerHTML = `<div class="head"><div><h1>Settings</h1><p class="muted small">Changes apply from now on. Past shows and pay keep the values they ran under.</p></div></div>
    <div class="settings"><nav class="side">${SECTIONS.map(([k, l]) => `<a href="#settings/${k}" class="${k === S.section ? 'on' : ''}">${l}</a>`).join('')}</nav>
    <div id="sec"></div></div>`;
  const fn = { platforms: secPlatforms, pay: secPay, people: secPeople, roles: secRoles, pricing: secPricing, rules: secRules,
    inventory: secInventory, values: secValues, photos: secPhotos, backups: secBackups, security: secSecurity, whatnot: secWhatnot }[S.section];
  await fn($('#sec'));
}

// field helpers: read inputs back into setting objects
const F = {
  pct: (id, v, opt = {}) => `<div class="affix"><input id="${id}" type="number" step="0.01" min="0" value="${v === null ? '' : v / 100}" placeholder="${opt.ph || ''}"><span>%</span></div>`,
  money: (id, v, opt = {}) => `<div class="affix"><span>$</span><input id="${id}" type="number" step="0.01" min="0" value="${v === null ? '' : (v / 100).toFixed(2)}" placeholder="${opt.ph || ''}"></div>`,
  int: (id, v) => `<input id="${id}" class="inp" type="number" step="1" min="0" value="${v}">`,
  read: {
    pct: (id, nullable) => { const s = $('#' + id).value.trim(); if (s === '') { if (nullable) return null; throw new Error('Fill in every field'); } return Math.round(Number(s) * 100); },
    money: (id, nullable) => { const s = $('#' + id).value.trim(); if (s === '') { if (nullable) return null; throw new Error('Fill in every field'); } return Math.round(Number(s) * 100); },
    int: id => { const s = $('#' + id).value.trim(); if (s === '' || !Number.isInteger(Number(s))) throw new Error('Use whole numbers'); return Number(s); },
  },
};
function sw(id, on) { return `<label class="switch"><input type="checkbox" id="${id}" ${on ? 'checked' : ''}><span></span></label>`; }
async function saveSetting(key, value, btn) {
  if (btn) btn.disabled = true;
  try { const r = await rpc('tfd_set_setting', { p_key: key, p_value: value }); toast(r.unchanged ? 'No changes' : 'Saved'); await renderSettings(); }
  catch (e) { toast(e.message, true); if (btn) btn.disabled = false; }
}
function historyLink(key) { return `<button class="btn" data-hist="${key}">History</button>`; }
function wireHistory(el) {
  el.querySelectorAll('[data-hist]').forEach(b => b.onclick = async () => {
    const rows = await rpc('tfd_setting_history', { p_key: b.dataset.hist });
    modal(`<h2>Change history</h2><table><tr><th>Effective</th><th>By</th><th>Value</th></tr>${rows.map(r =>
      `<tr><td class="small">${r.effective_from.startsWith('2000') ? 'Original default' : when(r.effective_from)}</td><td>${esc(r.set_by)}</td><td class="small mono">${esc(JSON.stringify(r.value))}</td></tr>`).join('')}</table>`);
  });
}
function modal(html) {
  const m = document.createElement('div'); m.className = 'modal-bg';
  m.innerHTML = `<div class="modal">${html}<div class="actions"><button class="btn" data-close>Close</button></div></div>`;
  m.onclick = e => { if (e.target === m || e.target.dataset.close !== undefined) m.remove(); };
  document.body.appendChild(m); return m;
}

function secPlatforms(el) {
  const st = S.settings.settings;
  const card = k => { const p = st['platform.' + k]; return `<div class="panel"><div class="head"><h2>${esc(p.label)}</h2>${historyLink('platform.' + k)}</div>
    <div class="grid">
      <label class="f">Fee: % of sale price${F.pct(k + '_sale', p.pct_sale_bp, { ph: 'Not set' })}</label>
      <label class="f">Fee: % of customer shipping${F.pct(k + '_ship', p.pct_ship_bp, { ph: 'Not set' })}</label>
      <label class="f">Fee: fixed per order${F.money(k + '_fixed', p.fixed_cents, { ph: 'Not set' })}</label>
      <label class="f">Typical customer shipping${F.money(k + '_ts', p.typical_ship_cents, { ph: 'Not set' })}</label>
    </div>
    ${p.pct_sale_bp === null ? '<div class="note warn">Fees not set: floor prices for this platform show as "not set".</div>' : p.typical_ship_cents === null ? '<div class="note warn">Typical shipping not set: floors use $0 shipping and are flagged.</div>' : ''}
    <div class="actions"><button class="btn primary" data-save="${k}">Save ${esc(p.label)}</button></div></div>`; };
  el.innerHTML = card('tiktok') + card('whatnot') + `<div class="panel"><h2>Floor price check</h2>
    <p class="muted small">Uses the saved fees above, the streamer default commission and the floor profit % from Pricing.</p>
    <div class="row"><label class="f">Cost${F.money('fc', 5000)}</label><label class="f">Platform<select id="fp" class="inp"><option value="tiktok">TikTok</option><option value="whatnot">Whatnot</option></select></label>
    <button class="btn" id="fgo" style="align-self:flex-end">Calculate</button></div><div id="fout" style="margin-top:12px"></div></div>`;
  el.querySelectorAll('[data-save]').forEach(b => b.onclick = () => {
    const k = b.dataset.save; const p = st['platform.' + k];
    try { saveSetting('platform.' + k, { label: p.label, pct_sale_bp: F.read.pct(k + '_sale', true), pct_ship_bp: F.read.pct(k + '_ship', true), fixed_cents: F.read.money(k + '_fixed', true), typical_ship_cents: F.read.money(k + '_ts', true) }, b); }
    catch (e) { toast(e.message, true); }
  });
  $('#fgo').onclick = async () => {
    const r = await rpc('tfd_floor_preview', { p_cost_cents: Math.round(Number($('#fc').value) * 100), p_platform: $('#fp').value });
    $('#fout').innerHTML = r.flags.includes('fees_not_set') ? '<div class="note warn">Fees for this platform are not set.</div>'
      : `<div class="row"><div><div class="muted small">Streamer sees</div><div class="big">${money(r.rounded_cents)}</div></div>
         <div style="margin-left:24px"><div class="muted small">Exact floor</div><div class="mono">${money(r.exact_cents)}</div></div></div>
         ${r.flags.includes('shipping_not_set') ? '<div class="note warn">Typical shipping not set, so this assumes $0 shipping.</div>' : ''}`;
  };
  wireHistory(el);
}

function rateRow(role, label) {
  const r = S.settings.roleRates[role];
  return `<tr><td>${label}</td><td style="width:170px">${F.money('rh_' + role, r.hourly_cents)}</td><td style="width:150px">${F.pct('rc_' + role, r.commission_bp)}</td>
    <td style="width:90px"><button class="btn" data-rate="${role}">Save</button></td></tr>`;
}
function secPay(el) {
  const o = S.settings.settings.overtime;
  el.innerHTML = `<div class="panel"><h2>Role default pay</h2><p class="muted small">Used unless a person has their own rate (People) or a show override is set at review. Commission is on the price after platform fees.</p>
    <table><tr><th>Role</th><th>Hourly</th><th>Commission</th><th></th></tr>
    ${rateRow('streamer', 'Streamer')}${rateRow('assistant', 'Assistant')}${rateRow('packer', 'Packer')}</table>
    <p class="muted small">Assistants never earn commission or pull credit, whatever this says. Admins are unpaid.</p>
    <h3>Tiered commission</h3><p class="muted small">Builder arrives once you decide what tiers are based on.</p></div>
    <div class="panel"><div class="head"><h2>Overtime (packers only)</h2>${historyLink('overtime')}</div>
    <div class="grid"><label class="f">Weekly hours before overtime${F.int('ot_h', o.threshold_hours)}</label>
    <label class="f">Overtime multiplier<div class="affix"><input id="ot_m" type="number" step="0.05" min="1" value="${o.multiplier_bp / 10000}"><span>×</span></div></label>
    <label class="f">Workweek starts<select id="ot_w" class="inp">${['sunday', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday'].map(d => `<option ${d === o.week_start ? 'selected' : ''}>${d}</option>`).join('')}</select></label></div>
    <p class="muted small">Streamers and assistants never get overtime.</p>
    <div class="actions"><button class="btn primary" id="ot_s">Save overtime</button></div></div>`;
  el.querySelectorAll('[data-rate]').forEach(b => b.onclick = async () => {
    const role = b.dataset.rate;
    try { await rpc('tfd_set_rate', { p_scope: 'role', p_target: role, p_hourly_cents: F.read.money('rh_' + role), p_commission_bp: F.read.pct('rc_' + role) }); toast('Saved'); renderSettings(); }
    catch (e) { toast(e.message, true); }
  });
  $('#ot_s').onclick = e => { try { saveSetting('overtime', { threshold_hours: F.read.int('ot_h'), multiplier_bp: Math.round(Number($('#ot_m').value) * 10000), week_start: $('#ot_w').value }, e.target); } catch (err) { toast(err.message, true); } };
  wireHistory(el);
}

async function secPeople(el) {
  const users = await rpc('tfd_users');
  el.innerHTML = `<div class="panel"><div class="head"><h2>People</h2><button class="btn primary" id="add">Add person</button></div>
    <table><tr><th>Name</th><th>Role</th><th>Pay</th><th>Status</th><th></th></tr>
    ${users.map(u => `<tr><td>${esc(u.name)}${u.username ? `<div class="muted small">${esc(u.username)}</div>` : ''}</td><td>${u.role === 'claude' ? '<span class="tag claude">Claude</span>' : esc(u.role)}</td>
      <td class="small">${u.role === 'admin' ? 'Unpaid' : u.rate ? `${money(u.rate.hourly_cents)}/hr${u.rate.commission_bp ? ' + ' + pct(u.rate.commission_bp) : ''} <span class="muted">(${u.rate.source === 'person' ? 'own rate' : 'role default'})</span>` : '—'}</td>
      <td>${u.active ? 'Active' : '<span class="tag off">Inactive</span>'}</td>
      <td>${u.role === 'claude' ? '' : `<button class="btn" data-edit="${u.id}">Edit</button>`}</td></tr>`).join('')}</table>
    <p class="muted small">Inactive people keep all their history. Claude is its own user so the Activity Log shows exactly what Claude did.</p></div>`;
  $('#add').onclick = () => {
    const m = modal(`<h2>Add person</h2><div class="grid">
      <label class="f">Name<input id="an" class="inp"></label>
      <label class="f">Role<select id="ar" class="inp"><option value="streamer">Streamer</option><option value="assistant">Assistant</option><option value="packer">Packer</option><option value="admin">Admin</option></select></label>
      <label class="f">Username (or email for admins)<input id="au" class="inp" autocapitalize="none"></label>
      <label class="f">Password (8+ characters)<input id="ap" class="inp" type="password" autocomplete="new-password"></label></div>
      <p class="muted small">Pay starts at the role default. Set their own rate after adding, with Edit.</p>
      <div class="err" id="ae"></div><div class="actions"><button class="btn primary" id="as">Add</button></div>`);
    m.querySelector('#as').onclick = async () => {
      try { await server('POST', '/api/users', { name: $('#an').value, role: $('#ar').value, login: $('#au').value, password: $('#ap').value }); m.remove(); toast('Added'); renderSettings(); }
      catch (e) { $('#ae').textContent = e.message; }
    };
  };
  el.querySelectorAll('[data-edit]').forEach(b => b.onclick = () => {
    const u = users.find(x => x.id === Number(b.dataset.edit));
    const pr = u.personal || { hourly_cents: null, commission_bp: null };
    const m = modal(`<h2>Edit ${esc(u.name)}</h2><div class="grid">
      <label class="f">Name<input id="en" class="inp" value="${esc(u.name)}"></label>
      <label class="f">Role<select id="er" class="inp">${['streamer', 'assistant', 'packer', 'admin'].map(r => `<option ${r === u.role ? 'selected' : ''}>${r}</option>`).join('')}</select></label>
      <label class="f">New password (leave blank to keep)<input id="ep" class="inp" type="password" autocomplete="new-password"></label>
      <label class="f">Status<select id="ea" class="inp"><option value="1" ${u.active ? 'selected' : ''}>Active</option><option value="0" ${u.active ? '' : 'selected'}>Inactive</option></select></label></div>
      <h3>Own pay rate</h3><p class="muted small">Leave blank to use the role default. Applies from now on.</p>
      <div class="grid"><label class="f">Hourly${F.money('eh', pr.hourly_cents, { ph: 'Role default' })}</label><label class="f">Commission${F.pct('ec', pr.commission_bp, { ph: 'Role default' })}</label></div>
      <div class="err" id="ee"></div><div class="actions"><button class="btn primary" id="es">Save</button></div>`);
    m.querySelector('#es').onclick = async () => {
      try {
        await rpc('tfd_update_user', { p_id: u.id, p_name: $('#en').value, p_role: $('#er').value, p_active: $('#ea').value === '1' });
        if ($('#ep').value) await server('PATCH', '/api/users', { id: u.id, password: $('#ep').value });
        const h = F.read.money('eh', true), c = F.read.pct('ec', true);
        if (h !== pr.hourly_cents || c !== pr.commission_bp) await rpc('tfd_set_rate', { p_scope: 'user', p_target: String(u.id), p_hourly_cents: h, p_commission_bp: c });
        const ownPw = !!$('#ep').value && u.id === S.state.me.id;
        m.remove();
        if (ownPw && u.id === S.state.me.id) { await signOut(); await boot(); return toast('Password changed. Sign in with your new password.'); }
        toast('Saved'); renderSettings();
      } catch (e) { $('#ee').textContent = e.message; }
    };
  });
}

const PERM_ROWS = [
  ['dashboard', 'Dashboard', { all: 'All', own: 'Own stats only', none: 'No' }],
  ['cost_profit', 'Cost and profit'], ['inventory_edit', 'Inventory edits'],
  ['live_mapping', 'Live mapping', { full: 'Full', streamer_safe: 'Streamer-safe', none: 'No' }],
  ['fulfillment', 'Fulfillment'], ['payroll', 'Payroll', { all: 'All', own: 'Own pay only', none: 'No' }],
  ['settings', 'Settings', { yes: 'Yes', confirm: 'With confirmation', no: 'No' }], ['activity_log', 'Activity Log'],
];
function secRoles(el) {
  const roles = S.settings.roles;
  el.innerHTML = `<div class="panel"><h2>Roles & access</h2><p class="muted small">Changes apply the next time each person loads a page. Admins always keep Settings and Activity Log.</p>
    <div style="overflow-x:auto"><table class="roles"><tr><th>Permission</th>${roles.map(r => `<th>${esc(r.label)}</th>`).join('')}</tr>
    ${PERM_ROWS.map(([k, label, ch]) => `<tr><td>${label}</td>${roles.map(r => `<td>${ch
      ? `<select class="inp" data-r="${r.name}" data-k="${k}">${Object.entries(ch).map(([v, l]) => `<option value="${v}" ${r.perms[k] === v ? 'selected' : ''}>${l}</option>`).join('')}</select>`
      : sw(`p_${r.name}_${k}`, r.perms[k]).replace('<input', `<input data-r="${r.name}" data-k="${k}"`)}</td>`).join('')}</tr>`).join('')}
    <tr><td></td>${roles.map(r => `<td><button class="btn" data-saverole="${r.name}">Save</button></td>`).join('')}</tr></table></div>
    <p class="muted small">Every page and every change is checked against these roles by the database itself, not just hidden in the screen.</p></div>`;
  el.querySelectorAll('[data-saverole]').forEach(b => b.onclick = async () => {
    const name = b.dataset.saverole, perms = {};
    el.querySelectorAll(`[data-r="${name}"]`).forEach(i => perms[i.dataset.k] = i.type === 'checkbox' ? i.checked : i.value);
    try { const r = await rpc('tfd_set_role', { p_name: name, p_perms: perms }); toast(r.unchanged ? 'No changes' : 'Saved'); renderSettings(); } catch (e) { toast(e.message, true); }
  });
}

function secPricing(el) {
  const p = S.settings.settings.pricing;
  el.innerHTML = `<div class="panel"><div class="head"><h2>Pricing</h2>${historyLink('pricing')}</div><div class="grid">
    <label class="f">Floor profit (% of cost)${F.pct('pf', p.floor_profit_bp)}</label>
    <label class="f">Sold-near-floor threshold${F.pct('pn', p.near_floor_bp)}</label></div>
    <ul class="muted small"><li>Floor = lowest price where item profit is at least the floor profit % of cost, after platform fees and commission.</li>
    <li>Floors round up to the next whole dollar. The rounded floor is what the streamer sees and what below/near-floor checks use.</li>
    <li>Floors use the highest unit cost currently in stock for that SKU.</li>
    <li>A sale is "near floor" if it sold for less than the threshold above its floor.</li></ul>
    <div class="actions"><button class="btn primary" id="ps">Save pricing</button></div></div>`;
  $('#ps').onclick = e => { try { saveSetting('pricing', { floor_profit_bp: F.read.pct('pf'), near_floor_bp: F.read.pct('pn') }, e.target); } catch (err) { toast(err.message, true); } };
  wireHistory(el);
}

const RULES = [
  ['photo_required', 'Photo required for every package'], ['all_items_scanned', 'Every item scanned before a package can finish'],
  ['label_scan_required', 'Label scan required (search allowed as a fallback)'], ['adjust_reason_required', 'Reason required on every inventory adjustment'],
  ['adjust_confirm_enabled', 'Confirm large inventory adjustments'], ['unmatched_must_match', 'Unmatched orders must be matched by hand before a show can finalize'],
  ['inventory_locked_live', 'Inventory locked during live mapping (pause to add; subtracting asks to confirm)'],
  ['oversell_warnings', 'Oversell warnings (warn and explain; bypass with "Yes, I understand")'], ['claude_confirm_settings', 'Claude confirms with Kenny before changing settings'],
];
function secRules(el) {
  const r = S.settings.settings.rules;
  el.innerHTML = `<div class="panel"><div class="head"><h2>Rules</h2>${historyLink('rules')}</div>
    ${RULES.map(([k, l]) => `<div class="toggle"><span>${l}</span>${sw('r_' + k, r[k])}</div>`).join('')}
    <h3>Large adjustment = more than</h3><div class="grid"><label class="f">Units${F.int('r_units', r.adjust_confirm_units)}</label><label class="f">Value at cost${F.money('r_cents', r.adjust_confirm_cents)}</label></div>
    <div class="actions"><button class="btn primary" id="rs">Save rules</button></div></div>`;
  $('#rs').onclick = e => {
    try {
      const v = {}; RULES.forEach(([k]) => v[k] = $('#r_' + k).checked);
      v.adjust_confirm_units = F.read.int('r_units'); v.adjust_confirm_cents = F.read.money('r_cents');
      saveSetting('rules', v, e.target);
    } catch (err) { toast(err.message, true); }
  };
  wireHistory(el);
}

const REQ_GROUPS = [
  ['Lot', [['supplier', 'Supplier'], ['invoice_no', 'Invoice #'], ['received_date', 'Date received'], ['lot_photo', 'At least one lot photo (box / product)']]],
  ['Each SKU row', [['brand', 'Brand'], ['model', 'Model #'], ['color_code', 'Color code'], ['lens_size', 'Lens size'], ['upc', 'UPC'], ['name', 'Product name'],
    ['color_name', 'Color name'], ['retail', 'Retail price'], ['weight', 'Weight'], ['image_url', 'Listing image URL'], ['category', 'Category'],
    ['subcategory', 'Subcategory'], ['specs', 'Specs'], ['bin', 'Bin (if off, a blank bin goes to NOT_ASSIGNED)'], ['invoiced_qty', 'Invoiced qty'], ['received_qty', 'Received qty']]],
];
function secInventory(el) {
  const v = S.settings.settings.inventory;
  el.innerHTML = `<div class="panel"><div class="head"><h2>Inventory</h2>${historyLink('inventory')}</div>
    <h3>Required when confirming a lot</h3><p class="muted small">Turn on what every lot must have before you can confirm the count. Unit cost is always required (profit and floors depend on it).
      Product fields are only checked on NEW SKUs. Matched SKUs already have them.</p>
    ${REQ_GROUPS.map(([g, fields]) => `<h3 class="small muted" style="margin:14px 0 2px">${g}</h3>` + fields.map(([k, l]) => `<div class="toggle"><span>${l}</span>${sw('if_' + k, v.required_fields.includes(k))}</div>`).join('')).join('')}
    <div class="toggle"><span>Unit cost</span><span class="muted small">Always required</span></div>
    <h3>Show suggestions</h3><p class="muted small">Suggest a SKU for the next show when it has fewer than X units for Y or more shows.</p>
    <div class="grid"><label class="f">Fewer than (units)${F.int('is_u', v.show_suggest_max_units)}</label><label class="f">For at least (shows)${F.int('is_s', v.show_suggest_min_shows)}</label>
    <label class="f">Default low-stock threshold (units)${F.int('is_l', v.low_stock_default)}</label></div>
    <div class="actions"><button class="btn primary" id="is">Save inventory settings</button></div></div>`;
  $('#is').onclick = e => {
    try {
      const req = REQ_GROUPS.flatMap(([, f]) => f.map(([k]) => k)).filter(k => $('#if_' + k).checked);
      saveSetting('inventory', { required_fields: req, show_suggest_max_units: F.read.int('is_u'), show_suggest_min_shows: F.read.int('is_s'), low_stock_default: F.read.int('is_l') }, e.target);
    } catch (err) { toast(err.message, true); }
  };
  wireHistory(el);
}
const VALUE_FIELDS = [['supplier', 'Supplier'], ['brand', 'Brand'], ['model', 'Model #'], ['color_code', 'Color code'], ['lens_size', 'Lens size'], ['name', 'Product name'],
  ['color_name', 'Color name'], ['category', 'Category'], ['subcategory', 'Subcategory'], ['specs', 'Specs'], ['bin', 'Bin']];
async function secValues(el) {
  S.valueField = S.valueField || 'brand';
  const vals = await rpc('tfd_value_usage', { p_field: S.valueField });
  el.innerHTML = `<div class="panel"><h2>Dropdown values</h2>
    <p class="muted small">Every value you've typed in a lot shows up in the dropdowns. Fix a misspelling here and it changes everywhere: SKUs, lots (including confirmed ones) and the dropdowns.
      Renaming to a value that already exists merges the two. Every change is logged and can be rolled back from Inventory → Versions.</p>
    <div class="row" style="margin-bottom:12px"><select id="vf" class="inp">${VALUE_FIELDS.map(([k, l]) => `<option value="${k}" ${k === S.valueField ? 'selected' : ''}>${l}</option>`).join('')}</select>
      <input id="vq" class="inp" placeholder="Search values" style="flex:1;min-width:160px"></div>
    <table id="vt"></table></div>`;
  const used = v => S.valueField === 'supplier' ? `${v.lots} lot(s)` : S.valueField === 'bin' ? `${v.skus} SKU(s)` : [v.skus ? v.skus + ' SKU(s)' : '', v.rows ? v.rows + ' lot row(s)' : ''].filter(Boolean).join(', ');
  const draw = () => {
    const lc = $('#vq').value.trim().toLowerCase();
    $('#vt').innerHTML = `<tr><th>Value</th><th>Used in</th><th></th></tr>${vals.filter(v => !lc || v.value.toLowerCase().includes(lc)).map(v => `<tr><td><b>${esc(v.value)}</b></td><td class="small">${used(v)}</td>
      <td>${S.valueField === 'bin' && v.value === 'NOT_ASSIGNED' ? '' : `<button class="btn" data-ed="${esc(v.value)}">Fix spelling</button>`}</td></tr>`).join('') || '<tr><td colspan="3" class="muted">No values yet.</td></tr>'}`;
    el.querySelectorAll('[data-ed]').forEach(b => b.onclick = () => editValue(b.dataset.ed));
  };
  const editValue = old => {
    const label = VALUE_FIELDS.find(f => f[0] === S.valueField)[1];
    const m = modal(`<h2>Fix ${esc(label.toLowerCase())}</h2><p>Current: <b>${esc(old)}</b></p>
      <label class="f">Change to<input id="vn" class="inp" value="${esc(old)}"></label><div id="vp"></div>
      <div class="err" id="ve"></div><div class="actions"><button class="btn" id="vchk">Preview</button><button class="btn primary hidden" id="vgo">Change everywhere</button></div>`);
    const go = async confirm => {
      try {
        const r = await rpc('tfd_value_rename', { p_field: S.valueField, p_old: old, p_new: $('#vn').value, p_confirm: confirm });
        if (!confirm) {
          const what = [r.skus ? r.skus + ' SKU(s)' : '', r.rows ? r.rows + ' lot row(s)' : '', r.lots ? r.lots + ' lot(s)' : ''].filter(Boolean).join(', ') || 'the bin';
          $('#vp').innerHTML = r.blocked ? `<div class="note bad">Can't do this: it would make SKUs identical (same brand, model, color, size): ${esc(r.blocked)}. Fix one of those SKUs in Stock first.</div>`
            : `<div class="note ${r.merge ? 'warn' : ''}">Will change ${what} from "${esc(old)}" to "${esc($('#vn').value.trim())}".${r.merge ? ' That value already exists, so the two will be merged into one.' : ''}</div>`;
          $('#vgo').classList.toggle('hidden', !!r.blocked);
          return;
        }
        m.remove(); toast('Changed everywhere'); secValues(el);
      } catch (e) { $('#ve').textContent = e.message; }
    };
    $('#vn').oninput = () => { $('#vgo').classList.add('hidden'); $('#vp').innerHTML = ''; };
    $('#vchk').onclick = () => go(false);
    $('#vgo').onclick = () => go(true);
  };
  $('#vf').onchange = () => { S.valueField = $('#vf').value; secValues(el); };
  $('#vq').oninput = draw;
  draw();
}
function secPhotos(el) {
  const v = S.settings.settings.photos;
  el.innerHTML = `<div class="panel"><div class="head"><h2>Packing photos</h2>${historyLink('photos')}</div>
    <div class="grid"><label class="f">Delete photos after (days)${F.int('ph_d', v.retention_days)}</label></div>
    <p class="muted small">Photos are compressed to about 200KB. A photo tied to an open refund or dispute is never auto-deleted, and every deletion is logged.</p>
    <div class="actions"><button class="btn primary" id="phs">Save</button></div></div>`;
  $('#phs').onclick = e => { try { saveSetting('photos', { retention_days: F.read.int('ph_d') }, e.target); } catch (err) { toast(err.message, true); } };
  wireHistory(el);
}
function secBackups(el) {
  el.innerHTML = `<div class="panel"><h2>Backups</h2>
    <p>The database lives on Supabase. On the Pro plan (switch before real shows) Supabase takes a <b>daily backup</b> automatically and keeps it for 7 days.</p>
    <p class="muted small">History is never overwritten inside the app either: every setting, rate and change is kept and shown in the Activity Log. A downloadable export arrives with Inventory.</p></div>`;
}
function secSecurity(el) {
  const v = S.settings.settings.security;
  el.innerHTML = `<div class="panel"><div class="head"><h2>Security</h2>${historyLink('security')}</div>
    <div class="grid"><label class="f">Sign admins out after idle (minutes)${F.int('sc_m', v.idle_signout_minutes)}</label></div>
    <div class="actions"><button class="btn primary" id="scs">Save</button></div></div>`;
  $('#scs').onclick = e => { try { saveSetting('security', { idle_signout_minutes: F.read.int('sc_m') }, e.target); } catch (err) { toast(err.message, true); } };
  wireHistory(el);
}
function secWhatnot(el) {
  const v = S.settings.settings.whatnot_export;
  const txt = (id, label, val, ph = '') => `<label class="f">${label}<input id="${id}" class="inp" value="${esc(val || '')}" placeholder="${ph}"></label>`;
  el.innerHTML = `<div class="panel"><div class="head"><h2>Whatnot export</h2>${historyLink('whatnot_export')}</div>
    <p class="muted small">Values written into every row of the Whatnot bulk-upload file. Type them exactly as Whatnot's own template expects (copy them from a row Whatnot accepted).</p>
    <div class="grid">${txt('wn_c', 'Category', v.category)}${txt('wn_s', 'Sub Category', v.subcategory)}${txt('wn_t', 'Type', v.type, 'Not set')}
      <label class="f">Price column<select id="wn_p" class="inp"><option value="retail" ${v.price_source === 'retail' ? 'selected' : ''}>Retail price</option><option value="floor" ${v.price_source === 'floor' ? 'selected' : ''}>Floor price (Whatnot)</option></select></label>
      ${txt('wn_sp', 'Shipping Profile', v.shipping_profile, 'Not set')}${txt('wn_o', 'Offerable', v.offerable, 'e.g. TRUE or FALSE')}${txt('wn_h', 'Hazmat', v.hazmat, 'Not set')}${txt('wn_cd', 'Condition', v.condition, 'Not set')}</div>
    <div class="actions"><button class="btn primary" id="wns">Save</button></div></div>`;
  $('#wns').onclick = e => saveSetting('whatnot_export', { category: $('#wn_c').value, subcategory: $('#wn_s').value, type: $('#wn_t').value, price_source: $('#wn_p').value,
    shipping_profile: $('#wn_sp').value, offerable: $('#wn_o').value.toUpperCase(), hazmat: $('#wn_h').value, condition: $('#wn_cd').value }, e.target);
  wireHistory(el);
}
// ---------------- activity log ----------------
async function renderActivity() {
  const q = S.actQ || {};
  const d = await rpc('tfd_activity', { p_filters: Object.fromEntries(Object.entries(q).filter(([, v]) => v)) });
  const opt = (arr, cur) => '<option value="">All</option>' + arr.map(a => `<option ${a === cur ? 'selected' : ''}>${esc(a)}</option>`).join('');
  $('#main').innerHTML = `<div class="head"><div><h1>Activity Log</h1><p class="muted small">Every change, who made it and why. Entries can't be edited or deleted.</p></div></div>
    <div class="panel"><div class="grid">
      <label class="f">From<input type="date" id="af" class="inp" value="${q.from || ''}"></label><label class="f">To<input type="date" id="at" class="inp" value="${q.to || ''}"></label>
      <label class="f">Who<select id="aa" class="inp">${opt(d.facets.actors, q.actor)}</select></label><label class="f">Tab<select id="ab" class="inp">${opt(d.facets.tabs, q.tab)}</select></label>
      <label class="f">Action<select id="ac" class="inp">${opt(d.facets.actions, q.action)}</select></label><label class="f">Search (SKU, show, order #…)<input id="aq" class="inp" value="${esc(q.q || '')}"></label></div>
      <div class="actions"><button class="btn" id="ax">Clear</button><button class="btn primary" id="ago">Filter</button></div></div>
    <div class="panel"><table><tr><th>When</th><th>Who</th><th>Tab</th><th>What changed</th><th></th></tr>
    ${d.rows.map(r => `<tr><td class="small" style="white-space:nowrap">${when(r.at)}</td>
      <td>${r.actor === 'Claude' ? '<span class="tag claude">Claude</span>' : esc(r.actor)}</td><td class="small">${esc(r.tab)}</td>
      <td>${esc(r.summary)}${r.reason ? `<div class="muted small">Reason: ${esc(r.reason)}</div>` : ''}${r.request ? `<div class="muted small">Request: ${esc(r.request)}</div>` : ''}${r.file ? `<div class="muted small">File: ${esc(r.file)}</div>` : ''}${r.undone_by ? `<div class="small"><span class="tag off">Undone (#${r.undone_by})</span></div>` : ''}</td>
      <td>${r.can_undo ? `<button class="btn" data-undo="${r.id}">Undo</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">Nothing here yet.</td></tr>'}
    </table></div>`;
  $('#ago').onclick = () => { S.actQ = { from: $('#af').value, to: $('#at').value, actor: $('#aa').value, tab: $('#ab').value, action: $('#ac').value, q: $('#aq').value }; renderActivity(); };
  $('#ax').onclick = () => { S.actQ = {}; renderActivity(); };
  document.querySelectorAll('[data-undo]').forEach(b => b.onclick = () => {
    const r = d.rows.find(x => x.id === Number(b.dataset.undo));
    const m = modal(`<h2>Undo this change?</h2><p>${esc(r.summary)}</p><label class="f">Reason<input id="ur" class="inp"></label><div class="err" id="ue"></div>
      <div class="actions"><button class="btn primary" id="uy">Undo</button></div>`);
    m.querySelector('#uy').onclick = async () => {
      try { await rpc('tfd_undo', { p_id: r.id, p_reason: $('#ur').value, p_confirm: true }); m.remove(); toast('Undone'); renderActivity(); }
      catch (e) { $('#ue').textContent = e.message; }
    };
  });
}

boot().catch(e => { $('#app').innerHTML = `<div class="center"><div class="card"><h1>Can't reach the app</h1><p class="muted">${esc(e.message)}</p></div></div>`; });
