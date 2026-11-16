'use strict';
// Fulfillment: admin queue / pick list / lookup / problems / scanner cards, and the packing station (packers sign in with their own account).

// ---------------------------------------------------------------- Code 128 (set B) as SVG, for the printed scanner cards
const FC128 = '212222 222122 222221 121223 121322 131222 122213 122312 132212 221213 221312 231212 112232 122132 122231 113222 123122 123221 223211 221132 221231 213212 223112 312131 311222 321122 321221 312212 322112 322211 212123 212321 232121 111323 131123 131321 112313 132113 132311 211313 231113 231311 112133 112331 132131 113123 113321 133121 313121 211331 231131 213113 213311 213131 311123 311321 331121 312113 312311 332111 314111 221411 431111 111224 111422 121124 121421 141122 141221 112214 112412 122114 122411 142112 142211 241211 221114 413111 241112 134111 111242 121142 121241 114212 124112 124211 411212 421112 421211 212141 214121 412121 111143 111341 131141 114113 114311 411113 411311 113141 114131 311141 411131 211412 211214 211232'.split(' ');
function code128Svg(text, h = 70) {
  const vals = [104, ...[...text].map(ch => ch.charCodeAt(0) - 32)];
  const sum = vals.reduce((a, v, i) => a + v * (i || 1), 0) % 103;
  const pats = [...vals, sum].map(v => FC128[v]).concat('2331112');
  let x = 10, rects = '';
  pats.forEach(p => [...p].forEach((w, i) => { w = Number(w); if (i % 2 === 0) rects += `<rect x="${x}" y="0" width="${w}" height="${h}"/>`; x += w; }));
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${x + 10} ${h}" width="${(x + 10) * 2.2}" height="${h * 1.3}" shape-rendering="crispEdges">${rects}</svg>`;
}
const CARDS = [['TFD-SNAP', 'TAKE PICTURE'], ['TFD-DONE', 'FINISH PACKAGE'], ['TFD-UNDO', 'UNDO LAST SCAN'], ['TFD-PROBLEM', 'PROBLEM']];

async function signedUrl(bucket, path) {
  const t = await token();
  const r = await fetch(`${CFG.url}/storage/v1/object/sign/${bucket}`, { method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn: 3600, paths: [path] }) });
  const d = await r.json().catch(() => []);
  return Array.isArray(d) && d[0] && d[0].signedURL ? CFG.url + '/storage/v1' + d[0].signedURL : null;
}
const ageTxt = iso => { const h = (Date.now() - new Date(iso)) / 3600000; return h < 1 ? Math.round(h * 60) + 'm' : h < 48 ? Math.round(h) + 'h' : Math.round(h / 24) + 'd'; };
const PK_STATUS = { todo: ['Not started', ''], in_progress: ['In progress', 'live'], packed: ['Packed', 'ok'], problem: ['Problem', 'off'] };
const pkTag = s => `<span class="tag ${PK_STATUS[s]?.[1] || ''}">${PK_STATUS[s]?.[0] || s}</span>`;

async function renderFulfillment() {
  const [, a] = location.hash.slice(1).split('/');
  const main = $('#main');
  try {
    if (S.state.me.role !== 'admin' || a === 'pack') return packStation(main);
    if (a === 'picklist') return pickListPage(main);
    if (a === 'cards') return cardsPage(main);
    return fulfillmentAdmin(main);
  } catch (e) { main.innerHTML = `<div class="note bad">${esc(e.message)}</div>`; }
}

// ================================================================ admin
async function fulfillmentAdmin(main) {
  const q = await rpc('tfd_pack_queue');
  if (!stillOn('fulfillment')) return;
  const st = q.storage, mb = (st.bytes / 1048576).toFixed(1);
  const problems = q.packages.filter(p => p.status === 'problem');
  main.innerHTML = `<div class="head"><div><h1>Fulfillment</h1><p class="muted small">Every package from finalized shows that isn't packed yet, oldest first.</p></div>
      <div class="row wrap"><a class="btn" href="#fulfillment/picklist">Pick list</a><a class="btn" href="#fulfillment/cards">Scanner cards</a><a class="btn primary" href="#fulfillment/pack">Pack</a></div></div>
    <div class="grid stats">
      <div class="panel"><div class="muted small">Packages left</div><b class="big" style="${q.packages.length ? '' : 'color:var(--ok)'}">${q.packages.length}</b>${q.packages.length ? '' : '<div class="small">Zero pending ✓</div>'}</div>
      <div class="panel"><div class="muted small">Problems</div><b class="big" style="${problems.length ? 'color:var(--bad)' : ''}">${problems.length}</b></div>
      <div class="panel"><div class="muted small">Packed today</div><b class="big">${q.packed_today}</b></div>
      <div class="panel"><div class="muted small">Packing now</div><b class="big">${q.clocked_in.length}</b><div class="muted small">${q.clocked_in.map(c => `${esc(c.name)} since ${new Date(c.since).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}`).join(', ')}</div></div>
      <div class="panel"><div class="muted small">Photo storage</div><b class="big">${mb} MB</b><div class="muted small">${st.photos} photo(s), kept ${st.retention_days} days</div></div></div>
    ${q.by_show.length ? `<div class="panel"><h3 style="margin-top:0">Left by show</h3>${q.by_show.map(b => `<div class="row" style="justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--line)"><span>${esc(b.show)}</span><span><b>${b.left}</b> <span class="muted small">oldest ${ageTxt(b.oldest)}</span></span></div>`).join('')}</div>` : ''}
    <div class="panel"><div class="row wrap"><input id="lq" class="inp" placeholder="Find a package: tracking #, order #, buyer or name" style="flex:1;min-width:240px"><button class="btn" id="lgo">Find</button></div><div id="lres"></div></div>
    ${problems.length ? `<div class="panel"><h3 style="margin-top:0">Problems</h3><table><tr><th>Package</th><th>Buyer</th><th>Problem</th><th></th></tr>
      ${problems.map(p => `<tr><td class="mono small">${esc(p.tracking || '#' + p.id)}<div class="muted">${esc(p.show)}</div></td><td>${esc(p.ship_name || p.buyer || '')}</td>
        <td>${esc(p.problem_note || '')}<div class="muted small">by ${esc(p.problem_by || '')}</div></td><td><button class="btn sm" data-rs="${p.id}">Resolve</button></td></tr>`).join('')}</table></div>` : ''}
    <div class="panel"><h3 style="margin-top:0">Queue</h3><div style="overflow-x:auto"><table><tr><th>Status</th><th>Tracking</th><th>Show</th><th>Buyer</th><th>Items</th><th>Photo</th><th>Age</th></tr>
      ${q.packages.map(p => `<tr class="click" data-pk="${esc(p.tracking || p.id)}"><td>${pkTag(p.status)}</td><td class="mono small">${esc(p.tracking || '—')}</td><td class="small">${esc(p.show)}</td>
        <td>${esc(p.ship_name || '')}<div class="muted small">${esc(p.buyer || '')}</div></td><td>${p.scanned}/${p.units}</td><td>${p.photos ? '✓' : ''}</td><td>${ageTxt(p.created_at)}</td></tr>`).join('')
        || '<tr><td colspan="7" class="muted">Nothing to pack. Packages appear here when a show is finalized.</td></tr>'}</table></div></div>`;
  const find = async v => {
    try { const r = await rpc('tfd_pack_lookup', { p_q: v }); $('#lres').innerHTML = r.length ? r.map(lookupCard).join('') : '<p class="muted">No package found.</p>'; bindLookup(r); }
    catch (e) { $('#lres').innerHTML = `<div class="err">${esc(e.message)}</div>`; }
  };
  $('#lgo').onclick = () => find($('#lq').value);
  $('#lq').onkeydown = e => { if (e.key === 'Enter') find($('#lq').value); };
  main.querySelectorAll('[data-pk]').forEach(tr => tr.onclick = () => { $('#lq').value = tr.dataset.pk; find(tr.dataset.pk); $('#lq').scrollIntoView({ behavior: 'smooth' }); });
  main.querySelectorAll('[data-rs]').forEach(b => b.onclick = () => {
    const m = modal(`<h2>Resolve problem</h2><p>The package goes back to the queue with its scans kept.</p><label class="f">What did you do?<input id="rn" class="inp" placeholder="e.g. swapped the damaged pair"></label>
      <div class="err" id="re"></div><div class="actions"><button class="btn primary" id="ry">Back to queue</button></div>`);
    m.querySelector('#ry').onclick = async () => { try { await rpc('tfd_pack_resolve', { p_pkg: Number(b.dataset.rs), p_note: m.querySelector('#rn').value }); m.remove(); toast('Back in the queue'); renderFulfillment(); } catch (e) { m.querySelector('#re').textContent = e.message; } };
  });
  function lookupCard(p) {
    return `<div class="panel" style="margin-top:10px"><div class="head"><div><b class="mono">${esc(p.tracking || 'no tracking #')}</b> ${pkTag(p.status)}<div class="muted small">${esc(p.show)} · ${esc(p.ship_name || '')} (${esc(p.buyer || '')}) · order${p.orders.length > 1 ? 's' : ''} ${p.orders.map(esc).join(', ')}</div>
        ${p.packed_at ? `<div class="small">Packed by ${esc(p.packed_by)} ${when(p.packed_at)}</div>` : ''}${p.problem_note ? `<div class="small">Problem: ${esc(p.problem_note)}${p.resolved_note ? ' · fixed: ' + esc(p.resolved_note) : ''}</div>` : ''}</div>
        ${p.status === 'packed' ? `<button class="btn sm danger" data-up="${p.id}">Unpack</button>` : ''}</div>
      <div class="small">${p.items.map(i => `${i.qty} × <span class="mono">${i.sku}</span> ${esc(i.name || '')} <span class="muted">(${i.scanned}/${i.qty} scanned)</span>`).join('<br>')}</div>
      <div class="row wrap" style="margin-top:8px">${p.all_photos.map(ph => ph.deleted_at ? `<span class="tag off">photo ${ph.deleted_reason === 'retake' ? 'retaken' : 'deleted'} ${new Date(ph.deleted_at).toLocaleDateString()}</span>` : `<img data-ph="${esc(ph.path)}" alt="" style="width:160px;height:120px;object-fit:cover;border-radius:8px;background:#ddd;cursor:pointer" title="${esc(ph.by)} ${when(ph.at)}">`).join('') || '<span class="muted small">No photos</span>'}</div></div>`;
  }
  function bindLookup() {
    $('#lres').querySelectorAll('img[data-ph]').forEach(async img => { const u = await signedUrl('pack-photos', img.dataset.ph); if (u) { img.src = u; img.onclick = () => window.open(u, '_blank'); } });
    $('#lres').querySelectorAll('[data-up]').forEach(b => b.onclick = () => {
      const m = modal(`<h2>Unpack this package?</h2><p>It goes back to the queue (scans and photos kept). Use this if it was finished by mistake.</p>
        <label class="f">Reason<input id="ur" class="inp"></label><div class="err" id="ue"></div><div class="actions"><button class="btn danger" id="uy">Unpack</button></div>`);
      m.querySelector('#uy').onclick = async () => { try { await rpc('tfd_pack_unpack', { p_pkg: Number(b.dataset.up), p_reason: m.querySelector('#ur').value }); m.remove(); toast('Back in the queue'); renderFulfillment(); } catch (e) { m.querySelector('#ue').textContent = e.message; } };
    });
  }
  // photos past retention: delete the files, then mark them (logged)
  try {
    const ex = await rpc('tfd_photos_expired');
    if (ex.length) {
      const t = await token();
      const r = await fetch(`${CFG.url}/storage/v1/object/pack-photos`, { method: 'DELETE', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' }, body: JSON.stringify({ prefixes: ex.map(x => x.path) }) });
      if (r.ok) await rpc('tfd_photos_mark_deleted', { p_ids: ex.map(x => x.id), p_reason: 'past the retention period' });
    }
  } catch {}
}

async function pickListPage(main) {
  const rows = await rpc('tfd_pick_list');
  if (!stillOn('fulfillment')) return;
  const total = rows.reduce((a, r) => a + r.need, 0);
  main.innerHTML = `<div class="head noprint"><div><a href="#fulfillment" class="small">← Fulfillment</a><h1>Pick list</h1></div><div class="row"><button class="btn primary" id="pp">Print</button></div></div>
    <div class="panel printable"><h2 style="margin-top:0">Pick list · ${new Date().toLocaleString()}</h2><p>${total} unit(s), ${rows.length} SKU(s), sorted by bin.</p>
    <table><tr><th>✓</th><th>Qty</th><th>SKU</th><th>Product</th><th>Bin</th><th>Note</th></tr>
    ${rows.map(r => `<tr><td>☐</td><td><b>${r.need}</b></td><td class="mono">${r.sku}</td><td>${esc([r.brand, r.model].filter(Boolean).join(' '))} <span class="muted">${esc(r.color || '')}</span><div class="small">${esc(r.name || '')}</div></td>
      <td><b>${esc(r.bin || '—')}</b></td><td class="small">${r.stage_note ? '<b>Last one is the stage sample: grab it from the table</b>' : r.on_stage ? 'Sample is on the stage table' : ''}</td></tr>`).join('') || '<tr><td colspan="6" class="muted">Nothing to pick.</td></tr>'}</table></div>`;
  $('#pp').onclick = () => window.print();
}

function cardsPage(main) {
  main.innerHTML = `<div class="head noprint"><div><a href="#fulfillment" class="small">← Fulfillment</a><h1>Scanner cards</h1><p class="muted small">Print, cut out and tape near the packing table. Scan a card to run the action.</p></div>
      <button class="btn primary noprint" id="pp">Print</button></div>
    <div class="cards printable">${CARDS.map(([c, l]) => `<div class="pcardx"><div class="pcl">${l}</div>${code128Svg(c)}<div class="mono small">${c}</div></div>`).join('')}</div>`;
  $('#pp').onclick = () => window.print();
}

// ================================================================ packing station
const PQKEY = 'tfd_packq';
const loadPQ = () => { try { return JSON.parse(localStorage.getItem(PQKEY)) || []; } catch { return []; } };
const savePQ = q => { try { localStorage.setItem(PQKEY, JSON.stringify(q)); } catch {} };

async function packStation(main) {
  const P = { data: null, cur: null, stream: null, sync: 'ok', msg: '' };
  const load = async () => { P.data = await rpc('tfd_pack_data'); if (P.cur) P.cur = P.data.packages.find(p => p.id === P.cur.id) || null; };
  await load();
  if (!stillOn('fulfillment')) return;
  if (!P.data.clock_in) {
    main.innerHTML = `<div class="panel" style="max-width:520px;margin:40px auto;text-align:center"><h1>Packing</h1><p>Hi ${esc(P.data.me)}. ${P.data.packages.length} package(s) waiting.</p>
      <button class="btn primary huge-btn" id="cin">Clock in</button><p class="muted small">Your time counts from now until you clock out.</p>
      ${S.state.me.role === 'admin' ? '<p><a href="#fulfillment" class="small">← Back to Fulfillment</a></p>' : ''}</div>`;
    $('#cin').onclick = async () => { try { await rpc('tfd_pack_clock', { p_in: true }); packStation(main); } catch (e) { toast(e.message, true); } };
    return;
  }
  main.innerHTML = `<div class="packst">
    <div class="livebar"><div><div class="lname">Packing · ${esc(P.data.me)}</div><div class="muted small">Clocked in ${new Date(P.data.clock_in).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' })}</div></div>
      <div class="lstat"><span class="muted small">Left</span><b class="big" id="left"></b></div><div class="lstat"><span class="pill" id="sync"></span></div>
      <div class="row"><a class="btn sm" href="#fulfillment/picklist">Pick list</a><button class="btn sm" id="cout">Clock out</button></div></div>
    <div class="panel scanp"><input id="scan" class="inp scaninp" autocomplete="off" placeholder="Scan a shipping label to start"><div id="msg"></div></div>
    <div class="packgrid"><div id="pkg"></div>
      <div class="panel" id="campanel"><div class="row" style="justify-content:space-between"><h3 style="margin:0">Camera</h3><select id="camsel" class="inp" style="max-width:220px"></select></div>
        <video id="vid" autoplay playsinline muted style="width:100%;border-radius:10px;background:#000;margin-top:8px;aspect-ratio:4/3;object-fit:cover"></video>
        <canvas id="cv" style="display:none"></canvas><div class="row" style="margin-top:8px"><button class="btn" id="snap">Take picture</button><span class="muted small">or scan TAKE PICTURE</span></div></div></div>
    <div class="panel"><div class="row wrap"><input id="sq" class="inp" placeholder="Label won't scan? Search buyer or name" style="flex:1"><button class="btn" id="sgo">Search</button></div><div id="sres"></div></div></div>`;
  const msg = (h, cls) => { $('#msg').innerHTML = h ? `<div class="note ${cls || ''}" style="margin-top:10px">${h}</div>` : ''; };
  const focus = () => { const s = $('#scan'); if (s && !document.querySelector('.modal')) s.focus(); };
  const draw = () => {
    const q = loadPQ();
    $('#left').textContent = P.data.packages.filter(p => p.status !== 'packed').length;
    const sy = $('#sync'); sy.textContent = P.sync === 'off' ? `Offline · ${q.length} waiting` : q.length ? `Saving ${q.length}…` : 'All saved'; sy.className = 'pill ' + (P.sync === 'off' ? 'bad' : q.length ? 'warn' : 'ok');
    const p = P.cur, el = $('#pkg');
    $('#scan').placeholder = p ? 'Scan each item, then TAKE PICTURE, then FINISH' : 'Scan a shipping label to start';
    if (!p) { el.innerHTML = `<div class="panel"><p class="muted" style="font-size:1.1rem">Scan the shipping label of the next package.</p></div>`; return; }
    const pend = q.filter(x => x.pkg === p.id);
    const items = p.items.map(i => ({ ...i, got: i.scanned + pend.filter(x => x.sku === i.sku).length }));
    const allIn = items.every(i => i.got >= i.qty);
    el.innerHTML = `<div class="panel"><div class="head"><div><div class="muted small">${esc(p.show)} · ${p.platform === 'tiktok' ? 'TikTok' : 'Whatnot'}</div>
        <h2 style="margin:2px 0">${esc(p.ship_name || p.buyer || 'Buyer')}</h2><div class="muted small">${esc(p.buyer || '')} · <span class="mono">${esc(p.tracking || 'no tracking #')}</span></div></div>
        ${pkTag(p.status)}</div>
      ${p.status === 'problem' ? `<div class="note bad">Marked Problem: ${esc(p.problem_note || '')}. Kenny has to resolve it before it can be finished.</div>` : ''}
      ${p.resolved_note ? `<div class="note small">Fixed by Kenny: ${esc(p.resolved_note)}</div>` : ''}
      <div class="pitems">${items.map(i => `<div class="pitem ${i.got >= i.qty ? 'done' : ''}">${i.image_url ? `<img src="${esc(i.image_url)}" alt="">` : '<div class="noimg">No image</div>'}
        <div><b>${esc([i.brand, i.model].filter(Boolean).join(' '))}</b> <span class="muted">${esc(i.color || '')}${i.lens_size ? ' · ' + esc(i.lens_size) + 'mm' : ''}</span>
          <div class="small">${esc(i.name || '')}</div><div class="small">SKU <span class="mono">${i.sku}</span> · bin <b>${esc(i.bin || '—')}</b>${i.on_stage ? ' · <b>sample may be on the stage table</b>' : ''}</div></div>
        <div class="pcount"><b class="big">${i.got}/${i.qty}</b>${i.got >= i.qty ? '<div class="okc">✓</div>' : ''}</div></div>`).join('')}</div>
      <div class="row wrap" style="margin-top:10px">${p.photos.map(ph => `<div class="thumb"><img data-ph="${esc(ph.path)}" alt=""><button class="btn sm" data-rm="${ph.id}">Retake</button></div>`).join('') || `<span class="muted small">${P.data.rules.photo_required ? 'Photo needed: label and every item together.' : 'No photo yet.'}</span>`}</div>
      <div class="actions" style="justify-content:space-between;margin-top:12px"><div class="row"><button class="btn" id="und">Undo last scan</button><button class="btn danger" id="prob">Problem</button><button class="btn" id="leave">Leave package</button></div>
        <button class="btn primary" id="fin" ${(!allIn && P.data.rules.all_items_scanned) || (P.data.rules.photo_required && !p.photos.length) || p.status === 'problem' ? 'disabled' : ''}>Finish package</button></div></div>`;
    el.querySelectorAll('img[data-ph]').forEach(async img => { const u = await signedUrl('pack-photos', img.dataset.ph); if (u) img.src = u; });
    el.querySelectorAll('[data-rm]').forEach(b => b.onclick = () => online(async () => { const r = await rpc('tfd_pack_photo_remove', { p_photo: Number(b.dataset.rm) }); P.cur = r.package; draw(); msg('Photo removed. Take a new one.'); }));
    $('#und').onclick = undo; $('#prob').onclick = problem; $('#fin').onclick = finish; $('#leave').onclick = () => { P.cur = null; msg(''); draw(); focus(); };
  };
  const online = async fn => {
    if (loadPQ().length) { await flush(); if (loadPQ().length) return toast('Waiting for the connection to save the scans first', true); }
    try { await fn(); } catch (e) { beep('bad'); toast(isNetErr(e) ? 'No connection. Try again in a moment.' : e.message, true); if (isNetErr(e)) { P.sync = 'off'; draw(); } }
    focus();
  };
  const findLabel = raw => {
    const s = raw.toUpperCase().replace(/\s/g, '');
    const open = P.data.packages.filter(p => p.status !== 'packed');
    return open.filter(p => (p.tracking && p.tracking.length >= 8 && (s === p.tracking.toUpperCase() || s.endsWith(p.tracking.toUpperCase()) || s.includes(p.tracking.toUpperCase())))
      || (p.package_key && s === p.package_key.toUpperCase()) || p.orders.some(o => o && s === String(o).toUpperCase()));
  };
  const openPkg = p => { P.cur = p; msg(`Opened <b>${esc(p.ship_name || p.buyer || 'package')}</b>. Scan each item.`, 'ok'); beep('ok'); draw(); startCam(); };
  const scan = async raw => {
    const v = raw.trim(); if (!v) return;
    const V = v.toUpperCase();
    if (V === 'TFD-SNAP') return snap();
    if (V === 'TFD-DONE') return finish();
    if (V === 'TFD-UNDO') return undo();
    if (V === 'TFD-PROBLEM') return problem();
    const lbl = findLabel(v);
    if (!P.cur) {
      if (lbl.length === 1) return openPkg(lbl[0]);
      if (lbl.length > 1) { msg('More than one package matches that label. Pick one below.', 'warn'); return showResults(lbl); }
      beep('bad'); return msg(`No unpacked package for <span class="mono">${esc(v)}</span>. Try searching by name below, or ask Kenny.`, 'bad big');
    }
    if (lbl.length && !lbl.includes(P.cur) && !lbl.some(p => p.id === P.cur.id)) {
      beep('warn'); return msg(`That's another package's label (${esc(lbl[0].ship_name || lbl[0].buyer || '')}). Finish this one first, or tap <b>Leave package</b>.`, 'warn big');
    }
    if (lbl.some(p => p.id === P.cur.id)) return msg('Same label again. Now scan each item.', '');
    // item scan: check locally, queue, send
    const p = P.cur, q = loadPQ();
    if (p.status === 'problem') { beep('bad'); return msg('This package is marked Problem. Kenny has to resolve it.', 'bad big'); }
    const it = p.items.find(i => i.sku === V || (i.upc && i.upc.toUpperCase() === V));
    if (!it) { beep('bad'); return msg(`<b>WRONG ITEM.</b> ${esc(v)} is not in this package. Put it back.`, 'bad big'); }
    const got = it.scanned + q.filter(x => x.pkg === p.id && x.sku === it.sku).length;
    if (got >= it.qty) { beep('bad'); return msg(`<b>TOO MANY.</b> This package only needs ${it.qty} of SKU ${it.sku}.`, 'bad big'); }
    q.push({ pkg: p.id, sku: it.sku, code: v, client_id: uuid() }); savePQ(q);
    beep('ok'); msg(`✓ ${esc([it.brand, it.model].filter(Boolean).join(' '))} (${got + 1}/${it.qty})`, 'ok');
    draw(); flush();
  };
  let flushing = false;
  const flush = async () => {
    if (flushing) return; flushing = true;
    try {
      let q = loadPQ();
      while (q.length) {
        const it = q[0]; let r;
        try { r = await rpc('tfd_pack_scan', { p_pkg: it.pkg, p_code: it.code, p_client_id: it.client_id }); }
        catch (e) { if (isNetErr(e)) { P.sync = 'off'; draw(); setTimeout(flush, 3000); return; } r = { ok: false, error: e.message }; }
        q = loadPQ(); q.shift(); savePQ(q);
        if (!r.ok) { beep('bad'); msg(`<b>Scan of ${esc(it.code)} was not saved:</b> ${esc(r.error)}`, 'bad big'); }
        else if (r.package && P.cur && P.cur.id === r.package.id) P.cur = r.package;
        P.sync = 'ok';
      }
      await load(); draw();
    } finally { flushing = false; }
  };
  const undo = () => { if (!P.cur) return; online(async () => { const r = await rpc('tfd_pack_undo', { p_pkg: P.cur.id }); P.cur = r.package; msg(`Undid the last scan (SKU ${r.sku}).`); draw(); }); };
  const finish = () => {
    if (!P.cur) return msg('Scan a label first.', 'warn');
    online(async () => {
      try { await rpc('tfd_pack_finish', { p_pkg: P.cur.id }); }
      catch (e) { beep('bad'); return msg(esc(e.message), 'bad big'); }
      beep('ok'); const who = P.cur.ship_name || P.cur.buyer || 'package';
      P.cur = null; await load(); draw(); msg(`✓ <b>${esc(who)}</b> packed. Scan the next label.`, 'ok'); stopCam();
    });
  };
  const problem = () => {
    if (!P.cur) return msg('Scan a label first.', 'warn');
    const m = modal(`<h2>Problem with this package</h2><div class="row wrap">${['Item missing', 'Item damaged', 'Wrong item', 'Label problem'].map(t => `<button class="btn sm" data-t="${t}">${t}</button>`).join('')}</div>
      <label class="f">Note for Kenny<input id="pn" class="inp"></label><div class="err" id="pe"></div><div class="actions"><button class="btn danger" id="py">Mark Problem</button></div>`);
    m.querySelectorAll('[data-t]').forEach(b => b.onclick = () => { m.querySelector('#pn').value = b.dataset.t + ': '; m.querySelector('#pn').focus(); });
    m.querySelector('#pn').focus();
    m.querySelector('#py').onclick = () => online(async () => { try { await rpc('tfd_pack_problem', { p_pkg: P.cur.id, p_note: m.querySelector('#pn').value }); m.remove(); P.cur = null; await load(); draw(); msg('Marked Problem and sent to Kenny. Scan the next label.', 'warn'); stopCam(); } catch (e) { m.querySelector('#pe').textContent = e.message; } });
  };
  // ---- camera
  const CAMKEY = 'tfd_cam';
  const startCam = async () => {
    if (P.stream) return;
    try {
      const want = (() => { try { return localStorage.getItem(CAMKEY); } catch { return null; } })();
      P.stream = await navigator.mediaDevices.getUserMedia({ video: want ? { deviceId: { exact: want }, width: { ideal: 1920 } } : { facingMode: 'environment', width: { ideal: 1920 } }, audio: false });
      $('#vid').srcObject = P.stream;
      const devs = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput');
      const cur = P.stream.getVideoTracks()[0].getSettings().deviceId;
      $('#camsel').innerHTML = devs.map((d, i) => `<option value="${esc(d.deviceId)}" ${d.deviceId === cur ? 'selected' : ''}>${esc(d.label || 'Camera ' + (i + 1))}</option>`).join('');
    } catch (e) { P.stream = null; $('#campanel').querySelector('h3').textContent = 'Camera: ' + (e.name === 'NotAllowedError' ? 'allow camera access in Safari' : 'not available'); }
  };
  const stopCam = () => { if (P.stream) { P.stream.getTracks().forEach(t => t.stop()); P.stream = null; } };
  $('#camsel').onchange = () => { try { localStorage.setItem(CAMKEY, $('#camsel').value); } catch {} stopCam(); startCam(); focus(); };
  const snap = () => {
    if (!P.cur) return msg('Scan a label first.', 'warn');
    online(async () => {
      if (!P.stream) await startCam();
      const v = $('#vid'); if (!v.videoWidth) throw new Error('The camera isn\'t ready yet');
      const scale = Math.min(1, 1600 / v.videoWidth), c = $('#cv');
      c.width = Math.round(v.videoWidth * scale); c.height = Math.round(v.videoHeight * scale);
      c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
      const blob = await new Promise(r => c.toBlob(r, 'image/jpeg', 0.7));
      const path = `pkg-${P.cur.id}/${Date.now()}.jpg`, t = await token();
      const up = await fetch(`${CFG.url}/storage/v1/object/pack-photos/${path}`, { method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t, 'Content-Type': 'image/jpeg' }, body: blob });
      if (!up.ok) throw new Error('Photo upload failed (' + up.status + ')');
      const r = await rpc('tfd_pack_photo_add', { p_pkg: P.cur.id, p_path: path, p_bytes: blob.size });
      P.cur = r.package; beep('ok'); msg(`📷 Photo saved (${Math.round(blob.size / 1024)} KB). Scan FINISH when ready.`, 'ok'); draw();
    });
  };
  // ---- search
  const showResults = list => {
    $('#sres').innerHTML = list.length ? list.map(p => `<div class="row" style="justify-content:space-between;border-bottom:1px solid var(--line);padding:6px 0"><span><b>${esc(p.ship_name || '')}</b> <span class="muted small">${esc(p.buyer || '')} · ${esc(p.show)} · ${p.items.reduce((a, i) => a + i.qty, 0)} item(s)</span></span>
      <button class="btn sm" data-op="${p.id}">Open</button></div>`).join('') : '<p class="muted">No match.</p>';
    $('#sres').querySelectorAll('[data-op]').forEach(b => b.onclick = () => { openPkg(P.data.packages.find(p => p.id === Number(b.dataset.op))); $('#sres').innerHTML = ''; $('#sq').value = ''; focus(); });
  };
  const search = () => {
    const t = $('#sq').value.trim().toLowerCase(); if (t.length < 2) return;
    showResults(P.data.packages.filter(p => p.status !== 'packed' && [p.buyer, p.ship_name, p.tracking, ...p.orders].some(x => x && String(x).toLowerCase().includes(t))));
  };
  $('#sgo').onclick = search; $('#sq').onkeydown = e => { if (e.key === 'Enter') search(); };
  $('#snap').onclick = snap;
  $('#scan').addEventListener('keydown', e => { if (e.key === 'Enter') { e.preventDefault(); const v = e.target.value; e.target.value = ''; scan(v); } });
  $('#cout').onclick = () => online(async () => {
    if (P.cur && !confirm('Leave the open package unfinished and clock out?')) return;
    await rpc('tfd_pack_clock', { p_in: false }); stopCam(); toast('Clocked out'); packStation(main);
  });
  window.addEventListener('online', () => flush(), { once: true });
  window.addEventListener('hashchange', stopCam, { once: true });
  if (!window.__packFocus) { window.__packFocus = true; document.addEventListener('click', e => { const s = document.querySelector('.packst #scan'); if (s && !e.target.closest('input,select,button,a,textarea,.modal') && !document.querySelector('.modal')) s.focus(); }); }
  draw(); focus();
  if (loadPQ().length) flush();
}
