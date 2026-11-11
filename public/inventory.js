'use strict';
// Inventory tab: Lots (receiving), Adjustments, Stock, Lists, Bins, Versions. Uses rpc/modal/toast/esc/money/when/CFG/token from app.js.

const INV = { sub: 'lots', fv: {} };
const INV_SUBS = [['lots', 'Lots'], ['adjustments', 'Adjustments'], ['stock', 'Stock'], ['lists', 'Lists'], ['bins', 'Bins'], ['versions', 'Versions']];
const REASONS_OUT = ['damaged', 'lost', 'theft', 'personal/sample', 'return to supplier', 'count correction'];
const dollarsIn = v => { const s = String(v ?? '').replace(/[$,\s]/g, ''); if (s === '') return null; const n = Number(s); if (!Number.isFinite(n) || n < 0) throw new Error('"' + v + '" isn\'t a dollar amount'); return Math.round(n * 100); };
const intIn = (v, label) => { const s = String(v ?? '').trim(); if (s === '') return null; const n = Number(s); if (!Number.isInteger(n) || n < 0) throw new Error(label + ' must be a whole number'); return n; };
const numIn = (v, label) => { const s = String(v ?? '').trim(); if (s === '') return null; const n = Number(s); if (!Number.isFinite(n) || n < 0) throw new Error(label + ' must be a number'); return s; };
const dl = c => c === null || c === undefined ? '' : (c / 100).toFixed(2);
const prodLabel = p => p.name || [p.brand, p.model].filter(Boolean).join(' ') || 'SKU ' + (p.sku || '');
const prodSub = p => [p.brand, p.model, p.color_code, p.lens_size].filter(Boolean).join(' · ');
const S_inv = {};

async function renderInventory() {
  let sub = location.hash.split('/')[1];
  if (sub === 'receiving') sub = 'lots';
  if (sub && INV_SUBS.find(s => s[0] === sub)) INV.sub = sub;
  INV.lot = INV.sub === 'lots' ? (Number(location.hash.split('/')[2]) || null) : null;
  $('#main').innerHTML = `<div class="head"><div><h1>Inventory</h1></div></div>
    <div class="row" style="margin-bottom:16px">${INV_SUBS.map(([k, l]) => `<a class="btn ${k === INV.sub ? 'primary' : ''}" href="#inventory/${k}">${l}</a>`).join('')}</div>
    <div id="inv"></div>`;
  const el = $('#inv');
  try {
    INV.fv = await rpc('tfd_field_values');
    await ({ lots: invLots, adjustments: invAdjust, stock: invStock, lists: invLists, bins: invBins, versions: invVersions })[INV.sub](el);
  } catch (e) { el.innerHTML = `<div class="note bad">${esc(e.message)}</div>`; }
}

// ================================================================ searchable dropdown (pick a past value, or + New)
const COMBO = { el: null, input: null, items: [], on: -1 };
function comboClose() { if (COMBO.el) COMBO.el.classList.add('hidden'); COMBO.input = null; }
function comboOpen(input) {
  if (!COMBO.el) { COMBO.el = document.createElement('div'); COMBO.el.id = 'combo'; document.body.appendChild(COMBO.el);
    COMBO.el.addEventListener('mousedown', e => { const d = e.target.closest('[data-i]'); if (!d) return; e.preventDefault(); comboPick(Number(d.dataset.i)); }); }
  COMBO.input = input;
  const key = input.dataset.combo, typed = input.value.trim(), lc = typed.toLowerCase();
  const all = INV.fv[key] || [];
  const hits = all.filter(v => !lc || String(v).toLowerCase().includes(lc)).slice(0, 60);
  const exact = all.some(v => String(v).toLowerCase() === lc);
  COMBO.items = hits.map(v => ({ v, label: esc(v) }));
  if (typed && !exact && (key === 'supplier' || key === 'brand')) COMBO.items.push({ v: typed, label: `+ New ${esc(key === 'bin' ? 'bin' : 'value')}: “${esc(typed)}”`, isNew: true });
  if (!COMBO.items.length) return comboClose();
  COMBO.on = -1;
  COMBO.el.innerHTML = COMBO.items.map((it, i) => `<div data-i="${i}" class="${it.isNew ? 'new' : ''}">${it.label}</div>`).join('');
  const r = input.getBoundingClientRect();
  Object.assign(COMBO.el.style, { left: r.left + 'px', top: (r.bottom + 2) + 'px', minWidth: Math.max(r.width, 180) + 'px' });
  COMBO.el.classList.remove('hidden');
}
function comboPick(i) {
  const it = COMBO.items[i], input = COMBO.input; if (!it || !input) return;
  input.value = it.v;
  const key = input.dataset.combo;
  if (it.isNew) { INV.fv[key] = [...(INV.fv[key] || []), it.v]; }
  comboClose();
  input.dispatchEvent(new Event('change', { bubbles: true }));
}
document.addEventListener('focusin', e => { if (e.target.matches && e.target.matches('input[data-combo]')) comboOpen(e.target); });
document.addEventListener('input', e => { if (e.target.matches && e.target.matches('input[data-combo]')) comboOpen(e.target); });
document.addEventListener('focusout', e => { if (e.target === COMBO.input) setTimeout(() => { if (document.activeElement !== COMBO.input) comboClose(); }, 120); });
document.addEventListener('scroll', () => comboClose(), true);
document.addEventListener('keydown', e => {
  if (!COMBO.input || e.target !== COMBO.input || COMBO.el.classList.contains('hidden')) return;
  const n = COMBO.items.length;
  if (e.key === 'ArrowDown' || e.key === 'ArrowUp') { e.preventDefault(); COMBO.on = (COMBO.on + (e.key === 'ArrowDown' ? 1 : -1) + n) % n;
    COMBO.el.querySelectorAll('[data-i]').forEach((d, i) => d.classList.toggle('on', i === COMBO.on)); COMBO.el.children[COMBO.on]?.scrollIntoView({ block: 'nearest' }); }
  else if (e.key === 'Enter' && COMBO.on >= 0) { e.preventDefault(); comboPick(COMBO.on); }
  else if (e.key === 'Escape') comboClose();
});
const comboInput = (id, key, val, extra = '') => `<input id="${id}" class="inp" data-combo="${key}" autocomplete="off" value="${esc(val ?? '')}" ${extra}>`;

// ================================================================ lot photos (private storage, admins only)
function shrinkImage(file, max = 1600) {
  return new Promise((res, rej) => {
    const img = new Image();
    img.onload = () => { const k = Math.min(1, max / Math.max(img.width, img.height)); const c = document.createElement('canvas');
      c.width = Math.round(img.width * k); c.height = Math.round(img.height * k); c.getContext('2d').drawImage(img, 0, 0, c.width, c.height);
      URL.revokeObjectURL(img.src); c.toBlob(b => b ? res(b) : rej(new Error('Could not read the photo')), 'image/jpeg', 0.85); };
    img.onerror = () => rej(new Error('Could not read "' + file.name + '" (use JPG or PNG)'));
    img.src = URL.createObjectURL(file);
  });
}
async function uploadLotPhoto(lotId, file, lineId) {
  const blob = await shrinkImage(file);
  const path = `lot-${lotId}/${Date.now()}-${Math.random().toString(36).slice(2, 8)}.jpg`;
  const t = await token();
  const r = await fetch(`${CFG.url}/storage/v1/object/lot-photos/${path}`, { method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t, 'Content-Type': 'image/jpeg' }, body: blob });
  if (!r.ok) throw new Error('Photo upload failed: ' + ((await r.json().catch(() => ({}))).message || r.status));
  await rpc('tfd_line_photo_add', { p_receipt_id: lotId, p_line_id: lineId, p_path: path });
}
async function signPhotos(paths) {
  if (!paths.length) return {};
  const t = await token();
  const r = await fetch(`${CFG.url}/storage/v1/object/sign/lot-photos`, { method: 'POST', headers: { apikey: CFG.anonKey, Authorization: 'Bearer ' + t, 'Content-Type': 'application/json' }, body: JSON.stringify({ expiresIn: 3600, paths }) });
  const d = await r.json().catch(() => []);
  const out = {}; (Array.isArray(d) ? d : []).forEach(x => { if (x.signedURL) out[x.path] = CFG.url + '/storage/v1' + x.signedURL; });
  return out;
}
// one cell per SKU row: thumbnails + add button. Internal only (not the listing image).
async function fillPhotoCells(root, r, reload) {
  const urls = await signPhotos(r.photos.map(p => p.path)).catch(() => ({}));
  const req = (r.required || []).includes('lot_photo');
  root.querySelectorAll('[data-phl]').forEach(td => {
    const lid = Number(td.dataset.phl), mine = r.photos.filter(p => p.line_id === lid);
    td.innerHTML = `<div class="phcell ${req && !mine.length && r.status === 'draft' ? 'bad' : ''}" title="${req && !mine.length ? 'Lot image is required' : 'Lot image: photo of the item / box (internal)'}">
      ${mine.map(p => `<img src="${esc(urls[p.path] || '')}" alt="Lot image" data-big="${esc(urls[p.path] || '')}" data-phid="${p.id}">`).join('')}
      <label class="phadd" title="Add lot image">+<input type="file" accept="image/*" multiple></label></div>`;
    td.querySelector('input').onchange = async e => {
      const files = [...e.target.files]; if (!files.length) return;
      toast(`Uploading ${files.length} image(s)…`);
      try { for (const f of files) await uploadLotPhoto(r.id, f, lid); toast('Lot image added'); reload(); } catch (err) { toast(err.message, true); }
    };
    td.querySelectorAll('[data-big]').forEach(i => i.onclick = () => {
      const m = modal(`<img src="${i.dataset.big}" alt="Lot image" style="width:100%;border-radius:8px"><div class="actions"><button class="btn danger" id="phdel">Remove this image</button></div>`);
      m.querySelector('.modal').style.maxWidth = '900px';
      m.querySelector('#phdel').onclick = async () => { try { await rpc('tfd_lot_photo_delete', { p_id: Number(i.dataset.phid) }); m.remove(); reload(); } catch (e) { toast(e.message, true); } };
    });
  });
}

// ================================================================ Lots
const TEMPLATE_COLS = ['Supplier', 'Invoice #', 'Date', 'Brand', 'Model #', 'Color Code', 'Lens Size', 'UPC', 'Product Name', 'Color Name',
  'Invoiced Qty', 'Received Qty', 'Unit Cost', 'Retail Price', 'Weight (oz)', 'Category', 'Subcategory', 'Specs', 'Image URL', 'Bin'];
const COL_KEYS = { 'supplier': 'supplier', 'invoice #': 'invoice_no', 'invoice': 'invoice_no', 'date': 'date', 'brand': 'brand', 'model #': 'model', 'model': 'model',
  'color code': 'color_code', 'lens size': 'lens_size', 'upc': 'upc', 'product name': 'name', 'color name': 'color_name', 'invoiced qty': 'invoiced_qty', 'quantity': 'invoiced_qty',
  'received qty': 'received_qty', 'unit cost': 'unit_cost', 'retail price': 'retail', 'weight (oz)': 'weight_oz', 'weight': 'weight_oz', 'category': 'category',
  'subcategory': 'subcategory', 'specs': 'specs', 'image url': 'image_url', 'bin': 'bin_code' };
function templateToLines(rows) {
  if (!rows.length) throw new Error('The file is empty');
  const map = rows[0].map(h => COL_KEYS[h.trim().toLowerCase()]);
  if (!map.some(Boolean)) throw new Error('No TFD template columns found. Download the template and convert the invoice into it.');
  const meta = {}, lines = [];
  rows.slice(1).forEach((r, i) => {
    const o = {}; map.forEach((k, j) => { if (k) o[k] = (r[j] ?? '').trim(); });
    if (o.supplier && !meta.supplier) meta.supplier = o.supplier;
    if (o.invoice_no && !meta.invoice_no) meta.invoice_no = o.invoice_no;
    if (o.date && !meta.date) meta.date = o.date;
    const { supplier, invoice_no, date, ...rest } = o;
    if (!Object.values(rest).some(Boolean)) return;
    try {
      lines.push({ brand: o.brand, model: o.model, color_code: o.color_code, lens_size: o.lens_size, upc: o.upc, name: o.name, color_name: o.color_name,
        invoiced_qty: intIn(o.invoiced_qty, 'Invoiced qty'), received_qty: intIn(o.received_qty, 'Received qty'), unit_cost_cents: dollarsIn(o.unit_cost),
        retail_cents: dollarsIn(o.retail), weight_oz: numIn(o.weight_oz, 'Weight'), category: o.category, subcategory: o.subcategory, specs: o.specs, image_url: o.image_url, bin_code: o.bin_code });
    } catch (e) { throw new Error('Row ' + (i + 2) + ': ' + e.message); }
  });
  return { meta, lines };
}

async function invLots(el) {
  if (INV.lot) return lotView(el, INV.lot);
  const rs = await rpc('tfd_receipts');
  const q = INV.lotQ = INV.lotQ || { q: '', supplier: '', invoice: '', from: '', to: '', skuMin: '', skuMax: '', costMin: '', costMax: '', status: '' };
  const suppliers = [...new Set(rs.map(r => r.supplier).filter(Boolean))].sort();
  el.innerHTML = `<div class="panel"><div class="head"><div><h2>Lots</h2><div class="muted small">Each inventory upload is a lot. Nothing changes stock until you confirm the count.</div></div><div class="row">
      <button class="btn" id="tpl">Download template</button><button class="btn primary" id="newr">New lot</button></div></div>
    <div class="row" style="margin-bottom:10px"><input id="lq" class="inp" style="flex:1;min-width:220px" placeholder="Search anything in a lot: name, supplier, invoice, brand, model, UPC, SKU…" value="${esc(q.q)}">
      <button class="btn" id="lfx">Clear filters</button></div>
    <div class="grid filters">
      <label class="f">Supplier<select id="lf_supplier" class="inp"><option value="">All</option>${suppliers.map(s => `<option ${s === q.supplier ? 'selected' : ''}>${esc(s)}</option>`).join('')}</select></label>
      <label class="f">Invoice #<input id="lf_invoice" class="inp" value="${esc(q.invoice)}"></label>
      <label class="f">Date from<input id="lf_from" type="date" class="inp" value="${esc(q.from)}"></label><label class="f">Date to<input id="lf_to" type="date" class="inp" value="${esc(q.to)}"></label>
      <label class="f">SKUs from<input id="lf_skuMin" type="number" min="0" class="inp" value="${esc(q.skuMin)}"></label><label class="f">SKUs to<input id="lf_skuMax" type="number" min="0" class="inp" value="${esc(q.skuMax)}"></label>
      <label class="f">Cost from ($)<input id="lf_costMin" type="number" min="0" step="0.01" class="inp" value="${esc(q.costMin)}"></label><label class="f">Cost to ($)<input id="lf_costMax" type="number" min="0" step="0.01" class="inp" value="${esc(q.costMax)}"></label>
      <label class="f">Status<select id="lf_status" class="inp">${[['', 'All'], ['draft', 'Draft'], ['confirmed', 'Confirmed'], ['undone', 'Undone']].map(([v, l]) => `<option value="${v}" ${v === q.status ? 'selected' : ''}>${l}</option>`).join('')}</select></label></div>
    <div style="overflow-x:auto"><table id="ltbl"></table></div></div>`;
  const draw = () => {
    const num = (v, f) => v === '' ? null : f(Number(v));
    const lc = q.q.trim().toLowerCase();
    const rows = rs.filter(r => (!lc || (r.search || '').toLowerCase().includes(lc)) && (!q.supplier || r.supplier === q.supplier)
      && (!q.invoice || (r.invoice_no || '').toLowerCase().includes(q.invoice.toLowerCase())) && (!q.from || r.received_date >= q.from) && (!q.to || r.received_date <= q.to)
      && (num(q.skuMin, x => r.skus >= x) ?? true) && (num(q.skuMax, x => r.skus <= x) ?? true)
      && (num(q.costMin, x => r.cost_cents >= x * 100) ?? true) && (num(q.costMax, x => r.cost_cents <= x * 100) ?? true) && (!q.status || r.status === q.status));
    $('#ltbl').innerHTML = `<tr><th>Lot name</th><th>Supplier</th><th>Invoice</th><th>Date</th><th>SKUs</th><th>Units</th><th>Cost</th><th>Photos</th><th>Status</th></tr>
      ${rows.map(r => `<tr data-r="${r.id}" class="click"><td><b>${esc(r.name)}</b></td><td>${esc(r.supplier || '—')}</td><td>${esc(r.invoice_no || '—')}</td><td style="white-space:nowrap">${esc(r.received_date)}</td>
        <td>${r.skus}</td><td>${r.units}</td><td class="mono">${money(r.cost_cents)}</td><td>${r.photos || ''}</td>
        <td>${r.status === 'draft' ? '<span class="tag">Draft</span>' : r.status === 'undone' ? '<span class="tag off">Undone</span>' : 'Confirmed'}${r.discrepancies ? ` <span class="tag off">${r.discrepancies} count diff</span>` : ''}</td></tr>`).join('')
        || `<tr><td colspan="9" class="muted">${rs.length ? 'No lots match.' : 'No lots yet. Click New lot.'}</td></tr>`}`;
    el.querySelectorAll('[data-r]').forEach(tr => tr.onclick = () => { location.hash = '#inventory/lots/' + tr.dataset.r; });
  };
  $('#lq').oninput = () => { q.q = $('#lq').value; draw(); };
  ['supplier', 'invoice', 'from', 'to', 'skuMin', 'skuMax', 'costMin', 'costMax', 'status'].forEach(k => { $('#lf_' + k).oninput = $('#lf_' + k).onchange = () => { q[k] = $('#lf_' + k).value; draw(); }; });
  $('#lfx').onclick = () => { INV.lotQ = null; invLots(el); };
  $('#tpl').onclick = () => downloadCSV('TFD Lot Template.csv', TEMPLATE_COLS, []);
  $('#newr').onclick = () => {
    const m = modal(`<h2>New lot</h2><div class="grid">
      <label class="f">Supplier${comboInput('rs', 'supplier', '')}</label>
      <label class="f">Invoice #<input id="ri" class="inp"></label>
      <label class="f">Date received<input id="rd" class="inp" type="date" value="${new Date().toLocaleDateString('en-CA')}"></label></div>
      <label class="f" style="margin-top:12px">TFD template CSV (leave empty to type the rows in yourself)<input id="rf" type="file" accept=".csv"></label>
      <p class="muted small">The lot is named Supplier · Invoice # · Date automatically. You can rename it.</p>
      <div class="err" id="re"></div><div class="actions"><button class="btn primary" id="rgo">Create lot</button></div>`);
    m.querySelector('#rgo').onclick = async () => {
      try {
        let lines = [], meta = {}, fname = null;
        const f = $('#rf').files[0];
        if (f) { ({ meta, lines } = templateToLines(parseCSV(await f.text()))); fname = f.name; }
        const id = await rpc('tfd_receipt_create', { p_supplier: $('#rs').value.trim() || meta.supplier || '', p_invoice_no: $('#ri').value.trim() || meta.invoice_no || '',
          p_date: $('#rd').value || meta.date || null, p_lines: lines.length ? lines : [{}], p_source_file: fname });
        m.remove(); location.hash = '#inventory/lots/' + id;
      } catch (e) { $('#re').textContent = e.message; }
    };
  };
  draw();
}

// [key, header, type, required-key, width]
const LOT_COLS = [
  ['brand', 'Brand', 'combo', 'brand', 130], ['model', 'Model #', 'combo', 'model', 120], ['color_code', 'Color code', 'combo', 'color_code', 100], ['lens_size', 'Lens size', 'combo', 'lens_size', 80],
  ['upc', 'UPC', 'text', 'upc', 140], ['name', 'Product name', 'combo', 'name', 210], ['color_name', 'Color name', 'combo', 'color_name', 130],
  ['invoiced_qty', 'Invoiced', 'int', 'invoiced_qty', 80], ['received_qty', 'Received', 'int', 'received_qty', 80], ['unit_cost_cents', 'Unit cost $', 'money', 'cost', 95],
  ['retail_cents', 'Retail $', 'money', 'retail', 95], ['weight_oz', 'Weight oz', 'num', 'weight', 85], ['category', 'Category', 'combo', 'category', 160],
  ['subcategory', 'Subcategory', 'combo', 'subcategory', 130], ['specs', 'Specs', 'combo', 'specs', 150], ['image_url', 'Listing image URL', 'text', 'image_url', 190],
  ['bin_code', 'Bin', 'combo', 'bin', 120]];
const comboKey = k => k === 'bin_code' ? 'bin' : k;
const cellShow = (c, v) => c[2] === 'money' ? dl(v) : (v ?? '');
function cellRead(c, raw) {
  if (c[2] === 'money') return dollarsIn(raw);
  if (c[2] === 'int') return intIn(raw, c[1]);
  if (c[2] === 'num') return numIn(raw, c[1]);
  const s = String(raw).trim(); return s === '' ? null : (c[0] === 'bin_code' ? s.toUpperCase() : s);
}
function lineFields(l) {
  const o = {}; LOT_COLS.forEach(([k]) => o[k] = l[k]);
  return { ...o, lists: l.lists || [], map_sku: l.map_sku, confirmed_new: l.confirmed_new, update_catalog: l.update_catalog };
}
const candText = c => `${esc(c.sku)} · ${esc(prodSub(c) || c.name || '')}${c.upc ? ' · UPC ' + esc(c.upc) : ''} · ${c.on_hand} on hand`;

async function lotView(el, id) {
  const [r, fv] = await Promise.all([rpc('tfd_receipt', { p_id: id }), rpc('tfd_field_values')]);
  INV.fv = fv;
  const draft = r.status === 'draft';
  const req = new Set(r.required || []); req.add('cost');
  el.innerHTML = `<div class="panel"><div class="head"><div style="flex:1;min-width:0"><a href="#inventory/lots" id="back" class="small">← All lots</a>
      <h2 style="margin-top:6px" id="lname">${esc(r.name)} ${draft ? '<span class="tag">Draft</span>' : r.status === 'undone' ? '<span class="tag off">Undone</span>' : '<span class="tag">Confirmed</span>'}</h2></div>
      <div class="row">${draft ? '<button class="btn danger" id="discard">Discard draft</button>' : '<button class="btn" id="labels">Print SKU labels</button>'}</div></div>
    <div class="grid">
      <label class="f">Lot name<input id="hn" class="inp" value="${esc(r.name)}"></label>
      <label class="f"><span>Supplier ${req.has('supplier') ? '<span class="req">*</span>' : ''}</span>${comboInput('hs', 'supplier', r.supplier, draft ? '' : 'disabled')}</label>
      <label class="f"><span>Invoice # ${req.has('invoice_no') ? '<span class="req">*</span>' : ''}</span><input id="hi" class="inp" value="${esc(r.invoice_no || '')}" ${draft ? '' : 'disabled'}></label>
      <label class="f"><span>Date received ${req.has('received_date') ? '<span class="req">*</span>' : ''}</span><input id="hd" class="inp" type="date" value="${esc(r.received_date)}" ${draft ? '' : 'disabled'}></label></div>
    <p class="muted small">${r.source_file ? `Imported from ${esc(r.source_file)} · ` : ''}Started by ${esc(r.created_by)}${r.confirmed_at ? ` · confirmed by ${esc(r.confirmed_by)} ${when(r.confirmed_at)}` : ''}</p></div>
    <div class="panel"><div class="head"><div><h2 style="margin:0">SKUs <span class="muted small">(${r.lines.length} row${r.lines.length === 1 ? '' : 's'})</span></h2>
        <div class="muted small">${draft ? 'Type straight into the grid. Scroll right for every field. <span class="req">*</span> = required. Red = needs fixing.' : 'Everything entered for this lot, as confirmed.'}</div></div>
      ${draft ? '<div class="row"><button class="btn hidden" id="matchall"></button><button class="btn" id="addl">Add row</button></div>' : ''}</div>
      <div class="lotwrap"><table class="lot" id="lgrid"></table></div>
      ${draft ? '<div id="issues"></div>' : ''}</div>`;
  const reload = () => lotView(el, id);
  let nameEdited = false;
  $('#hn').oninput = () => { nameEdited = true; };

  if (!draft) {
    $('#hn').onchange = async () => { try { const x = await rpc('tfd_lot_header', { p_id: id, p_supplier: r.supplier, p_invoice_no: r.invoice_no, p_date: r.received_date, p_name: $('#hn').value }); toast('Renamed'); $('#lname').firstChild.textContent = x.name + ' '; } catch (e) { toast(e.message, true); } };
    $('#labels').onclick = () => printLabels(r.lines.filter(l => l.result_sku).map(l => ({ sku: l.result_sku, name: l.name || `${l.brand || ''} ${l.model || ''}`, qty: l.received_qty })));
    $('#lgrid').innerHTML = `<tr><th class="stk0">#</th><th class="stk1">SKU</th>${LOT_COLS.map(c => `<th>${c[1]}</th>`).join('')}<th>Lot image</th></tr>
      ${r.lines.map(l => `<tr><td class="stk0">${l.line_no}</td><td class="stk1">${l.result_sku ? `<a href="#" data-sku="${l.result_sku}" class="mono"><b>${l.result_sku}</b></a>` : '<span class="muted small">no SKU (0 received)</span>'}
        ${l.received_qty !== null && l.invoiced_qty !== null && l.received_qty !== l.invoiced_qty ? `<div class="small" style="color:var(--bad)">${l.received_qty < l.invoiced_qty ? 'Short' : 'Over'} by ${Math.abs(l.received_qty - l.invoiced_qty)}</div>` : ''}</td>
        ${LOT_COLS.map(c => `<td class="ro">${esc(c[2] === 'money' ? (l[c[0]] === null ? '' : money(l[c[0]])) : (l[c[0]] ?? ''))}</td>`).join('')}<td data-phl="${l.id}"></td></tr>`).join('')}`;
    fillPhotoCells($('#lgrid'), r, reload);
    el.querySelectorAll('[data-sku]').forEach(a => a.onclick = e => { e.preventDefault(); skuDrawer(a.dataset.sku, reload); });
    return;
  }

  // ---- draft: editable grid
  const lines = r.lines;
  const saveHeader = async () => {
    try { const x = await rpc('tfd_lot_header', { p_id: id, p_supplier: $('#hs').value, p_invoice_no: $('#hi').value, p_date: $('#hd').value, p_name: nameEdited ? $('#hn').value : null });
      $('#hn').value = x.name; $('#lname').firstChild.textContent = x.name + ' '; nameEdited = false; refresh(); } catch (e) { toast(e.message, true); }
  };
  ['#hn', '#hs', '#hi', '#hd'].forEach(s => $(s).addEventListener('change', saveHeader));

  $('#lgrid').innerHTML = `<tr><th class="stk0">#</th><th class="stk1">Match</th>${LOT_COLS.map(c => `<th>${c[1]}${req.has(c[3]) ? ' <span class="req">*</span>' : ''}</th>`).join('')}<th>Lot image${req.has('lot_photo') ? ' <span class="req">*</span>' : ''}</th><th></th></tr>
    ${lines.map(l => `<tr data-lid="${l.id}"><td class="stk0">${l.line_no}</td><td class="stk1 mcell"></td>
      ${LOT_COLS.map(c => `<td><input class="cell" style="width:${c[4]}px" data-f="${c[0]}" ${c[2] === 'combo' ? `data-combo="${comboKey(c[0])}" autocomplete="off"` : ''}
        ${['int', 'num', 'money'].includes(c[2]) ? 'inputmode="decimal"' : ''} value="${esc(cellShow(c, l[c[0]]))}"></td>`).join('')}
      <td data-phl="${l.id}"></td><td><button class="btn sm danger" data-delrow="${l.id}" title="Delete row">×</button></td></tr>`).join('')}`;
  fillPhotoCells($('#lgrid'), r, reload);

  let chain = Promise.resolve();
  const refresh = async () => {
    const x = await rpc('tfd_receipt', { p_id: id });
    if (x.lines.length !== lines.length) return reload();
    x.lines.forEach(nl => { const i = lines.findIndex(l => l.id === nl.id); if (i >= 0) lines[i] = nl; });
    r.issues = x.issues; decorate();
  };
  const save = (line, patch) => {
    Object.assign(line, patch);
    chain = chain.then(() => rpc('tfd_receipt_line_save', { p_receipt_id: id, p_line_id: line.id, p_fields: lineFields(line) })).then(refresh).catch(e => toast(e.message, true));
    return chain;
  };
  const decorate = () => {
    lines.forEach(l => {
      const tr = el.querySelector(`tr[data-lid="${l.id}"]`); if (!tr) return;
      const c = l.check, p = c.product, bad = {}, rowMsgs = [];
      c.problems.forEach(pr => { if (pr.f && tr.querySelector(`[data-f="${pr.f}"]`)) (bad[pr.f] = bad[pr.f] || []).push(pr.m); else rowMsgs.push(pr.m); });
      const conf = Object.fromEntries((c.conflicts || []).map(x => [x.field, x]));
      tr.querySelectorAll('.cell').forEach(inp => {
        const f = inp.dataset.f, col = LOT_COLS.find(x => x[0] === f);
        inp.classList.toggle('bad', !!bad[f]); inp.classList.toggle('warn', !bad[f] && !!conf[f]);
        inp.title = bad[f] ? bad[f].join('\n') : conf[f] ? `Catalog has: ${conf[f].catalog}` : '';
        const catVal = p && f !== 'bin_code' ? cellShow(col, p[f]) : '';
        inp.placeholder = c.status === 'existing' && catVal !== '' ? String(catVal) : (f === 'bin_code' && c.status === 'new' && !req.has('bin') ? 'NOT_ASSIGNED' : '');
        if (f === 'bin_code') {
          const soldOut = c.status === 'existing' && p && p.on_hand === 0, lock = c.status === 'existing' && !soldOut;
          inp.disabled = lock;
          if (lock) { inp.value = ''; inp.placeholder = p?.bin || ''; inp.title = `SKU ${p?.sku} is in stock in bin ${p?.bin}. Move it from Bins if needed`; }
          else if (soldOut && !l.bin_code) { inp.placeholder = 'Pick bin'; inp.classList.add('bad'); inp.title = `SKU ${p.sku} is sold out (was in ${p.bin}). Pick the bin it goes in`; }
          else if (l.bin_code && !(INV.fv.bin || []).includes(l.bin_code)) { inp.classList.add('bad'); inp.title = `Bin "${l.bin_code}" doesn't exist. Pick a bin from the list`; } }
      });
      let h = '';
      if (c.status === 'existing') h = `<b class="mono">SKU ${p ? p.sku : l.map_sku}</b> <span class="tag">${l.map_sku ? 'Matched' : 'Same item'}</span>${l.map_sku ? ' <a href="#" data-act="unmatch" class="small">unmatch</a>' : ''}
        ${c.conflicts.length ? `<div class="small" style="color:var(--warn)">Differs from catalog: ${c.conflicts.map(x => esc(x.field.replace(/_cents|_oz/, '').replace(/_/g, ' '))).join(', ')}</div>
          <label class="small"><input type="checkbox" data-act="updcat" ${l.update_catalog ? 'checked' : ''}> Update the catalog with this row</label>` : ''}`;
      else if (c.status === 'new') h = `<span class="tag claude">NEW SKU</span>${l.confirmed_new ? ' <a href="#" data-act="unnew" class="small">undo</a>' : ''}`;
      else h = c.candidates.map(x => `<div class="cand"><button class="btn sm primary" data-act="match" data-sku="${x.sku}">Match ${x.sku}</button> <span class="small"><b>${esc(x.reason)}</b>: ${candText(x)}</span></div>`).join('')
        + (c.status === 'suggest' ? '<button class="btn sm" data-act="new">It\'s a new SKU</button>' : '');
      if (rowMsgs.length) h += `<div class="small" style="color:var(--bad)">${rowMsgs.map(esc).join('<br>')}</div>`;
      tr.querySelector('.mcell').innerHTML = h;
    });
    const ups = lines.filter(l => l.check.status === 'suggest' && l.check.candidates[0]?.reason === 'Same UPC').length;
    const ma = $('#matchall'); ma.classList.toggle('hidden', !ups); ma.textContent = `Match all by UPC (${ups})`;
    const units = lines.reduce((a, l) => a + (l.received_qty ?? l.invoiced_qty ?? 0), 0), cost = lines.reduce((a, l) => a + (l.received_qty ?? l.invoiced_qty ?? 0) * (l.unit_cost_cents || 0), 0);
    const n = r.issues.length;
    $('#issues').innerHTML = `<div class="actions" style="justify-content:space-between;align-items:flex-start"><div><b>${units}</b> units · <b>${money(cost)}</b> at cost
        ${n ? `<div class="note bad" style="margin-top:10px"><b>Can't confirm yet. ${n} thing${n === 1 ? '' : 's'} to fix:</b><ul style="margin:6px 0 0 18px;padding:0">${r.issues.map(x => `<li>${esc(x)}</li>`).join('')}</ul></div>` : ''}</div>
      <button class="btn primary" id="confirm" ${n ? 'disabled' : ''}>${n ? `Confirm count (${n} left)` : 'Confirm count'}</button></div>`;
    $('#confirm').onclick = confirmLot;
  };
  const grid = $('#lgrid');
  grid.addEventListener('change', e => {
    const inp = e.target; if (!inp.classList.contains('cell')) return;
    const l = lines.find(x => x.id === Number(inp.closest('tr').dataset.lid)), col = LOT_COLS.find(c => c[0] === inp.dataset.f);
    let v; try { v = cellRead(col, inp.value); } catch (err) { inp.classList.add('bad'); inp.title = err.message; return toast(err.message, true); }
    if (v === (l[col[0]] ?? null) || (col[2] === 'num' && Number(v) === Number(l[col[0]]) && v !== null)) return;
    save(l, { [col[0]]: v });
  });
  grid.addEventListener('click', e => {
    const a = e.target.closest('[data-act]'), del = e.target.closest('[data-delrow]');
    if (del) { const l = lines.find(x => x.id === Number(del.dataset.delrow));
      if (!confirm(`Delete row ${l.line_no}?`)) return;
      return chain = chain.then(() => rpc('tfd_receipt_line_delete', { p_receipt_id: id, p_line_id: l.id })).then(reload).catch(err => toast(err.message, true)); }
    if (!a) return;
    if (a.tagName === 'A') e.preventDefault();
    const l = lines.find(x => x.id === Number(a.closest('tr').dataset.lid));
    ({ match: () => save(l, { map_sku: a.dataset.sku, confirmed_new: false }), new: () => save(l, { confirmed_new: true, map_sku: null }),
      unmatch: () => save(l, { map_sku: null }), unnew: () => save(l, { confirmed_new: false }), updcat: () => save(l, { update_catalog: a.checked }) })[a.dataset.act]();
  });
  $('#addl').onclick = () => { chain = chain.then(() => rpc('tfd_receipt_line_save', { p_receipt_id: id, p_line_id: null, p_fields: {} })).then(reload).catch(err => toast(err.message, true)); };
  $('#matchall').onclick = () => { chain = chain.then(() => rpc('tfd_lot_match_all', { p_id: id })).then(x => { toast(`Matched ${x.matched} row(s)`); return reload(); }).catch(err => toast(err.message, true)); };
  $('#discard').onclick = () => {
    const m = modal(`<h2>Discard this draft?</h2><p>Lot "${esc(r.name)}" and its ${lines.length} row(s) will be deleted. Stock was never changed. (It stays restorable from Versions.)</p><div class="actions"><button class="btn danger" id="dy">Discard</button></div>`);
    m.querySelector('#dy').onclick = async () => { try { await rpc('tfd_receipt_discard', { p_id: id }); m.remove(); location.hash = '#inventory/lots'; } catch (e) { toast(e.message, true); } };
  };
  const confirmLot = async () => {
    await chain;
    const units = lines.reduce((a, l) => a + (l.received_qty ?? l.invoiced_qty ?? 0), 0), cost = lines.reduce((a, l) => a + (l.received_qty ?? l.invoiced_qty ?? 0) * (l.unit_cost_cents || 0), 0);
    const newN = lines.filter(l => l.check.status === 'new' && (l.received_qty ?? l.invoiced_qty ?? 0) > 0).length;
    const short = lines.filter(l => l.received_qty !== null && l.invoiced_qty !== null && l.received_qty !== l.invoiced_qty);
    const unbinned = lines.filter(l => l.check.status === 'new' && !l.bin_code).length;
    const m = modal(`<h2>Confirm count</h2><p>Adds <b>${units}</b> units (<b>${money(cost)}</b> at cost) to stock${newN ? ` and creates <b>${newN}</b> new SKU(s)` : ''}.</p>
      ${unbinned ? `<div class="note warn">${unbinned} new SKU(s) have no bin and will go to <b>NOT_ASSIGNED</b>.</div>` : ''}
      ${short.length ? `<div class="note warn">${short.length} row(s) differ from the invoice. They'll be flagged for a supplier claim.</div>` : ''}
      <div class="err" id="ce" style="white-space:pre-line"></div><div class="actions"><button class="btn primary" id="cy">Confirm count</button></div>`);
    m.querySelector('#cy').onclick = async () => {
      try { const res = await rpc('tfd_receipt_confirm', { p_id: id }); m.remove(); toast(`Added ${res.units} units · ${res.new_skus} new SKU(s)`); reload(); }
      catch (e) { m.querySelector('#ce').textContent = e.message; }
    };
  };
  decorate();
}

// ================================================================ Adjustments
async function invAdjust(el) {
  const [stock, act] = await Promise.all([rpc('tfd_stock'), rpc('tfd_activity', { p_filters: { tab: 'Inventory' } })]);
  const recent = act.rows.filter(r => r.action === 'adjust_out' || r.action === 'adjust_in').slice(0, 25);
  const A = INV.adj = INV.adj || { q: '', sku: '', sel: null };
  el.innerHTML = `<div class="panel"><h2>Find the product</h2>
      <div class="grid"><label class="f">SKU<input id="as" class="inp mono" inputmode="numeric" placeholder="6 digits" value="${esc(A.sku)}"></label>
        <label class="f" style="grid-column:span 2">Search anything (name, brand, model, color, size, UPC, bin…)<input id="aq" class="inp" placeholder="e.g. 01, aviator, RB3025, A4" value="${esc(A.q)}"></label></div>
      <div id="ares" style="margin-top:10px;max-height:320px;overflow:auto"></div></div>
    <div class="panel" id="apanel"></div>
    <div class="panel"><h2>Customer returns</h2><p class="muted">Returns are entered by order number, so they arrive with Shows, once orders exist in the app.</p></div>
    <div class="panel"><h2>Recent adjustments</h2><table><tr><th>When</th><th>Who</th><th>What</th></tr>
      ${recent.map(r => `<tr><td class="small" style="white-space:nowrap">${when(r.at)}</td><td>${esc(r.actor)}</td><td><span style="color:var(--${r.action === 'adjust_out' ? 'bad' : 'ok'})">${esc(r.summary)}</span>${r.reason ? `<div class="muted small">${esc(r.reason)}</div>` : ''}${r.undone_by ? ' <span class="tag off">Undone</span>' : ''}</td></tr>`).join('') || '<tr><td colspan="3" class="muted">None yet.</td></tr>'}
    </table><p class="muted small">To undo one, use the Activity Log or Versions.</p></div>`;
  const hay = s => [s.sku, s.name, s.brand, s.model, s.color_code, s.color_name, s.lens_size, s.upc, s.category, s.subcategory, s.specs, s.bin, ...(s.lots || [])].filter(Boolean).join(' ').toLowerCase();
  const results = () => {
    const sk = A.sku.trim(), lc = A.q.trim().toLowerCase();
    if (!sk && !lc) { $('#ares').innerHTML = '<p class="muted small">Type a SKU, or search by anything about the product.</p>'; return; }
    const rows = stock.filter(s => (!sk || s.sku.includes(sk)) && (!lc || hay(s).includes(lc))).slice(0, 100);
    if (sk.length === 6 && rows.length === 1 && A.sel !== rows[0].sku) { A.sel = rows[0].sku; panel(); }
    $('#ares').innerHTML = `<table><tr><th>SKU</th><th>Product</th><th>UPC</th><th>Bin</th><th>On hand</th></tr>
      ${rows.map(s => `<tr data-pick="${s.sku}" class="click ${s.sku === A.sel ? 'sel' : ''}"><td class="mono">${s.sku}</td><td><b>${esc(prodLabel(s))}</b><div class="muted small">${esc(prodSub(s))}${s.color_name ? ' · ' + esc(s.color_name) : ''}</div></td>
        <td class="small mono">${esc(s.upc || '')}</td><td>${esc(s.bin || '')}</td><td>${s.on_hand}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">Nothing matches.</td></tr>'}</table>`;
    el.querySelectorAll('[data-pick]').forEach(tr => tr.onclick = () => { A.sel = tr.dataset.pick; results(); panel(); });
  };
  const panel = () => {
    const s = stock.find(x => x.sku === A.sel);
    const last = INV.lastAdj ? `<div class="banner ${INV.lastAdj.dir}">${esc(INV.lastAdj.text)}</div>` : '';
    if (INV.lastAdj && !INV.lastAdj.timer) INV.lastAdj.timer = setTimeout(() => { INV.lastAdj = null; document.querySelector('#apanel .banner')?.remove(); }, 10000);
    if (!s) { $('#apanel').innerHTML = `${last}<h2>Adjust stock</h2><p class="muted">Pick a product above.</p>`; return; }
    $('#apanel').innerHTML = `${last}<h2>Adjust stock</h2>
      <div class="note"><b class="mono">${s.sku}</b> · <b>${esc(prodLabel(s))}</b> · ${esc(prodSub(s))} · bin ${esc(s.bin || '—')} · <b>${s.on_hand}</b> on hand</div>
      <div class="grid"><label class="f">Change<select id="ad" class="inp"><option value="out">Remove units</option><option value="in">Add units</option></select></label>
        <label class="f">Quantity<input id="aqty" class="inp" type="number" min="1" value="1"></label>
        <label class="f">Reason<select id="ar" class="inp">${REASONS_OUT.map(r => `<option>${r}</option>`).join('')}</select></label>
        <label class="f">Note (optional)<input id="an" class="inp"></label></div>
      <div class="err" id="ae"></div><div class="actions"><button class="btn primary" id="ago">Save adjustment</button></div>
      <p class="muted small">Removals take the oldest cost first (FIFO). Additions come in at the most recent cost.</p>`;
    $('#ad').onchange = () => { $('#ar').innerHTML = ($('#ad').value === 'out' ? REASONS_OUT : ['count correction', 'found']).map(r => `<option>${r}</option>`).join(''); };
    const go = async confirm => {
      try {
        const dir = $('#ad').value, qty = intIn($('#aqty').value, 'Quantity');
        const r = await rpc('tfd_adjust', { p_sku: s.sku, p_direction: dir, p_qty: qty, p_reason: $('#ar').value, p_note: $('#an').value, p_confirm: confirm });
        if (r.needs_confirm) { const m = modal(`<h2>Large adjustment</h2><p>${esc(r.message)}</p><div class="actions"><button class="btn primary" id="cy">Confirm</button></div>`); m.querySelector('#cy').onclick = () => { m.remove(); go(true); }; return; }
        INV.lastAdj = { dir, text: `${dir === 'out' ? 'Removed' : 'Added'} ${qty} × SKU ${s.sku} (${prodLabel(s)}) · ${$('#ar').value} · ${money(r.value_cents)} at cost · now ${r.on_hand} on hand` };
        invAdjust(el);
      } catch (e) { $('#ae').textContent = e.message; }
    };
    $('#ago').onclick = () => go(false);
  };
  $('#as').oninput = () => { A.sku = $('#as').value.replace(/\D/g, ''); results(); };
  $('#aq').oninput = () => { A.q = $('#aq').value; results(); };
  results(); panel();
}

// ================================================================ Stock
async function invStock(el) {
  const [stock, lists] = await Promise.all([rpc('tfd_stock'), rpc('tfd_lists')]);
  INV.stockQ = INV.stockQ || { q: '', brand: '', bin: '', sort: 'sku', dir: 1, show: 'in' };
  const q = INV.stockQ;
  const brands = [...new Set(stock.map(s => s.brand).filter(Boolean))].sort(), bins = [...new Set(stock.map(s => s.bin).filter(Boolean))].sort();
  const low = stock.filter(s => s.on_hand > 0 && s.on_hand <= s.low_stock_effective && !s.low_dismissed), out = stock.filter(s => s.on_hand === 0 && !s.out_dismissed);
  const totals = stock.reduce((a, s) => ({ units: a.units + s.on_hand, value: a.value + s.value_cents }), { units: 0, value: 0 });
  const cols = [['sku', 'SKU'], ['name', 'Product'], ['upc', 'UPC'], ['bin', 'Bin'], ['on_hand', 'On hand'], ['held', 'Held'], ['sold_not_packed', 'Sold, not packed'], ['available', 'Available'],
    ['floor_tiktok', 'Floor (TikTok)'], ['floor_whatnot', 'Floor (Whatnot)'], ['value_cents', 'Value at cost'], ['last_received', 'Last received'], ['sold_30', 'Sold 30d']];
  const hay = s => [s.sku, s.name, s.brand, s.model, s.color_code, s.color_name, s.lens_size, s.upc, s.category, s.subcategory, s.specs, s.bin, ...(s.lots || []), ...(s.suppliers || [])].filter(Boolean).join(' ').toLowerCase();
  const draw = () => {
    let rows = stock.filter(s => (q.show === 'all' || (q.show === 'in' ? s.on_hand > 0 : s.on_hand === 0)) && (!q.brand || s.brand === q.brand) && (!q.bin || s.bin === q.bin) && (!q.q || hay(s).includes(q.q.toLowerCase())));
    rows.sort((a, b) => { const x = a[q.sort], y = b[q.sort]; return (x === y ? 0 : x === null || x === undefined ? 1 : y === null || y === undefined ? -1 : x > y ? 1 : -1) * q.dir; });
    $('#stbl').innerHTML = `<tr>${cols.map(([k, l]) => `<th data-sort="${k}" style="cursor:pointer;white-space:nowrap">${l}${q.sort === k ? (q.dir > 0 ? ' ↑' : ' ↓') : ''}</th>`).join('')}</tr>
      ${rows.map(s => `<tr data-sku="${s.sku}" class="click"><td class="mono">${s.sku}</td>
        <td><div class="row" style="flex-wrap:nowrap">${s.image_url ? `<img src="${esc(s.image_url)}" alt="" style="width:36px;height:36px;object-fit:cover;border-radius:6px">` : ''}
          <div><b>${esc(prodLabel(s))}</b><div class="muted small">${esc(prodSub(s))}${s.color_name ? ' · ' + esc(s.color_name) : ''}</div></div></div></td>
        <td class="small mono">${esc(s.upc || '')}</td><td>${s.bin === 'NOT_ASSIGNED' ? '<span class="tag off">NOT_ASSIGNED</span>' : esc(s.bin || '—')}</td><td>${s.on_hand}</td><td>${s.held}</td><td>${s.sold_not_packed}</td>
        <td>${s.available}${s.available > 0 && s.available <= s.low_stock_effective ? ' <span class="tag off">Low</span>' : ''}</td>
        <td class="mono">${s.floor_tiktok === null ? '—' : money(s.floor_tiktok)}</td><td class="mono">${s.floor_whatnot === null ? '<span class="muted">not set</span>' : money(s.floor_whatnot)}</td>
        <td class="mono">${money(s.value_cents)}</td><td class="small">${esc(s.last_received || '—')}</td><td>${s.sold_30}</td></tr>`).join('') || `<tr><td colspan="${cols.length}" class="muted">Nothing matches.</td></tr>`}`;
    el.querySelectorAll('[data-sort]').forEach(th => th.onclick = () => { if (q.sort === th.dataset.sort) q.dir *= -1; else { q.sort = th.dataset.sort; q.dir = 1; } draw(); });
    el.querySelectorAll('[data-sku]').forEach(tr => tr.onclick = () => skuDrawer(tr.dataset.sku, () => invStock(el)));
  };
  const chip = (s, kind) => `<span class="chip">${s.sku} ${esc(prodLabel(s))}${kind === 'low' ? ` (${s.on_hand} left)` : ''}<button class="dismiss" data-dis="${s.sku}" data-kind="${kind}" title="Dismiss until stock changes">×</button></span>`;
  el.innerHTML = `${low.length || out.length ? `<div class="panel"><h2>Alerts</h2>
      ${low.length ? `<div class="note warn"><b>Low stock:</b> ${low.map(s => chip(s, 'low')).join(' ')}</div>` : ''}
      ${out.length ? `<div class="note bad"><b>Out of stock:</b> ${out.map(s => chip(s, 'out')).join(' ')}</div>` : ''}
      <p class="muted small">× dismisses an alert until that SKU's stock changes again.</p></div>` : ''}
    <div class="panel"><div class="head"><div><h2>Stock</h2><div class="muted small">${stock.length} SKUs · ${totals.units} units · ${money(totals.value)} at cost · click a row to see or edit everything</div></div>
      <div class="row"><select id="exl" class="inp"><option value="">Full inventory</option>${lists.map(l => `<option value="${l.id}">${esc(l.name)}</option>`).join('')}</select>
      <button class="btn" id="exw">Export for Whatnot</button></div></div>
      <div class="row" style="margin-bottom:12px"><div class="seg" id="sshow">${[['in', `In stock (${stock.filter(s => s.on_hand > 0).length})`], ['out', `Out of stock (${stock.filter(s => s.on_hand === 0).length})`], ['all', 'All']].map(([k, l]) => `<button data-show="${k}" class="${q.show === k ? 'on' : ''}">${l}</button>`).join('')}</div>
        <input id="sq" class="inp" placeholder="Search anything: SKU, name, model, color, size, UPC, bin, lot…" style="flex:1;min-width:200px" value="${esc(q.q)}">
        <select id="sb" class="inp"><option value="">All brands</option>${brands.map(b => `<option ${b === q.brand ? 'selected' : ''}>${esc(b)}</option>`).join('')}</select>
        <select id="sbin" class="inp"><option value="">All bins</option>${bins.map(b => `<option ${b === q.bin ? 'selected' : ''}>${esc(b)}</option>`).join('')}</select></div>
      <div style="overflow-x:auto"><table id="stbl"></table></div>
      <p class="muted small">Floors use the highest unit cost in stock and round up to a whole dollar. Held and sold-not-packed fill in once Shows are built.</p></div>`;
  $('#sq').oninput = () => { q.q = $('#sq').value; draw(); };
  el.querySelectorAll('[data-show]').forEach(b => b.onclick = () => { q.show = b.dataset.show; el.querySelectorAll('[data-show]').forEach(x => x.classList.toggle('on', x === b)); draw(); });
  $('#sb').onchange = () => { q.brand = $('#sb').value; draw(); };
  $('#sbin').onchange = () => { q.bin = $('#sbin').value; draw(); };
  $('#exw').onclick = () => whatnotExport($('#exl').value ? Number($('#exl').value) : null);
  el.querySelectorAll('[data-dis]').forEach(b => b.onclick = async () => { try { await rpc('tfd_alert_dismiss', { p_sku: b.dataset.dis, p_kind: b.dataset.kind }); invStock(el); } catch (e) { toast(e.message, true); } });
  draw();
}

async function skuDrawer(sku, done) {
  const h = await rpc('tfd_sku_history', { p_sku: sku });
  const p = h.product;
  const KIND = { receipt: 'Received', adjust_out: 'Removed', adjust_in: 'Added', bin_move: 'Bin move', verify: 'Bin verify', receipt_undo: 'Lot undone', adjust_undo: 'Adjustment undone' };
  const txt = (id, label, val, extra = '') => `<label class="f">${label}<input id="${id}" class="inp" value="${esc(val ?? '')}" ${extra}></label>`;
  const cmb = (id, label, key, val) => `<label class="f">${label}${comboInput(id, key, val)}</label>`;
  const m = modal(`<h2>SKU ${p.sku}</h2><p class="muted">${esc(prodSub(p))} · <b>${p.on_hand}</b> on hand</p>
    ${p.image_url ? `<img src="${esc(p.image_url)}" alt="" style="max-width:160px;border-radius:8px">` : ''}
    <h3>Product</h3><div class="grid">${cmb('pb', 'Brand', 'brand', p.brand)}${cmb('pm', 'Model #', 'model', p.model)}${cmb('pcc', 'Color code', 'color_code', p.color_code)}${cmb('pls', 'Lens size', 'lens_size', p.lens_size)}
      ${txt('pu', 'UPC', p.upc)}${cmb('pn', 'Product name', 'name', p.name)}${cmb('pcn', 'Color name', 'color_name', p.color_name)}${txt('pr', 'Retail price ($)', dl(p.retail_cents), 'inputmode="decimal"')}
      ${txt('pw', 'Weight (oz)', p.weight_oz, 'inputmode="decimal"')}${cmb('pc', 'Category', 'category', p.category)}${cmb('ps', 'Subcategory', 'subcategory', p.subcategory)}${cmb('psp', 'Specs', 'specs', p.specs)}
      ${txt('pi', 'Listing image URL', p.image_url)}${txt('pl', 'Low-stock alert at (blank = default)', p.low_stock, 'type="number" min="0"')}</div>
    <p class="muted small">Brand + model + color + size can't match another SKU, and a UPC can only be on one SKU.</p>
    <div class="err" id="pe"></div><div class="actions"><button class="btn" id="plab">Print label</button><button class="btn primary" id="psave">Save changes</button></div>
    <h3>Bin</h3><div class="row">${comboInput('pbin', 'bin', p.bin)}<button class="btn" id="pmove">Move all ${p.on_hand} units here</button></div>
    <h3>Cost layers (FIFO)</h3><table><tr><th>Received</th><th>Unit cost</th><th>In</th><th>Left</th></tr>
      ${h.layers.map(c => `<tr><td class="small">${when(c.created_at)}${c.receipt ? ' · lot #' + c.receipt : ' · count up'}</td><td class="mono">${money(c.unit_cost_cents)}</td><td>${c.qty_in}</td><td>${c.qty_remaining}</td></tr>`).join('')}</table>
    <h3>History</h3><table><tr><th>When</th><th>What</th><th>Qty</th><th>Who</th></tr>
      ${h.moves.map(x => `<tr><td class="small">${when(x.at)}</td><td>${KIND[x.kind] || esc(x.kind)}${x.reason ? ` <span class="muted small">(${esc(x.reason)})</span>` : ''}${x.detail && x.detail.to ? ` <span class="muted small">${esc(x.detail.from || '')} → ${esc(x.detail.to)}</span>` : ''}${x.receipt_id ? ` <span class="muted small">lot #${x.receipt_id}</span>` : ''}</td>
        <td>${x.qty > 0 ? '+' : ''}${x.qty || ''}</td><td>${esc(x.actor)}</td></tr>`).join('')}</table>`);
  m.querySelector('.modal').style.maxWidth = '820px';
  const close = () => { m.remove(); done(); };
  m.querySelector('#plab').onclick = () => printLabels([{ sku: p.sku, name: prodLabel(p), qty: 1 }]);
  m.querySelector('#pmove').onclick = async () => { try { const r = await rpc('tfd_move_sku', { p_sku: sku, p_bin: $('#pbin').value }); toast(r.unchanged ? 'Already in that bin' : 'Moved'); close(); } catch (e) { m.querySelector('#pe').textContent = e.message; } };
  m.querySelector('#psave').onclick = async () => {
    try {
      const r = await rpc('tfd_product_update', { p_sku: sku, p_fields: { brand: $('#pb').value, model: $('#pm').value, color_code: $('#pcc').value, lens_size: $('#pls').value, upc: $('#pu').value,
        name: $('#pn').value, color_name: $('#pcn').value, retail_cents: dollarsIn($('#pr').value), weight_oz: numIn($('#pw').value, 'Weight'), category: $('#pc').value,
        subcategory: $('#ps').value, specs: $('#psp').value, image_url: $('#pi').value, low_stock: intIn($('#pl').value, 'Low-stock alert') } });
      toast(r.unchanged ? 'No changes' : 'Saved'); close();
    } catch (e) { m.querySelector('#pe').textContent = e.message; }
  };
}

// ================================================================ Bins
async function invBins(el) {
  const bins = await rpc('tfd_bins');
  INV.binQ = INV.binQ || ''; INV.binShow = INV.binShow || 'all';
  el.innerHTML = `<div class="panel"><div class="head"><div><h2>Bins</h2><p class="muted small">One bin per SKU, each SKU in its own labeled bag. Click a bin to see what's in it and its history.</p></div>
      <div class="row"><button class="btn" id="mv">Move SKU</button><button class="btn primary" id="nb">New bin</button></div></div>
    <div class="row" style="margin-bottom:12px"><div class="seg">${[['all', `All (${bins.length})`], ['used', `With stock (${bins.filter(b => b.skus.length).length})`], ['empty', `Empty (${bins.filter(b => !b.skus.length).length})`]].map(([k, l]) => `<button data-bshow="${k}" class="${INV.binShow === k ? 'on' : ''}">${l}</button>`).join('')}</div>
      <input id="bq" class="inp" style="flex:1;min-width:200px" placeholder="Search bins: bin code, or a SKU / product inside" value="${esc(INV.binQ)}"></div>
    <div class="grid" id="bgrid"></div></div>`;
  const draw = () => {
    const lc = INV.binQ.trim().toLowerCase();
    const rows = bins.filter(b => (INV.binShow === 'all' || (INV.binShow === 'empty' ? !b.skus.length : b.skus.length || b.code === 'NOT_ASSIGNED')) && (!lc || b.code.toLowerCase().includes(lc) || b.skus.some(s => [s.sku, s.name, s.brand, s.model, s.color_code, s.color_name, s.lens_size, s.upc].filter(Boolean).join(' ').toLowerCase().includes(lc))));
    $('#bgrid').innerHTML = rows.map(b => `<div class="panel bincard ${b.code === 'NOT_ASSIGNED' && b.skus.length ? 'warnc' : ''} ${b.skus.length ? '' : 'empty'}" data-bin="${esc(b.code)}" style="margin:0">
        <div class="head" style="margin-bottom:6px"><h2 style="margin:0">${esc(b.code)}</h2><span class="muted small">${b.skus.length} SKU${b.skus.length === 1 ? '' : 's'} · ${b.skus.reduce((a, s) => a + s.on_hand, 0)} units</span></div>
        ${b.note ? `<div class="muted small">${esc(b.note)}</div>` : ''}
        ${b.skus.slice(0, 6).map(s => `<div class="small" style="padding:3px 0;border-bottom:1px solid var(--line)"><span class="mono">${s.sku}</span> · ${esc(prodLabel(s))} <b style="float:right">${s.on_hand}</b></div>`).join('') || '<div class="muted small">Empty</div>'}
        ${b.skus.length > 6 ? `<div class="muted small">+${b.skus.length - 6} more</div>` : ''}</div>`).join('') || '<p class="muted">No bins match.</p>';
    el.querySelectorAll('[data-bin]').forEach(c => c.onclick = () => binModal(c.dataset.bin, () => invBins(el)));
  };
  $('#bq').oninput = () => { INV.binQ = $('#bq').value; draw(); };
  el.querySelectorAll('[data-bshow]').forEach(b => b.onclick = () => { INV.binShow = b.dataset.bshow; el.querySelectorAll('[data-bshow]').forEach(x => x.classList.toggle('on', x === b)); draw(); });
  $('#nb').onclick = () => {
    const m = modal(`<h2>New bin</h2><div class="grid"><label class="f">Code (e.g. A4)<input id="bc" class="inp"></label><label class="f">Note (optional)<input id="bn" class="inp"></label></div>
      <div class="err" id="be"></div><div class="actions"><button class="btn primary" id="bs">Create</button></div>`);
    m.querySelector('#bs').onclick = async () => { try { await rpc('tfd_bin_create', { p_code: $('#bc').value, p_note: $('#bn').value }); m.remove(); invBins(el); } catch (e) { m.querySelector('#be').textContent = e.message; } };
  };
  $('#mv').onclick = () => moveModal(null, () => invBins(el));
  draw();
}
function moveModal(sku, done) {
  const m = modal(`<h2>Move SKU</h2><p class="muted small">Moves all units of the SKU. There's no partial move.</p>
    <div class="grid"><label class="f">SKU<input id="ms" class="inp mono" value="${esc(sku || '')}"></label><label class="f">To bin${comboInput('mb', 'bin', '')}</label></div>
    <div class="err" id="me"></div><div class="actions"><button class="btn primary" id="mgo">Move</button></div>`);
  m.querySelector('#mgo').onclick = async () => { try { await rpc('tfd_move_sku', { p_sku: $('#ms').value.trim(), p_bin: $('#mb').value }); m.remove(); toast('Moved'); done(); } catch (e) { m.querySelector('#me').textContent = e.message; } };
}
async function binModal(code, done) {
  const b = await rpc('tfd_bin_detail', { p_code: code });
  const KIND = { bin_move: 'Moved', receipt: 'Arrived', verify: 'Verified' };
  const m = modal(`<h2>Bin ${esc(b.code)}</h2>${b.note ? `<p class="muted">${esc(b.note)}</p>` : ''}
    <div class="head"><h3 style="margin:0">In this bin now</h3><div class="row"><button class="btn" id="bmv">Move a SKU in</button><button class="btn primary" id="bver" ${b.skus.length ? '' : 'disabled'}>Verify counts</button></div></div>
    <table><tr><th>SKU</th><th>Product</th><th>UPC</th><th>On hand</th></tr>${b.skus.map(s => `<tr data-sku="${s.sku}" class="click"><td class="mono">${s.sku}</td><td><b>${esc(prodLabel(s))}</b><div class="muted small">${esc(prodSub(s))}</div></td><td class="small mono">${esc(s.upc || '')}</td><td>${s.on_hand}</td></tr>`).join('') || '<tr><td colspan="4" class="muted">Empty</td></tr>'}</table>
    <h3>History</h3><p class="muted small">Includes SKUs that sold out of this bin.</p><table><tr><th>When</th><th>What</th><th>SKU</th><th>Who</th></tr>
    ${b.history.map(x => `<tr><td class="small" style="white-space:nowrap">${when(x.at)}</td><td>${x.kind === 'bin_move' ? (x.to === b.code ? `Moved in from ${esc(x.from || 'no bin')}` : `Moved out to ${esc(x.to)}`) : x.kind === 'receipt' ? `Arrived (${x.qty} units, lot)` : x.kind === 'verify' ? 'Count verified' : x.kind === 'adjust_out' ? `Removed ${-x.qty} (${esc(x.reason || '')})` : x.kind === 'adjust_in' ? `Added ${x.qty} (${esc(x.reason || '')})` : esc(KIND[x.kind] || x.kind)}</td>
      <td><span class="mono">${x.sku}</span> <span class="small">${esc(x.name || '')}</span></td><td>${esc(x.actor)}</td></tr>`).join('') || '<tr><td colspan="4" class="muted">No history yet.</td></tr>'}</table>`);
  m.querySelector('.modal').style.maxWidth = '780px';
  m.querySelectorAll('[data-sku]').forEach(tr => tr.onclick = () => { m.remove(); skuDrawer(tr.dataset.sku, done); });
  m.querySelector('#bmv').onclick = () => { m.remove(); moveModal(null, done); setTimeout(() => { const i = document.querySelector('#mb'); if (i) i.value = b.code; }, 0); };
  m.querySelector('#bver').onclick = () => { m.remove(); verifyModal(b, done); };
}
function verifyModal(b, done) {
  const m = modal(`<h2>Verify bin ${esc(b.code)}</h2><p class="muted small">Count each bag and enter what's really there.</p>
    ${b.skus.map(s => `<div class="toggle"><span><span class="mono">${s.sku}</span> · ${esc(prodLabel(s))}</span><input class="inp" style="width:80px" type="number" min="0" data-cnt="${s.sku}"></div>`).join('')}
    <div id="vd"></div><div class="err" id="ve"></div><div class="actions"><button class="btn primary" id="vgo">Check counts</button></div>`);
  const counts = () => { const o = {}; m.querySelectorAll('[data-cnt]').forEach(i => { if (i.value === '') throw new Error('Enter a count for every SKU'); o[i.dataset.cnt] = intIn(i.value, 'Count'); }); return o; };
  m.querySelector('#vgo').onclick = async () => {
    try {
      const c = counts();
      const r = await rpc('tfd_bin_verify', { p_bin: b.code, p_counts: c, p_confirm: false });
      if (!r.differences.length) { await rpc('tfd_bin_verify', { p_bin: b.code, p_counts: c, p_confirm: true }); m.remove(); toast('All counts match. Verified.'); return done(); }
      $('#vd').innerHTML = `<div class="note warn">Differences:<br>${r.differences.map(d => `${d.sku}: app says ${d.on_hand}, counted ${d.counted} (${d.diff > 0 ? '+' : ''}${d.diff})`).join('<br>')}<br>Confirming records these as count corrections.</div>`;
      const btn2 = m.querySelector('#vgo'); btn2.textContent = 'Confirm corrections';
      btn2.onclick = async () => { try { await rpc('tfd_bin_verify', { p_bin: b.code, p_counts: counts(), p_confirm: true }); m.remove(); toast('Corrected'); done(); } catch (e) { $('#ve').textContent = e.message; } };
    } catch (e) { $('#ve').textContent = e.message; }
  };
}

// ================================================================ Versions (inventory safety net)
async function invVersions(el) {
  const raw = await rpc('tfd_versions', { p_limit: 500 });
  const vs = [];   // fold runs of draft-grid edits into one row (restoring lands after the newest edit in the run)
  raw.forEach(v => { const prev = vs[vs.length - 1];
    if (prev && prev.summary.startsWith('Lot draft edited') && v.summary === 'Lot draft edited') { prev.n = (prev.n || 1) + 1; prev.changes += v.changes; prev.at = v.at; prev.summary = `Lot draft edited (${prev.n} edits)`; }
    else vs.push({ ...v }); });
  el.innerHTML = `<div class="panel"><h2>Versions</h2>
    <p class="muted small">Every inventory action saves a version automatically. If something goes wrong (a bad lot, a wrong adjustment, a mass mistake), restore inventory to how it was right after any earlier action.
      Everything after that point is reversed. A restore is itself a version, so it can be reversed too. Lot photo files are never deleted.</p>
    <div style="overflow-x:auto"><table><tr><th>When</th><th>Who</th><th>What happened</th><th>Changes</th><th></th></tr>
    ${vs.map((v, i) => `<tr><td class="small" style="white-space:nowrap">${when(v.at)}</td><td>${v.actor === 'Claude' ? '<span class="tag claude">Claude</span>' : esc(v.actor || '')}</td>
      <td>${v.restore ? '<span class="tag">Restore</span> ' : ''}${esc(v.summary)}</td><td>${v.changes}</td>
      <td>${i === 0 ? '<span class="tag">Current</span>' : `<button class="btn" style="white-space:nowrap" data-v="${i}">Restore to here</button>`}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">No versions yet. They start with the next inventory action.</td></tr>'}
    </table></div></div>`;
  el.querySelectorAll('[data-v]').forEach(b => b.onclick = () => {
    const i = Number(b.dataset.v), v = vs[i];
    const m = modal(`<h2>Restore inventory?</h2>
      <p>Inventory goes back to exactly how it was right after:<br><b>${esc(v.summary)}</b> <span class="muted small">(${when(v.at)}, ${esc(v.actor || '')})</span></p>
      <div class="note warn">Every later version shown above it will be reversed: stock, SKUs, lots, bins, lists and alerts. Nothing is deleted from history, and you can reverse this restore from this same page.</div>
      <label class="f">Reason<input id="vr" class="inp"></label><label class="f" style="margin-top:10px">Type RESTORE to confirm<input id="vc" class="inp" autocomplete="off"></label>
      <div class="err" id="ve"></div><div class="actions"><button class="btn danger" id="vgo">Restore</button></div>`);
    m.querySelector('#vgo').onclick = async () => {
      try { const r = await rpc('tfd_version_restore', { p_tx: v.tx, p_reason: $('#vr').value, p_confirm: $('#vc').value.trim() }); m.remove(); toast(`Restored. ${r.actions} action(s) reversed.`); invVersions(el); }
      catch (e) { m.querySelector('#ve').textContent = e.message; }
    };
  });
}

// ================================================================ CSV helpers
function parseCSV(text) {
  const rows = []; let row = [], f = '', q = false;
  text = text.replace(/^﻿/, '');
  for (let i = 0; i < text.length; i++) {
    const c = text[i];
    if (q) { if (c === '"') { if (text[i + 1] === '"') { f += '"'; i++; } else q = false; } else f += c; }
    else if (c === '"') q = true;
    else if (c === ',') { row.push(f); f = ''; }
    else if (c === '\n' || c === '\r') { if (c === '\r' && text[i + 1] === '\n') i++; row.push(f); f = ''; if (row.some(x => x.trim() !== '')) rows.push(row); row = []; }
    else f += c;
  }
  row.push(f); if (row.some(x => x.trim() !== '')) rows.push(row);
  return rows;
}
const csvCell = v => { const s = v === null || v === undefined ? '' : String(v); return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s; };
function downloadCSV(name, header, rows) {
  const text = [header, ...rows].map(r => r.map(csvCell).join(',')).join('\r\n');
  const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob([text], { type: 'text/csv' })); a.download = name; a.click();
  setTimeout(() => URL.revokeObjectURL(a.href), 2000);
}

async function whatnotExport(listId, preloaded) {
  const d = preloaded || await rpc('tfd_whatnot_export', { p_list_id: listId });
  const w = d.settings;
  const blank = [['type', 'Type'], ['shipping_profile', 'Shipping Profile'], ['offerable', 'Offerable'], ['hazmat', 'Hazmat'], ['condition', 'Condition']].filter(([k]) => !w[k]);
  const noFloor = w.price_source === 'floor' && d.rows.some(r => r.floor_whatnot === null);
  const go = async () => {
    const header = ['Category', 'Sub Category', 'Title', 'Description', 'Quantity', 'Type', 'Price', 'Shipping Profile', 'Offerable', 'Hazmat', 'Condition', 'Cost Per Item', 'SKU',
      'Image URL 1', 'Image URL 2', 'Image URL 3', 'Image URL 4', 'Image URL 5', 'Image URL 6', 'Image URL 7', 'Image URL 8'];
    const rows = d.rows.map(r => [r.category || w.category, r.subcategory || w.subcategory, r.name || `${r.brand} ${r.model}`,
      [r.brand, r.model, r.color_name || r.color_code, r.lens_size ? r.lens_size + 'mm' : '', r.specs].filter(Boolean).join(' · '),
      r.qty, w.type, dl(w.price_source === 'floor' ? r.floor_whatnot : r.retail_cents), w.shipping_profile, w.offerable, w.hazmat, w.condition,
      dl(r.cost_cents), r.sku, r.image_url || '', '', '', '', '', '', '', '']);
    downloadCSV(`Whatnot upload - ${d.list} - ${new Date().toLocaleDateString('en-CA')}.csv`, header, rows);
    await rpc('tfd_export_logged', { p_what: 'Whatnot upload: ' + d.list, p_rows: rows.length }).catch(() => {});
  };
  if (!d.rows.length) return toast('Nothing in stock to export for ' + d.list, true);
  if (blank.length || noFloor) {
    const m = modal(`<h2>Before you export</h2>
      ${blank.length ? `<div class="note warn">These Whatnot columns are blank: <b>${blank.map(b => b[1]).join(', ')}</b>. Fill them in Settings → Whatnot export, or Whatnot may reject the file.</div>` : ''}
      ${noFloor ? '<div class="note warn">Price is set to "floor" but Whatnot fees aren\'t set, so some prices would be blank.</div>' : ''}
      <p>${d.rows.length} SKU(s) from ${esc(d.list)}.</p><div class="actions"><a class="btn" href="#settings/whatnot">Go to Settings</a><button class="btn primary" id="xg">Export anyway</button></div>`);
    m.querySelector('#xg').onclick = () => { m.remove(); go(); };
  } else go();
}

// ================================================================ Lists
async function invLists(el) {
  const [lists, stock] = await Promise.all([rpc('tfd_lists'), rpc('tfd_stock')]);
  el.innerHTML = `<div class="panel"><div class="head"><div><h2>Lists</h2><p class="muted small">Saved views of your stock. A SKU in two lists shares one count. Deleting a list never touches stock.</p></div>
      <button class="btn primary" id="nl">New list</button></div>
    <table><tr><th>Name</th><th>Type</th><th>SKUs</th><th>Units</th><th></th></tr>
    ${lists.map(l => `<tr><td><b>${esc(l.name)}</b>${l.pct ? ` <span class="tag">${l.pct}% of stock</span>` : ''}</td><td>${l.kind === 'manual' ? 'Hand-picked' : 'Rule'}</td><td>${l.count}</td><td>${l.units}</td>
      <td class="row"><button class="btn" data-ex="${l.id}">Export for Whatnot</button><button class="btn" data-ed="${l.id}">Edit</button></td></tr>`).join('') || '<tr><td colspan="5" class="muted">No lists yet.</td></tr>'}</table></div>`;
  $('#nl').onclick = () => listModal(null, stock, () => invLists(el));
  el.querySelectorAll('[data-ed]').forEach(b => b.onclick = () => listModal(lists.find(l => l.id === Number(b.dataset.ed)), stock, () => invLists(el)));
  el.querySelectorAll('[data-ex]').forEach(b => b.onclick = () => whatnotExport(Number(b.dataset.ex)));
}

function listModal(l, stock, done) {
  const v = l || { name: '', kind: 'rule', rule: {}, pct: null, skus: [] };
  const brands = INV.fv.brand || [];
  const ru = v.rule || {};
  const csv = a => (a || []).join(', ');
  const m = modal(`<h2>${l ? 'Edit list' : 'New list'}</h2>
    <div class="grid"><label class="f">Name<input id="ln_" class="inp" value="${esc(v.name)}"></label>
      <label class="f">Type<select id="lk" class="inp"><option value="rule" ${v.kind === 'rule' ? 'selected' : ''}>Rule (updates itself)</option><option value="manual" ${v.kind === 'manual' ? 'selected' : ''}>Hand-picked SKUs</option></select></label>
      <label class="f">% of each SKU's units (blank = all)<input id="lp" class="inp" type="number" min="1" max="100" value="${v.pct ?? ''}"></label></div>
    <div id="lrule"><h3>Rule</h3><p class="muted small">Leave a field blank to include everything. Lists of values are comma-separated.</p>
      <div class="row">${brands.map(b => `<label class="small"><input type="checkbox" data-br="${esc(b)}" ${(ru.brands || []).some(x => x.toLowerCase() === b.toLowerCase()) ? 'checked' : ''}> ${esc(b)}</label>`).join('') || '<span class="muted small">Brands show up here once you receive them in a lot.</span>'}</div>
      <div class="grid" style="margin-top:10px">
        <label class="f">Categories<input id="rc" class="inp" value="${esc(csv(ru.categories))}"></label><label class="f">Subcategories<input id="rsc" class="inp" value="${esc(csv(ru.subcategories))}"></label>
        <label class="f">Suppliers<input id="rsu" class="inp" value="${esc(csv(ru.suppliers))}"></label><label class="f">Lot #s<input id="rre" class="inp" value="${esc(csv(ru.receipts))}"></label>
        <label class="f">Retail from ($)<input id="rr1" class="inp" type="number" step="0.01" value="${dl(ru.retail_min)}"></label><label class="f">Retail to ($)<input id="rr2" class="inp" type="number" step="0.01" value="${dl(ru.retail_max)}"></label>
        <label class="f">On hand at least<input id="rq1" class="inp" type="number" min="0" value="${ru.qty_min ?? ''}"></label><label class="f">On hand at most<input id="rq2" class="inp" type="number" min="0" value="${ru.qty_max ?? ''}"></label></div></div>
    <div id="lman"><h3>SKUs</h3><textarea id="lsk" class="inp" rows="5" style="width:100%" placeholder="One SKU per line, or comma-separated">${esc((v.skus || []).join('\n'))}</textarea>
      <p class="muted small">${stock.length} SKUs in stock. </p></div>
    <div class="err" id="lerr"></div><div class="actions">${l ? '<button class="btn danger" id="ldel">Delete list</button>' : ''}<button class="btn primary" id="lsv">Save list</button></div>`);
  const sync = () => { const r = $('#lk').value === 'rule'; $('#lrule').classList.toggle('hidden', !r); $('#lman').classList.toggle('hidden', r); };
  $('#lk').onchange = sync; sync();
  const split = s => s.split(/[,\n]/).map(x => x.trim()).filter(Boolean);
  m.querySelector('#lsv').onclick = async () => {
    try {
      const kind = $('#lk').value;
      const rule = kind === 'rule' ? Object.fromEntries(Object.entries({
        brands: [...m.querySelectorAll('[data-br]')].filter(x => x.checked).map(x => x.dataset.br), categories: split($('#rc').value), subcategories: split($('#rsc').value),
        suppliers: split($('#rsu').value), receipts: split($('#rre').value), retail_min: dollarsIn($('#rr1').value), retail_max: dollarsIn($('#rr2').value),
        qty_min: intIn($('#rq1').value, 'On hand at least'), qty_max: intIn($('#rq2').value, 'On hand at most') }).filter(([, x]) => x !== null && !(Array.isArray(x) && !x.length))) : {};
      await rpc('tfd_list_save', { p_id: l ? l.id : null, p_name: $('#ln_').value, p_kind: kind, p_rule: rule, p_pct: intIn($('#lp').value, '%'), p_skus: kind === 'manual' ? split($('#lsk').value) : [] });
      m.remove(); toast('Saved'); done();
    } catch (e) { m.querySelector('#lerr').textContent = e.message; }
  };
  if (l) m.querySelector('#ldel').onclick = async () => { if (!confirm('Delete list "' + l.name + '"? Stock is not touched.')) return; try { await rpc('tfd_list_delete', { p_id: l.id }); m.remove(); done(); } catch (e) { toast(e.message, true); } };
}

// ================================================================ Labels (Code 128)
const C128 = ['212222','222122','222221','121223','121322','131222','122213','122312','132212','221213','221312','231212','112232','122132','122231','113222','123122','123221','223211','221132','221231','213212','223112','312131','311222','321122','321221','312212','322112','322211','212123','212321','232121','111323','131123','131321','112313','132113','132311','211313','231113','231311','112133','112331','132131','113123','113321','133121','313121','211331','231131','213113','213311','213131','311123','311321','331121','312113','312311','332111','314111','221411','431111','111224','111422','121124','121421','141122','141221','112214','112412','122114','122411','142112','142211','241211','221114','413111','241112','134111','111242','121142','121241','114212','124112','124211','411212','421112','421211','212141','214121','412121','111143','111341','131141','114113','114311','411113','411311','113141','114131','311141','411131','211412','211214','211232','2331112'];
function code128svg(text, h = 50) {
  const codes = [104]; for (const ch of text) codes.push(ch.charCodeAt(0) - 32);
  codes.push(codes.reduce((a, c, i) => a + c * (i || 1), 0) % 103, 106);
  let x = 10, bars = '';
  for (const c of codes) [...C128[c]].forEach((w, i) => { w = Number(w) * 2; if (i % 2 === 0) bars += `<rect x="${x}" y="0" width="${w}" height="${h}"/>`; x += w; });
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${x + 10}" height="${h}" viewBox="0 0 ${x + 10} ${h}">${bars}</svg>`;
}
function printLabels(items) {
  const labels = items;   // one label per SKU: it goes on the SKU's bag in its bin
  const w = window.open('', '_blank');
  if (!w) return toast('Allow pop-ups to print labels', true);
  w.document.write(`<!doctype html><title>SKU labels</title><style>body{font-family:-apple-system,Arial,sans-serif;margin:16px}.l{display:inline-block;border:1px dashed #bbb;padding:10px 12px;margin:6px;text-align:center;width:240px}
    .s{font:600 18px monospace;margin-top:4px}.n{font-size:11px;color:#333;margin-top:2px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}@media print{.l{border:0}}</style>
    ${labels.map(it => `<div class="l">${code128svg(it.sku)}<div class="s">${esc(it.sku)}</div><div class="n">${esc(it.name || '')}</div></div>`).join('')}
    <script>setTimeout(()=>print(),300)<\/script>`);
  w.document.close();
}
