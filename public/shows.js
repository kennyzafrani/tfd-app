'use strict';
// Shows tab: list (multi-delete, restore), setup (live mapping / listed, per-show fees), live screen (streamer-safe,
// offline-tolerant scans, double-scan guard, beeps), listed-show lookups + Record win, conclude → hours → (Phase 4) CSV + finalize.

const STAGE = { setup: ['Live', 'live'], live: ['Live', 'live'], ended: ['Concluded', 'off'], matched: ['Matched', ''], finalized: ['Finalized', 'ok'] };
const stageTag = st => `<span class="tag ${STAGE[st]?.[1] || ''}">${STAGE[st]?.[0] || esc(st)}</span>`;
const isNetErr = e => e instanceof TypeError || /Failed to fetch|NetworkError|Load failed/i.test(e.message || '');
const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => (Math.random() * 16 | 0).toString(16)));
const platName = p => p === 'tiktok' ? 'TikTok' : 'Whatnot';
const pctTxt = bp => bp == null ? 'not set' : (bp / 100) + '%';
const feeTxt = f => !f || f.pct_sale_bp == null ? 'Fee not set' : `Fee ${pctTxt(f.pct_sale_bp)} of sale${f.pct_ship_bp ? ` + ${pctTxt(f.pct_ship_bp)} of shipping` : ''}${f.fixed_cents ? ` + $${(f.fixed_cents / 100).toFixed(2)}` : ''}`;

// short beeps: good scan, warning, blocked
const BEEP = { ctx: null };
function beep(kind) {
  try {
    BEEP.ctx = BEEP.ctx || new (window.AudioContext || window.webkitAudioContext)();
    const c = BEEP.ctx, tones = kind === 'ok' ? [[1320, 0.08]] : kind === 'warn' ? [[660, 0.12], [660, 0.12]] : [[220, 0.35]];
    let t = c.currentTime;
    tones.forEach(([f, d]) => { const o = c.createOscillator(), g = c.createGain(); o.frequency.value = f; o.type = 'square'; g.gain.value = 0.08;
      o.connect(g); g.connect(c.destination); o.start(t); o.stop(t + d); t += d + 0.06; });
  } catch {}
}

async function renderShows() {
  const [, a, b] = location.hash.slice(1).split('/');
  const main = $('#main');
  try {
    if (a === 'new') return showSetup(main, null);
    if (a === 'deleted') return showList(main, true);
    if (a && b === 'edit') return showSetup(main, Number(a));
    if (a) return showPage(main, Number(a));
    return showList(main, false);
  } catch (e) { main.innerHTML = `<div class="note bad">${esc(e.message)}</div>`; }
}

// ================================================================ list
async function showList(main, deleted) {
  const admin = S.state.me.role === 'admin';
  const shows = await rpc(deleted ? 'tfd_shows_deleted' : 'tfd_shows');
  const sel = new Set();
  main.innerHTML = `<div class="head"><div><h1>${deleted ? 'Deleted shows' : 'Shows'}</h1><p class="muted small">${deleted ? 'Hidden shows. Restore puts a show back with its pulls held again.' : 'Every show with its stage. Click one to open it.'}</p></div>
      <div class="row">${admin ? (deleted ? '<a class="btn" href="#shows">← Back to shows</a>' : '<a class="btn" href="#shows/deleted">Deleted</a><button class="btn danger" id="dsel" disabled>Delete selected</button><a class="btn primary" href="#shows/new">New show</a>') : ''}</div></div>
    <div class="panel"><div style="overflow-x:auto"><table><tr>${admin && !deleted ? '<th><input type="checkbox" id="sall"></th>' : ''}<th>Date</th><th>Show</th><th>Type</th><th>Platform</th><th>Fee</th><th>Lineup</th><th>Pulls</th><th>Hours</th><th>${deleted ? 'Deleted' : 'Stage'}</th></tr>
    ${shows.map(s => `<tr class="${deleted ? '' : 'click'}" data-show="${s.id}">${admin && !deleted ? `<td data-cb><input type="checkbox" data-sel="${s.id}" ${s.status === 'finalized' || s.status === 'matched' ? 'disabled title="Unfinalize first"' : ''}></td>` : ''}
      <td class="small" style="white-space:nowrap">${new Date(s.started_at || s.created_at).toLocaleDateString()}</td>
      <td><b>${esc(s.label)}</b><div class="muted small">${esc(s.list_name)}</div></td><td>${s.type === 'listed' ? 'Listed' : 'Live mapping'}</td><td>${platName(s.platform)}</td>
      <td>${pctTxt(s.fee_bp)}</td><td class="small">${s.lineup.map(esc).join(', ')}</td><td>${s.pulls}</td><td>${s.hours ? Number(s.hours).toFixed(2) : '—'}</td>
      <td>${deleted ? `<div class="small">${when(s.deleted_at)} by ${esc(s.deleted_by)}<div class="muted">${esc(s.deleted_reason || '')}</div></div><button class="btn sm" data-rs="${s.id}">Restore</button>` : stageTag(s.status)}</td></tr>`).join('')
      || `<tr><td colspan="10" class="muted">${deleted ? 'Nothing deleted.' : 'No shows yet.' + (admin ? ' Click New show.' : '')}</td></tr>`}</table></div></div>`;
  if (!deleted) main.querySelectorAll('tr[data-show]').forEach(tr => tr.onclick = e => { if (e.target.closest('[data-cb]')) return; location.hash = '#shows/' + tr.dataset.show; });
  const upd = () => { const b = $('#dsel'); if (b) { b.disabled = !sel.size; b.textContent = sel.size ? `Delete selected (${sel.size})` : 'Delete selected'; } };
  main.querySelectorAll('[data-sel]').forEach(cb => cb.onchange = () => { cb.checked ? sel.add(Number(cb.dataset.sel)) : sel.delete(Number(cb.dataset.sel)); upd(); });
  if ($('#sall')) $('#sall').onchange = e => { main.querySelectorAll('[data-sel]:not([disabled])').forEach(cb => { cb.checked = e.target.checked; cb.onchange(); }); };
  if ($('#dsel')) $('#dsel').onclick = () => {
    const picked = shows.filter(s => sel.has(s.id)), held = picked.reduce((a, s) => a + s.pulls, 0);
    const m = modal(`<h2>Delete ${picked.length} show${picked.length > 1 ? 's' : ''}?</h2><p>${picked.map(s => esc(s.label)).join(', ')}</p>
      <p>${held ? `<b>${held}</b> held unit(s) go back to available.` : 'Nothing is held.'} The show is hidden, not erased: restore it any time from <b>Deleted</b>.</p>
      <label class="f">Reason<input id="dr" class="inp" placeholder="e.g. test show"></label><div class="err" id="de"></div>
      <div class="actions"><button class="btn danger" id="dy">Delete</button></div>`);
    m.querySelector('#dy').onclick = async () => {
      try { const r = await rpc('tfd_show_delete', { p_ids: [...sel], p_reason: m.querySelector('#dr').value }); m.remove(); toast(`Deleted ${r.deleted} show(s)`); renderShows(); }
      catch (e) { m.querySelector('#de').textContent = e.message; }
    };
  };
  main.querySelectorAll('[data-rs]').forEach(b => b.onclick = () => {
    const s = shows.find(x => x.id === Number(b.dataset.rs));
    const m = modal(`<h2>Restore ${esc(s.label)}?</h2><p>It comes back with its ${s.pulls} pull(s) held again (only if there's enough stock).</p>
      <label class="f">Reason<input id="rr" class="inp"></label><div class="err" id="re"></div><div class="actions"><button class="btn primary" id="ry">Restore</button></div>`);
    m.querySelector('#ry').onclick = async () => { try { await rpc('tfd_show_restore', { p_id: s.id, p_reason: m.querySelector('#rr').value }); m.remove(); toast('Restored'); location.hash = '#shows/' + s.id; } catch (e) { m.querySelector('#re').textContent = e.message; } };
  });
}

// ================================================================ setup (new or edit)
async function showSetup(main, id) {
  const [opt, s] = await Promise.all([rpc('tfd_lineup_options'), id ? rpc('tfd_show', { p_id: id }) : null]);
  if (s && (s.status === 'finalized' || s.status === 'matched')) { location.hash = '#shows/' + id; return; }
  const hasPulls = s ? s.pulls.some(p => p.status !== 'void') : false;
  const v = s ? { type: s.type, platform: s.platform, name: s.name || '', list_id: s.list_id || '', split_mode: s.split_mode || 'even', fees: { ...s.fees },
      people: s.people.map(p => ({ profile_id: p.profile_id, role: p.role, hourly_cents: p.hourly_cents, commission_bp: p.commission_bp, lead: p.lead })) }
    : { type: 'live', platform: 'tiktok', name: '', list_id: '', split_mode: 'even', fees: { ...opt.platforms.tiktok }, people: [] };
  const person = pid => opt.people.find(p => p.id === Number(pid));
  const rateFor = (pid, role) => { const p = person(pid); return p ? p[role] : { hourly_cents: 0, commission_bp: 0 }; };
  const lock = hasPulls ? 'disabled title="Can\'t change once the show has pulls"' : '';
  main.innerHTML = `<div class="head"><div><a href="${id ? '#shows/' + id : '#shows'}" class="small">← ${id ? 'Back to show' : 'All shows'}</a><h1>${id ? 'Edit show setup' : 'New show'}</h1></div></div>
    <div class="panel"><h2>1. Show type</h2><div class="seg" id="ty">${[['live', 'Live mapping (random pulls)'], ['listed', 'Listed']].map(([k, l]) => `<button data-v="${k}" class="${v.type === k ? 'on' : ''}" ${lock}>${l}</button>`).join('')}</div>
      <p class="muted small" id="tyhelp"></p></div>
    <div class="panel"><h2>2. Platform & fee</h2><div class="seg" id="pl">${[['tiktok', 'TikTok'], ['whatnot', 'Whatnot']].map(([k, l]) => `<button data-v="${k}" class="${v.platform === k ? 'on' : ''}" ${lock}>${l}</button>`).join('')}</div>
      <div class="grid" style="margin-top:12px">
        <label class="f">Fee: % of sale price<div class="affix"><input id="f_sale" type="number" min="0" step="0.01" style="width:80px"><span>%</span></div></label>
        <label class="f">Fee: % of shipping<div class="affix"><input id="f_ship" type="number" min="0" step="0.01" style="width:80px"><span>%</span></div></label>
        <label class="f">Fixed fee per order<div class="affix"><span>$</span><input id="f_fix" type="number" min="0" step="0.01" style="width:80px"></div></label></div>
      <p class="muted small" id="plhelp"></p></div>
    <div class="panel"><h2>3. Inventory</h2><label class="f">What can be run on this show<select id="li" class="inp" ${lock}><option value="">Full inventory</option>
      ${opt.lists.map(l => `<option value="${l.id}" ${String(v.list_id) === String(l.id) ? 'selected' : ''}>${esc(l.name)}${l.pct ? ` (${l.pct}% of stock, hard cap)` : ''}</option>`).join('')}</select></label>
      <p class="muted small">Make lists in Inventory → Lists. A % list caps each SKU at that % of its available units, fixed when the show is created.</p></div>
    <div class="panel"><div class="head"><h2 style="margin:0">4. Lineup</h2><button class="btn" id="addp">Add person</button></div>
      <div id="ppl"></div><div id="split"></div>
      <p class="muted small">Add every streamer and assistant who works the show. Rates start at each person's default and only change for this show. Hours are entered after the show.</p></div>
    <div class="panel"><h2>5. Show name <span class="muted small">(optional)</span></h2><input id="nm" class="inp" style="width:100%" placeholder='The live title viewers see, e.g. "Halloween all day stream starting at $1!!"' value="${esc(v.name)}">
      <p class="muted small">A label for the shows list and Dashboard only. It plays no part in CSV matching.</p></div>
    <div class="err" id="se"></div><div class="actions"><button class="btn primary" id="sv">${id ? 'Save setup' : 'Create show & go live'}</button></div>`;
  const toBp = el => el.value === '' ? null : Math.round(Number(el.value) * 100);
  const fillFees = () => { $('#f_sale').value = v.fees.pct_sale_bp == null ? '' : v.fees.pct_sale_bp / 100; $('#f_ship').value = v.fees.pct_ship_bp == null ? '' : v.fees.pct_ship_bp / 100;
    $('#f_fix').value = v.fees.fixed_cents == null ? '' : (v.fees.fixed_cents / 100).toFixed(2); };
  const help = () => {
    $('#tyhelp').textContent = v.type === 'live' ? 'Scan every pull live. Each scan holds a unit until the show is finalized. A buyer\'s choice is just scanning the item they picked.'
      : 'Export your list to the platform before the show. Scans look items up; turn on Record win to log what a buyer picked.';
    $('#pl').querySelectorAll('button').forEach(b => b.classList.toggle('on', b.dataset.v === v.platform));
    const d = opt.platforms[v.platform];
    $('#plhelp').innerHTML = `Default from Settings: ${feeTxt(d)}. Change it here for a promo (e.g. 0%); it only affects this show and locks when the show is finalized. ${v.platform === 'whatnot' ? 'Giveaways allowed.' : 'No giveaways on TikTok.'}`;
  };
  const drawPeople = () => {
    const streamers = v.people.filter(p => p.role === 'streamer');
    $('#ppl').innerHTML = v.people.length ? `<div style="overflow-x:auto"><table><tr><th>Person</th><th>Role</th><th>Hourly</th><th>Commission</th>${streamers.length > 1 && v.split_mode === 'lead' ? '<th>Lead</th>' : ''}<th></th></tr>
      ${v.people.map((p, i) => `<tr><td><select class="inp" data-i="${i}" data-k="profile_id">${opt.people.filter(o => o.id === p.profile_id || !v.people.some(q => q.profile_id === o.id)).map(o => `<option value="${o.id}" ${o.id === p.profile_id ? 'selected' : ''}>${esc(o.name)} (${o.role})</option>`).join('')}</select></td>
        <td><select class="inp" data-i="${i}" data-k="role">${(person(p.profile_id)?.role === 'admin' ? ['assistant'] : ['streamer', 'assistant']).map(r => `<option ${r === p.role ? 'selected' : ''}>${r}</option>`).join('')}</select></td>
        <td><div class="affix"><span>$</span><input type="number" min="0" step="0.01" data-i="${i}" data-k="hourly_cents" value="${(p.hourly_cents / 100).toFixed(2)}" style="width:80px"><span>/hr</span></div></td>
        <td>${p.role === 'streamer' ? `<div class="affix"><input type="number" min="0" step="0.01" data-i="${i}" data-k="commission_bp" value="${p.commission_bp / 100}" style="width:60px"><span>%</span></div>` : '<span class="muted small">none</span>'}</td>
        ${streamers.length > 1 && v.split_mode === 'lead' ? `<td>${p.role === 'streamer' ? `<input type="radio" name="lead" data-i="${i}" data-k="lead" ${p.lead ? 'checked' : ''}>` : ''}</td>` : ''}
        <td><button class="btn sm danger" data-rm="${i}">×</button></td></tr>`).join('')}</table></div>` : '<p class="muted">Add at least one streamer.</p>';
    $('#split').innerHTML = streamers.length > 1 ? `<div class="row" style="margin-top:10px"><span class="small muted">Commission with more than one streamer:</span><div class="seg" id="sm">${[['even', 'Split evenly'], ['lead', 'Lead + support']].map(([k, l]) => `<button data-v="${k}" class="${v.split_mode === k ? 'on' : ''}">${l}</button>`).join('')}</div></div>` : '';
    $('#ppl').querySelectorAll('[data-k]').forEach(inp => inp.onchange = () => {
      const p = v.people[Number(inp.dataset.i)], k = inp.dataset.k;
      if (k === 'profile_id') { p.profile_id = Number(inp.value); if (person(p.profile_id).role === 'admin') p.role = 'assistant'; Object.assign(p, pick(rateFor(p.profile_id, p.role))); }
      else if (k === 'role') { p.role = inp.value; Object.assign(p, pick(rateFor(p.profile_id, p.role))); if (p.role === 'assistant') p.commission_bp = 0; }
      else if (k === 'hourly_cents') p.hourly_cents = Math.round(Number(inp.value || 0) * 100);
      else if (k === 'commission_bp') p.commission_bp = Math.round(Number(inp.value || 0) * 100);
      else if (k === 'lead') v.people.forEach((q, j) => q.lead = j === Number(inp.dataset.i));
      drawPeople();
    });
    $('#ppl').querySelectorAll('[data-rm]').forEach(b => b.onclick = () => { v.people.splice(Number(b.dataset.rm), 1); drawPeople(); });
    $('#sm')?.querySelectorAll('button').forEach(b => b.onclick = () => { v.split_mode = b.dataset.v; drawPeople(); });
  };
  const pick = r => ({ hourly_cents: r.hourly_cents, commission_bp: r.commission_bp });
  $('#ty').querySelectorAll('button').forEach(b => b.onclick = () => { if (b.disabled) return; v.type = b.dataset.v; $('#ty').querySelectorAll('button').forEach(x => x.classList.toggle('on', x === b)); help(); });
  $('#pl').querySelectorAll('button').forEach(b => b.onclick = () => { if (b.disabled || v.platform === b.dataset.v) return; v.platform = b.dataset.v; v.fees = { ...opt.platforms[v.platform] }; fillFees(); help(); });
  $('#addp').onclick = () => {
    const free = opt.people.find(o => !v.people.some(q => q.profile_id === o.id));
    if (!free) return toast('Everyone is already in the lineup', true);
    const role = free.role === 'streamer' ? 'streamer' : 'assistant';
    v.people.push({ profile_id: free.id, role, ...pick(rateFor(free.id, role)), lead: false }); drawPeople();
  };
  $('#sv').onclick = async () => {
    try {
      const fees = { pct_sale_bp: toBp($('#f_sale')), pct_ship_bp: toBp($('#f_ship')), fixed_cents: toBp($('#f_fix')), typical_ship_cents: v.fees.typical_ship_cents ?? null };
      const sid = await rpc('tfd_show_save', { p_id: id, p: { type: v.type, platform: v.platform, name: $('#nm').value, list_id: $('#li').value || null, split_mode: v.split_mode, fees,
        people: v.people.map(p => ({ ...p, lead: v.split_mode === 'lead' && p.lead })) } });
      toast(id ? 'Setup saved' : 'Show is live'); location.hash = '#shows/' + sid;
    } catch (e) { $('#se').textContent = e.message; }
  };
  fillFees(); help(); drawPeople();
}

// ================================================================ show page (by stage)
async function showPage(main, id) {
  const s = await rpc('tfd_show', { p_id: id });
  if (s.status === 'setup' || s.status === 'live') return liveScreen(main, s);
  return showEnded(main, s);
}

const lineupHtml = s => s.people.map(p => `${esc(p.name)} <span class="muted small">${p.role}${p.lead ? ', lead' : ''}${p.hourly_cents != null ? ` · $${(p.hourly_cents / 100).toFixed(2)}/hr${p.commission_bp ? ` + ${p.commission_bp / 100}%` : ''}` : ''}</span>`).join('<br>');

async function exportListing(s, done) {
  const run = async confirm => {
    const d = await rpc('tfd_show_export', { p_show: s.id, p_confirm: confirm });
    if (d.needs_confirm) {
      const m = modal(`<h2>This may oversell</h2><p>For these SKUs, what you're listing plus what other unfinished shows listed or hold is more than you have:</p>
        <table><tr><th>SKU</th><th>Listing</th><th>Other shows</th><th>Held</th><th>On hand</th></tr>${d.warnings.map(w => `<tr><td class="mono">${w.sku}</td><td>${w.exporting}</td><td>${w.other_shows}</td><td>${w.held}</td><td>${w.on_hand}</td></tr>`).join('')}</table>
        <p class="muted small">It never blocks. If you continue, the export is logged with this warning.</p><div class="actions"><button class="btn primary" id="yu">Yes, I understand</button></div>`);
      m.querySelector('#yu').onclick = async () => { m.remove(); try { await run(true); } catch (e) { toast(e.message, true); } };
      return;
    }
    await whatnotExport(null, d);
    done && done();
  };
  try { await run(false); } catch (e) { toast(e.message, true); }
}

// ================================================================ live screen
async function liveScreen(main, s) {
  const listed = s.type === 'listed';
  const QKEY = 'tfd_q_' + s.id;
  const loadQ = () => { try { return JSON.parse(localStorage.getItem(QKEY)) || []; } catch { return []; } };
  const saveQ = q => { try { localStorage.setItem(QKEY, JSON.stringify(q)); } catch {} };
  let cat = await rpc('tfd_show_catalog', { p_id: s.id });
  const L = { s, items: {}, avail: {}, used: {}, giveNext: false, winMode: false, sync: 'ok', lastScan: { sku: null, at: 0 } };
  const loadCat = c => { L.items = {}; L.avail = {}; c.items.forEach(it => { L.items[it.sku] = it; L.avail[it.sku] = it.available; }); L.used = { ...(c.used || {}) }; L.scope = c.scope; L.caps = c.caps; };
  loadCat(cat);
  loadQ().forEach(q => { if (L.avail[q.sku] != null) L.avail[q.sku]--; L.used[q.sku] = (L.used[q.sku] || 0) + 1; });

  main.innerHTML = `<div class="live">
    <div class="livebar"><div><a href="#shows" class="small">← Shows</a><div class="lname">${esc(s.label)}</div><div class="muted small">${platName(s.platform)} · ${listed ? 'Listed show' : 'Live mapping'} · ${esc(s.list_name)}${s.list_pct ? ` (${s.list_pct}% cap)` : ''}</div></div>
      <div class="lstat"><span class="tag live">● LIVE</span></div>
      <div class="lstat"><span class="muted small">${listed ? 'Next win' : 'Part'}</span><b class="big" id="prt"></b></div>
      ${listed ? '' : '<div class="lstat pullbox"><span class="muted small">NEXT PULL</span><b class="huge" id="nxt"></b></div>'}
      <div class="lstat"><span class="muted small" id="cl1"></span><b id="cv1"></b></div><div class="lstat"><span class="muted small">Total</span><b id="cv2"></b></div>
      <div class="lstat"><span class="pill" id="sync"></span></div></div>
    <div class="livegrid"><div>
      <div class="panel scanp"><div class="row"><input id="scan" class="inp scaninp" autocomplete="off" inputmode="numeric">
        ${listed ? '<button class="btn" id="wm">Record win: off</button>' : `<button class="btn primary" id="again" disabled>Run again</button>${s.platform === 'whatnot' ? '<button class="btn" id="gv">Giveaway: off</button>' : ''}`}</div>
        ${listed ? '' : '<div class="muted small" id="againl" style="margin-top:6px"></div>'}
        <div id="msg"></div></div>
      <div class="panel" id="card"><p class="muted">${listed ? 'Scan a bag to see its details and floor. Lookups hold nothing. Turn on Record win to log the item a buyer picked.' : 'Scan the first pull. For a buyer\'s choice, scan the item they picked.'}</p></div>
    </div><div>
      <div class="panel"><h3 style="margin-top:0">Controls</h3><div class="ctl">
        <button class="btn" id="un">Undo last</button>
        ${listed ? (s.is_admin ? '<button class="btn" id="ex">Export listing</button>' : '') : '<button class="btn" id="np">New Part</button><button class="btn" id="po">Set pull #</button>'}
        ${s.is_admin ? `<a class="btn" href="#shows/${s.id}/edit">Edit setup</a>` : ''}
        <button class="btn danger" id="end">Conclude show & import CSV</button></div>
        <p class="muted small" style="margin-bottom:0">${feeTxt(s.fees)} (this show). Stock can be added or adjusted in Inventory while live.</p></div>
      <div class="panel"><h3 style="margin-top:0">${listed ? 'Wins' : 'Pulls'}</h3><div id="pl" class="plist"></div></div>
    </div></div></div>`;

  const draw = () => {
    const sv = L.s, q = loadQ();
    $('#prt').textContent = listed ? '#' + sv.next_win : sv.part;
    if (!listed) $('#nxt').textContent = '#' + (sv.next_pull + q.length);
    $('#cl1').textContent = listed ? 'Wins' : 'This Part';
    $('#cv1').textContent = listed ? sv.counts.wins : sv.counts.part + q.length;
    $('#cv2').textContent = sv.counts.total + q.length;
    $('#scan').placeholder = listed ? (L.winMode ? 'Scan the item the buyer picked (records the win)' : 'Scan or type a SKU to look it up') : 'Scan or type a SKU, then Enter';
    if (!listed) {   // Run again = the last item pulled, if there's still one to run
      const lastQ = q[q.length - 1], lastP = sv.pulls.find(p => p.status !== 'void' && p.kind !== 'win');
      const last = lastQ ? lastQ.sku : lastP ? lastP.sku : null, c = last && L.items[last];
      const capped = last && L.caps && L.caps[last] != null && (L.used[last] || 0) >= L.caps[last];
      const left = last ? (L.avail[last] ?? 0) : 0;
      $('#again').disabled = !last || left <= 0 || capped; $('#again').dataset.sku = last || '';
      $('#againl').textContent = !last ? 'Run again repeats the last item pulled.' : `Last: ${last} ${c ? c.name || [c.brand, c.model].filter(Boolean).join(' ') : ''} · ${capped ? 'list limit reached' : left > 0 ? left + ' left' : 'out of stock'}`;
    }
    const sy = $('#sync');
    sy.textContent = L.sync === 'off' ? `Offline · ${q.length} waiting` : q.length ? `Saving ${q.length}…` : 'All saved';
    sy.className = 'pill ' + (L.sync === 'off' ? 'bad' : q.length ? 'warn' : 'ok');
    const rows = [...q.slice().reverse().map(x => ({ queued: true, part: sv.part, pull_no: '…', sku: x.sku, kind: x.kind, name: L.items[x.sku]?.name || '', status: 'held' })), ...sv.pulls];
    $('#pl').innerHTML = rows.slice(0, 200).map(p => `<div class="prow ${p.status === 'void' ? 'void' : ''}"><div><b>${p.kind === 'win' ? 'Win #' : (sv.part > 1 || p.part > 1 ? `P${p.part} #` : '#')}${p.pull_no}</b>
        <span class="mono small">${p.sku}</span> ${esc(p.name || [p.brand, p.model].filter(Boolean).join(' '))}
        ${p.kind === 'giveaway' ? '<span class="tag claude">Giveaway</span>' : ''}${p.outside_list ? '<span class="tag off">Outside list</span>' : ''}${p.queued ? '<span class="tag off">waiting</span>' : ''}${p.status === 'void' ? `<span class="tag off">Void</span> <span class="muted small">${esc(p.note || '')}</span>` : ''}</div>
      ${!p.queued && p.status === 'held' ? `<div class="row"><button class="btn sm" data-ed="${p.id}">Edit SKU</button>${sv.platform === 'whatnot' && p.kind !== 'win' ? `<button class="btn sm" data-gv="${p.id}" data-k="${p.kind}">${p.kind === 'giveaway' ? 'Not giveaway' : 'Giveaway'}</button>` : ''}<button class="btn sm danger" data-vd="${p.id}">Void</button></div>` : ''}</div>`).join('')
      || '<p class="muted">Nothing yet.</p>';
    $('#pl').querySelectorAll('[data-ed]').forEach(b => b.onclick = () => editPull(sv, sv.pulls.find(p => p.id === Number(b.dataset.ed)), refresh));
    $('#pl').querySelectorAll('[data-vd]').forEach(b => b.onclick = () => voidPull(sv.pulls.find(p => p.id === Number(b.dataset.vd)), refresh));
    $('#pl').querySelectorAll('[data-gv]').forEach(b => b.onclick = () => online(async () => { await rpc('tfd_pull_kind', { p_pull: Number(b.dataset.gv), p_kind: b.dataset.k === 'giveaway' ? 'normal' : 'giveaway' }); await refresh(); }));
  };
  const refresh = async () => {
    if (!$('#scan')) return;
    try { L.s = await rpc('tfd_show', { p_id: s.id }); if (L.s.status !== 'live') return renderShows();
      if (!loadQ().length) { cat = await rpc('tfd_show_catalog', { p_id: s.id }); loadCat(cat); }
      if (L.sync === 'off') L.sync = 'ok'; draw();
    } catch (e) { if (isNetErr(e)) { L.sync = 'off'; draw(); } else toast(e.message, true); }
  };
  const online = async fn => {
    if (loadQ().length) { await flush(); if (loadQ().length) return toast('Waiting for the connection to save the queued scans first', true); }
    try { await fn(); } catch (e) { toast(isNetErr(e) ? 'No connection. Try again in a moment.' : e.message, true); if (isNetErr(e)) { L.sync = 'off'; draw(); } }
  };
  const msg = (html, cls) => { $('#msg').innerHTML = html ? `<div class="note ${cls || ''}" style="margin-top:10px">${html}</div>` : ''; };
  const ask = (title, body, yes) => new Promise(res => {
    const m = modal(`<h2>${title}</h2><p>${body}</p><div class="actions"><button class="btn" id="an">No</button><button class="btn primary" id="ay">${yes}</button></div>`);
    let done = false; const fin = v => { if (done) return; done = true; m.remove(); res(v); $('#scan')?.focus(); };
    m.querySelector('#ay').onclick = () => fin(true); m.querySelector('#an').onclick = () => fin(false);
    m.addEventListener('click', e => { if (e.target === m || e.target.dataset.close !== undefined) fin(false); }); m.querySelector('#ay').focus();
  });
  const cardHtml = (c, extra) => `<div class="pcard">${c.image_url ? `<img src="${esc(c.image_url)}" alt="">` : '<div class="noimg">No image</div>'}
      <div><div class="muted small">SKU <span class="mono">${c.sku}</span>${c.upc ? ` · UPC ${esc(c.upc)}` : ''}${c.bin ? ` · bin ${esc(c.bin)}` : ''}</div>
      <div class="pbrand">${esc(c.brand || '')} <span class="muted">${esc(c.model || '')}</span></div>
      <div>${esc(c.name || '')}${c.color_name || c.color_code ? ` · ${esc(c.color_name || c.color_code)}` : ''}${c.lens_size ? ` · ${esc(c.lens_size)}mm` : ''}</div>
      ${c.specs ? `<div class="muted small">${esc(c.specs)}</div>` : ''}
      <div class="pnums"><div><span class="muted small">FLOOR</span><b class="huge">${c.floor_cents == null ? '—' : '$' + Math.round(c.floor_cents / 100)}</b></div>
        <div><span class="muted small">RETAIL</span><b class="big">${c.retail_cents == null ? '—' : '$' + (c.retail_cents / 100).toFixed(0)}</b></div>
        <div><span class="muted small">${extra && extra.lookup ? 'AVAILABLE' : 'LEFT AFTER THIS'}</span><b class="big">${extra && extra.left != null ? extra.left : c.available}</b></div></div>
      ${extra && extra.tags ? extra.tags : ''}</div></div>`;

  // ---- double-scan guard: same SKU again within 3 seconds asks first
  const guard = async sku => {
    const now = Date.now(), dup = L.lastScan.sku === sku && now - L.lastScan.at < 3000;
    L.lastScan = { sku, at: now };
    if (!dup) return true;
    beep('warn');
    const ok = await ask('Scanned twice?', `SKU <b class="mono">${sku}</b> was just scanned a moment ago. Record it again as a separate ${listed ? 'win' : 'pull'}?`, 'Yes, record again');
    L.lastScan = { sku, at: Date.now() };
    return ok;
  };

  // ---- scanning
  const scan = async raw => {
    const sku = raw.trim(); if (!sku) return;
    if (listed && !L.winMode) {
      try { const c = await rpc('tfd_lookup', { p_show: s.id, p_sku: sku }); msg(''); beep('ok');
        $('#card').innerHTML = cardHtml(c, { lookup: true, tags: `${c.in_scope ? '' : '<span class="tag off">Not in this show\'s list</span> '}${c.listed_qty != null ? `<span class="tag">Listed: ${c.listed_qty}</span>` : ''}` });
      } catch (e) { const c = L.items[sku]; if (isNetErr(e) && c) $('#card').innerHTML = cardHtml(c, { lookup: true, tags: '<span class="tag off">offline: last known</span>' }); else { beep('bad'); msg(esc(e.message), 'bad'); } }
      return;
    }
    if (listed) return recordWin(sku);
    const c = L.items[sku];
    if (!c) { // not in the local catalog (maybe brand new): ask the server directly
      try { const r = await rpc('tfd_scan', { p_show: s.id, p_sku: sku, p_client_id: uuid(), p_kind: L.giveNext ? 'giveaway' : 'normal' }); return afterServerScan(r); }
      catch (e) { beep('bad'); return msg(esc(isNetErr(e) ? `SKU ${sku} isn't in this device's list and there's no connection to check it.` : e.message), 'bad'); }
    }
    if ((L.avail[sku] || 0) <= 0) { beep('bad'); $('#card').innerHTML = cardHtml(c, { left: 0 }); return msg('<b>Out of stock — unable to run</b>', 'bad big'); }
    if (L.caps && L.caps[sku] != null && (L.used[sku] || 0) >= L.caps[sku]) { beep('bad'); $('#card').innerHTML = cardHtml(c, { left: L.avail[sku] }); return msg(`<b>List limit reached (${L.caps[sku]} for this show) — unable to run</b>`, 'bad big'); }
    // live mapping: running the same item over and over is normal, so no "scanned twice?" check here
    let outside = false;
    if (L.scope && !L.scope.includes(sku)) {
      beep('warn');
      if (!await ask('Not in this show\'s inventory', `SKU ${sku} (${esc(c.name || c.brand + ' ' + c.model)}) isn't in <b>${esc(s.list_name)}</b>. Run it anyway?`, 'Run it')) return;
      outside = true;
    }
    const kind = L.giveNext ? 'giveaway' : 'normal';
    const q = loadQ(); q.push({ client_id: uuid(), sku, kind, outside, at: Date.now() }); saveQ(q);
    L.avail[sku]--; L.used[sku] = (L.used[sku] || 0) + 1;
    const left = L.avail[sku], low = left <= (c.low_stock ?? 2);
    beep(low ? 'warn' : 'ok');
    $('#card').innerHTML = cardHtml(c, { left, tags: `<div class="row" style="margin-top:8px"><span class="tag big">Pull #${L.s.next_pull + q.length - 1}${L.s.part > 1 ? ` · Part ${L.s.part}` : ''}</span>${kind === 'giveaway' ? '<span class="tag claude">Giveaway</span>' : ''}${outside ? '<span class="tag off">Outside list</span>' : ''}</div>` });
    msg(low ? `<b>Low stock:</b> ${left} left after this one.` : '', low ? 'warn' : '');
    if (L.giveNext) { L.giveNext = false; setGive(); }
    draw(); flush();
  };
  const afterServerScan = r => {
    if (r.needs_confirm) { beep('warn'); return msg(esc(r.message) + ' Ask an admin to add it to the list, or scan it again once it shows up.', 'warn'); }
    if (!r.ok) { beep('bad'); if (r.card) $('#card').innerHTML = cardHtml(r.card, { left: r.card.available }); return msg(`<b>${esc(r.error)}</b>`, 'bad big'); }
    beep('ok');
    $('#card').innerHTML = cardHtml(r.card, { left: r.card.available, tags: `<span class="tag big">${r.pull.kind === 'win' ? 'Win' : 'Pull'} #${r.pull.pull_no}</span>` });
    if (L.giveNext) { L.giveNext = false; setGive(); }
    refresh();
  };
  const recordWin = sku => online(async () => {
    if (!await guard(sku)) return;
    const cid = uuid();
    let r = await rpc('tfd_record_win', { p_show: s.id, p_sku: sku, p_client_id: cid });
    if (r.needs_confirm) { beep('warn'); if (!await ask('Not in this show\'s inventory', esc(r.message), 'Record it')) return;
      r = await rpc('tfd_record_win', { p_show: s.id, p_sku: sku, p_client_id: cid, p_confirm_outside: true }); }
    afterServerScan(r);
    if (r.ok) msg(`Win #${r.pull.pull_no} recorded.`, 'ok');
  });
  let flushing = false;
  const flush = async () => {
    if (flushing) return; flushing = true;
    try {
      let q = loadQ();
      while (q.length) {
        const it = q[0];
        let r;
        try { r = await rpc('tfd_scan', { p_show: s.id, p_sku: it.sku, p_client_id: it.client_id, p_kind: it.kind, p_confirm_outside: it.outside }); }
        catch (e) { if (isNetErr(e)) { L.sync = 'off'; draw(); setTimeout(flush, 3000); return; }
          r = { ok: false, error: e.message }; }
        q = loadQ(); q.shift(); saveQ(q);
        if (!r.ok || r.needs_confirm) { beep('bad'); msg(`<b>Scan of SKU ${it.sku} was rejected by the server:</b> ${esc(r.error || r.message)}. It was NOT recorded.`, 'bad big'); }
        L.sync = 'ok';
      }
      await refresh();
    } finally { flushing = false; }
  };

  const setGive = () => { const b = $('#gv'); if (b) { b.textContent = 'Giveaway: ' + (L.giveNext ? 'ON for next scan' : 'off'); b.classList.toggle('primary', L.giveNext); } };
  if ($('#gv')) $('#gv').onclick = () => { L.giveNext = !L.giveNext; setGive(); $('#scan').focus(); };
  if ($('#wm')) $('#wm').onclick = () => { L.winMode = !L.winMode; $('#wm').textContent = 'Record win: ' + (L.winMode ? 'ON' : 'off'); $('#wm').classList.toggle('primary', L.winMode); draw(); $('#scan').focus(); };
  if ($('#ex')) $('#ex').onclick = () => exportListing(L.s, refresh);

  // ---- controls
  $('#scan').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); const v = e.target.value; e.target.value = ''; scan(v); } });
  if ($('#again')) $('#again').onclick = () => { const k = $('#again').dataset.sku; if (k) scan(k); $('#scan').focus(); };
  $('#un').onclick = () => online(async () => {
    const last = L.s.pulls.find(p => p.status === 'held'); if (!last) return toast('Nothing to undo', true);
    if (!await ask('Undo last?', `Undo ${last.kind === 'win' ? 'win' : 'pull'} #${last.pull_no} (SKU ${last.sku})? The unit goes back to available.`, 'Undo')) return;
    await rpc('tfd_pull_undo_last', { p_show: s.id }); msg(`Undid #${last.pull_no}.`); await refresh();
  });
  if ($('#np')) $('#np').onclick = () => online(async () => {
    if (!await ask(`Start Part ${L.s.part + 1}?`, 'Pull numbers restart at #1.', 'Start Part ' + (L.s.part + 1))) return;
    await rpc('tfd_show_new_part', { p_show: s.id }); msg(`Part ${L.s.part + 1} started.`, 'ok'); await refresh();
  });
  if ($('#po')) $('#po').onclick = () => {
    const m = modal(`<h2>Set next pull #</h2><p class="muted small">Only if the numbering got out of step with the platform. Logged.</p>
      <div class="grid"><label class="f">Next pull #<input id="pn" class="inp" type="number" min="1" value="${L.s.next_pull}"></label><label class="f">Reason<input id="pr" class="inp"></label></div>
      <div class="err" id="pe"></div><div class="actions"><button class="btn primary" id="py">Set</button></div>`);
    m.querySelector('#py').onclick = () => online(async () => { try { await rpc('tfd_show_set_pull', { p_show: s.id, p_next: Number($('#pn').value), p_reason: $('#pr').value }); m.remove(); await refresh(); } catch (e) { m.querySelector('#pe').textContent = e.message; } });
  };
  $('#end').onclick = () => online(async () => {
    const held = L.s.pulls.filter(p => p.status === 'held').length;
    const m = modal(`<h2>Conclude show?</h2><p>Scanning stops. <b>${held}</b> ${listed ? 'win(s)' : 'pull(s)'} stay held until the show is finalized.</p>
      <p>Next: import the ${s.platform === 'tiktok' ? 'TikTok "To Ship"' : 'Whatnot'} CSV, enter hours for each person, then Finalize.</p>
      <p class="muted small">Ended by mistake? An admin can reopen it.</p><div class="err" id="ee"></div>
      <div class="actions"><button class="btn" data-close>Keep scanning</button><button class="btn danger" id="ey">Conclude show</button></div>`);
    m.querySelector('#ey').onclick = async () => { try { await rpc('tfd_show_end', { p_show: s.id, p_confirm: 'SHOW OVER' }); m.remove(); renderShows(); } catch (e) { m.querySelector('#ee').textContent = e.message; } };
  });

  window.addEventListener('online', () => flush(), { once: true });
  draw(); setGive(); $('#scan').focus();
  if (loadQ().length) flush();
}

function editPull(s, p, done) {
  const m = modal(`<h2>Edit ${p.kind === 'win' ? 'win' : 'pull'} #${p.pull_no}</h2><p>Currently SKU <b class="mono">${p.sku}</b> ${esc(p.name || '')}. The new SKU is checked against stock like a scan.</p>
    <div class="grid"><label class="f">New SKU<input id="ns" class="inp mono"></label><label class="f">Reason<input id="nr" class="inp" placeholder="e.g. scanned the wrong bag"></label></div>
    <div class="err" id="ne"></div><div class="actions"><button class="btn primary" id="ny">Save</button></div>`);
  const go = async conf => {
    try { const r = await rpc('tfd_pull_edit', { p_pull: p.id, p_sku: $('#ns').value, p_reason: $('#nr').value, p_confirm_outside: conf });
      if (r.needs_confirm) { if (confirm(r.message)) return go(true); return; }
      m.remove(); toast('Pull updated'); done();
    } catch (e) { m.querySelector('#ne').textContent = e.message; }
  };
  m.querySelector('#ny').onclick = () => go(false);
}
function voidPull(p, done) {
  const m = modal(`<h2>Void ${p.kind === 'win' ? 'win' : 'pull'} #${p.pull_no}?</h2><p>SKU <b class="mono">${p.sku}</b> ${esc(p.name || '')} goes back to available. The number isn't reused.</p>
    <label class="f">Reason<input id="vr" class="inp"></label><div class="err" id="ve"></div><div class="actions"><button class="btn danger" id="vy">Void</button></div>`);
  m.querySelector('#vy').onclick = async () => { try { await rpc('tfd_pull_void', { p_pull: p.id, p_reason: $('#vr').value }); m.remove(); toast('Voided'); done(); } catch (e) { m.querySelector('#ve').textContent = e.message; } };
}

// ================================================================ concluded: CSV (Phase 4) → hours → finalize (Phase 4)
const pad2 = n => String(n).padStart(2, '0');
const toLocalInput = iso => { if (!iso) return ''; const d = new Date(iso); return `${d.getFullYear()}-${pad2(d.getMonth() + 1)}-${pad2(d.getDate())}T${pad2(d.getHours())}:${pad2(d.getMinutes())}`; };
const hrs = (a, b) => (new Date(b) - new Date(a)) / 3600000;

function showEnded(main, s) {
  const admin = s.is_admin, listed = s.type === 'listed', fin = s.status === 'finalized', locked = fin || s.status === 'matched';
  const held = s.pulls.filter(p => p.status === 'held');
  main.innerHTML = `<div class="head"><div><a href="#shows" class="small">← All shows</a><h1>${esc(s.label)} ${stageTag(s.status)}</h1>
      <p class="muted small">${platName(s.platform)} · ${listed ? 'Listed show' : 'Live mapping'} · ${esc(s.list_name)} · ${feeTxt(s.fees)}</p></div>
      <div class="row"><button class="btn" id="dl">Download mapping file</button>${admin && !fin ? `<a class="btn" href="#shows/${s.id}/edit">Edit setup</a>` : ''}${admin && s.status === 'ended' ? '<button class="btn" id="ro">Reopen show</button>' : ''}</div></div>
    <div class="grid stats">
      <div class="panel"><div class="muted small">${listed ? 'Wins' : 'Pulls held'}</div><b class="big">${held.length}</b></div>
      <div class="panel"><div class="muted small">Giveaways</div><b class="big">${s.counts.giveaways}</b></div>
      <div class="panel"><div class="muted small">Voided</div><b class="big">${s.counts.void}</b></div>
      <div class="panel"><div class="muted small">Parts</div><b class="big">${listed ? '—' : s.part}</b></div></div>
    ${admin ? '<div id="imp"></div>' : `<div class="panel"><p class="muted">An admin imports the ${s.platform === 'tiktok' ? 'TikTok' : 'Whatnot'} CSV and finalizes the show.</p></div>`}
    ${admin ? `<div class="panel"><div class="head"><h2 style="margin:0">Step 2 · Hours</h2>${fin ? '' : '<button class="btn" id="addh">Add row</button>'}</div>
      <div class="row wrap" style="gap:12px;align-items:flex-end"><label class="f"><b>Show started</b><input type="datetime-local" id="sst" class="inp" ${fin ? 'disabled' : ''}></label>
        <label class="f"><b>Show ended</b><input type="datetime-local" id="sen" class="inp" ${fin ? 'disabled' : ''}></label><div id="shr" class="small" style="padding-bottom:10px"></div></div>
      <p class="muted small">Then one row per stretch someone worked, inside the show's time. Add as many rows as you need for each streamer and assistant.</p>
      <div id="hrs"></div><div class="err" id="he"></div>${fin ? '' : '<div class="actions"><button class="btn primary" id="hs">Save hours</button></div>'}</div>` : ''}
    ${admin ? '<div id="fin"></div>' : ''}
    <div class="panel"><h2>Lineup</h2>${lineupHtml(s)}</div>
    <div class="panel"><h2>${listed ? 'Wins' : 'Pulls'}</h2><div id="pl" class="plist"></div></div>`;
  $('#pl').innerHTML = s.pulls.map(p => `<div class="prow ${p.status !== 'held' ? 'void' : ''}"><div><b>${p.kind === 'win' ? 'Win #' : `P${p.part} #`}${p.pull_no}</b> <span class="mono small">${p.sku}</span> ${esc(p.name || '')}
      ${p.kind === 'giveaway' ? '<span class="tag claude">Giveaway</span>' : ''}${p.outside_list ? '<span class="tag off">Outside list</span>' : ''}${p.status === 'void' ? `<span class="tag off">Void</span> <span class="muted small">${esc(p.note || '')}</span>` : ''}
      <span class="muted small">· ${when(p.at)} · ${esc(p.by)}</span></div>
      ${p.status === 'held' && !locked ? `<div class="row"><button class="btn sm" data-ed="${p.id}">Edit SKU</button><button class="btn sm danger" data-vd="${p.id}">Void</button></div>` : ''}</div>`).join('') || '<p class="muted">No pulls.</p>';
  const re = () => renderShows();
  $('#pl').querySelectorAll('[data-ed]').forEach(b => b.onclick = () => editPull(s, s.pulls.find(p => p.id === Number(b.dataset.ed)), re));
  $('#pl').querySelectorAll('[data-vd]').forEach(b => b.onclick = () => voidPull(s.pulls.find(p => p.id === Number(b.dataset.vd)), re));
  $('#dl').onclick = async () => {
    const d = await rpc('tfd_show_mapping', { p_show: s.id });
    downloadCSV(`${d.label} - mapping.csv`, ['Part', 'Pull #', 'Type', 'Status', 'SKU', 'Product', 'Brand', 'Model', 'Color code', 'Lens size', 'Scanned at', 'Scanned by', 'Outside list', 'Note'],
      d.rows.map(r => [r.kind === 'win' ? 'Win' : r.part, r.pull_no, r.kind, r.status, r.sku, r.product, r.brand, r.model, r.color_code, r.lens_size, new Date(r.scanned_at).toLocaleString(), r.scanned_by, r.outside_list ? 'yes' : '', r.note || '']));
  };
  if ($('#ro')) $('#ro').onclick = () => {
    const m = modal(`<h2>Reopen show?</h2><p>Goes back to the live screen so you can keep scanning. Hours you entered stay.</p>
      <label class="f">Reason<input id="rr" class="inp" placeholder="e.g. concluded by mistake"></label><div class="err" id="re"></div><div class="actions"><button class="btn primary" id="ry">Reopen</button></div>`);
    m.querySelector('#ry').onclick = async () => { try { await rpc('tfd_show_reopen', { p_show: s.id, p_reason: m.querySelector('#rr').value }); m.remove(); renderShows(); } catch (e) { m.querySelector('#re').textContent = e.message; } };
  };
  if (!admin) return;
  // ---- hours editor
  const day = toLocalInput(s.started_at || s.created_at).slice(0, 10);
  $('#sst').value = toLocalInput(s.show_start_at || s.started_at || s.created_at);
  $('#sen').value = toLocalInput(s.show_end_at || s.ended_at || '');
  const win = () => [$('#sst').value, $('#sen').value];
  const rows = (s.shifts || []).map(h => ({ profile_id: h.profile_id, start: toLocalInput(h.start_at), end: toLocalInput(h.end_at) }));
  if (!rows.length && !fin) s.people.forEach(p => rows.push({ profile_id: p.profile_id, start: '', end: '' }));
  const drawH = () => {
    const [ws, we] = win(), wok = ws.length === 16 && we.length === 16 && hrs(ws, we) > 0;
    $('#shr').innerHTML = ws.length === 16 && we.length === 16 ? (hrs(ws, we) > 0 ? `Show hours: <b>${hrs(ws, we).toFixed(2)}</b>` : '<span style="color:var(--bad)">End must be after start</span>') : '';
    const outside = r => wok && r.start.length === 16 && r.end.length === 16 && (r.start < ws || r.end > we);
    const tot = {};
    rows.forEach(r => { const h = r.start.length === 16 && r.end.length === 16 ? hrs(r.start, r.end) : 0; if (h > 0) tot[r.profile_id] = (tot[r.profile_id] || 0) + h; });
    $('#hrs').innerHTML = rows.length ? `<div style="overflow-x:auto"><table><tr><th>Person</th><th>Role</th><th>Start</th><th>End</th><th>Hours</th><th></th></tr>
      ${rows.map((r, i) => { const p = s.people.find(x => x.profile_id === r.profile_id); const h = r.start.length === 16 && r.end.length === 16 ? hrs(r.start, r.end) : null;
        return `<tr><td><select class="inp" data-i="${i}" data-k="profile_id" ${fin ? 'disabled' : ''}>${s.people.map(x => `<option value="${x.profile_id}" ${x.profile_id === r.profile_id ? 'selected' : ''}>${esc(x.name)}</option>`).join('')}</select></td>
          <td class="small">${p ? p.role : ''}</td>
          <td><input type="datetime-local" class="inp" data-i="${i}" data-k="start" value="${r.start.length === 16 ? r.start : ''}" ${fin ? 'disabled' : ''}></td>
          <td><input type="datetime-local" class="inp" data-i="${i}" data-k="end" value="${r.end.length === 16 ? r.end : ''}" ${fin ? 'disabled' : ''}></td>
          <td class="${h != null && h <= 0 ? 'bad' : ''}">${h == null ? '—' : h.toFixed(2)}${outside(r) ? '<div class="small" style="color:var(--bad)">outside the show</div>' : ''}</td><td>${fin ? '' : `<button class="btn sm danger" data-rm="${i}">×</button>`}</td></tr>`; }).join('')}</table></div>
      <p class="small"><b>Totals:</b> ${s.people.map(p => `${esc(p.name)} ${(tot[p.profile_id] || 0).toFixed(2)}h`).join(' · ')}</p>` : '<p class="muted">No hours entered.</p>';
    $('#hrs').querySelectorAll('[data-k]').forEach(inp => inp.onchange = () => { const r = rows[Number(inp.dataset.i)]; r[inp.dataset.k] = inp.dataset.k === 'profile_id' ? Number(inp.value) : inp.value; drawH(); });
    $('#hrs').querySelectorAll('[data-rm]').forEach(b => b.onclick = () => { rows.splice(Number(b.dataset.rm), 1); drawH(); });
  };
  drawH();
  $('#sst').onchange = $('#sen').onchange = drawH;
  if ($('#addh')) $('#addh').onclick = () => { const last = rows[rows.length - 1]; rows.push({ profile_id: last ? last.profile_id : s.people[0].profile_id, start: last && last.end.length === 16 ? last.end : '', end: '' }); drawH(); };
  if ($('#hs')) $('#hs').onclick = async () => {
    $('#he').textContent = '';
    if (rows.some(r => r.start.length !== 16 || r.end.length !== 16)) return $('#he').textContent = 'Fill in the start and end date and time on every row (or remove empty rows).';
    const [ws, we] = win();
    if (ws.length !== 16 || we.length !== 16) return $('#he').textContent = 'Enter when the show started and ended.';
    try { await rpc('tfd_show_hours_save', { p_show: s.id, p_start: new Date(ws).toISOString(), p_end: new Date(we).toISOString(),
        p_shifts: rows.map(r => ({ profile_id: r.profile_id, start_at: new Date(r.start).toISOString(), end_at: new Date(r.end).toISOString() })) });
      toast('Hours saved'); renderShows(); } catch (e) { $('#he').textContent = e.message; }
  };
  showReview(s);
}
