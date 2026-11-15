'use strict';
// Phase 4a: import the platform CSV, match orders to pulls, review, finalize / unfinalize, remove CSV.

const cents = v => { const s = String(v ?? '').replace(/[\t$,\s]/g, ''); if (s === '') return null; const n = Number(s); return Number.isFinite(n) ? Math.round(n * 100) : NaN; };
const clean = v => String(v ?? '').replace(/\t/g, '').trim();
const PROBLEM = {
  duplicate: 'Another order already matched this pull #', no_pull: 'No scanned pull with this Part and #', no_pull_number: 'No pull # on this row',
  part_unknown: "Can't tell which Part (the listing name has no \"Part N\")", giveaway_line: 'Giveaway listing: pick the pull it was',
  no_win: 'No recorded win for this SKU', no_sku: 'No TFD SKU on this row', unmatched: 'Unmatched by you', outside_window: "Placed outside this show's time (another show?)",
  no_item: 'No item (gift card / sponsor line)', ignored_manual: 'Marked not part of this show', before_scan: 'Placed before its pull was scanned'
};

// TikTok "To Ship" times: "10/08/2026 2:59:23 PM" → "2026-10-08 14:59:23" (wall clock; the server works out the zone)
function tiktokTime(v) {
  const m = clean(v).match(/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s*(AM|PM)?$/i);
  if (!m) return null;
  let h = Number(m[4]); if (m[7]) { const pm = m[7].toUpperCase() === 'PM'; if (h === 12) h = pm ? 12 : 0; else if (pm) h += 12; }
  const p = n => String(n).padStart(2, '0');
  return `${m[3]}-${p(m[1])}-${p(m[2])} ${p(h)}:${m[5]}:${m[6]}`;
}

// → { rows: [normalized orders], errors: [] }
function parseShowCSV(text, platform) {
  const grid = parseCSV(text);
  if (grid.length < 2) return { rows: [], errors: ['The file has no rows'] };
  const head = grid[0].map(h => clean(h));
  const col = name => head.indexOf(name);
  const isTT = col('Order ID') >= 0 && col('Seller SKU') >= 0, isWN = col('order_id') >= 0 && col('product_name') >= 0;
  if (platform === 'tiktok' && !isTT) return { rows: [], errors: [isWN ? 'This is a Whatnot file, but the show is on TikTok' : 'This doesn\'t look like a TikTok "To Ship" export (no Order ID / Seller SKU columns)'] };
  if (platform === 'whatnot' && !isWN) return { rows: [], errors: [isTT ? 'This is a TikTok file, but the show is on Whatnot' : 'This doesn\'t look like a Whatnot show report (no order_id / product_name columns)'] };
  const need = platform === 'tiktok' ? ['Order ID', 'Seller SKU', 'Product Name', 'Quantity', 'SKU Subtotal Before Discount', 'SKU Seller Discount', 'Original Shipping Fee', 'Shipping Fee Seller Discount', 'Created Time']
    : ['order_id', 'product_name', 'product_quantity', 'original_item_price', 'placed_at', 'cancelled_or_failed', 'sku'];
  const missing = need.filter(n => col(n) < 0);
  if (missing.length) return { rows: [], errors: ['Missing column(s): ' + missing.join(', ')] };
  const rows = [], errors = [];
  grid.slice(1).forEach((r, i) => {
    const g = n => clean(r[col(n)]);
    const raw = {}; head.forEach((h, k) => { if (h) raw[h] = clean(r[k]); });
    const line = i + 2, name = platform === 'tiktok' ? g('Product Name') : g('product_name');
    const pm = name.match(/part\s*(\d+)/i);
    if (platform === 'tiktok') {
      if (Number(g('Quantity') || 1) !== 1) errors.push(`Row ${line}: quantity ${g('Quantity')}. Each pull should be its own order of 1`);
      const sale = cents(g('SKU Subtotal Before Discount')), sd = cents(g('SKU Seller Discount')) || 0, ship = cents(g('Original Shipping Fee')), shd = cents(g('Shipping Fee Seller Discount')) || 0;
      if (sale === null || Number.isNaN(sale)) errors.push(`Row ${line}: no price`);
      const pn = /^\d+$/.test(g('Seller SKU')) ? Number(g('Seller SKU')) : /^\d+$/.test(g('Variation')) ? Number(g('Variation')) : null;
      const st = /cancel/i.test(g('Order Status')) ? 'cancelled' : 'paid';
      rows.push({ line, order_id: g('Order ID'), status: st, product_name: name, part: pm ? Number(pm[1]) : null, pull_no: pn, sku: null,
        sale_cents: (sale || 0) - sd, ship_cents: Number.isNaN(ship) || ship === null ? 0 : ship - shd, placed_local: tiktokTime(g('Created Time')) || tiktokTime(g('Paid Time')),
        tracking: g('Tracking ID'), package_key: g('Package ID') || g('Tracking ID'), buyer: g('Buyer Username'), ship_name: g('Recipient'), raw });
    } else {
      if (Number(g('product_quantity') || 1) !== 1) errors.push(`Row ${line}: quantity ${g('product_quantity')}. Each pull should be its own order of 1`);
      const sale = cents(g('original_item_price'));
      if (sale === null || Number.isNaN(sale)) errors.push(`Row ${line}: no price`);
      const nm = name.match(/#\s*(\d+)\s*$/), cf = g('cancelled_or_failed').toLowerCase();
      rows.push({ line, order_id: g('order_id'), status: cf.startsWith('fail') ? 'failed' : cf.startsWith('cancel') ? 'cancelled' : 'paid', product_name: name,
        part: pm ? Number(pm[1]) : null, pull_no: nm ? Number(nm[1]) : null, sku: /^\d{6}$/.test(g('sku')) ? g('sku') : null,
        sale_cents: sale || 0, ship_cents: null, coupon_cents: cents(g('coupon_price')) || null, placed_local: g('placed_at').slice(0, 19) || null,
        tracking: g('tracking_code'), package_key: g('shipment_id') || g('tracking_code'), buyer: g('buyer_username'), ship_name: (g('shipping_address').split(',')[0] || '').trim(), raw });
    }
  });
  return { rows, errors };
}

async function uploadShowFile(showId, file) {
  const path = `show-${showId}/${Date.now()}-${file.name.replace(/[^A-Za-z0-9._-]+/g, '_')}`;
  const t = await token();
  const r = await fetch(`${CFG.url}/storage/v1/object/show-files/${path}`, { method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t, 'Content-Type': 'text/csv' }, body: file });
  if (!r.ok) throw new Error('Saving the original file failed: ' + ((await r.json().catch(() => ({}))).message || r.status));
  return path;
}
async function openShowFile(path) {
  const t = await token();
  const r = await fetch(`${CFG.url}/storage/v1/object/sign/show-files`, { method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn: 600, paths: [path] }) });
  const d = await r.json().catch(() => []);
  const u = Array.isArray(d) && d[0] && d[0].signedURL;
  if (!u) return toast('Couldn\'t open the original file', true);
  window.open(CFG.url + '/storage/v1' + u, '_blank');
}

const TZ_NAME = { 'America/New_York': 'Eastern', UTC: 'UTC', 'America/Chicago': 'Central', 'America/Denver': 'Mountain', 'America/Los_Angeles': 'Pacific' };
const pullTxt = o => o.kind === 'win' ? `Win #${o.pull_no_matched}` : o.pull_part === 0 ? `Added #${o.pull_no_matched}` : `P${o.pull_part} #${o.pull_no_matched}`;
const fileTxt = o => o.pull_no != null ? `${o.part ? 'Part ' + o.part + ' ' : ''}#${o.pull_no}` : (o.file_sku ? 'SKU ' + o.file_sku : '—');

async function showReview(s) {
  const imp = $('#imp'), fin = $('#fin');
  if (!imp) return;
  if (s.status === 'ended') {
    imp.innerHTML = `<div class="panel"><h2>Step 1 · Import the ${s.platform === 'tiktok' ? 'TikTok "To Ship"' : 'Whatnot'} CSV</h2>
      <p class="muted">Export it from ${s.platform === 'tiktok' ? 'TikTok Seller Center (Orders → To Ship → Export)' : 'Whatnot (show report)'} before anything ships, then pick it here. The original file is saved untouched.</p>
      <div class="row"><input type="file" id="cf" accept=".csv"><button class="btn primary" id="cgo">Import & match</button></div><div class="err" id="ce"></div></div>`;
    fin.innerHTML = `<div class="panel"><h2>Step 3 · Finalize</h2><p class="muted">Import the CSV first.</p><button class="btn primary" disabled>Finalize</button></div>`;
    $('#cgo').onclick = async () => {
      const f = $('#cf').files[0]; $('#ce').textContent = '';
      if (!f) return $('#ce').textContent = 'Pick the CSV file';
      const { rows, errors } = parseShowCSV(await f.text(), s.platform);
      if (errors.length) return $('#ce').innerHTML = esc(errors.slice(0, 8).join(' · ')) + (errors.length > 8 ? ` (+${errors.length - 8} more)` : '');
      if (!rows.length) return $('#ce').textContent = 'No orders in the file';
      $('#cgo').disabled = true; $('#cgo').textContent = 'Importing…';
      try {
        let path = null; try { path = await uploadShowFile(s.id, f); } catch (e) { if (!confirm(e.message + '\n\nImport anyway without keeping the original file?')) throw e; }
        const r = await rpc('tfd_show_import', { p_show: s.id, p_file_name: f.name, p_file_path: path, p_rows: rows });
        toast(`${r.matched} order(s) matched`); renderShows();
      } catch (e) { $('#ce').textContent = e.message; $('#cgo').disabled = false; $('#cgo').textContent = 'Import & match'; }
    };
    return;
  }
  const r = await rpc('tfd_show_review', { p_show: s.id });
  if (!r.import) { imp.innerHTML = ''; return; }
  const done = r.status === 'finalized', T = r.totals, os = r.orders;
  const attn = os.filter(o => o.state === 'needs_match' || (o.state === 'matched' && o.problem === 'before_scan' && !o.ack));
  const mins = o => o.placed_at && o.scanned_at ? Math.round((new Date(o.scanned_at) - new Date(o.placed_at)) / 60000) : null;
  let tab = attn.length && !done ? 'attn' : 'matched';
  imp.innerHTML = `<div class="panel"><div class="head"><div><h2 style="margin:0">Step 1 · CSV ${done ? '' : '<span class="tag ok">imported</span>'}</h2>
      <p class="muted small" style="margin:4px 0 0">${esc(r.import.file_name)} · ${T.rows} row(s) · by ${esc(r.import.by)} ${when(r.import.at)}</p></div>
      <div class="row">${r.import.file_path ? '<button class="btn sm" id="cof">Original file</button>' : ''}${done ? '' : '<button class="btn sm danger" id="crm">Remove CSV</button>'}</div></div>
    <div class="grid stats">
      <div class="panel"><div class="muted small">Matched</div><b class="big">${T.units}</b></div>
      <div class="panel"><div class="muted small">Need a match</div><b class="big" style="${T.needs_match ? 'color:var(--bad)' : ''}">${T.needs_match}</b></div>
      <div class="panel"><div class="muted small">Not this show</div><b class="big">${T.ignored}</b></div>
      <div class="panel"><div class="muted small">Failed / cancelled</div><b class="big">${T.failed}</b></div>
      <div class="panel"><div class="muted small">Pulls with no order</div><b class="big">${r.released.length}</b></div></div>
    <div class="seg" id="otab" style="margin:8px 0">${[['attn', `Needs attention (${attn.length})`], ['matched', `Matched (${T.units})`], ['floor', `Below floor (${T.below_floor})`], ['ignored', `Not this show (${T.ignored})`], ['failed', `Failed (${T.failed})`], ['released', `No order (${r.released.length})`]]
      .map(([k, l]) => `<button data-v="${k}">${l}</button>`).join('')}</div>
    <div id="olist" style="overflow-x:auto"></div></div>
  <div class="panel"><h2>Money ${done ? '<span class="tag ok">final</span>' : '<span class="muted small">(cost is an estimate until finalize)</span>'}</h2>
    <div class="grid stats">
      <div class="panel"><div class="muted small">Sales</div><b class="big">${money(T.sales_cents)}</b></div>
      <div class="panel"><div class="muted small">Platform fees</div><b class="big">${money(T.fees_cents)}</b><div class="muted small">${feeTxt(r.fees)}</div></div>
      <div class="panel"><div class="muted small">Commission</div><b class="big">${money(T.commission_cents)}</b><div class="muted small">${r.commission_bp / 100}% of sales after fees</div></div>
      <div class="panel"><div class="muted small">Cost of goods (FIFO)</div><b class="big">${money(T.cost_cents)}</b>${T.giveaway_cost_cents ? `<div class="muted small">+ ${money(T.giveaway_cost_cents)} giveaways</div>` : ''}</div>
      <div class="panel"><div class="muted small">Item profit</div><b class="big">${money(T.profit_cents)}</b><div class="muted small">before hourly pay</div></div></div>
    <h3>Pay</h3><div style="overflow-x:auto"><table><tr><th>Person</th><th>Role</th><th>Hours</th><th>Hourly</th><th>Hourly pay</th><th>Commission</th><th>Total</th></tr>
      ${r.pay.map(p => `<tr><td>${esc(p.name)}</td><td>${p.role}</td><td>${Number(p.hours).toFixed(2)}</td><td>${money(p.hourly_cents)}</td><td>${money(p.hourly_pay_cents)}</td>
        <td>${p.role === 'streamer' ? money(p.commission_cents) + ` <span class="muted small">(${p.commission_bp / 100}%)</span>` : '—'}</td><td><b>${money(p.hourly_pay_cents + p.commission_cents)}</b></td></tr>`).join('')}</table></div>
    ${r.hours_entered ? '' : '<p class="note warn small">No hours entered yet (Step 2), so hourly pay is $0.</p>'}</div>`;
  $('#otab').querySelectorAll('button').forEach(b => b.onclick = () => { tab = b.dataset.v; drawList(); });
  if ($('#cof')) $('#cof').onclick = () => openShowFile(r.import.file_path);
  if ($('#crm')) $('#crm').onclick = () => {
    const m = modal(`<h2>Remove the CSV?</h2><p>Undoes the import and every match fix. The show goes back to Concluded and pulls released for having no order are held again.</p>
      <label class="f">Reason<input id="xr" class="inp" placeholder="e.g. wrong file"></label><div class="err" id="xe"></div><div class="actions"><button class="btn danger" id="xy">Remove CSV</button></div>`);
    m.querySelector('#xy').onclick = async () => { try { await rpc('tfd_show_remove_csv', { p_show: s.id, p_reason: m.querySelector('#xr').value }); m.remove(); toast('CSV removed'); renderShows(); } catch (e) { m.querySelector('#xe').textContent = e.message; } };
  };
  const fix = async (id, action, extra) => { try { await rpc('tfd_order_resolve', { p_order: id, p_action: action, ...extra }); renderShows(); } catch (e) { toast(e.message, true); } };
  const pullOpts = r.open_pulls.map(p => `<option value="${p.id}">${p.kind === 'win' ? 'Win #' + p.pull_no : p.part === 0 ? 'Added #' + p.pull_no : `P${p.part} #${p.pull_no}`} · ${p.sku} ${esc(p.product || '')}${p.status === 'released' ? ' (released)' : ''}</option>`).join('');
  const orderRow = (o, mode) => {
    const head = `<td class="mono small">${esc(o.order_id || 'row ' + o.line)}</td><td class="small">${esc(o.product_name || '')}<div class="muted">${fileTxt(o)}</div></td><td class="small">${esc(o.buyer || '')}</td><td>${money(o.sale_cents)}</td>`;
    if (mode === 'attn') {
      if (o.state === 'matched') return `<tr>${head}<td colspan="2"><span class="tag off">${PROBLEM.before_scan}</span> <span class="small">${mins(o)} min before ${pullTxt(o)} (SKU ${o.sku}) was scanned</span></td>
        <td><div class="row"><button class="btn sm primary" data-ack="${o.id}">It's right</button><button class="btn sm" data-un="${o.id}">Unmatch</button></div></td></tr>`;
      return `<tr>${head}<td><span class="tag off">${PROBLEM[o.problem] || esc(o.problem || '')}</span></td>
        <td><div class="row"><select class="inp" data-ps="${o.id}" style="max-width:260px"><option value="">Match to a pull…</option>${pullOpts}</select>
          <input class="inp mono" data-sk="${o.id}" placeholder="or SKU" style="width:90px" inputmode="numeric"><button class="btn sm" data-sko="${o.id}">Use SKU</button></div></td>
        <td><button class="btn sm" data-ig="${o.id}">Not this show</button></td></tr>`;
    }
    if (mode === 'matched' || mode === 'floor') return `<tr class="${o.below_floor ? 'warnrow' : ''}">${head}<td>${pullTxt(o)} <span class="mono small">${o.sku}</span><div class="small">${esc(o.product || '')}${o.kind === 'giveaway' ? ' <span class="tag claude">Giveaway</span>' : ''}${o.how === 'manual' ? ' <span class="tag">by hand</span>' : ''}</div></td>
      <td class="small">${o.ship_cents != null ? money(o.ship_cents) : '—'}</td><td class="small">${money(o.fee_cents)}</td><td class="small">${money(o.commission_cents)}</td><td class="small">${money(o.cost_cents)}</td>
      <td><b style="${o.below_floor ? 'color:var(--bad)' : ''}">${money(o.profit_cents)}</b>${o.below_floor ? ' <span class="tag off">below floor</span>' : ''}</td>
      <td>${done ? '' : `<button class="btn sm" data-un="${o.id}">Unmatch</button>`}</td></tr>`;
    return `<tr>${head}<td class="small">${o.state === 'failed' ? esc(o.status) : (PROBLEM[o.problem] || '') + (o.note ? ': ' + esc(o.note) : '')}</td><td class="small">${o.placed_at ? when(o.placed_at) : ''}</td>
      <td>${o.state === 'ignored' && !done ? `<button class="btn sm" data-in="${o.id}">Include</button>` : ''}</td></tr>`;
  };
  const drawList = () => {
    $('#otab').querySelectorAll('button').forEach(b => b.classList.toggle('on', b.dataset.v === tab));
    const L = $('#olist');
    if (tab === 'released') { L.innerHTML = r.released.length ? `<p class="muted small">Scanned, but no paid order in the file: the sale didn't go through, so these units are available again.</p><table><tr><th>Pull</th><th>SKU</th><th>Product</th></tr>
      ${r.released.map(p => `<tr><td>${p.kind === 'win' ? 'Win #' : `P${p.part} #`}${p.pull_no}</td><td class="mono">${p.sku}</td><td>${esc(p.product || '')}</td></tr>`).join('')}</table>` : '<p class="muted">Every pull has an order.</p>'; return; }
    const list = tab === 'attn' ? attn : tab === 'matched' ? os.filter(o => o.state === 'matched') : tab === 'floor' ? os.filter(o => o.below_floor) : os.filter(o => o.state === tab);
    const hd = tab === 'attn' ? '<th>Order</th><th>Listing</th><th>Buyer</th><th>Price</th><th>Problem</th><th>Fix</th><th></th>'
      : tab === 'matched' || tab === 'floor' ? '<th>Order</th><th>Listing</th><th>Buyer</th><th>Price</th><th>Pull</th><th>Ship</th><th>Fee</th><th>Comm.</th><th>Cost</th><th>Profit</th><th></th>'
      : '<th>Order</th><th>Listing</th><th>Buyer</th><th>Price</th><th>Why</th><th>Placed</th><th></th>';
    L.innerHTML = list.length ? `<table><tr>${hd}</tr>${list.map(o => orderRow(o, tab)).join('')}</table>` : `<p class="muted">${tab === 'attn' ? 'Nothing needs attention.' : 'None.'}</p>`;
    L.querySelectorAll('[data-ack]').forEach(b => b.onclick = () => fix(Number(b.dataset.ack), 'ack'));
    L.querySelectorAll('[data-un]').forEach(b => b.onclick = () => fix(Number(b.dataset.un), 'unmatch'));
    L.querySelectorAll('[data-in]').forEach(b => b.onclick = () => fix(Number(b.dataset.in), 'include'));
    L.querySelectorAll('[data-ps]').forEach(sel => sel.onchange = () => { if (sel.value) fix(Number(sel.dataset.ps), 'pull', { p_pull: Number(sel.value) }); });
    L.querySelectorAll('[data-sko]').forEach(b => b.onclick = () => { const v = L.querySelector(`[data-sk="${b.dataset.sko}"]`).value.trim(); if (!/^\d{6}$/.test(v)) return toast('Enter a 6-digit SKU', true); fix(Number(b.dataset.sko), 'sku', { p_sku: v }); });
    L.querySelectorAll('[data-ig]').forEach(b => b.onclick = () => {
      const m = modal(`<h2>Not part of this show?</h2><p>The order is left out of this show's sales. Use this for an order from another show, or one that was refunded.</p>
        <label class="f">Reason<input id="ir" class="inp"></label><div class="err" id="ie"></div><div class="actions"><button class="btn primary" id="iy">Leave it out</button></div>`);
      m.querySelector('#iy').onclick = async () => { try { await rpc('tfd_order_resolve', { p_order: Number(b.dataset.ig), p_action: 'ignore', p_reason: m.querySelector('#ir').value }); m.remove(); renderShows(); } catch (e) { m.querySelector('#ie').textContent = e.message; } };
    });
  };
  drawList();

  // ---- Step 3
  const bl = r.blockers || [];
  fin.innerHTML = done ? `<div class="panel"><h2>Step 3 · Finalized <span class="tag ok">locked</span></h2>
      <p>Finalized by ${esc(r.finalized_by)} ${when(r.finalized_at)}. Fees, pay and pulls are locked and ${T.units} unit(s) came out of inventory.</p>
      <button class="btn danger" id="unf">Unfinalize</button></div>`
    : `<div class="panel"><h2>Step 3 · Finalize</h2>
      ${bl.length ? `<div class="note bad"><b>Fix these first:</b><ul style="margin:6px 0 0">${bl.map(b => `<li>${esc(b)}</li>`).join('')}</ul></div>` : '<p class="muted">Everything is matched.</p>'}
      ${T.below_floor ? `<p class="note warn small">${T.below_floor} sale(s) below floor (see the Below floor tab). Info only.</p>` : ''}
      <button class="btn primary" id="fz" ${bl.length ? 'disabled' : ''}>Finalize show</button></div>`;
  if ($('#fz')) $('#fz').onclick = () => {
    const payTot = r.pay.reduce((a, p) => a + p.hourly_pay_cents + p.commission_cents, 0);
    const m = modal(`<h2>Finalize ${esc(s.label)}?</h2><ul>
        <li><b>${T.units}</b> unit(s) come out of inventory (est. cost ${money((T.cost_cents || 0) + (T.giveaway_cost_cents || 0))}, oldest stock first).</li>
        <li>Fee locks at <b>${feeTxt(r.fees)}</b>. Later Settings changes never touch this show.</li>
        <li>Pay locks at <b>${money(payTot)}</b> (${r.pay.map(p => `${esc(p.name)} ${money(p.hourly_pay_cents + p.commission_cents)}`).join(', ')}).</li>
        <li>Sales ${money(T.sales_cents)}, item profit ${money(T.profit_cents)}.</li></ul>
      ${r.hours_entered ? '' : '<div class="note warn">No hours entered: hourly pay will be $0.</div>'}
      <p class="muted small">You can unfinalize later if something's wrong.</p><div class="err" id="fe"></div>
      <div class="actions"><button class="btn" data-close>Cancel</button><button class="btn primary" id="fy">Yes, finalize</button></div>`);
    m.querySelector('#fy').onclick = async () => { m.querySelector('#fy').disabled = true; try { await rpc('tfd_show_finalize', { p_show: s.id }); m.remove(); toast('Show finalized'); renderShows(); } catch (e) { m.querySelector('#fe').textContent = e.message; m.querySelector('#fy').disabled = false; } };
  };
  if ($('#unf')) $('#unf').onclick = () => {
    const m = modal(`<h2>Unfinalize ${esc(s.label)}?</h2><p>The ${T.units} unit(s) go back into inventory (to the same cost layers), and fees and pay are no longer locked. The show goes back to the review step.</p>
      <label class="f">Reason<input id="ur" class="inp" placeholder="e.g. wrong price on an order"></label><div class="err" id="ue"></div>
      <div class="actions"><button class="btn" data-close>Cancel</button><button class="btn danger" id="uy">Yes, unfinalize</button></div>`);
    m.querySelector('#uy').onclick = async () => { try { await rpc('tfd_show_unfinalize', { p_show: s.id, p_reason: m.querySelector('#ur').value }); m.remove(); toast('Unfinalized'); renderShows(); } catch (e) { m.querySelector('#ue').textContent = e.message; } };
  };
}
