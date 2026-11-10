'use strict';
// Inventory tab (Phase 2): Receiving, Adjustments, Stock, Lists, Bins. Uses rpc/modal/toast/esc/money from app.js.

const INV = { sub: 'receiving' };
const INV_SUBS = [['receiving', 'Receiving'], ['adjustments', 'Adjustments'], ['stock', 'Stock'], ['lists', 'Lists'], ['bins', 'Bins']];
const REASONS_OUT = ['damaged', 'lost', 'theft', 'personal/sample', 'return to supplier', 'count correction'];
const dollarsIn = v => { const s = String(v ?? '').replace(/[$,\s]/g, ''); if (s === '') return null; const n = Number(s); if (!Number.isFinite(n) || n < 0) throw new Error('"' + v + '" isn\'t a dollar amount'); return Math.round(n * 100); };
const intIn = (v, label) => { const s = String(v ?? '').trim(); if (s === '') return null; const n = Number(s); if (!Number.isInteger(n) || n < 0) throw new Error(label + ' must be a whole number'); return n; };
const dl = c => c === null || c === undefined ? '' : (c / 100).toFixed(2);

async function renderInventory() {
  const sub = location.hash.split('/')[1];
  if (sub && INV_SUBS.find(s => s[0] === sub)) INV.sub = sub;
  if (INV.sub !== 'receiving') INV.receipt = null;
  S_inv.settings = (await rpc('tfd_settings')).settings;
  $('#main').innerHTML = `<div class="head"><div><h1>Inventory</h1></div></div>
    <div class="row" style="margin-bottom:16px">${INV_SUBS.map(([k, l]) => `<a class="btn ${k === INV.sub ? 'primary' : ''}" href="#inventory/${k}" style="text-decoration:none">${l}</a>`).join('')}</div>
    <div id="inv"></div>`;
  const el = $('#inv');
  try { await ({ receiving: invReceiving, adjustments: invAdjust, stock: invStock, lists: invLists, bins: invBins })[INV.sub](el); }
  catch (e) { el.innerHTML = `<div class="note bad">${esc(e.message)}</div>`; }
}

// ================================================================ Receiving
const TEMPLATE_COLS = ['Supplier', 'Invoice #', 'Date', 'Brand', 'Model #', 'Color Code', 'Lens Size', 'Quantity', 'Unit Cost',
  'Product Name', 'Color Name', 'Retail Price', 'Category', 'Subcategory', 'Weight (oz)', 'UPC', 'Image URL', 'Bin'];
const COL_KEYS = { 'brand': 'brand', 'model #': 'model', 'model': 'model', 'color code': 'color_code', 'lens size': 'lens_size', 'quantity': 'invoiced_qty',
  'unit cost': 'unit_cost', 'product name': 'name', 'color name': 'color_name', 'retail price': 'retail', 'category': 'category', 'subcategory': 'subcategory',
  'weight (oz)': 'weight_oz', 'weight': 'weight_oz', 'upc': 'upc', 'image url': 'image_url', 'bin': 'bin_code', 'supplier': 'supplier', 'invoice #': 'invoice_no', 'date': 'date' };

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

function templateToLines(rows) {
  if (!rows.length) throw new Error('The file is empty');
  const head = rows[0].map(h => h.trim().toLowerCase());
  const map = head.map(h => COL_KEYS[h]);
  const missing = ['brand', 'model', 'color_code', 'lens_size', 'invoiced_qty', 'unit_cost'].filter(k => !map.includes(k));
  if (missing.length) throw new Error('This isn\'t the TFD receiving template. Missing columns: ' + missing.join(', ') + '. Download the template and convert the invoice into it.');
  const meta = {}; const lines = [];
  rows.slice(1).forEach((r, i) => {
    const o = {}; map.forEach((k, j) => { if (k) o[k] = (r[j] ?? '').trim(); });
    if (o.supplier && !meta.supplier) meta.supplier = o.supplier;
    if (o.invoice_no && !meta.invoice_no) meta.invoice_no = o.invoice_no;
    if (o.date && !meta.date) meta.date = o.date;
    if (!['brand', 'model', 'color_code', 'lens_size', 'invoiced_qty', 'unit_cost'].some(k => o[k])) return;
    try {
      lines.push({ brand: o.brand, model: o.model, color_code: o.color_code, lens_size: o.lens_size, invoiced_qty: intIn(o.invoiced_qty, 'Quantity') ?? 0,
        unit_cost_cents: dollarsIn(o.unit_cost), name: o.name, color_name: o.color_name, retail_cents: dollarsIn(o.retail), category: o.category,
        subcategory: o.subcategory, weight_oz: o.weight_oz || null, upc: o.upc, image_url: o.image_url, bin_code: o.bin_code });
    } catch (e) { throw new Error('Row ' + (i + 2) + ': ' + e.message); }
  });
  return { meta, lines };
}

async function invReceiving(el) {
  if (INV.receipt) return receiptEditor(el, INV.receipt);
  const rs = await rpc('tfd_receipts');
  el.innerHTML = `<div class="panel"><div class="head"><h2>Receipts</h2><div class="row">
      <button class="btn" id="tpl">Download template</button><button class="btn primary" id="newr">New receipt</button></div></div>
    <table><tr><th>#</th><th>Supplier</th><th>Invoice</th><th>Date</th><th>Lines</th><th>Units</th><th>Cost</th><th>Status</th></tr>
    ${rs.map(r => `<tr data-r="${r.id}" style="cursor:pointer"><td>${r.id}</td><td>${esc(r.supplier)}</td><td>${esc(r.invoice_no || '—')}</td><td>${esc(r.received_date)}</td>
      <td>${r.lines}</td><td>${r.units}</td><td class="mono">${money(r.cost_cents)}</td>
      <td>${r.status === 'draft' ? '<span class="tag">Draft</span>' : r.status === 'undone' ? '<span class="tag off">Undone</span>' : 'Confirmed'}${r.discrepancies ? ` <span class="tag off">${r.discrepancies} count diff</span>` : ''}</td></tr>`).join('')
      || '<tr><td colspan="8" class="muted">No receipts yet. Click New receipt.</td></tr>'}</table>
    <p class="muted small">Every import uses the TFD receiving template. Convert any supplier invoice into it first (an AI can do this), then import. Nothing changes stock until you click Confirm count.</p></div>`;
  $('#tpl').onclick = () => downloadCSV('TFD Receiving Template.csv', TEMPLATE_COLS, [['Designer Eyes', 'INV-1001', '2026-11-10', 'Ray-Ban', 'RB3025', '001', '58', '10', '50.00', 'Ray-Ban Aviator Classic Gold', 'Gold / Green', '163.00', 'Bags & Accessories', 'Sunglasses', '1.5', '', '', 'A4']]);
  el.querySelectorAll('[data-r]').forEach(tr => tr.onclick = () => { INV.receipt = Number(tr.dataset.r); invReceiving(el); });
  $('#newr').onclick = () => {
    const sup = (S_inv.settings?.lists?.suppliers) || [];
    const m = modal(`<h2>New receipt</h2><div class="grid">
      <label class="f">Supplier<input id="rs" class="inp" list="supl" value="${esc(sup[0] || '')}"><datalist id="supl">${sup.map(s => `<option value="${esc(s)}">`).join('')}</datalist></label>
      <label class="f">Invoice # (optional for one-offs)<input id="ri" class="inp"></label>
      <label class="f">Date received<input id="rd" class="inp" type="date" value="${new Date().toLocaleDateString('en-CA')}"></label></div>
      <label class="f" style="margin-top:12px">TFD template CSV (leave empty for a blank receipt)<input id="rf" type="file" accept=".csv"></label>
      <div class="err" id="re"></div><div class="actions"><button class="btn primary" id="rgo">Create draft</button></div>`);
    m.querySelector('#rgo').onclick = async () => {
      try {
        let lines = [], meta = {}, fname = null;
        const f = $('#rf').files[0];
        if (f) { ({ meta, lines } = templateToLines(parseCSV(await f.text()))); fname = f.name; }
        const supplier = $('#rs').value.trim() || meta.supplier, inv = $('#ri').value.trim() || meta.invoice_no || '', d = $('#rd').value || meta.date;
        const id = await rpc('tfd_receipt_create', { p_supplier: supplier, p_invoice_no: inv, p_date: d, p_lines: lines, p_source_file: fname });
        m.remove(); INV.receipt = id; invReceiving(el);
      } catch (e) { $('#re').textContent = e.message; }
    };
  };
}
const S_inv = {};

function lineFields(l) {
  return { brand: l.brand, model: l.model, color_code: l.color_code, lens_size: l.lens_size, invoiced_qty: l.invoiced_qty, received_qty: l.received_qty,
    unit_cost_cents: l.unit_cost_cents, name: l.name, color_name: l.color_name, retail_cents: l.retail_cents, weight_oz: l.weight_oz, image_url: l.image_url,
    category: l.category, subcategory: l.subcategory, upc: l.upc, specs: l.specs, bin_code: l.bin_code, lists: l.lists, map_sku: l.map_sku,
    confirmed_new: l.confirmed_new, updates: l.updates };
}

async function receiptEditor(el, id) {
  const r = await rpc('tfd_receipt', { p_id: id });
  const lists = (await rpc('tfd_lists')).filter(x => x.kind === 'manual');
  const draft = r.status === 'draft';
  const units = r.lines.reduce((a, l) => a + l.received_qty, 0), cost = r.lines.reduce((a, l) => a + l.received_qty * (l.unit_cost_cents || 0), 0);
  const problems = r.lines.filter(l => l.check && (l.check.problems.length || l.check.status === 'near')).length;
  const badge = l => !l.check ? (l.result_sku ? `<span class="mono">${l.result_sku}</span>` : '') :
    l.check.status === 'existing' ? `<span class="mono">${l.check.product.sku}</span>` : l.check.status === 'near' ? '<span class="tag off">Check match</span>' : '<span class="tag claude">NEW</span>';
  el.innerHTML = `<div class="panel"><div class="head"><div><a href="#inventory/receiving" id="back" class="small">← All receipts</a>
      <h2 style="margin-top:6px">Receipt #${r.id} ${draft ? '<span class="tag">Draft</span>' : r.status === 'undone' ? '<span class="tag off">Undone</span>' : '<span class="tag">Confirmed</span>'}</h2></div>
      ${draft ? '<button class="btn danger" id="discard">Discard draft</button>' : ''}</div>
    <div class="grid"><label class="f">Supplier<input id="hs" class="inp" value="${esc(r.supplier)}" ${draft ? '' : 'disabled'}></label>
      <label class="f">Invoice #<input id="hi" class="inp" value="${esc(r.invoice_no || '')}" ${draft ? '' : 'disabled'}></label>
      <label class="f">Date received<input id="hd" class="inp" type="date" value="${esc(r.received_date)}" ${draft ? '' : 'disabled'}></label></div>
    ${r.source_file ? `<p class="muted small">Imported from ${esc(r.source_file)}</p>` : ''}</div>
    <div class="panel"><div class="head"><h2>Lines</h2>${draft ? `<div class="row">
      <select id="bl" class="inp"><option value="">Add all lines to list…</option>${lists.map(x => `<option value="${x.id}">${esc(x.name)}</option>`).join('')}</select>
      <input id="bb" class="inp" placeholder="Bin for new lines" style="width:150px"><button class="btn" id="bba">Apply</button>
      <button class="btn" id="addl">Add line</button></div>` : ''}</div>
    <div style="overflow-x:auto"><table><tr><th>#</th><th>SKU</th><th>Product</th><th>Invoiced</th><th>Received</th><th>Unit cost</th><th>Bin</th><th></th></tr>
    ${r.lines.map(l => `<tr><td>${l.line_no}</td><td>${badge(l)}</td>
      <td><b>${esc(l.brand || '?')} ${esc(l.model || '')}</b> <span class="muted">${esc(l.color_code || '')} · ${esc(l.lens_size || '')}</span><div class="small">${esc(l.name || (l.check?.product?.name) || '')}</div>
        ${l.check && l.check.problems.length ? `<div class="note bad" style="margin:6px 0 0">${l.check.problems.map(esc).join('<br>')}</div>` : ''}
        ${l.check && l.check.status === 'near' ? `<div class="note warn" style="margin:6px 0 0">Similar to ${l.check.near.map(n => `${n.sku} (${esc(n.color_code)} · ${esc(n.lens_size)})`).join(', ')}. Open Details to pick one or confirm it's new.</div>` : ''}
        ${l.check && l.check.conflicts.length ? `<div class="note warn" style="margin:6px 0 0">Differs from catalog: ${l.check.conflicts.map(c => esc(c.field.replace(/_/g, ' '))).join(', ')} (catalog kept unless you choose otherwise in Details)</div>` : ''}
        ${!draft && l.received_qty !== l.invoiced_qty ? `<div class="small" style="color:var(--bad)">${l.received_qty < l.invoiced_qty ? 'Short' : 'Over'} by ${Math.abs(l.received_qty - l.invoiced_qty)}</div>` : ''}</td>
      <td>${l.invoiced_qty}</td>
      <td>${draft ? `<input class="inp" style="width:70px" type="number" min="0" data-rq="${l.id}" value="${l.received_qty}">` : l.received_qty}</td>
      <td>${draft ? `<div class="affix" style="width:110px"><span>$</span><input type="number" step="0.01" min="0" data-uc="${l.id}" value="${dl(l.unit_cost_cents)}"></div>` : money(l.unit_cost_cents)}</td>
      <td>${l.check && l.check.status === 'existing' && l.check.product.bin ? esc(l.check.product.bin) : draft ? `<input class="inp" style="width:80px" data-bin="${l.id}" value="${esc(l.bin_code || '')}">` : esc(l.bin_code || '')}</td>
      <td>${draft ? `<button class="btn" data-det="${l.id}">Details</button>` : ''}</td></tr>`).join('') || '<tr><td colspan="8" class="muted">No lines yet.</td></tr>'}
    </table></div>
    <div class="actions" style="justify-content:space-between"><div><b>${units}</b> units received · <b>${money(cost)}</b> at cost${problems ? ` · <span style="color:var(--bad)">${problems} line(s) need attention</span>` : ''}</div>
      ${draft ? '<button class="btn primary" id="confirm">Confirm count</button>' : `<button class="btn" id="labels">Print SKU labels</button>`}</div></div>`;
  $('#back').onclick = e => { e.preventDefault(); INV.receipt = null; invReceiving(el); };
  if (!draft) { $('#labels').onclick = () => printLabels(r.lines.filter(l => l.result_sku).map(l => ({ sku: l.result_sku, name: l.name || `${l.brand} ${l.model}`, qty: l.received_qty }))); return; }
  const reload = () => receiptEditor(el, id);
  const saveHeader = async () => { try { await rpc('tfd_receipt_header', { p_id: id, p_supplier: $('#hs').value, p_invoice_no: $('#hi').value, p_date: $('#hd').value }); } catch (e) { toast(e.message, true); } };
  ['#hs', '#hi', '#hd'].forEach(s => $(s).onchange = saveHeader);
  const saveLine = async (l, patch) => { try { await rpc('tfd_receipt_line_save', { p_receipt_id: id, p_line_id: l ? l.id : null, p_fields: { ...(l ? lineFields(l) : {}), ...patch } }); reload(); } catch (e) { toast(e.message, true); } };
  el.querySelectorAll('[data-rq]').forEach(i => i.onchange = () => { try { saveLine(r.lines.find(l => l.id === Number(i.dataset.rq)), { received_qty: intIn(i.value, 'Received') ?? 0 }); } catch (e) { toast(e.message, true); } });
  el.querySelectorAll('[data-uc]').forEach(i => i.onchange = () => { try { saveLine(r.lines.find(l => l.id === Number(i.dataset.uc)), { unit_cost_cents: dollarsIn(i.value) }); } catch (e) { toast(e.message, true); } });
  el.querySelectorAll('[data-bin]').forEach(i => i.onchange = () => saveLine(r.lines.find(l => l.id === Number(i.dataset.bin)), { bin_code: i.value }));
  el.querySelectorAll('[data-det]').forEach(b => b.onclick = () => lineModal(id, r.lines.find(l => l.id === Number(b.dataset.det)), lists, reload));
  $('#addl').onclick = () => lineModal(id, null, lists, reload);
  $('#bba').onclick = async () => {
    const bin = $('#bb').value.trim(), list = $('#bl').value;
    if (!bin && !list) return toast('Pick a list or type a bin first', true);
    try {
      for (const l of r.lines) {
        const patch = {};
        if (bin && !l.bin_code && !(l.check?.status === 'existing' && l.check.product.bin)) patch.bin_code = bin;
        if (list && !(l.lists || []).includes(Number(list))) patch.lists = [...(l.lists || []), Number(list)];
        if (Object.keys(patch).length) await rpc('tfd_receipt_line_save', { p_receipt_id: id, p_line_id: l.id, p_fields: { ...lineFields(l), ...patch } });
      }
      toast('Applied'); reload();
    } catch (e) { toast(e.message, true); }
  };
  $('#discard').onclick = () => {
    const m = modal(`<h2>Discard this draft?</h2><p>Receipt #${id} and its ${r.lines.length} line(s) will be deleted. Stock was never changed.</p><div class="actions"><button class="btn danger" id="dy">Discard</button></div>`);
    m.querySelector('#dy').onclick = async () => { try { await rpc('tfd_receipt_discard', { p_id: id }); m.remove(); INV.receipt = null; invReceiving(el); } catch (e) { toast(e.message, true); } };
  };
  $('#confirm').onclick = () => {
    const short = r.lines.filter(l => l.received_qty !== l.invoiced_qty);
    const m = modal(`<h2>Confirm count</h2><p>This adds <b>${units}</b> units (<b>${money(cost)}</b> at cost) to stock and creates any NEW SKUs.</p>
      ${short.length ? `<div class="note warn">${short.length} line(s) differ from the invoice. They'll be flagged for a supplier claim.</div>` : ''}
      <div class="err" id="ce" style="white-space:pre-line"></div><div class="actions"><button class="btn primary" id="cy">Confirm count</button></div>`);
    m.querySelector('#cy').onclick = async () => {
      try {
        const res = await rpc('tfd_receipt_confirm', { p_id: id });
        m.remove(); toast(`Added ${res.units} units · ${res.new_skus} new SKU(s)`); reload();
      } catch (e) { $('#ce').textContent = e.message; }
    };
  };
}

function lineModal(rid, l, lists, done) {
  const v = l || { invoiced_qty: 0, received_qty: 0, lists: [], updates: [] };
  const c = l && l.check;
  const inp = (id, label, val, extra = '') => `<label class="f">${label}<input id="${id}" class="inp" value="${esc(val ?? '')}" ${extra}></label>`;
  const m = modal(`<h2>${l ? 'Line ' + l.line_no : 'New line'}</h2>
    ${c && c.status === 'near' ? `<div class="note warn">This looks like an existing product. Pick it if it's the same thing (a typo on the invoice), or confirm it's new.
      <div class="row" style="margin-top:8px">${c.near.map(n => `<button class="btn" data-map="${n.sku}">Use ${n.sku}: ${esc(n.brand)} ${esc(n.model)} ${esc(n.color_code)} · ${esc(n.lens_size)}</button>`).join('')}
      <button class="btn primary" id="isnew">It's a new product</button></div></div>` : ''}
    ${l && l.map_sku ? `<div class="note ok">Mapped to existing SKU ${l.map_sku}. <button class="btn" id="unmap">Undo</button></div>` : ''}
    <h3>Identity (brand + model # + color code + lens size = one product)</h3>
    <div class="grid">${inp('lb', 'Brand', v.brand, 'list="brl"')}<datalist id="brl">${((S_inv.settings?.lists?.brands) || []).map(b => `<option value="${esc(b)}">`).join('')}</datalist>
      ${inp('lm', 'Model #', v.model)}${inp('lc', 'Color code', v.color_code)}${inp('ll', 'Lens size', v.lens_size)}</div>
    <h3>Count and cost</h3>
    <div class="grid">${inp('lqi', 'Invoiced qty', v.invoiced_qty, 'type="number" min="0"')}${inp('lqr', 'Received qty', v.received_qty, 'type="number" min="0"')}${inp('luc', 'Unit cost ($)', dl(v.unit_cost_cents), 'type="number" step="0.01" min="0"')}
      ${inp('lbin', 'Bin', v.bin_code, c && c.status === 'existing' && c.product.bin ? 'disabled placeholder="' + esc(c.product.bin) + '"' : '')}</div>
    <h3>Product details ${c && c.status === 'existing' ? '<span class="muted small">(catalog values are kept unless you tick "update catalog")</span>' : ''}</h3>
    <div class="grid">${inp('ln', 'Product name', v.name)}${inp('lcn', 'Color name', v.color_name)}${inp('lr', 'Retail price ($)', dl(v.retail_cents), 'type="number" step="0.01" min="0"')}
      ${inp('lw', 'Weight (oz)', v.weight_oz, 'type="number" step="0.01" min="0"')}${inp('lcat', 'Category', v.category)}${inp('lsub', 'Subcategory', v.subcategory)}
      ${inp('lu', 'UPC', v.upc)}${inp('li', 'Image URL', v.image_url)}${inp('lsp', 'Specs', v.specs)}</div>
    ${c && c.conflicts.length ? `<h3>Differs from catalog</h3>${c.conflicts.map(x => `<div class="toggle"><span><b>${esc(x.field.replace(/_/g, ' '))}</b>: catalog "${esc(x.catalog)}" vs invoice "${esc(x.line)}"</span>
      <label class="small"><input type="checkbox" data-upd="${x.field}" ${x.update ? 'checked' : ''}> update catalog</label></div>`).join('')}` : ''}
    <h3>Add to lists</h3><div class="row">${lists.map(x => `<label class="small"><input type="checkbox" data-list="${x.id}" ${(v.lists || []).includes(x.id) ? 'checked' : ''}> ${esc(x.name)}</label>`).join('') || '<span class="muted small">No manual lists yet (Inventory → Lists).</span>'}</div>
    <div class="err" id="le2"></div><div class="actions">${l ? '<button class="btn danger" id="ldel">Delete line</button>' : ''}<button class="btn primary" id="lsave">Save line</button></div>`);
  const read = extra => {
    const f = {
      brand: $('#lb').value, model: $('#lm').value, color_code: $('#lc').value, lens_size: $('#ll').value,
      invoiced_qty: intIn($('#lqi').value, 'Invoiced qty') ?? 0, received_qty: intIn($('#lqr').value, 'Received qty') ?? 0, unit_cost_cents: dollarsIn($('#luc').value),
      bin_code: $('#lbin').disabled ? null : $('#lbin').value, name: $('#ln').value, color_name: $('#lcn').value, retail_cents: dollarsIn($('#lr').value),
      weight_oz: $('#lw').value || null, category: $('#lcat').value, subcategory: $('#lsub').value, upc: $('#lu').value, image_url: $('#li').value, specs: $('#lsp').value,
      lists: [...m.querySelectorAll('[data-list]')].filter(x => x.checked).map(x => Number(x.dataset.list)),
      updates: [...m.querySelectorAll('[data-upd]')].filter(x => x.checked).map(x => x.dataset.upd),
      map_sku: l ? l.map_sku : null, confirmed_new: l ? l.confirmed_new : false, ...extra };
    return f;
  };
  const save = async extra => {
    try { await rpc('tfd_receipt_line_save', { p_receipt_id: rid, p_line_id: l ? l.id : null, p_fields: read(extra) }); m.remove(); done(); }
    catch (e) { m.querySelector('#le2').textContent = e.message; }
  };
  m.querySelector('#lsave').onclick = () => save({});
  m.querySelectorAll('[data-map]').forEach(b => b.onclick = () => save({ map_sku: b.dataset.map, confirmed_new: false }));
  if (m.querySelector('#isnew')) m.querySelector('#isnew').onclick = () => save({ confirmed_new: true, map_sku: null });
  if (m.querySelector('#unmap')) m.querySelector('#unmap').onclick = () => save({ map_sku: null });
  if (m.querySelector('#ldel')) m.querySelector('#ldel').onclick = async () => { try { await rpc('tfd_receipt_line_delete', { p_receipt_id: rid, p_line_id: l.id }); m.remove(); done(); } catch (e) { toast(e.message, true); } };
}

// ================================================================ Adjustments
async function invAdjust(el) {
  const stock = await rpc('tfd_stock');
  const act = await rpc('tfd_activity', { p_filters: { tab: 'Inventory' } });
  const recent = act.rows.filter(r => r.action === 'adjust_out' || r.action === 'adjust_in').slice(0, 25);
  el.innerHTML = `<div class="panel"><h2>Adjust stock</h2><div class="grid">
      <label class="f">SKU<input id="as" class="inp" list="skl" placeholder="6 digits"><datalist id="skl">${stock.map(s => `<option value="${s.sku}">${esc(s.name || s.brand + ' ' + s.model)} · ${s.on_hand} on hand</option>`).join('')}</datalist></label>
      <label class="f">Change<select id="ad" class="inp"><option value="out">Remove units</option><option value="in">Add units (count correction)</option></select></label>
      <label class="f">Quantity<input id="aq" class="inp" type="number" min="1" value="1"></label>
      <label class="f">Reason<select id="ar" class="inp">${REASONS_OUT.map(r => `<option>${r}</option>`).join('')}</select></label>
      <label class="f">Note (optional)<input id="an" class="inp"></label></div>
    <div id="ainfo" class="muted small" style="margin-top:8px"></div>
    <div class="err" id="ae"></div><div class="actions"><button class="btn primary" id="ago">Save adjustment</button></div>
    <p class="muted small">Removals take the oldest cost first (FIFO). Additions come in at the most recent cost.</p></div>
    <div class="panel"><h2>Customer returns</h2><p class="muted">Returns are entered by order number, so they arrive with Shows (Phase 3–4), once orders exist in the app.</p></div>
    <div class="panel"><h2>Recent adjustments</h2><table><tr><th>When</th><th>Who</th><th>What</th></tr>
      ${recent.map(r => `<tr><td class="small">${when(r.at)}</td><td>${esc(r.actor)}</td><td>${esc(r.summary)}${r.reason ? `<div class="muted small">${esc(r.reason)}</div>` : ''}${r.undone_by ? ' <span class="tag off">Undone</span>' : ''}</td></tr>`).join('') || '<tr><td colspan="3" class="muted">None yet.</td></tr>'}
    </table><p class="muted small">To undo one, use the Activity Log.</p></div>`;
  const info = () => { const s = stock.find(x => x.sku === $('#as').value.trim()); $('#ainfo').textContent = s ? `${s.name || s.brand + ' ' + s.model} · ${s.on_hand} on hand · bin ${s.bin || '—'}` : ''; };
  $('#as').oninput = info;
  $('#ad').onchange = () => { $('#ar').innerHTML = ($('#ad').value === 'out' ? REASONS_OUT : ['count correction', 'found']).map(r => `<option>${r}</option>`).join(''); };
  const go = async confirm => {
    try {
      const r = await rpc('tfd_adjust', { p_sku: $('#as').value.trim(), p_direction: $('#ad').value, p_qty: intIn($('#aq').value, 'Quantity'), p_reason: $('#ar').value, p_note: $('#an').value, p_confirm: confirm });
      if (r.needs_confirm) {
        const m = modal(`<h2>Large adjustment</h2><p>${esc(r.message)}</p><div class="actions"><button class="btn primary" id="cy">Confirm</button></div>`);
        m.querySelector('#cy').onclick = () => { m.remove(); go(true); }; return;
      }
      toast(`Saved · ${money(r.value_cents)} at cost · ${r.on_hand} now on hand`); invAdjust(el);
    } catch (e) { $('#ae').textContent = e.message; }
  };
  $('#ago').onclick = () => go(false);
}

// ================================================================ Stock
async function invStock(el) {
  const [stock, lists] = await Promise.all([rpc('tfd_stock'), rpc('tfd_lists')]);
  INV.stockQ = INV.stockQ || { q: '', brand: '', bin: '', sort: 'sku', dir: 1 };
  const q = INV.stockQ;
  const brands = [...new Set(stock.map(s => s.brand))].sort(), bins = [...new Set(stock.map(s => s.bin).filter(Boolean))].sort();
  const low = stock.filter(s => s.available > 0 && s.available <= s.low_stock_effective), out = stock.filter(s => s.available === 0 && s.on_hand === 0);
  const totals = stock.reduce((a, s) => ({ units: a.units + s.on_hand, value: a.value + s.value_cents }), { units: 0, value: 0 });
  const cols = [['sku', 'SKU'], ['name', 'Product'], ['bin', 'Bin'], ['on_hand', 'On hand'], ['held', 'Held'], ['sold_not_packed', 'Sold, not packed'], ['available', 'Available'],
    ['floor_tiktok', 'Floor (TikTok)'], ['floor_whatnot', 'Floor (Whatnot)'], ['value_cents', 'Value at cost'], ['last_received', 'Last received'], ['sold_30', 'Sold 30d']];
  const draw = () => {
    let rows = stock.filter(s => (!q.brand || s.brand === q.brand) && (!q.bin || s.bin === q.bin) &&
      (!q.q || [s.sku, s.name, s.brand, s.model, s.color_code, s.color_name].join(' ').toLowerCase().includes(q.q.toLowerCase())));
    rows.sort((a, b) => { const x = a[q.sort], y = b[q.sort]; return (x === y ? 0 : x === null || x === undefined ? 1 : y === null || y === undefined ? -1 : x > y ? 1 : -1) * q.dir; });
    $('#stbl').innerHTML = `<tr>${cols.map(([k, l]) => `<th data-sort="${k}" style="cursor:pointer;white-space:nowrap">${l}${q.sort === k ? (q.dir > 0 ? ' ↑' : ' ↓') : ''}</th>`).join('')}</tr>
      ${rows.map(s => `<tr data-sku="${s.sku}" style="cursor:pointer"><td class="mono">${s.sku}</td>
        <td><div class="row" style="flex-wrap:nowrap">${s.image_url ? `<img src="${esc(s.image_url)}" alt="" style="width:36px;height:36px;object-fit:cover;border-radius:6px">` : ''}
          <div><b>${esc(s.name || s.brand + ' ' + s.model)}</b><div class="muted small">${esc(s.brand)} ${esc(s.model)} · ${esc(s.color_code)} · ${esc(s.lens_size)}</div></div></div></td>
        <td>${esc(s.bin || '—')}</td><td>${s.on_hand}</td><td>${s.held}</td><td>${s.sold_not_packed}</td>
        <td>${s.available}${s.available > 0 && s.available <= s.low_stock_effective ? ' <span class="tag off">Low</span>' : ''}</td>
        <td class="mono">${s.floor_tiktok === null ? '—' : money(s.floor_tiktok)}</td><td class="mono">${s.floor_whatnot === null ? '<span class="muted">not set</span>' : money(s.floor_whatnot)}</td>
        <td class="mono">${money(s.value_cents)}</td><td class="small">${esc(s.last_received || '—')}</td><td>${s.sold_30}</td></tr>`).join('') || `<tr><td colspan="${cols.length}" class="muted">Nothing matches.</td></tr>`}`;
    el.querySelectorAll('[data-sort]').forEach(th => th.onclick = () => { if (q.sort === th.dataset.sort) q.dir *= -1; else { q.sort = th.dataset.sort; q.dir = 1; } draw(); });
    el.querySelectorAll('[data-sku]').forEach(tr => tr.onclick = () => skuDrawer(tr.dataset.sku, () => invStock(el)));
  };
  el.innerHTML = `${low.length || out.length ? `<div class="panel"><h2>Alerts</h2>
      ${low.length ? `<div class="note warn"><b>Low stock:</b> ${low.map(s => `${s.sku} (${s.available} left)`).join(', ')}</div>` : ''}
      ${out.length ? `<div class="note bad"><b>Out of stock:</b> ${out.map(s => s.sku).join(', ')}</div>` : ''}
      <p class="muted small">"Remove the stage sample" alerts and show suggestions start once Shows are built.</p></div>` : ''}
    <div class="panel"><div class="head"><div><h2>Stock</h2><div class="muted small">${stock.length} SKUs · ${totals.units} units · ${money(totals.value)} at cost</div></div>
      <div class="row"><select id="exl" class="inp"><option value="">Full inventory</option>${lists.map(l => `<option value="${l.id}">${esc(l.name)}</option>`).join('')}</select>
      <button class="btn" id="exw">Export for Whatnot</button></div></div>
      <div class="row" style="margin-bottom:12px"><input id="sq" class="inp" placeholder="Search SKU, name, model, color…" style="flex:1;min-width:200px" value="${esc(q.q)}">
        <select id="sb" class="inp"><option value="">All brands</option>${brands.map(b => `<option ${b === q.brand ? 'selected' : ''}>${esc(b)}</option>`).join('')}</select>
        <select id="sbin" class="inp"><option value="">All bins</option>${bins.map(b => `<option ${b === q.bin ? 'selected' : ''}>${esc(b)}</option>`).join('')}</select></div>
      <div style="overflow-x:auto"><table id="stbl"></table></div>
      <p class="muted small">Floors use the highest unit cost in stock and round up to a whole dollar. Held and sold-not-packed fill in once Shows are built.</p></div>`;
  $('#sq').oninput = () => { q.q = $('#sq').value; draw(); };
  $('#sb').onchange = () => { q.brand = $('#sb').value; draw(); };
  $('#sbin').onchange = () => { q.bin = $('#sbin').value; draw(); };
  $('#exw').onclick = () => whatnotExport($('#exl').value ? Number($('#exl').value) : null);
  draw();
}

async function skuDrawer(sku, done) {
  const h = await rpc('tfd_sku_history', { p_sku: sku });
  const p = h.product;
  const KIND = { receipt: 'Received', adjust_out: 'Removed', adjust_in: 'Added', bin_move: 'Bin move', verify: 'Bin verify', receipt_undo: 'Receipt undone', adjust_undo: 'Adjustment undone' };
  const inp = (id, label, val, extra = '') => `<label class="f">${label}<input id="${id}" class="inp" value="${esc(val ?? '')}" ${extra}></label>`;
  const m = modal(`<h2>SKU ${p.sku}</h2><p class="muted">${esc(p.brand)} ${esc(p.model)} · ${esc(p.color_code)} · ${esc(p.lens_size)} · bin ${esc(p.bin || '—')} · ${p.on_hand} on hand</p>
    ${p.image_url ? `<img src="${esc(p.image_url)}" alt="" style="max-width:160px;border-radius:8px">` : ''}
    <div class="grid">${inp('pn', 'Product name', p.name)}${inp('pcn', 'Color name', p.color_name)}${inp('pr', 'Retail price ($)', dl(p.retail_cents), 'type="number" step="0.01"')}
      ${inp('pw', 'Weight (oz)', p.weight_oz, 'type="number" step="0.01"')}${inp('pc', 'Category', p.category)}${inp('ps', 'Subcategory', p.subcategory)}
      ${inp('pu', 'UPC', p.upc)}${inp('pi', 'Image URL', p.image_url)}${inp('psp', 'Specs', p.specs)}${inp('pl', 'Low-stock threshold (blank = default)', p.low_stock, 'type="number" min="0"')}</div>
    <div class="err" id="pe"></div><div class="actions"><button class="btn" id="plab">Print label</button><button class="btn primary" id="psave">Save details</button></div>
    <h3>Cost layers (FIFO)</h3><table><tr><th>Received</th><th>Unit cost</th><th>In</th><th>Left</th></tr>
      ${h.layers.map(c => `<tr><td class="small">${when(c.created_at)}${c.receipt ? ' · receipt #' + c.receipt : ' · count up'}</td><td class="mono">${money(c.unit_cost_cents)}</td><td>${c.qty_in}</td><td>${c.qty_remaining}</td></tr>`).join('')}</table>
    <h3>History</h3><table><tr><th>When</th><th>What</th><th>Qty</th><th>Who</th></tr>
      ${h.moves.map(x => `<tr><td class="small">${when(x.at)}</td><td>${KIND[x.kind] || esc(x.kind)}${x.reason ? ` <span class="muted small">(${esc(x.reason)})</span>` : ''}${x.detail && x.detail.to ? ` <span class="muted small">→ ${esc(x.detail.to)}</span>` : ''}${x.receipt_id ? ` <span class="muted small">#${x.receipt_id}</span>` : ''}</td>
        <td>${x.qty > 0 ? '+' : ''}${x.qty || ''}</td><td>${esc(x.actor)}</td></tr>`).join('')}</table>`);
  m.querySelector('.modal').style.maxWidth = '760px';
  m.querySelector('#plab').onclick = () => printLabels([{ sku: p.sku, name: p.name || `${p.brand} ${p.model}`, qty: 1 }]);
  m.querySelector('#psave').onclick = async () => {
    try {
      const r = await rpc('tfd_product_update', { p_sku: sku, p_fields: { name: $('#pn').value, color_name: $('#pcn').value, retail_cents: dollarsIn($('#pr').value), weight_oz: $('#pw').value,
        category: $('#pc').value, subcategory: $('#ps').value, upc: $('#pu').value, image_url: $('#pi').value, specs: $('#psp').value, low_stock: intIn($('#pl').value, 'Threshold') } });
      toast(r.unchanged ? 'No changes' : 'Saved'); m.remove(); done();
    } catch (e) { m.querySelector('#pe').textContent = e.message; }
  };
}

async function whatnotExport(listId) {
  const d = await rpc('tfd_whatnot_export', { p_list_id: listId });
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
  const brands = (S_inv.settings?.lists?.brands) || [];
  const ru = v.rule || {};
  const csv = a => (a || []).join(', ');
  const m = modal(`<h2>${l ? 'Edit list' : 'New list'}</h2>
    <div class="grid"><label class="f">Name<input id="ln_" class="inp" value="${esc(v.name)}"></label>
      <label class="f">Type<select id="lk" class="inp"><option value="rule" ${v.kind === 'rule' ? 'selected' : ''}>Rule (updates itself)</option><option value="manual" ${v.kind === 'manual' ? 'selected' : ''}>Hand-picked SKUs</option></select></label>
      <label class="f">% of each SKU's units (blank = all)<input id="lp" class="inp" type="number" min="1" max="100" value="${v.pct ?? ''}"></label></div>
    <div id="lrule"><h3>Rule</h3><p class="muted small">Leave a field blank to include everything. Lists of values are comma-separated.</p>
      <div class="row">${brands.map(b => `<label class="small"><input type="checkbox" data-br="${esc(b)}" ${(ru.brands || []).some(x => x.toLowerCase() === b.toLowerCase()) ? 'checked' : ''}> ${esc(b)}</label>`).join('') || '<span class="muted small">Add brands in Settings → Lists.</span>'}</div>
      <div class="grid" style="margin-top:10px">
        <label class="f">Categories<input id="rc" class="inp" value="${esc(csv(ru.categories))}"></label><label class="f">Subcategories<input id="rsc" class="inp" value="${esc(csv(ru.subcategories))}"></label>
        <label class="f">Suppliers<input id="rsu" class="inp" value="${esc(csv(ru.suppliers))}"></label><label class="f">Receipt #s<input id="rre" class="inp" value="${esc(csv(ru.receipts))}"></label>
        <label class="f">Retail from ($)<input id="rr1" class="inp" type="number" step="0.01" value="${dl(ru.retail_min)}"></label><label class="f">Retail to ($)<input id="rr2" class="inp" type="number" step="0.01" value="${dl(ru.retail_max)}"></label>
        <label class="f">On hand at least<input id="rq1" class="inp" type="number" min="0" value="${ru.qty_min ?? ''}"></label><label class="f">On hand at most<input id="rq2" class="inp" type="number" min="0" value="${ru.qty_max ?? ''}"></label></div></div>
    <div id="lman"><h3>SKUs</h3><textarea id="lsk" class="inp" rows="5" style="width:100%" placeholder="One SKU per line, or comma-separated">${esc((v.skus || []).join('\n'))}</textarea>
      <p class="muted small">${stock.length} SKUs in stock. You can also add SKUs to lists while receiving.</p></div>
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

// ================================================================ Bins
async function invBins(el) {
  const bins = await rpc('tfd_bins');
  el.innerHTML = `<div class="panel"><div class="head"><div><h2>Bins</h2><p class="muted small">One bin per SKU. Each SKU sits in its own labeled bag inside its bin.</p></div>
      <div class="row"><button class="btn" id="mv">Move SKU</button><button class="btn primary" id="nb">New bin</button></div></div>
    <div class="grid">${bins.map(b => `<div class="panel" style="margin:0"><div class="head" style="margin-bottom:8px"><h2 style="margin:0">${esc(b.code)}</h2>
        <button class="btn" data-ver="${esc(b.code)}" ${b.skus.length ? '' : 'disabled'}>Verify</button></div>
      ${b.note ? `<div class="muted small">${esc(b.note)}</div>` : ''}
      ${b.skus.map(s => `<div class="small" style="padding:4px 0;border-bottom:1px solid var(--line)"><span class="mono">${s.sku}</span> · ${esc(s.name || s.brand + ' ' + s.model)} <b style="float:right">${s.on_hand}</b></div>`).join('') || '<div class="muted small">Empty</div>'}
      </div>`).join('') || '<p class="muted">No bins yet. They are also created automatically when you receive into a new bin code.</p>'}</div></div>`;
  $('#nb').onclick = () => {
    const m = modal(`<h2>New bin</h2><div class="grid"><label class="f">Code (e.g. A4)<input id="bc" class="inp"></label><label class="f">Note (optional)<input id="bn" class="inp"></label></div>
      <div class="err" id="be"></div><div class="actions"><button class="btn primary" id="bs">Create</button></div>`);
    m.querySelector('#bs').onclick = async () => { try { await rpc('tfd_bin_create', { p_code: $('#bc').value, p_note: $('#bn').value }); m.remove(); invBins(el); } catch (e) { m.querySelector('#be').textContent = e.message; } };
  };
  $('#mv').onclick = () => {
    const m = modal(`<h2>Move SKU</h2><p class="muted small">Moves all units of the SKU. There's no partial move.</p>
      <div class="grid"><label class="f">SKU<input id="ms" class="inp"></label><label class="f">To bin<input id="mb" class="inp" list="bnl"><datalist id="bnl">${bins.map(b => `<option value="${esc(b.code)}">`).join('')}</datalist></label></div>
      <div class="err" id="me"></div><div class="actions"><button class="btn primary" id="mgo">Move</button></div>`);
    m.querySelector('#mgo').onclick = async () => { try { await rpc('tfd_move_sku', { p_sku: $('#ms').value.trim(), p_bin: $('#mb').value }); m.remove(); toast('Moved'); invBins(el); } catch (e) { m.querySelector('#me').textContent = e.message; } };
  };
  el.querySelectorAll('[data-ver]').forEach(btn => btn.onclick = () => {
    const b = bins.find(x => x.code === btn.dataset.ver);
    const m = modal(`<h2>Verify bin ${esc(b.code)}</h2><p class="muted small">Count each bag and enter what's really there.</p>
      ${b.skus.map(s => `<div class="toggle"><span><span class="mono">${s.sku}</span> · ${esc(s.name || s.brand + ' ' + s.model)}</span><input class="inp" style="width:80px" type="number" min="0" data-cnt="${s.sku}"></div>`).join('')}
      <div id="vd"></div><div class="err" id="ve"></div><div class="actions"><button class="btn primary" id="vgo">Check counts</button></div>`);
    const counts = () => { const o = {}; m.querySelectorAll('[data-cnt]').forEach(i => { if (i.value === '') throw new Error('Enter a count for every SKU'); o[i.dataset.cnt] = intIn(i.value, 'Count'); }); return o; };
    m.querySelector('#vgo').onclick = async () => {
      try {
        const c = counts();
        const r = await rpc('tfd_bin_verify', { p_bin: b.code, p_counts: c, p_confirm: false });
        if (!r.differences.length) { await rpc('tfd_bin_verify', { p_bin: b.code, p_counts: c, p_confirm: true }); m.remove(); toast('All counts match. Verified.'); return invBins(el); }
        $('#vd').innerHTML = `<div class="note warn">Differences:<br>${r.differences.map(d => `${d.sku}: app says ${d.on_hand}, counted ${d.counted} (${d.diff > 0 ? '+' : ''}${d.diff})`).join('<br>')}<br>Confirming records these as count corrections.</div>`;
        const btn2 = m.querySelector('#vgo'); btn2.textContent = 'Confirm corrections';
        btn2.onclick = async () => { try { await rpc('tfd_bin_verify', { p_bin: b.code, p_counts: counts(), p_confirm: true }); m.remove(); toast('Corrected'); invBins(el); } catch (e) { $('#ve').textContent = e.message; } };
      } catch (e) { $('#ve').textContent = e.message; }
    };
  });
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
