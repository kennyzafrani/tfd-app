'use strict';
// Dashboard (admins): filtered totals vs. the previous period, per-hour row, breakdowns, shows, saved filters, streamer view.

const DASH = { f: null, streamerView: false, tab: 'show' };
const ymd = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const PRESETS = [['all', 'All time'], ['today', 'Today'], ['yesterday', 'Yesterday'], ['last7', 'Last 7 days'], ['last30', 'Last 30 days'],
  ['week', 'This week'], ['month', 'This month'], ['lastmonth', 'Last month'], ['custom', 'Custom dates']];
function presetRange(k, f) {
  const t = new Date(); t.setHours(12, 0, 0, 0); const d = n => { const x = new Date(t); x.setDate(x.getDate() + n); return ymd(x); };
  switch (k) {
    case 'today': return [d(0), d(0)];
    case 'yesterday': return [d(-1), d(-1)];
    case 'last7': return [d(-6), d(0)];
    case 'last30': return [d(-29), d(0)];
    case 'week': return [d(-t.getDay()), d(0)];
    case 'month': return [ymd(new Date(t.getFullYear(), t.getMonth(), 1)), d(0)];
    case 'lastmonth': return [ymd(new Date(t.getFullYear(), t.getMonth() - 1, 1)), ymd(new Date(t.getFullYear(), t.getMonth(), 0))];
    case 'custom': return [f.from || '', f.to || ''];
    default: return ['', ''];
  }
}
const blankF = () => ({ preset: 'all', from: '', to: '', dows: [], hour_from: '', hour_to: '', shows: [], platforms: [], parts: [], people: [], skus: [], brands: [], suppliers: [], lots: [], price_min: '', price_max: '' });
function loadF() { try { const v = JSON.parse(localStorage.getItem('tfd_dash_f')); if (v && typeof v === 'object') return { ...blankF(), ...v }; } catch {} return blankF(); }
function saveF() { try { localStorage.setItem('tfd_dash_f', JSON.stringify(DASH.f)); } catch {} }
function toQuery(f) {
  const [from, to] = presetRange(f.preset, f);
  const c = x => Math.round(Number(x) * 100);
  return { from, to, dows: f.dows, hour_from: f.hour_from === '' ? null : Number(f.hour_from), hour_to: f.hour_to === '' ? null : Number(f.hour_to),
    shows: f.shows, platforms: f.platforms, parts: f.parts.map(Number), people: f.people, skus: f.skus, brands: f.brands, suppliers: f.suppliers, lots: f.lots,
    price_min: f.price_min === '' ? null : c(f.price_min), price_max: f.price_max === '' ? null : c(f.price_max) };
}
const DOW = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const hourLbl = h => h === 0 || h === 24 ? '12am' : h === 12 ? '12pm' : h < 12 ? h + 'am' : (h - 12) + 'pm';
const num = (v, d = 0) => v === null || v === undefined ? '—' : Number(v).toLocaleString(undefined, { maximumFractionDigits: d, minimumFractionDigits: d });
const dpct = (a, b) => b ? (100 * a / b).toFixed(1) + '%' : '—';

async function renderDashboard() {
  const main = $('#main');
  if (S.state.me.role !== 'admin') { main.innerHTML = '<div class="panel"><h1>Dashboard</h1><p class="muted">Ask an admin to show you your stats.</p></div>'; return; }
  DASH.f = DASH.f || loadF();
  main.innerHTML = '<div class="panel muted">Loading…</div>';
  let d;
  let iv = null;
  try { [d, iv] = await Promise.all([rpc('tfd_dashboard', { p: toQuery(DASH.f) }), rpc('tfd_inventory_value').catch(() => null)]); } catch (e) { if (stillOn('dashboard')) main.innerHTML = `<div class="note bad">${esc(e.message)}</div>`; return; }
  if (!stillOn('dashboard')) return;
  const f = DASH.f, T = d.totals, P = d.previous, C = d.choices;
  const oneStreamer = f.people.length === 1;
  const sv = oneStreamer && DASH.streamerView;
  const who = oneStreamer ? (C.people.find(p => p.id === f.people[0]) || {}).name : '';
  const prod = T.product_filter;
  const ms = (key, label, items, idOf, lblOf) => `<details class="ms" data-ms="${key}"><summary>${label}${f[key].length ? ` <b>(${f[key].length})</b>` : ''}</summary><div class="msl">
      ${items.length ? items.map(x => `<label><input type="checkbox" value="${esc(String(idOf(x)))}" ${f[key].map(String).includes(String(idOf(x))) ? 'checked' : ''}> ${esc(lblOf(x))}</label>`).join('') : '<span class="muted small">None yet</span>'}</div></details>`;
  const delta = (k, invert) => {
    if (!P || P[k] === null || P[k] === undefined || T[k] === null || T[k] === undefined) return '';
    const a = Number(T[k]), b = Number(P[k]); if (!b) return a ? '<span class="dlt up">new</span>' : '';
    const ch = (a - b) / Math.abs(b) * 100, good = invert ? ch < 0 : ch > 0;
    return `<span class="dlt ${Math.abs(ch) < 0.05 ? '' : good ? 'up' : 'down'}">${ch > 0 ? '▲' : ch < 0 ? '▼' : ''} ${Math.abs(ch).toFixed(1)}%</span>`;
  };
  const tile = (label, val, k, sub, invert) => `<div class="panel tile"><div class="muted small">${label}</div><b class="big">${val}</b>${k ? delta(k, invert) : ''}${sub ? `<div class="muted small">${sub}</div>` : ''}</div>`;
  const H = T.hours ? Number(T.hours) : 0, per = v => H && v !== null && v !== undefined ? money(Math.round(Number(v) / H)) : '—';
  const totalPay = T.hourly_pay_cents === null ? null : Number(T.hourly_pay_cents) + Number(T.commission_cents);
  const tiles = sv ? [
      tile('Revenue', money(T.revenue_cents), 'revenue_cents'), tile('Orders', num(T.orders, 0), 'orders'), tile('Packages', num(T.packages), 'packages'),
      tile('Hours', num(T.hours, 2), 'hours'), tile('Avg sale', T.orders ? money(Math.round(T.revenue_cents / T.orders)) : '—'),
      tile('Hourly pay', money(T.hourly_pay_cents), 'hourly_pay_cents'), tile('Commission', money(T.commission_cents), 'commission_cents'), tile('Total pay', money(totalPay))]
    : [
      tile('Revenue', money(T.revenue_cents), 'revenue_cents', 'excl. shipping'),
      tile('Item profit', money(T.item_profit_cents), 'item_profit_cents', 'margin ' + dpct(T.item_profit_cents, T.revenue_cents)),
      tile('Net profit', prod ? '—' : money(T.net_profit_cents), 'net_profit_cents', prod ? 'not with product filters' : 'margin ' + dpct(T.net_profit_cents, T.revenue_cents)),
      tile('Hours streamed', prod ? '—' : num(T.hours, 2), 'hours'),
      tile('Orders', num(T.orders, 0), 'orders', T.giveaways ? num(T.giveaways) + ' giveaway(s)' : ''), tile('Packages', num(T.packages), 'packages'), tile('Unique SKUs', num(T.unique_skus), 'unique_skus'),
      tile('Avg sale / order', T.orders ? money(Math.round(T.revenue_cents / T.orders)) : '—'), tile('Avg cost / order', T.orders ? money(Math.round(T.cost_cents / T.orders)) : '—'),
      tile('Platform fees', money(T.fees_cents), 'fees_cents', null, true), tile('Cost of goods', money(T.cost_cents), 'cost_cents', null, true),
      tile('Hourly pay', prod ? '—' : money(T.hourly_pay_cents), 'hourly_pay_cents', 'streamers + assistants', true), tile('Commission', money(T.commission_cents), 'commission_cents', null, true),
      tile('Streamer pay total', prod ? '—' : money(totalPay), null, null, true),
      tile('Ad / marketing', prod ? '—' : money((T.ad_spend_cents || 0) + Number(T.giveaway_cost_cents || 0)), null, `ads ${prod ? '—' : money(T.ad_spend_cents)} + giveaways ${money(T.giveaway_cost_cents)}`, true),
      tile('Refunds', '0 · $0.00', null, 'arrive with Fulfillment'),
      tile('Inventory value', iv ? money(iv.cost_cents) : '—', null, iv ? `at cost, on hand now · ${num(iv.units, 0)} units, ${num(iv.skus, 0)} SKUs · retail ${money(iv.retail_cents)}` : '')];
  const perHour = prod || !H ? '' : `<div class="panel"><h3 style="margin-top:0">Per hour <span class="muted small">(${num(H, 2)} h)</span></h3><div class="grid stats">
      ${(sv ? [['Revenue', T.revenue_cents], ['Hourly pay', T.hourly_pay_cents], ['Commission', T.commission_cents], ['Total pay', totalPay]]
           : [['Revenue', T.revenue_cents], ['Item profit', T.item_profit_cents], ['Net profit', T.net_profit_cents], ['Hourly pay', T.hourly_pay_cents], ['Commission', T.commission_cents], ['Ad spend', T.ad_spend_cents]])
        .map(([l, v]) => `<div class="panel tile"><div class="muted small">${l}</div><b class="big">${per(v)}</b></div>`).join('')}
      <div class="panel tile"><div class="muted small">Orders</div><b class="big">${num(T.orders / H, 1)}</b></div><div class="panel tile"><div class="muted small">Packages</div><b class="big">${num(T.packages / H, 1)}</b></div></div></div>`;
  const [rf, rt] = presetRange(f.preset, f);
  main.innerHTML = `<div class="head"><div><h1>Dashboard${sv ? ` · ${esc(who)}` : ''}</h1>
      <p class="muted small">${rf ? `${rf} to ${rt}` : 'All time'}${P ? ` · compared with ${d.previous_range[0]} to ${d.previous_range[1]}` : ''}${T.estimate ? ' · <span class="tag">includes estimates</span> (shows not finalized yet)' : ''}</p></div>
      <div class="row">${oneStreamer ? `<label class="row small"><input type="checkbox" id="svt" ${sv ? 'checked' : ''}> Streamer view</label>` : ''}</div></div>
    <div class="panel filters-bar">
      <div class="row wrap">
        <select id="fp" class="inp">${PRESETS.map(([k, l]) => `<option value="${k}" ${f.preset === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
        ${f.preset === 'custom' ? `<input type="date" id="ff" class="inp" value="${esc(f.from)}"><span class="muted">to</span><input type="date" id="ft" class="inp" value="${esc(f.to)}">` : ''}
        ${ms('people', 'Streamers', C.people, x => x.id, x => x.name)}
        ${ms('shows', 'Shows', C.shows, x => x.id, x => `${new Date(x.at).toLocaleDateString()} · ${x.label}`)}
        ${ms('platforms', 'Platform', [{ id: 'tiktok', n: 'TikTok' }, { id: 'whatnot', n: 'Whatnot' }], x => x.id, x => x.n)}
        <details class="ms"><summary>More filters${['dows', 'parts', 'skus', 'brands', 'suppliers', 'lots'].some(k => f[k].length) || f.hour_from !== '' || f.price_min !== '' || f.price_max !== '' ? ' <b>(on)</b>' : ''}</summary><div class="msl wide">
          <div class="small muted">Days</div><div class="row wrap">${DOW.map((n, i) => `<label class="chip"><input type="checkbox" data-dow="${i}" ${f.dows.includes(i) ? 'checked' : ''}> ${n}</label>`).join('')}</div>
          <div class="small muted">Time slot (every day, Eastern)</div><div class="row"><select id="fhf" class="inp"><option value="">Any</option>${[...Array(24).keys()].map(h => `<option value="${h}" ${String(f.hour_from) === String(h) ? 'selected' : ''}>${hourLbl(h)}</option>`).join('')}</select>
            <span class="muted">to</span><select id="fht" class="inp"><option value="">Any</option>${[...Array(24).keys()].map(h => h + 1).map(h => `<option value="${h % 24}" ${f.hour_to !== '' && Number(f.hour_to) === h % 24 ? 'selected' : ''}>${hourLbl(h)}</option>`).join('')}</select></div>
          <div class="grid"><label class="f">SKUs (comma separated)<input id="fsk" class="inp mono" value="${esc(f.skus.join(', '))}"></label>
            <label class="f">Parts (e.g. 1, 2)<input id="fpt" class="inp" value="${esc(f.parts.join(', '))}"></label>
            <label class="f">Sale price from ($)<input id="fpmin" type="number" min="0" class="inp" value="${esc(f.price_min)}"></label><label class="f">to ($)<input id="fpmax" type="number" min="0" class="inp" value="${esc(f.price_max)}"></label></div>
          <div class="row wrap">${ms('brands', 'Brands', C.brands, x => x, x => x)}${ms('suppliers', 'Suppliers', C.suppliers, x => x, x => x)}${ms('lots', 'Lots', C.lots, x => x.id, x => x.name)}</div>
          <div class="actions"><button class="btn primary" id="fmo">Apply</button></div></div></details>
        <button class="btn" id="fclr">Clear</button>
        <span style="flex:1"></span>
        <select id="fsv" class="inp"><option value="">Saved filters…</option>${d.saved.map(x => `<option value="${x.id}">${esc(x.name)}</option>`).join('')}</select>
        <button class="btn" id="fsave">Save</button>${d.saved.length ? '<button class="btn sm danger" id="fdel" title="Delete the picked saved filter">×</button>' : ''}
      </div></div>
    ${!T.shows ? `<div class="note">No finalized or matched shows match these filters yet. Numbers appear once a show's CSV is imported.</div>` : ''}
    ${T.missing_cost ? `<div class="note warn small">${T.missing_cost} order(s) have no cost yet (SKU had no stock layers).</div>` : ''}
    ${prod ? '<div class="note small">Product filters are on: hours, hourly pay, ad spend, net profit and per-hour stats show —.</div>' : ''}
    <div class="grid stats dash">${tiles.join('')}</div>
    ${perHour}
    <div class="panel"><div class="seg" id="btab">${[['show', 'Shows'], ['streamer', 'Streamers'], ['sku', 'SKUs'], ['brand', 'Brands']].map(([k, l]) => `<button data-v="${k}" class="${DASH.tab === k ? 'on' : ''}">${l}</button>`).join('')}</div>
      <p class="muted small" style="margin:6px 0">Click a row to filter to it.${DASH.tab === 'streamer' ? ' Sales go to whoever was working when the item was scanned (split if two were).' : ''}</p>
      <div id="bt" style="overflow-x:auto"></div></div>
    ${d.pending_shows.length ? `<div class="panel"><h3 style="margin-top:0">Shows without a CSV yet</h3>${d.pending_shows.map(s => `<a href="#shows/${s.id}" class="small">${new Date(s.at).toLocaleDateString()} · ${esc(s.label)}</a> ${stageTag(s.status)}`).join('<br>')}</div>` : ''}`;

  // ---- breakdown tables
  const bt = $('#bt');
  const showProfit = !sv;
  if (DASH.tab === 'show') bt.innerHTML = d.by_show.length ? `<table><tr><th>Date</th><th>Show</th><th>Platform</th><th>Streamers</th><th>Hours</th><th>Orders</th><th>Revenue</th>${showProfit ? '<th>Item profit</th><th>Net profit</th>' : ''}<th>Stage</th><th></th></tr>
      ${d.by_show.map(s => `<tr class="click" data-add="shows" data-v="${s.id}"><td class="small">${new Date(s.at).toLocaleDateString()}</td><td><b>${esc(s.label)}</b></td><td>${platName(s.platform)}</td><td class="small">${s.streamers.map(esc).join(', ')}</td>
        <td>${num(s.hours, 2)}</td><td>${num(s.orders)}</td><td>${money(s.revenue_cents)}</td>${showProfit ? `<td>${money(s.item_profit_cents)}</td><td>${s.net_profit_cents === null ? '—' : money(s.net_profit_cents)}</td>` : ''}
        <td>${stageTag(s.status)}</td><td><a href="#shows/${s.id}" class="small" data-stop>Details</a></td></tr>`).join('')}</table>` : '<p class="muted">No shows.</p>';
  if (DASH.tab === 'streamer') bt.innerHTML = d.by_streamer.length ? `<table><tr><th>Streamer</th><th>Hours</th><th>Orders</th><th>Revenue</th><th>Revenue / hr</th>${showProfit ? '<th>Item profit</th>' : ''}</tr>
      ${d.by_streamer.map(s => `<tr class="click" data-add="people" data-v="${s.id}"><td><b>${esc(s.name)}</b></td><td>${num(s.hours, 2)}</td><td>${num(s.orders, 1)}</td><td>${money(s.revenue_cents)}</td>
        <td>${s.hours ? money(Math.round(s.revenue_cents / s.hours)) : '—'}</td>${showProfit ? `<td>${money(s.item_profit_cents)}</td>` : ''}</tr>`).join('')}</table>` : '<p class="muted">No streamers.</p>';
  if (DASH.tab === 'sku') bt.innerHTML = d.by_sku.length ? `<table><tr><th>SKU</th><th>Product</th><th>Brand</th><th>Orders</th><th>Revenue</th><th>Avg sale</th>${showProfit ? '<th>Item profit</th><th>Below floor</th>' : ''}</tr>
      ${d.by_sku.map(s => `<tr class="click" data-add="skus" data-v="${s.sku}"><td class="mono">${s.sku}</td><td>${esc(s.name || '')}</td><td>${esc(s.brand || '')}</td><td>${num(s.orders, 1)}</td><td>${money(s.revenue_cents)}</td>
        <td>${s.orders ? money(Math.round(s.revenue_cents / s.orders)) : '—'}</td>${showProfit ? `<td>${money(s.item_profit_cents)}</td><td>${Number(s.below_floor) ? num(s.below_floor) : ''}</td>` : ''}</tr>`).join('')}</table>` : '<p class="muted">No SKUs.</p>';
  if (DASH.tab === 'brand') bt.innerHTML = d.by_brand.length ? `<table><tr><th>Brand</th><th>Orders</th><th>Revenue</th><th>Avg sale</th>${showProfit ? '<th>Item profit</th>' : ''}</tr>
      ${d.by_brand.map(s => `<tr class="click" data-add="brands" data-v="${esc(s.brand)}"><td><b>${esc(s.brand)}</b></td><td>${num(s.orders, 1)}</td><td>${money(s.revenue_cents)}</td>
        <td>${s.orders ? money(Math.round(s.revenue_cents / s.orders)) : '—'}</td>${showProfit ? `<td>${money(s.item_profit_cents)}</td>` : ''}</tr>`).join('')}</table>` : '<p class="muted">No brands.</p>';
  bt.querySelectorAll('[data-add]').forEach(tr => tr.onclick = e => {
    if (e.target.closest('[data-stop]')) return;
    const k = tr.dataset.add, v = ['shows', 'people'].includes(k) ? Number(tr.dataset.v) : tr.dataset.v;
    if (!f[k].map(String).includes(String(v))) f[k].push(v);
    saveF(); renderDashboard();
  });

  // ---- filter controls
  const apply = () => { saveF(); renderDashboard(); };
  $('#btab').querySelectorAll('button').forEach(b => b.onclick = () => { DASH.tab = b.dataset.v; renderDashboard(); });
  $('#fp').onchange = () => { f.preset = $('#fp').value; if (f.preset === 'custom' && !f.from) { const [a, b] = presetRange('last7'); f.from = a; f.to = b; } apply(); };
  if ($('#ff')) { $('#ff').onchange = () => { f.from = $('#ff').value; apply(); }; $('#ft').onchange = () => { f.to = $('#ft').value; apply(); }; }
  main.querySelectorAll('details.ms[data-ms]').forEach(det => {
    const k = det.dataset.ms;
    det.querySelectorAll('input[type=checkbox]').forEach(cb => cb.onchange = () => {
      const v = ['shows', 'people', 'lots'].includes(k) ? Number(cb.value) : cb.value;
      f[k] = cb.checked ? [...f[k], v] : f[k].filter(x => String(x) !== String(v));
      if (!det.closest('.msl.wide')) apply();
    });
  });
  $('#fmo').onclick = () => {
    f.dows = [...main.querySelectorAll('[data-dow]')].filter(x => x.checked).map(x => Number(x.dataset.dow));
    f.hour_from = $('#fhf').value; f.hour_to = $('#fht').value;
    if ((f.hour_from === '') !== (f.hour_to === '')) return toast('Pick both ends of the time slot', true);
    f.skus = $('#fsk').value.split(/[,\s]+/).map(x => x.trim()).filter(Boolean);
    if (f.skus.some(x => !/^\d{6}$/.test(x))) return toast('SKUs are 6 digits', true);
    f.parts = $('#fpt').value.split(/[,\s]+/).map(x => x.trim()).filter(Boolean).map(Number).filter(n => n > 0);
    f.price_min = $('#fpmin').value; f.price_max = $('#fpmax').value;
    apply();
  };
  $('#fclr').onclick = () => { DASH.f = blankF(); DASH.streamerView = false; apply(); };
  if ($('#svt')) $('#svt').onchange = e => { DASH.streamerView = e.target.checked; renderDashboard(); };
  $('#fsv').onchange = () => { const s = d.saved.find(x => String(x.id) === $('#fsv').value); if (s) { DASH.f = { ...blankF(), ...s.filters }; apply(); } };
  $('#fsave').onclick = () => {
    const m = modal(`<h2>Save these filters</h2><p class="muted small">Date presets stay relative: "Last 7 days" always means the last 7 days.</p>
      <label class="f">Name<input id="sn2" class="inp" placeholder="e.g. Ally last 30 days"></label><div class="err" id="se2"></div><div class="actions"><button class="btn primary" id="sy2">Save</button></div>`);
    m.querySelector('#sy2').onclick = async () => { try { await rpc('tfd_dash_save', { p_name: m.querySelector('#sn2').value, p_filters: f }); m.remove(); toast('Saved'); renderDashboard(); } catch (e) { m.querySelector('#se2').textContent = e.message; } };
  };
  if ($('#fdel')) $('#fdel').onclick = async () => {
    const id = $('#fsv').value; if (!id) return toast('Pick a saved filter first', true);
    const s = d.saved.find(x => String(x.id) === id);
    if (!confirm(`Delete the saved filter "${s.name}"?`)) return;
    await rpc('tfd_dash_delete', { p_id: Number(id) }); toast('Deleted'); renderDashboard();
  };
}
