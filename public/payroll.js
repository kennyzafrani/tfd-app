'use strict';
// Payroll (admins): everyone's hours and pay for a date range, edits with reasons, extra time / bonuses / adjustments,
// mark paid (Zelle), carried balances, export, and a person page (also the streamer view: sales, never profit or cost).

const PAY = { preset: 'thisweek', from: '', to: '' };
const pYmd = d => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
function payRange() {
  const t = new Date(); t.setHours(12, 0, 0, 0); const add = (d, n) => { const x = new Date(d); x.setDate(x.getDate() + n); return x; };
  const sun = add(t, -t.getDay());
  switch (PAY.preset) {
    case 'thisweek': return [pYmd(sun), pYmd(add(sun, 6))];
    case 'lastweek': return [pYmd(add(sun, -7)), pYmd(add(sun, -1))];
    case 'thismonth': return [pYmd(new Date(t.getFullYear(), t.getMonth(), 1)), pYmd(new Date(t.getFullYear(), t.getMonth() + 1, 0))];
    case 'lastmonth': return [pYmd(new Date(t.getFullYear(), t.getMonth() - 1, 1)), pYmd(new Date(t.getFullYear(), t.getMonth(), 0))];
    default: return [PAY.from, PAY.to];
  }
}
try { const v = JSON.parse(localStorage.getItem('tfd_pay_range')); if (v && v.preset) Object.assign(PAY, v); } catch {}
const savePay = () => { try { localStorage.setItem('tfd_pay_range', JSON.stringify(PAY)); } catch {} };
const hm = m => { m = Math.round(Number(m) || 0); return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`; };
const hrsTxt = m => (Math.round((Number(m) || 0) / 60 * 100) / 100).toFixed(2);
const tShort = iso => new Date(iso).toLocaleTimeString([], { hour: 'numeric', minute: '2-digit' });
const dShort = d => new Date(String(d).length === 10 ? d + 'T12:00' : d).toLocaleDateString([], { weekday: 'short', month: 'short', day: 'numeric' });
const pLocal = iso => { if (!iso) return ''; const d = new Date(iso); const p = n => String(n).padStart(2, '0'); return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}T${p(d.getHours())}:${p(d.getMinutes())}`; };
const lockTag = l => l ? ' <span class="tag" title="This day is in a paid period. A change becomes an adjustment on the next pay.">paid</span>' : '';

async function renderPayroll() {
  const [, a, b] = location.hash.slice(1).split('/');
  const main = $('#main');
  if (!['admin', 'claude'].includes(S.state.me.role)) { main.innerHTML = '<div class="panel"><h1>Payroll</h1><p class="muted">Admins only.</p></div>'; return; }
  try { if (a === 'person' && b) return payPerson(main, Number(b)); return payMain(main); }
  catch (e) { main.innerHTML = `<div class="note bad">${esc(e.message)}</div>`; }
}

function rangeBar() {
  return `<div class="panel"><div class="row wrap">
    <select id="pr" class="inp">${[['thisweek', 'This week'], ['lastweek', 'Last week'], ['thismonth', 'This month'], ['lastmonth', 'Last month'], ['custom', 'Custom dates']].map(([k, l]) => `<option value="${k}" ${PAY.preset === k ? 'selected' : ''}>${l}</option>`).join('')}</select>
    ${PAY.preset === 'custom' ? `<input type="date" id="pf" class="inp" value="${esc(PAY.from)}"><span class="muted">to</span><input type="date" id="pt" class="inp" value="${esc(PAY.to)}">` : ''}
    <span class="muted small" id="prl"></span></div></div>`;
}
function bindRange(redraw) {
  $('#pr').onchange = () => { const [f, t] = payRange(); PAY.preset = $('#pr').value; if (PAY.preset === 'custom') { PAY.from = f; PAY.to = t; } savePay(); redraw(); };
  if ($('#pf')) { $('#pf').onchange = () => { PAY.from = $('#pf').value; savePay(); redraw(); }; $('#pt').onchange = () => { PAY.to = $('#pt').value; savePay(); redraw(); }; }
  const [f, t] = payRange(); $('#prl').textContent = f && t ? `${dShort(f)} – ${dShort(t)}` : '';
}

// ================================================================ everyone
async function payMain(main) {
  const [from, to] = payRange();
  if (!from || !to) { main.innerHTML = `<div class="head"><h1>Payroll</h1></div>${rangeBar()}`; bindRange(renderPayroll); return; }
  const d = await rpc('tfd_payroll', { p_from: from, p_to: to });
  if (!stillOn('payroll')) return;
  const ppl = d.people;
  const sum = k => ppl.reduce((a, p) => a + Number(p.totals[k] || 0), 0);
  const bal = p => Number(p.carried_cents) + Number(p.totals.earned_cents) - Number(p.paid_cents);
  const hours = [];
  ppl.forEach(p => {
    p.shifts.forEach(s => hours.push({ kind: 'show', p, s, at: s.start_at }));
    p.clocks.forEach(c => hours.push({ kind: 'clock', p, s: c, at: c.clock_in }));
    p.entries.filter(e => e.kind === 'hours').forEach(e => hours.push({ kind: 'entry', p, s: e, at: e.date }));
  });
  hours.sort((x, y) => new Date(x.at) - new Date(y.at));
  const open = ppl.filter(p => p.open_clock);
  main.innerHTML = `<div class="head"><div><h1>Payroll</h1><p class="muted small">Everyone's hours and pay for the dates you pick. Only finalized shows count.</p></div>
      <div class="row wrap"><button class="btn" id="add">Add hours / bonus / adjustment</button><button class="btn" id="exp">Export CSV</button></div></div>
    ${rangeBar()}
    ${d.week_cut && ppl.some(p => p.role === 'packer') ? `<div class="note warn small">These dates cut through a workweek (weeks start ${esc(d.week_start)}). Packer overtime is figured per workweek, so pick whole weeks when paying packers.</div>` : ''}
    ${open.length ? `<div class="note warn small">Still clocked in: ${open.map(p => `<b>${esc(p.name)}</b> since ${new Date(p.open_clock.clock_in).toLocaleString([], { month: 'short', day: 'numeric', hour: 'numeric', minute: '2-digit' })} <button class="btn sm" data-fix="${p.open_clock.id}" data-pid="${p.profile_id}" data-in="${esc(p.open_clock.clock_in)}">Set clock-out</button>`).join(' · ')}. Open time isn't paid until it's closed.</div>` : ''}
    ${d.pending_shows.length ? `<div class="note small">Not counted yet (not finalized): ${d.pending_shows.map(s => `<a href="#shows/${s.id}">${esc(s.label)}</a> ${stageTag(s.status)}`).join(' · ')}</div>` : ''}
    <div class="panel"><h3 style="margin-top:0">Pay</h3><div style="overflow-x:auto"><table><tr><th>Person</th><th>Hours</th><th>Hourly pay</th><th>Overtime</th><th>Commission</th><th>Bonus / adj.</th><th>Earned</th><th>Carried in</th><th>Paid</th><th>Balance</th><th></th></tr>
      ${ppl.map(p => { const T = p.totals; return `<tr class="click" data-person="${p.profile_id}"><td><b>${esc(p.name)}</b> <span class="muted small">${p.role}${p.active ? '' : ', inactive'}</span></td>
        <td>${hrsTxt(T.minutes)}</td><td>${money(Number(T.show_pay_cents) + Number(T.pack_pay_cents) + Number(T.other_pay_cents))}</td><td>${T.ot_premium_cents ? money(T.ot_premium_cents) + ` <span class="muted small">(${hrsTxt(T.ot_minutes)} h)</span>` : '—'}</td>
        <td>${T.commission_cents ? money(T.commission_cents) : '—'}</td><td>${T.bonus_cents || T.adjustment_cents ? money(Number(T.bonus_cents) + Number(T.adjustment_cents)) : '—'}</td>
        <td><b>${money(T.earned_cents)}</b></td><td>${p.carried_cents ? money(p.carried_cents) : '—'}</td><td>${p.paid_cents ? money(p.paid_cents) : '—'}</td>
        <td><b style="${bal(p) > 0 ? '' : 'color:var(--ok)'}">${money(bal(p))}</b></td><td data-stop>${bal(p) > 0 ? `<button class="btn sm primary" data-pay="${p.profile_id}">Mark paid</button>` : ''}</td></tr>`; }).join('')
        || '<tr><td colspan="11" class="muted">No paid team members yet. Add them in Settings → People.</td></tr>'}
      ${ppl.length ? `<tr class="tot"><td><b>Total</b></td><td>${hrsTxt(sum('minutes'))}</td><td>${money(sum('show_pay_cents') + sum('pack_pay_cents') + sum('other_pay_cents'))}</td><td>${money(sum('ot_premium_cents'))}</td><td>${money(sum('commission_cents'))}</td>
        <td>${money(sum('bonus_cents') + sum('adjustment_cents'))}</td><td><b>${money(sum('earned_cents'))}</b></td><td>${money(ppl.reduce((a, p) => a + Number(p.carried_cents), 0))}</td><td>${money(ppl.reduce((a, p) => a + Number(p.paid_cents), 0))}</td>
        <td><b>${money(ppl.reduce((a, p) => a + bal(p), 0))}</b></td><td></td></tr>` : ''}</table></div>
      <p class="muted small" style="margin-bottom:0">Click a person for every shift, show and payment behind their numbers.</p></div>
    <div class="panel"><h3 style="margin-top:0">Hours</h3><div style="overflow-x:auto"><table><tr><th>Day</th><th>Person</th><th>What</th><th>Time</th><th>Hours</th><th>Pay</th><th></th></tr>
      ${hours.map(h => h.kind === 'show' ? `<tr><td>${dShort(h.s.start_at)}</td><td>${esc(h.p.name)}</td><td><a href="#shows/${h.s.show_id}">${esc(h.s.show)}</a> <span class="muted small">${h.s.role}</span></td>
          <td>${tShort(h.s.start_at)} – ${tShort(h.s.end_at)}</td><td>${hm(h.s.minutes)}</td><td>${money(h.s.pay_cents)}${lockTag(h.s.locked)}</td><td><button class="btn sm" data-es="${h.s.id}">Edit</button></td></tr>`
        : h.kind === 'clock' ? `<tr><td>${dShort(h.s.clock_in)}</td><td>${esc(h.p.name)}</td><td>Packing${h.s.edited_by ? ` <span class="muted small" title="${esc(h.s.note || '')}">edited by ${esc(h.s.edited_by)}</span>` : ''}</td>
          <td>${tShort(h.s.clock_in)} – ${tShort(h.s.clock_out)}</td><td>${hm(h.s.minutes)}</td><td>${money(h.s.pay_cents)}${lockTag(h.s.locked)}</td><td><button class="btn sm" data-ec="${h.s.id}">Edit</button></td></tr>`
        : `<tr><td>${dShort(h.s.date)}</td><td>${esc(h.p.name)}</td><td>Other paid time <span class="muted small">${esc(h.s.reason)}</span></td><td>—</td><td>${hm(h.s.minutes)}</td><td>${money(h.s.amount_cents)}${lockTag(h.s.locked)}</td><td></td></tr>`).join('')
        || '<tr><td colspan="7" class="muted">No hours in these dates.</td></tr>'}</table></div>
      <div class="actions" style="justify-content:flex-start"><button class="btn sm" id="addclk">Add packing time</button></div>
      <p class="muted small" style="margin-bottom:0">Show hours are entered on each show (Step 2) and count once it's finalized. Every edit needs a reason and is in the Activity Log.</p></div>`;
  bindRange(renderPayroll);
  const find = (arr, id) => arr.find(x => x.id === id);
  main.querySelectorAll('tr[data-person]').forEach(tr => tr.onclick = e => { if (!e.target.closest('[data-stop]')) location.hash = `#payroll/person/${tr.dataset.person}`; });
  main.querySelectorAll('[data-pay]').forEach(b => b.onclick = () => { const p = ppl.find(x => x.profile_id === Number(b.dataset.pay)); markPaid(p, from, to, bal(p)); });
  main.querySelectorAll('[data-es]').forEach(b => b.onclick = () => { const id = Number(b.dataset.es); const p = ppl.find(x => find(x.shifts, id)); editShift(find(p.shifts, id), p); });
  main.querySelectorAll('[data-ec]').forEach(b => b.onclick = () => { const id = Number(b.dataset.ec); const p = ppl.find(x => find(x.clocks, id)); editClock(find(p.clocks, id), p); });
  main.querySelectorAll('[data-fix]').forEach(b => b.onclick = () => editClock({ id: Number(b.dataset.fix), clock_in: b.dataset.in, clock_out: null, open: true }, ppl.find(x => x.profile_id === Number(b.dataset.pid))));
  $('#addclk').onclick = () => editClock(null, null, ppl.filter(p => p.role === 'packer'));
  $('#add').onclick = () => addEntry(ppl);
  $('#exp').onclick = () => downloadCSV(`TFD payroll ${from} to ${to}.csv`,
    ['Person', 'Role', 'Hours', 'Show pay', 'Packing pay', 'Other paid time', 'Overtime premium', 'Commission', 'Bonuses', 'Adjustments', 'Earned', 'Carried in', 'Paid', 'Balance', 'Payments'],
    ppl.map(p => { const T = p.totals; return [p.name, p.role, hrsTxt(T.minutes), dl(T.show_pay_cents), dl(T.pack_pay_cents), dl(T.other_pay_cents), dl(T.ot_premium_cents), dl(T.commission_cents),
      dl(T.bonus_cents), dl(T.adjustment_cents), dl(T.earned_cents), dl(p.carried_cents), dl(p.paid_cents), dl(bal(p)),
      p.payments.map(x => `${x.paid_on} ${x.method} $${dl(x.amount_cents)}`).join('; ')]; }));
}

// ================================================================ modals
function editShift(s, p) {
  const m = modal(`<h2>Edit ${esc(p.name)}'s hours</h2><p class="muted small">${esc(s.show)} · show ran ${s.show_start_at ? `${dShort(s.show_start_at)} ${tShort(s.show_start_at)} – ${tShort(s.show_end_at)}` : '(no show times)'}</p>
    ${s.locked ? '<div class="note warn small">This day is in a paid period. The shift stays as paid and the difference is added as an adjustment on the next pay.</div>' : ''}
    <div class="grid"><label class="f">Start<input type="datetime-local" id="es1" class="inp" value="${pLocal(s.start_at)}"></label><label class="f">End<input type="datetime-local" id="es2" class="inp" value="${pLocal(s.end_at)}"></label></div>
    <label class="f">Reason<input id="esr" class="inp" placeholder="e.g. stayed 30 min after"></label><div class="err" id="ese"></div>
    <div class="actions" style="justify-content:space-between"><button class="btn danger" id="esd">Remove shift</button><button class="btn primary" id="esy">Save</button></div>`);
  const go = async del => {
    try {
      await rpc('tfd_pay_shift_edit', { p_shift: s.id, p_start: del ? null : new Date(m.querySelector('#es1').value).toISOString(), p_end: del ? null : new Date(m.querySelector('#es2').value).toISOString(), p_reason: m.querySelector('#esr').value });
      m.remove(); toast(s.locked ? 'Adjustment added' : 'Saved'); renderPayroll();
    } catch (e) { m.querySelector('#ese').textContent = e.message; }
  };
  m.querySelector('#esy').onclick = () => go(false);
  m.querySelector('#esd').onclick = () => { if (!m.querySelector('#esr').value.trim()) return m.querySelector('#ese').textContent = 'A reason is required'; if (confirm('Remove this shift?')) go(true); };
}

function editClock(c, p, packers) {
  const isNew = !c;
  const m = modal(`<h2>${isNew ? 'Add packing time' : c.open ? `Set ${esc(p.name)}'s clock-out` : `Edit ${esc(p.name)}'s packing time`}</h2>
    ${c && c.locked ? '<div class="note warn small">This day is in a paid period. The entry stays as paid and the difference is added as an adjustment on the next pay.</div>' : ''}
    ${isNew ? `<label class="f">Packer<select id="ecp" class="inp">${(packers || []).map(x => `<option value="${x.profile_id}">${esc(x.name)}</option>`).join('')}</select></label>` : ''}
    <div class="grid"><label class="f">Clock in<input type="datetime-local" id="ec1" class="inp" value="${c ? pLocal(c.clock_in) : ''}"></label><label class="f">Clock out<input type="datetime-local" id="ec2" class="inp" value="${c && c.clock_out ? pLocal(c.clock_out) : ''}"></label></div>
    <label class="f">Reason<input id="ecr" class="inp" placeholder="${c && c.open ? 'e.g. forgot to clock out' : 'e.g. paper timesheet'}"></label><div class="err" id="ece"></div>
    <div class="actions" style="justify-content:space-between">${!isNew ? '<button class="btn danger" id="ecd">Remove</button>' : '<span></span>'}<button class="btn primary" id="ecy">Save</button></div>`);
  if (isNew && !(packers || []).length) m.querySelector('#ece').textContent = 'No packers yet. Add one in Settings → People.';
  const go = async del => {
    try {
      const i = m.querySelector('#ec1').value, o = m.querySelector('#ec2').value;
      if (!del && (!i || !o)) throw new Error('Enter the clock-in and clock-out time');
      await rpc('tfd_pay_clock_save', { p_id: isNew ? null : c.id, p_profile: isNew ? Number(m.querySelector('#ecp').value) : null,
        p_in: del ? null : new Date(i).toISOString(), p_out: del ? null : new Date(o).toISOString(), p_reason: m.querySelector('#ecr').value });
      m.remove(); toast('Saved'); renderPayroll();
    } catch (e) { m.querySelector('#ece').textContent = e.message; }
  };
  m.querySelector('#ecy').onclick = () => go(false);
  if (m.querySelector('#ecd')) m.querySelector('#ecd').onclick = () => { if (!m.querySelector('#ecr').value.trim()) return m.querySelector('#ece').textContent = 'A reason is required'; if (confirm('Remove this packing time?')) go(true); };
}

function addEntry(ppl, only) {
  const list = only ? [only] : ppl;
  const m = modal(`<h2>Add to pay</h2>
    <div class="grid"><label class="f">Person<select id="ap" class="inp">${list.map(p => `<option value="${p.profile_id}">${esc(p.name)} (${p.role})</option>`).join('')}</select></label>
      <label class="f">Type<select id="ak" class="inp"><option value="hours">Other paid time (hours)</option><option value="bonus">Bonus</option><option value="adjustment">Adjustment (+ or −)</option></select></label>
      <label class="f">Date<input type="date" id="ad" class="inp" value="${pYmd(new Date())}"></label>
      <label class="f" id="ahw">Hours<input type="number" id="ah" class="inp" min="0" step="0.25" placeholder="e.g. 3.5"></label>
      <label class="f" id="aaw" style="display:none">Amount ($)<input type="number" id="aa" class="inp" step="0.01" placeholder="e.g. 25 or -10"></label></div>
    <p class="muted small" id="ahelp">Paid at the person's hourly rate for that day, e.g. an inventory count day.</p>
    <label class="f">Reason<input id="ar" class="inp"></label><div class="err" id="ae"></div><div class="actions"><button class="btn primary" id="ay">Add</button></div>`);
  const kind = () => m.querySelector('#ak').value;
  m.querySelector('#ak').onchange = () => { const h = kind() === 'hours'; m.querySelector('#ahw').style.display = h ? '' : 'none'; m.querySelector('#aaw').style.display = h ? 'none' : '';
    m.querySelector('#ahelp').textContent = h ? "Paid at the person's hourly rate for that day, e.g. an inventory count day." : kind() === 'bonus' ? 'Added on top of pay.' : 'A correction: positive adds to pay, negative takes it off.'; };
  m.querySelector('#ay').onclick = async () => {
    try {
      await rpc('tfd_pay_entry_add', { p_profile: Number(m.querySelector('#ap').value), p_kind: kind(), p_date: m.querySelector('#ad').value || null,
        p_minutes: kind() === 'hours' ? Math.round(Number(m.querySelector('#ah').value || 0) * 60) : null,
        p_amount_cents: kind() === 'hours' ? null : Math.round(Number(m.querySelector('#aa').value || 0) * 100), p_reason: m.querySelector('#ar').value });
      m.remove(); toast('Added'); renderPayroll();
    } catch (e) { m.querySelector('#ae').textContent = e.message; }
  };
}

function markPaid(p, from, to, balance) {
  const m = modal(`<h2>Mark ${esc(p.name)} paid</h2>
    <div class="grid"><label class="f">For work from<input type="date" id="mf" class="inp" value="${from}"></label><label class="f">to<input type="date" id="mt" class="inp" value="${to}"></label>
      <label class="f">Paid on<input type="date" id="mo" class="inp" value="${pYmd(new Date())}"></label><label class="f">Amount ($)<input type="number" id="ma" class="inp" step="0.01" min="0" value="${(Math.max(balance, 0) / 100).toFixed(2)}"></label>
      <label class="f">Method<input id="mm" class="inp" value="Zelle"></label><label class="f">Note (optional)<input id="mn" class="inp"></label></div>
    <p class="muted small">Balance owed: ${money(balance)}. Paying less is fine; the rest carries to the next pay. Once marked paid, the period's hours lock: later fixes become adjustments.</p>
    <div class="err" id="me"></div><div class="actions"><button class="btn primary" id="my">Mark paid</button></div>`);
  m.querySelector('#my').onclick = async () => {
    try { await rpc('tfd_pay_mark_paid', { p_profile: p.profile_id, p_from: m.querySelector('#mf').value || null, p_to: m.querySelector('#mt').value || null, p_paid_on: m.querySelector('#mo').value || null,
        p_amount_cents: Math.round(Number(m.querySelector('#ma').value || 0) * 100), p_method: m.querySelector('#mm').value, p_note: m.querySelector('#mn').value });
      m.remove(); toast('Marked paid'); renderPayroll(); } catch (e) { m.querySelector('#me').textContent = e.message; }
  };
}

// ================================================================ person page (also the streamer view: no profit or cost)
async function payPerson(main, id) {
  const [from, to] = payRange();
  const [p, all] = await Promise.all([rpc('tfd_pay_person', { p_profile: id, p_from: from, p_to: to }), rpc('tfd_payroll', { p_from: from, p_to: to })]);
  if (!stillOn('payroll')) return;
  const row = all.people.find(x => x.profile_id === id) || { carried_cents: 0, paid_cents: 0, payments: [] };
  const T = p.totals, bal = Number(row.carried_cents) + Number(T.earned_cents) - Number(row.paid_cents), S2 = p.sales;
  const line = (l, v, sub) => `<tr><td>${l}${sub ? ` <span class="muted small">${sub}</span>` : ''}</td><td style="text-align:right">${v}</td></tr>`;
  main.innerHTML = `<div class="head"><div><a href="#payroll" class="small">← Payroll</a><h1>${esc(p.name)} <span class="muted small">${p.role}</span></h1></div>
      <div class="row wrap"><button class="btn" id="padd">Add hours / bonus / adjustment</button>${bal > 0 ? '<button class="btn primary" id="ppay">Mark paid</button>' : ''}</div></div>
    ${rangeBar()}
    <div class="grid" style="grid-template-columns:repeat(auto-fit,minmax(300px,1fr))">
      <div class="panel"><h3 style="margin-top:0">Pay for these dates</h3><table class="kv">
        ${T.show_minutes ? line('Show hours', money(T.show_pay_cents), `${hrsTxt(T.show_minutes)} h`) : ''}
        ${T.pack_minutes ? line('Packing hours', money(T.pack_pay_cents), `${hrsTxt(T.pack_minutes)} h`) : ''}
        ${T.ot_premium_cents ? line('Overtime premium', money(T.ot_premium_cents), `${hrsTxt(T.ot_minutes)} h over the weekly limit`) : ''}
        ${T.other_minutes ? line('Other paid time', money(T.other_pay_cents), `${hrsTxt(T.other_minutes)} h`) : ''}
        ${p.role === 'streamer' ? line('Commission', money(T.commission_cents)) : ''}
        ${line('Adjustments', money(T.adjustment_cents))}${line('Bonuses', money(T.bonus_cents))}
        <tr class="tot"><td><b>Earned</b></td><td style="text-align:right"><b>${money(T.earned_cents)}</b></td></tr>
        ${line('Carried in from before', money(row.carried_cents))}${line('Already paid', money(row.paid_cents))}
        <tr class="tot"><td><b>Balance</b></td><td style="text-align:right"><b>${money(bal)}</b></td></tr></table></div>
      ${S2 ? `<div class="panel"><h3 style="margin-top:0">Sales ${S2.estimate ? '<span class="tag">includes estimates</span>' : ''}</h3><div class="grid stats">
          <div class="panel"><div class="muted small">Revenue</div><b class="big">${money(S2.revenue_cents)}</b></div>
          <div class="panel"><div class="muted small">Items sold</div><b class="big">${Number(S2.orders).toFixed(0)}</b></div>
          <div class="panel"><div class="muted small">Revenue / hour</div><b class="big">${S2.hours ? money(Math.round(S2.revenue_cents / S2.hours)) : '—'}</b></div>
          <div class="panel"><div class="muted small">Items / hour</div><b class="big">${S2.hours ? (S2.orders / S2.hours).toFixed(1) : '—'}</b></div></div>
        <table><tr><th>Show</th><th>Show length (h)</th><th>Items</th><th>Revenue</th><th>Per show hour</th></tr>${S2.by_show.map(s => `<tr><td><a href="#shows/${s.id}">${esc(s.label)}</a></td><td>${Number(s.hours || 0).toFixed(2)}</td><td>${Number(s.orders).toFixed(0)}</td><td>${money(s.revenue_cents)}</td><td>${s.hours ? money(Math.round(s.revenue_cents / s.hours)) : '—'}</td></tr>`).join('') || '<tr><td colspan="5" class="muted">No shows.</td></tr>'}</table>
        <p class="muted small" style="margin-bottom:0">Safe to show ${esc(p.name)}: sales only.</p></div>` : ''}</div>
    ${p.shifts.length ? `<div class="panel"><h3 style="margin-top:0">Show hours</h3><table><tr><th>Day</th><th>Show</th><th>Time</th><th>Hours</th><th>Rate</th><th>Pay</th><th></th></tr>
      ${p.shifts.map(s => `<tr><td>${dShort(s.start_at)}</td><td><a href="#shows/${s.show_id}">${esc(s.show)}</a></td><td>${tShort(s.start_at)} – ${tShort(s.end_at)}</td><td>${hm(s.minutes)}</td><td>${money(s.rate_cents)}</td><td>${money(s.pay_cents)}${lockTag(s.locked)}</td><td><button class="btn sm" data-es="${s.id}">Edit</button></td></tr>`).join('')}</table></div>` : ''}
    ${p.commission.length ? `<div class="panel"><h3 style="margin-top:0">Commission</h3><table><tr><th>Show</th><th>Orders</th><th>Sales after fees</th><th>Rate</th><th>Commission</th></tr>
      ${p.commission.map(c => `<tr><td><a href="#shows/${c.show_id}">${esc(c.show)}</a></td><td>${c.orders}</td><td>${money(c.sales_after_fees_cents)}</td><td>${c.commission_bp / 100}%</td><td>${money(c.commission_cents)}</td></tr>`).join('')}</table></div>` : ''}
    ${p.clocks.length || p.role === 'packer' ? `<div class="panel"><div class="head"><h3 style="margin:0">Packing hours</h3><button class="btn sm" id="pclk">Add packing time</button></div>
      <table><tr><th>Day</th><th>Clock in – out</th><th>Hours</th><th>Rate</th><th>Pay</th><th></th></tr>
      ${p.clocks.map(c => `<tr><td>${dShort(c.clock_in)}</td><td>${tShort(c.clock_in)} – ${tShort(c.clock_out)}${c.edited_by ? ` <span class="muted small" title="${esc(c.note || '')}">edited</span>` : ''}</td><td>${hm(c.minutes)}</td><td>${money(c.rate_cents)}</td><td>${money(c.pay_cents)}${lockTag(c.locked)}</td><td><button class="btn sm" data-ec="${c.id}">Edit</button></td></tr>`).join('') || '<tr><td colspan="6" class="muted">None.</td></tr>'}</table>
      ${p.weeks.length ? `<p class="small">${p.weeks.map(w => `Week of ${dShort(w.week_of)}: ${hrsTxt(w.minutes)} h${Number(w.ot_minutes) ? `, <b>${hrsTxt(w.ot_minutes)} h overtime</b> (+${money(w.premium_cents)})` : ''}`).join(' · ')}</p>` : ''}</div>` : ''}
    ${p.entries.length ? `<div class="panel"><h3 style="margin-top:0">Other time, bonuses and adjustments</h3><table><tr><th>Day</th><th>Type</th><th>Detail</th><th>Amount</th><th></th></tr>
      ${p.entries.map(e => `<tr><td>${dShort(e.date)}</td><td>${e.kind === 'hours' ? 'Other paid time' : e.kind === 'bonus' ? 'Bonus' : 'Adjustment'}</td><td class="small">${e.kind === 'hours' ? `${hm(e.minutes)} h at ${money(e.rate_cents)} · ` : ''}${esc(e.reason)} <span class="muted">by ${esc(e.by)}</span></td>
        <td>${money(e.amount_cents)}${lockTag(e.locked)}</td><td>${e.locked ? '' : `<button class="btn sm danger" data-de="${e.id}">Remove</button>`}</td></tr>`).join('')}</table></div>` : ''}
    <div class="panel"><h3 style="margin-top:0">Payments (all time)</h3><table><tr><th>Paid on</th><th>For</th><th>Amount</th><th>Method</th><th></th></tr>
      ${p.payments.map(x => `<tr><td>${dShort(x.paid_on)}</td><td>${dShort(x.period_from)} – ${dShort(x.period_to)}</td><td>${money(x.amount_cents)}</td><td>${esc(x.method)}${x.note ? ` <span class="muted small">${esc(x.note)}</span>` : ''}</td><td><button class="btn sm danger" data-dp="${x.id}">Remove</button></td></tr>`).join('') || '<tr><td colspan="5" class="muted">No payments recorded.</td></tr>'}</table></div>`;
  bindRange(renderPayroll);
  const me = { profile_id: p.profile_id, name: p.name, role: p.role };
  if ($('#padd')) $('#padd').onclick = () => addEntry([me], me);
  if ($('#ppay')) $('#ppay').onclick = () => markPaid(me, from, to, bal);
  if ($('#pclk')) $('#pclk').onclick = () => editClock(null, null, [me]);
  main.querySelectorAll('[data-es]').forEach(b => b.onclick = () => editShift(p.shifts.find(s => s.id === Number(b.dataset.es)), me));
  main.querySelectorAll('[data-ec]').forEach(b => b.onclick = () => editClock(p.clocks.find(s => s.id === Number(b.dataset.ec)), me));
  const del = (fn, idk, what) => main.querySelectorAll(`[data-${idk}]`).forEach(b => b.onclick = () => {
    const m = modal(`<h2>Remove this ${what}?</h2><label class="f">Reason<input id="dr" class="inp"></label><div class="err" id="de2"></div><div class="actions"><button class="btn danger" id="dy">Remove</button></div>`);
    m.querySelector('#dy').onclick = async () => { try { await rpc(fn, { p_id: Number(b.dataset[idk]), p_reason: m.querySelector('#dr').value }); m.remove(); toast('Removed'); renderPayroll(); } catch (e) { m.querySelector('#de2').textContent = e.message; } };
  });
  del('tfd_pay_entry_delete', 'de', 'entry'); del('tfd_pay_payment_delete', 'dp', 'payment (its period unlocks)');
}
