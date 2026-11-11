'use strict';
// Shows tab: list, setup (live mapping / listed), live mapping screen (streamer-safe, offline-tolerant scans),
// buyer's choice, giveaways, fixes, parts, end / reopen, listed-show export + lookups + live-map wins.
// Import, review and finalize come in Phase 4.

const SH = { timer: null };
const fmtClock = s => { s = Math.max(0, Math.floor(s)); return `${Math.floor(s / 3600)}:${String(Math.floor(s / 60) % 60).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`; };
const STAGE = { setup: ['Setup', ''], live: ['Live', 'live'], ended: ['Ended', 'off'], matched: ['Matched', ''], finalized: ['Finalized', 'ok'] };
const stageTag = st => `<span class="tag ${STAGE[st]?.[1] || ''}">${STAGE[st]?.[0] || esc(st)}</span>`;
const isNetErr = e => e instanceof TypeError || /Failed to fetch|NetworkError|Load failed/i.test(e.message || '');
const uuid = () => (crypto.randomUUID ? crypto.randomUUID() : 'xxxxxxxx-xxxx-4xxx-8xxx-xxxxxxxxxxxx'.replace(/x/g, () => (Math.random() * 16 | 0).toString(16)));

async function renderShows() {
  clearInterval(SH.timer);
  const [, a, b] = location.hash.slice(1).split('/');
  const main = $('#main');
  try {
    if (a === 'new') return showSetup(main, null);
    if (a && b === 'edit') return showSetup(main, Number(a));
    if (a) return showPage(main, Number(a));
    return showList(main);
  } catch (e) { main.innerHTML = `<div class="note bad">${esc(e.message)}</div>`; }
}

// ================================================================ list
async function showList(main) {
  const shows = await rpc('tfd_shows');
  const admin = S.state.me.role === 'admin';
  main.innerHTML = `<div class="head"><div><h1>Shows</h1><p class="muted small">Every show with its stage. Click one to open it where it left off.</p></div>
      ${admin ? '<a class="btn primary" href="#shows/new">New show</a>' : ''}</div>
    <div class="panel"><div style="overflow-x:auto"><table><tr><th>Date</th><th>Show</th><th>Type</th><th>Platform</th><th>Lineup</th><th>Pulls</th><th>Time live</th><th>Stage</th></tr>
    ${shows.map(s => `<tr class="click" data-show="${s.id}"><td class="small" style="white-space:nowrap">${new Date(s.started_at || s.created_at).toLocaleDateString()}</td>
      <td><b>${esc(s.label)}</b><div class="muted small">${esc(s.list_name)}</div></td><td>${s.type === 'listed' ? 'Listed' : 'Live mapping'}</td><td>${s.platform === 'tiktok' ? 'TikTok' : 'Whatnot'}</td>
      <td class="small">${s.lineup.map(esc).join(', ')}</td><td>${s.pulls}</td><td class="mono">${s.started_at ? fmtClock(s.seconds) : '—'}</td><td>${stageTag(s.status)}</td></tr>`).join('')
      || `<tr><td colspan="8" class="muted">No shows yet.${admin ? ' Click New show.' : ''}</td></tr>`}</table></div></div>`;
  main.querySelectorAll('[data-show]').forEach(tr => tr.onclick = () => { location.hash = '#shows/' + tr.dataset.show; });
}

// ================================================================ setup
async function showSetup(main, id) {
  const [opt, s] = await Promise.all([rpc('tfd_lineup_options'), id ? rpc('tfd_show', { p_id: id }) : null]);
  if (s && s.status !== 'setup') { location.hash = '#shows/' + id; return; }
  const v = s ? { type: s.type, platform: s.platform, name: s.name || '', list_id: s.list_id || '', split_mode: s.split_mode || 'even',
      people: s.people.map(p => ({ profile_id: p.profile_id, role: p.role, hourly_cents: p.hourly_cents, commission_bp: p.commission_bp, lead: p.lead })) }
    : { type: 'live', platform: 'tiktok', name: '', list_id: '', split_mode: 'even', people: [] };
  const person = pid => opt.people.find(p => p.id === Number(pid));
  const rateFor = (pid, role) => { const p = person(pid); return p ? p[role] : { hourly_cents: 0, commission_bp: 0 }; };
  const plat = k => opt.platforms[k];
  main.innerHTML = `<div class="head"><div><a href="#shows" class="small">← All shows</a><h1>${id ? 'Edit show setup' : 'New show'}</h1></div></div>
    <div class="panel"><h2>1. Show type</h2><div class="seg" id="ty">${[['live', 'Live mapping (random pulls)'], ['listed', 'Listed (Whatnot)']].map(([k, l]) => `<button data-v="${k}" class="${v.type === k ? 'on' : ''}">${l}</button>`).join('')}</div>
      <p class="muted small" id="tyhelp"></p></div>
    <div class="panel"><h2>2. Platform</h2><div class="seg" id="pl">${[['tiktok', 'TikTok'], ['whatnot', 'Whatnot']].map(([k, l]) => `<button data-v="${k}" class="${v.platform === k ? 'on' : ''}">${l}</button>`).join('')}</div>
      <p class="muted small" id="plhelp"></p></div>
    <div class="panel"><h2>3. Inventory</h2><label class="f">What can be run on this show<select id="li" class="inp"><option value="">Full inventory</option>
      ${opt.lists.map(l => `<option value="${l.id}" ${String(v.list_id) === String(l.id) ? 'selected' : ''}>${esc(l.name)}${l.pct ? ` (${l.pct}% of stock, hard cap)` : ''}</option>`).join('')}</select></label>
      <p class="muted small">Make lists in Inventory → Lists. A % list caps each SKU at that % of its available units, fixed when you press Start live.</p></div>
    <div class="panel"><div class="head"><h2 style="margin:0">4. Lineup</h2><button class="btn" id="addp">Add person</button></div>
      <div id="ppl"></div><div id="split"></div>
      <p class="muted small">Rates start at each person's default and only change for this show. An admin can fill the assistant spot unpaid.</p></div>
    <div class="panel"><h2>5. Show name <span class="muted small">(optional)</span></h2><input id="nm" class="inp" style="width:100%" placeholder='The live title viewers see, e.g. "Halloween all day stream starting at $1!!"' value="${esc(v.name)}">
      <p class="muted small">A label for the shows list and Dashboard only. It plays no part in CSV matching.</p></div>
    <div class="err" id="se"></div><div class="actions">${id ? '<button class="btn danger" id="cx">Cancel this show</button>' : ''}<button class="btn primary" id="sv">${id ? 'Save setup' : 'Create show'}</button></div>`;
  const help = () => {
    $('#tyhelp').textContent = v.type === 'live' ? 'Scan every pull live. Each scan holds a unit until the show is finalized.' : 'Export your list to Whatnot before the show. Scans only look items up; Live map handles buyer\'s choice.';
    if (v.type === 'listed') v.platform = 'whatnot';
    $('#pl').querySelectorAll('button').forEach(b => { b.classList.toggle('on', b.dataset.v === v.platform); b.disabled = v.type === 'listed' && b.dataset.v === 'tiktok'; });
    const p = plat(v.platform);
    $('#plhelp').innerHTML = p.pct_sale_bp === null ? '<span style="color:var(--warn)">Fees for this platform aren\'t set yet, so floors show as "not set". Settings → Platforms & fees.</span>'
      : `Fee ${p.pct_sale_bp / 100}% of sale${p.pct_ship_bp ? ` + ${p.pct_ship_bp / 100}% of shipping` : ''}${p.fixed_cents ? ` + $${(p.fixed_cents / 100).toFixed(2)}` : ''}. ${v.platform === 'whatnot' ? 'Giveaways allowed.' : 'No giveaways on TikTok.'}`;
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
    $('#split').innerHTML = streamers.length > 1 ? `<div class="row" style="margin-top:10px"><span class="small muted">Two streamers on air:</span><div class="seg" id="sm">${[['even', 'Split evenly'], ['lead', 'Lead + support']].map(([k, l]) => `<button data-v="${k}" class="${v.split_mode === k ? 'on' : ''}">${l}</button>`).join('')}</div></div>` : '';
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
  $('#ty').querySelectorAll('button').forEach(b => b.onclick = () => { v.type = b.dataset.v; $('#ty').querySelectorAll('button').forEach(x => x.classList.toggle('on', x === b)); help(); });
  $('#pl').querySelectorAll('button').forEach(b => b.onclick = () => { if (b.disabled) return; v.platform = b.dataset.v; help(); });
  $('#addp').onclick = () => {
    const free = opt.people.find(o => !v.people.some(q => q.profile_id === o.id));
    if (!free) return toast('Everyone is already in the lineup', true);
    const role = free.role === 'admin' ? 'assistant' : free.role === 'assistant' ? 'assistant' : 'streamer';
    v.people.push({ profile_id: free.id, role, ...pick(rateFor(free.id, role)), lead: false }); drawPeople();
  };
  $('#sv').onclick = async () => {
    try {
      const sid = await rpc('tfd_show_save', { p_id: id, p: { type: v.type, platform: v.platform, name: $('#nm').value, list_id: $('#li').value || null, split_mode: v.split_mode,
        people: v.people.map(p => ({ ...p, lead: v.split_mode === 'lead' && p.lead })) } });
      toast(id ? 'Setup saved' : 'Show created'); location.hash = '#shows/' + sid;
    } catch (e) { $('#se').textContent = e.message; }
  };
  if (id) $('#cx').onclick = () => {
    const m = modal(`<h2>Cancel this show?</h2><p>It hasn't started, so nothing was held. It disappears from the list (the log keeps it).</p>
      <label class="f">Reason<input id="cr" class="inp"></label><div class="err" id="ce"></div><div class="actions"><button class="btn danger" id="cy">Cancel show</button></div>`);
    m.querySelector('#cy').onclick = async () => { try { await rpc('tfd_show_cancel', { p_id: id, p_reason: $('#cr').value }); m.remove(); location.hash = '#shows'; } catch (e) { m.querySelector('#ce').textContent = e.message; } };
  };
  help(); drawPeople();
}

// ================================================================ show page (by stage)
async function showPage(main, id) {
  const s = await rpc('tfd_show', { p_id: id });
  if (s.status === 'setup') return showSetupView(main, s);
  if (s.status === 'live') return liveScreen(main, s);
  return showEnded(main, s);
}

const lineupHtml = s => s.people.map(p => `${esc(p.name)} <span class="muted small">${p.role}${p.lead ? ', lead' : ''}${p.hourly_cents != null ? ` · $${(p.hourly_cents / 100).toFixed(2)}/hr${p.commission_bp ? ` + ${p.commission_bp / 100}%` : ''}` : ''}</span>`).join('<br>');

function showSetupView(main, s) {
  const admin = s.is_admin;
  main.innerHTML = `<div class="head"><div><a href="#shows" class="small">← All shows</a><h1>${esc(s.label)} ${stageTag(s.status)}</h1></div>
      ${admin ? `<a class="btn" href="#shows/${s.id}/edit">Edit setup</a>` : ''}</div>
    <div class="panel"><div class="grid">
      <div><div class="muted small">Type</div><b>${s.type === 'listed' ? 'Listed show' : 'Live mapping'}</b></div>
      <div><div class="muted small">Platform</div><b>${s.platform === 'tiktok' ? 'TikTok' : 'Whatnot'}</b></div>
      <div><div class="muted small">Inventory</div><b>${esc(s.list_name)}</b>${s.list_pct ? ` <span class="tag">${s.list_pct}% cap</span>` : ''}</div>
      <div><div class="muted small">Lineup${s.split_mode ? ` (${s.split_mode === 'even' ? 'split evenly' : 'lead + support'})` : ''}</div>${lineupHtml(s)}</div></div></div>
    ${s.type === 'listed' ? `<div class="panel"><h2>Listing</h2>
      <p>${s.export_qty ? `Exported: <b>${Object.keys(s.export_qty).length}</b> SKUs, <b>${Object.values(s.export_qty).reduce((a, b) => a + b, 0)}</b> units. Re-export if the list changed.` : 'Not exported yet. Export the Whatnot bulk-upload file, then upload it to Whatnot before going live.'}</p>
      ${admin ? '<button class="btn" id="ex">Export listing for Whatnot</button>' : ''}</div>` : ''}
    <div class="panel" style="text-align:center;padding:32px"><button class="btn primary" id="go" style="font-size:1.2rem;padding:14px 36px">Start live</button>
      <p class="muted small">Starts the paid clock${s.type === 'live' ? ', unlocks scanning and locks inventory (pause to add stock)' : ''}.${s.list_pct ? ` ${s.list_pct}% caps are fixed at this moment.` : ''}</p></div>`;
  $('#go').onclick = async () => { try { await rpc('tfd_show_start', { p_id: s.id }); renderShows(); } catch (e) { toast(e.message, true); } };
  if ($('#ex')) $('#ex').onclick = () => exportListing(s, () => renderShows());
}

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
  const L = { s, items: {}, avail: {}, used: {}, giveNext: false, bc: s.bc, last: null, sync: 'ok', failed: [], t0: Date.now() };
  const loadCat = c => { L.items = {}; L.avail = {}; c.items.forEach(it => { L.items[it.sku] = it; L.avail[it.sku] = it.available; }); L.used = { ...(c.used || {}) }; L.scope = c.scope; L.caps = c.caps; };
  loadCat(cat);
  loadQ().forEach(q => { if (L.avail[q.sku] != null) L.avail[q.sku]--; L.used[q.sku] = (L.used[q.sku] || 0) + 1; });

  main.innerHTML = `<div class="live">
    <div class="livebar"><div><a href="#shows" class="small">← Shows</a><div class="lname">${esc(s.label)}</div><div class="muted small">${s.platform === 'tiktok' ? 'TikTok' : 'Whatnot'} · ${listed ? 'Listed show' : 'Live mapping'} · ${esc(s.list_name)}${s.list_pct ? ` (${s.list_pct}% cap)` : ''}</div></div>
      <div class="lstat"><span class="tag live" id="lvtag">● LIVE</span><span class="mono big" id="clk">0:00:00</span></div>
      <div class="lstat"><span class="muted small">${listed ? 'Next win' : 'Part'}</span><b class="big" id="prt"></b></div>
      ${listed ? '' : '<div class="lstat pullbox"><span class="muted small">NEXT PULL</span><b class="huge" id="nxt"></b></div>'}
      <div class="lstat"><span class="muted small" id="cl1"></span><b id="cv1"></b></div><div class="lstat"><span class="muted small">Total</span><b id="cv2"></b></div>
      <div class="lstat"><span class="pill" id="sync"></span></div></div>
    <div class="livegrid"><div>
      <div class="panel scanp"><div class="row"><input id="scan" class="inp scaninp" placeholder="${listed ? 'Scan or type a SKU to look it up' : 'Scan or type a SKU, then Enter'}" autocomplete="off" inputmode="numeric">
        ${listed ? '<button class="btn primary" id="bcb">Live map (buyer\'s choice)</button>' : `<button class="btn" id="bcb">Buyer's choice</button>${s.platform === 'whatnot' ? '<button class="btn" id="gv">Giveaway: off</button>' : ''}`}</div>
        <div id="msg"></div><div id="bcp"></div></div>
      <div class="panel" id="card"><p class="muted">${listed ? 'Scan a bag to see its details and floor. Lookups hold nothing.' : 'Scan the first pull.'}</p></div>
    </div><div>
      <div class="panel"><h3 style="margin-top:0">On air</h3><div class="row" id="air"></div></div>
      <div class="panel"><h3 style="margin-top:0">Controls</h3><div class="ctl">
        <button class="btn" id="pz"></button><button class="btn" id="un">Undo last</button>
        ${listed ? '' : '<button class="btn" id="np">New Part</button><button class="btn" id="po">Set pull #</button>'}
        <button class="btn danger" id="end">End show</button></div><div id="lockmsg" class="muted small"></div></div>
      <div class="panel"><h3 style="margin-top:0">${listed ? 'Live map wins' : 'Pulls'}</h3><div id="pl" class="plist"></div></div>
    </div></div></div>`;

  const draw = () => {
    const sv = L.s, q = loadQ();
    $('#prt').textContent = listed ? '#' + sv.next_win : sv.part;
    if (!listed) $('#nxt').textContent = '#' + (sv.next_pull + q.length);
    $('#cl1').textContent = listed ? 'Wins' : 'This Part';
    $('#cv1').textContent = listed ? sv.counts.wins : sv.counts.part + q.length;
    $('#cv2').textContent = sv.counts.total + q.length;
    $('#lvtag').textContent = sv.paused ? '❚❚ PAUSED' : '● LIVE'; $('#lvtag').className = 'tag ' + (sv.paused ? 'off' : 'live');
    $('#pz').textContent = sv.paused ? 'Resume mapping' : 'Pause';
    $('#lockmsg').textContent = sv.paused ? 'Paused: the clock keeps running. Inventory can be added; removing needs a confirm.' : 'Inventory is locked while live.';
    const sy = $('#sync');
    sy.textContent = L.sync === 'off' ? `Offline · ${q.length} waiting` : q.length ? `Saving ${q.length}…` : 'All saved';
    sy.className = 'pill ' + (L.sync === 'off' ? 'bad' : q.length ? 'warn' : 'ok');
    // on air
    const streamers = sv.people.filter(p => p.role === 'streamer');
    $('#air').innerHTML = streamers.map(p => `<button class="btn ${sv.on_air.includes(p.profile_id) ? 'primary' : ''}" data-air="${p.profile_id}">${esc(p.name)}</button>`).join('') || '<span class="muted">No streamers</span>';
    $('#air').querySelectorAll('[data-air]').forEach(b => b.onclick = () => online(async () => {
      const id = Number(b.dataset.air); let ids = sv.on_air.includes(id) ? sv.on_air.filter(x => x !== id) : [...sv.on_air, id];
      if (!ids.length) return toast('Someone has to be on air', true);
      await rpc('tfd_show_on_air', { p_id: sv.id, p_ids: ids }); await refresh();
    }));
    // pulls list (server + queued)
    const rows = [...q.slice().reverse().map(x => ({ queued: true, part: sv.part, pull_no: '…', sku: x.sku, kind: x.kind, name: L.items[x.sku]?.name || '', status: 'held' })),
      ...sv.pulls];
    $('#pl').innerHTML = rows.slice(0, 200).map(p => `<div class="prow ${p.status === 'void' ? 'void' : ''}"><div><b>${p.kind === 'win' ? 'Win #' : (sv.part > 1 || p.part > 1 ? `P${p.part} #` : '#')}${p.pull_no}</b>
        <span class="mono small">${p.sku}</span> ${esc(p.name || [p.brand, p.model].filter(Boolean).join(' '))}
        ${p.kind === 'giveaway' ? '<span class="tag claude">Giveaway</span>' : ''}${p.bc ? '<span class="tag">BC</span>' : ''}${p.outside_list ? '<span class="tag off">Outside list</span>' : ''}${p.queued ? '<span class="tag off">waiting</span>' : ''}${p.status === 'void' ? `<span class="tag off">Void</span> <span class="muted small">${esc(p.note || '')}</span>` : ''}</div>
      ${!p.queued && p.status === 'held' ? `<div class="row"><button class="btn sm" data-ed="${p.id}">Edit SKU</button>${sv.platform === 'whatnot' && p.kind !== 'win' ? `<button class="btn sm" data-gv="${p.id}" data-k="${p.kind}">${p.kind === 'giveaway' ? 'Not giveaway' : 'Giveaway'}</button>` : ''}<button class="btn sm danger" data-vd="${p.id}">Void</button></div>` : ''}</div>`).join('')
      || '<p class="muted">Nothing yet.</p>';
    $('#pl').querySelectorAll('[data-ed]').forEach(b => b.onclick = () => editPull(sv, sv.pulls.find(p => p.id === Number(b.dataset.ed)), refresh));
    $('#pl').querySelectorAll('[data-vd]').forEach(b => b.onclick = () => voidPull(sv.pulls.find(p => p.id === Number(b.dataset.vd)), refresh));
    $('#pl').querySelectorAll('[data-gv]').forEach(b => b.onclick = () => online(async () => { await rpc('tfd_pull_kind', { p_pull: Number(b.dataset.gv), p_kind: b.dataset.k === 'giveaway' ? 'normal' : 'giveaway' }); await refresh(); }));
    drawBc();
  };
  const refresh = async () => {
    try { L.s = await rpc('tfd_show', { p_id: s.id }); L.bc = L.s.bc; if (L.s.status !== 'live') { clearInterval(SH.timer); return renderShows(); }
      if (!loadQ().length) { cat = await rpc('tfd_show_catalog', { p_id: s.id }); loadCat(cat); }
      L.base = { secs: L.s.seconds, at: Date.now() }; if (L.sync === 'off') L.sync = 'ok'; draw();
    } catch (e) { if (isNetErr(e)) { L.sync = 'off'; draw(); } else toast(e.message, true); }
  };
  const online = async fn => {
    if (loadQ().length) { await flush(); if (loadQ().length) return toast('Waiting for the connection to save the queued scans first', true); }
    try { await fn(); } catch (e) { toast(isNetErr(e) ? 'No connection. Try again in a moment.' : e.message, true); if (isNetErr(e)) { L.sync = 'off'; draw(); } }
  };
  const msg = (html, cls) => { $('#msg').innerHTML = html ? `<div class="note ${cls || ''}" style="margin-top:10px">${html}</div>` : ''; };
  const cardHtml = (c, extra) => `<div class="pcard">${c.image_url ? `<img src="${esc(c.image_url)}" alt="">` : '<div class="noimg">No image</div>'}
      <div><div class="muted small">SKU <span class="mono">${c.sku}</span>${c.upc ? ` · UPC ${esc(c.upc)}` : ''}${c.bin ? ` · bin ${esc(c.bin)}` : ''}</div>
      <div class="pbrand">${esc(c.brand || '')} <span class="muted">${esc(c.model || '')}</span></div>
      <div>${esc(c.name || '')}${c.color_name || c.color_code ? ` · ${esc(c.color_name || c.color_code)}` : ''}${c.lens_size ? ` · ${esc(c.lens_size)}mm` : ''}</div>
      ${c.specs ? `<div class="muted small">${esc(c.specs)}</div>` : ''}
      <div class="pnums"><div><span class="muted small">FLOOR</span><b class="huge">${c.floor_cents == null ? '—' : '$' + Math.round(c.floor_cents / 100)}</b></div>
        <div><span class="muted small">RETAIL</span><b class="big">${c.retail_cents == null ? '—' : '$' + (c.retail_cents / 100).toFixed(0)}</b></div>
        <div><span class="muted small">${extra && extra.lookup ? 'AVAILABLE' : 'LEFT AFTER THIS'}</span><b class="big">${extra && extra.left != null ? extra.left : c.available}</b></div></div>
      ${extra && extra.tags ? extra.tags : ''}</div></div>`;

  // ---- scanning (live mapping: local-first queue; listed: lookup)
  const scan = async raw => {
    const sku = raw.trim(); if (!sku) return;
    if (L.bc) return bcAdd(sku);
    if (listed) {
      try { const c = await rpc('tfd_lookup', { p_show: s.id, p_sku: sku }); msg('');
        $('#card').innerHTML = cardHtml(c, { lookup: true, tags: `${c.in_scope ? '' : '<span class="tag off">Not in this show\'s list</span> '}${c.listed_qty != null ? `<span class="tag">Listed: ${c.listed_qty}</span>` : ''}` });
      } catch (e) { const c = L.items[sku]; if (isNetErr(e) && c) $('#card').innerHTML = cardHtml(c, { lookup: true, tags: '<span class="tag off">offline: last known</span>' }); else msg(esc(e.message), 'bad'); }
      return;
    }
    if (L.s.paused) return msg('Mapping is paused. Resume to scan.', 'warn');
    const c = L.items[sku];
    if (!c) { // not in the local catalog (maybe brand new): ask the server directly
      try { const r = await rpc('tfd_scan', { p_show: s.id, p_sku: sku, p_client_id: uuid(), p_kind: L.giveNext ? 'giveaway' : 'normal' }); return afterServerScan(r, sku); }
      catch (e) { return msg(esc(isNetErr(e) ? `SKU ${sku} isn't in this device's list and there's no connection to check it.` : e.message), 'bad'); }
    }
    if ((L.avail[sku] || 0) <= 0) { $('#card').innerHTML = cardHtml(c, { left: 0 }); return msg('<b>Out of stock — unable to run</b>', 'bad big'); }
    if (L.caps && L.caps[sku] != null && (L.used[sku] || 0) >= L.caps[sku]) { $('#card').innerHTML = cardHtml(c, { left: L.avail[sku] }); return msg(`<b>List limit reached (${L.caps[sku]} for this show) — unable to run</b>`, 'bad big'); }
    let outside = false;
    if (L.scope && !L.scope.includes(sku)) {
      outside = true;
      const ok = await new Promise(res => { const m = modal(`<h2>Not in this show's inventory</h2><p>SKU ${sku} (${esc(c.name || c.brand + ' ' + c.model)}) isn't in <b>${esc(s.list_name)}</b>. Run it anyway?</p>
        <div class="actions"><button class="btn primary" id="oy">Run it</button></div>`); m.querySelector('#oy').onclick = () => { m.remove(); res(true); }; m.querySelector('[data-close]').addEventListener('click', () => res(false)); });
      if (!ok) return;
    }
    const kind = L.giveNext ? 'giveaway' : 'normal';
    const q = loadQ(); q.push({ client_id: uuid(), sku, kind, outside, at: Date.now() }); saveQ(q);
    L.avail[sku]--; L.used[sku] = (L.used[sku] || 0) + 1;
    const left = L.avail[sku], low = left <= (c.low_stock ?? 2);
    $('#card').innerHTML = cardHtml(c, { left, tags: `<div class="row" style="margin-top:8px"><span class="tag big">Pull #${L.s.next_pull + q.length - 1}${L.s.part > 1 ? ` · Part ${L.s.part}` : ''}</span>${kind === 'giveaway' ? '<span class="tag claude">Giveaway</span>' : ''}${outside ? '<span class="tag off">Outside list</span>' : ''}</div>` });
    msg(low ? `<b>Low stock:</b> ${left} left after this one.` : '', low ? 'warn' : '');
    if (L.giveNext) { L.giveNext = false; setGive(); }
    draw(); flush();
  };
  const afterServerScan = (r, sku) => {
    if (r.needs_confirm) return msg(esc(r.message) + ' Use the list on the left to run it from the catalog, or ask an admin.', 'warn');
    if (!r.ok) { if (r.card) $('#card').innerHTML = cardHtml(r.card, { left: r.card.available }); return msg(`<b>${esc(r.error)}</b>`, 'bad big'); }
    $('#card').innerHTML = cardHtml(r.card, { left: r.card.available, tags: `<span class="tag big">Pull #${r.pull.pull_no}</span>` });
    if (L.giveNext) { L.giveNext = false; setGive(); }
    refresh();
  };
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
        if (!r.ok || r.needs_confirm) { L.failed.push({ sku: it.sku, error: r.error || r.message }); msg(`<b>Scan of SKU ${it.sku} was rejected by the server:</b> ${esc(r.error || r.message)}. It was NOT recorded.`, 'bad big'); }
        L.sync = 'ok';
      }
      await refresh();
    } finally { flushing = false; }
  };

  // ---- buyer's choice / live map
  const drawBc = () => {
    const box = $('#bcp'); if (!box) return;
    if (!L.bc) { box.innerHTML = ''; $('#scan').placeholder = listed ? 'Scan or type a SKU to look it up' : 'Scan or type a SKU, then Enter'; return; }
    $('#scan').placeholder = 'Scan every item shown to the buyer';
    box.innerHTML = `<div class="bcbox"><div class="head" style="margin-bottom:8px"><b>${listed ? 'Live map' : 'Buyer\'s choice'}: scan each item shown, then tap the one the winner picked</b><button class="btn" id="bcx">Cancel</button></div>
      <div class="bcitems">${L.bc.items.map(it => `<div class="bci">${it.image_url ? `<img src="${esc(it.image_url)}" alt="">` : '<div class="noimg small">No image</div>'}<div><b>${esc(it.brand || '')} ${esc(it.model || '')}</b><div class="small">${esc(it.name || '')} · <span class="mono">${it.sku}</span></div>
        <div class="small">Floor <b>${it.floor_cents == null ? '—' : '$' + Math.round(it.floor_cents / 100)}</b></div></div>
        <div class="row"><button class="btn primary" data-pick="${it.item_id}">Winner picked this</button><button class="btn sm" data-rmi="${it.item_id}">×</button></div></div>`).join('') || '<p class="muted">No items scanned yet.</p>'}</div></div>`;
    $('#bcx').onclick = () => online(async () => { await rpc('tfd_bc_cancel', { p_group: L.bc.id }); msg('Buyer\'s choice cancelled. Items are available again.'); await refresh(); });
    box.querySelectorAll('[data-pick]').forEach(b => b.onclick = () => online(async () => {
      const r = await rpc('tfd_bc_pick', { p_group: L.bc.id, p_item: Number(b.dataset.pick), p_client_id: uuid() });
      $('#card').innerHTML = cardHtml(r.card, { left: r.card.available, tags: `<span class="tag big">${listed ? 'Win' : 'Pull'} #${r.pull.pull_no}</span> <span class="tag">Buyer's choice</span>` });
      msg(`${listed ? 'Win' : 'Pull'} #${r.pull.pull_no} recorded. The other items are available again.`, 'ok'); await refresh();
    }));
    box.querySelectorAll('[data-rmi]').forEach(b => b.onclick = () => online(async () => { await rpc('tfd_bc_remove', { p_item: Number(b.dataset.rmi) }); await refresh(); }));
  };
  const bcAdd = sku => online(async () => {
    let r = await rpc('tfd_bc_add', { p_group: L.bc.id, p_sku: sku });
    if (r.needs_confirm) { if (!confirm(r.message)) return; r = await rpc('tfd_bc_add', { p_group: L.bc.id, p_sku: sku, p_confirm_outside: true }); }
    if (!r.ok) return msg(`<b>${esc(r.error)}</b>`, 'bad big');
    msg(''); await refresh();
  });
  $('#bcb').onclick = () => online(async () => { if (L.bc) return; await rpc('tfd_bc_open', { p_show: s.id }); await refresh(); $('#scan').focus(); });
  const setGive = () => { const b = $('#gv'); if (b) { b.textContent = 'Giveaway: ' + (L.giveNext ? 'ON for next scan' : 'off'); b.classList.toggle('primary', L.giveNext); } };
  if ($('#gv')) $('#gv').onclick = () => { L.giveNext = !L.giveNext; setGive(); $('#scan').focus(); };

  // ---- controls
  $('#scan').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); const v = e.target.value; e.target.value = ''; scan(v); } });
  $('#pz').onclick = () => online(async () => { await rpc('tfd_show_pause', { p_id: s.id, p_paused: !L.s.paused }); await refresh(); });
  $('#un').onclick = () => online(async () => {
    const last = L.s.pulls.find(p => p.status === 'held'); if (!last) return toast('Nothing to undo', true);
    if (!confirm(`Undo ${last.kind === 'win' ? 'win' : 'pull'} #${last.pull_no} (SKU ${last.sku})?`)) return;
    await rpc('tfd_pull_undo_last', { p_show: s.id }); msg(`Undid #${last.pull_no}.`); await refresh();
  });
  if ($('#np')) $('#np').onclick = () => online(async () => {
    if (!confirm(`Start Part ${L.s.part + 1}? Pull numbers restart at #1.`)) return;
    await rpc('tfd_show_new_part', { p_show: s.id }); msg(`Part ${L.s.part + 1} started.`, 'ok'); await refresh();
  });
  if ($('#po')) $('#po').onclick = () => {
    const m = modal(`<h2>Set next pull #</h2><p class="muted small">Only if the numbering got out of step with the platform. Logged.</p>
      <div class="grid"><label class="f">Next pull #<input id="pn" class="inp" type="number" min="1" value="${L.s.next_pull}"></label><label class="f">Reason<input id="pr" class="inp"></label></div>
      <div class="err" id="pe"></div><div class="actions"><button class="btn primary" id="py">Set</button></div>`);
    m.querySelector('#py').onclick = () => online(async () => { try { await rpc('tfd_show_set_pull', { p_show: s.id, p_next: Number($('#pn').value), p_reason: $('#pr').value }); m.remove(); await refresh(); } catch (e) { m.querySelector('#pe').textContent = e.message; } });
  };
  $('#end').onclick = () => {
    const m = modal(`<h2>End show</h2><p>Stops the clock and locks scanning. Holds stay until the CSV is imported and the show finalized.</p>
      <label class="f">Type SHOW OVER to confirm<input id="eo" class="inp" autocomplete="off"></label><div class="err" id="ee"></div><div class="actions"><button class="btn danger" id="ey">End show</button></div>`);
    m.querySelector('#ey').onclick = () => online(async () => {
      try { await rpc('tfd_show_end', { p_show: s.id, p_confirm: $('#eo').value }); m.remove(); clearInterval(SH.timer); renderShows(); } catch (e) { m.querySelector('#ee').textContent = e.message; }
    });
  };

  // ---- clock + resume
  L.base = { secs: s.seconds, at: Date.now() };
  SH.timer = setInterval(() => { const c = $('#clk'); if (!c) return clearInterval(SH.timer); c.textContent = fmtClock(L.base.secs + (Date.now() - L.base.at) / 1000); }, 500);
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

// ================================================================ ended (waiting for the CSV — import arrives in Phase 4)
function showEnded(main, s) {
  const admin = s.is_admin, listed = s.type === 'listed';
  const held = s.pulls.filter(p => p.status === 'held');
  main.innerHTML = `<div class="head"><div><a href="#shows" class="small">← All shows</a><h1>${esc(s.label)} ${stageTag(s.status)}</h1>
      <p class="muted small">${s.platform === 'tiktok' ? 'TikTok' : 'Whatnot'} · ${listed ? 'Listed show' : 'Live mapping'} · ${esc(s.list_name)} · ${fmtClock(s.seconds)} live</p></div>
      <div class="row"><button class="btn" id="dl">Download mapping file</button>${admin && s.status === 'ended' ? '<button class="btn" id="ro">Reopen show</button>' : ''}</div></div>
    <div class="grid stats">
      <div class="panel"><div class="muted small">${listed ? 'Live map wins' : 'Pulls held'}</div><b class="big">${held.length}</b></div>
      <div class="panel"><div class="muted small">Giveaways</div><b class="big">${s.counts.giveaways}</b></div>
      <div class="panel"><div class="muted small">Voided</div><b class="big">${s.counts.void}</b></div>
      <div class="panel"><div class="muted small">Parts</div><b class="big">${listed ? '—' : s.part}</b></div></div>
    <div class="panel"><h2>Next: import the ${s.platform === 'tiktok' ? 'TikTok "To Ship"' : 'Whatnot show report'} CSV</h2>
      <p class="muted">CSV import, matching, review and finalize are Phase 4. Until then the show waits here in Ended and its units stay held.</p></div>
    <div class="panel"><h2>Lineup</h2>${lineupHtml(s)}</div>
    <div class="panel"><h2>${listed ? 'Wins' : 'Pulls'}</h2><div id="pl" class="plist"></div></div>`;
  $('#pl').innerHTML = s.pulls.map(p => `<div class="prow ${p.status === 'void' ? 'void' : ''}"><div><b>${p.kind === 'win' ? 'Win #' : `P${p.part} #`}${p.pull_no}</b> <span class="mono small">${p.sku}</span> ${esc(p.name || '')}
      ${p.kind === 'giveaway' ? '<span class="tag claude">Giveaway</span>' : ''}${p.bc ? '<span class="tag">BC</span>' : ''}${p.outside_list ? '<span class="tag off">Outside list</span>' : ''}${p.status === 'void' ? `<span class="tag off">Void</span> <span class="muted small">${esc(p.note || '')}</span>` : ''}
      <span class="muted small">· ${when(p.at)}${p.on_air.length ? ' · ' + p.on_air.map(esc).join(' + ') : ''}</span></div>
      ${p.status === 'held' ? `<div class="row"><button class="btn sm" data-ed="${p.id}">Edit SKU</button><button class="btn sm danger" data-vd="${p.id}">Void</button></div>` : ''}</div>`).join('') || '<p class="muted">No pulls.</p>';
  const re = () => renderShows();
  $('#pl').querySelectorAll('[data-ed]').forEach(b => b.onclick = () => editPull(s, s.pulls.find(p => p.id === Number(b.dataset.ed)), re));
  $('#pl').querySelectorAll('[data-vd]').forEach(b => b.onclick = () => voidPull(s.pulls.find(p => p.id === Number(b.dataset.vd)), re));
  $('#dl').onclick = async () => {
    const d = await rpc('tfd_show_mapping', { p_show: s.id });
    downloadCSV(`${d.label} - mapping.csv`, ['Part', 'Pull #', 'Type', 'Status', 'SKU', 'Product', 'Brand', 'Model', 'Color code', 'Lens size', 'Scanned at', 'Scanned by', 'On air', "Buyer's choice", 'Outside list', 'Note'],
      d.rows.map(r => [r.kind === 'win' ? 'Win' : r.part, r.pull_no, r.kind, r.status, r.sku, r.product, r.brand, r.model, r.color_code, r.lens_size, new Date(r.scanned_at).toLocaleString(), r.scanned_by, r.on_air || '', r.buyers_choice ? 'yes' : '', r.outside_list ? 'yes' : '', r.note || '']));
  };
  if ($('#ro')) $('#ro').onclick = () => {
    const m = modal(`<h2>Reopen show?</h2><p>The clock resumes now. The gap since it ended is unpaid unless you edit hours at review.</p>
      <label class="f">Reason<input id="rr" class="inp" placeholder="e.g. ended by mistake"></label><div class="err" id="re"></div><div class="actions"><button class="btn primary" id="ry">Reopen</button></div>`);
    m.querySelector('#ry').onclick = async () => { try { await rpc('tfd_show_reopen', { p_show: s.id, p_reason: $('#rr').value }); m.remove(); renderShows(); } catch (e) { m.querySelector('#re').textContent = e.message; } };
  };
}
