// End-to-end: Payroll tab. Finalized show (Ally 2h at $30 + 1%), Pat packing clock, then the UI: summary, edit shift with reason,
// add bonus, mark paid (locks), person page (sales, no profit), CSV export, packer can't see it. Synthetic data only.
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
const OUT = __dirname; const BASE = 'http://localhost:8899';
const LOG = path.join(OUT, 'pay.log'); fs.writeFileSync(LOG, '');
const log = m => fs.appendFileSync(LOG, m + '\n');
const shot = (page, n) => page.screenshot({ path: path.join(OUT, n + '.png'), fullPage: true });
const ok = (c, m) => { if (!c) throw new Error('FAILED: ' + m); log('ok - ' + m); };

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, acceptDownloads: true });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message)); page.on('dialog', d => d.accept());
  await page.goto(BASE);
  await page.fill('#sn', 'Kenny'); await page.fill('#se_', 'kenny@example.com'); await page.fill('#sp', 'password123'); await page.click('#sb');
  await page.waitForSelector('.tabs');
  await page.evaluate(() => server('POST', '/api/users', { name: 'Ally', login: 'ally', password: 'password123', role: 'streamer' }));
  await page.evaluate(() => server('POST', '/api/users', { name: 'Pat', login: 'pat', password: 'password123', role: 'packer' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'platform.tiktok', p_value: { label: 'TikTok', pct_sale_bp: 600, pct_ship_bp: 600, fixed_cents: 0, typical_ship_cents: 800 }, p_effective_from: null, p_reason: 'test' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'inventory', p_value: { required_fields: ['received_qty'], show_suggest_max_units: 5, show_suggest_min_shows: 8, low_stock_default: 2 }, p_effective_from: null, p_reason: 'test' }));
  const lot = path.join(OUT, 'lot.csv');
  fs.writeFileSync(lot, 'Supplier,Invoice #,Date,Brand,Model #,Color Code,Lens Size,UPC,Product Name,Color Name,Invoiced Qty,Received Qty,Unit Cost,Retail Price,Weight (oz),Category,Subcategory,Specs,Image URL,Bin\r\n' +
    'Designer Eyes,INV-1,2026-11-10,Ray-Ban,RB3025,001,58,8053672000001,Aviator Classic Gold,Gold/Green,6,6,50.00,163.00,1.5,Bags & Accessories,Sunglasses,,,Q-01');
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr'); await page.click('#newr'); await page.setInputFiles('#rf', lot); await page.click('#rgo');
  await page.waitForSelector('#confirm:not([disabled])'); await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');
  // lot report: new-arrivals presentation (floor + MSRP, no cost)
  await page.waitForSelector('#lrep');
  const [rep] = await Promise.all([page.waitForEvent('popup'), page.click('#lrep')]);
  await rep.waitForSelector('.slide:not(.cover)');
  const rt = await rep.textContent('body');
  ok(rt.includes('Just landed') && rt.includes('FLOOR') && rt.includes('MSRP') && rt.includes('$163') && !/cost/i.test(rt), 'lot report: cover + slide with floor and MSRP, no cost');
  await rep.setViewportSize({ width: 1100, height: 850 }); await rep.screenshot({ path: path.join(OUT, 'lotreport.png'), fullPage: true });
  await rep.close();

  const ids = await page.evaluate(async () => {
    const ppl = await rpc('tfd_profiles_list', {}).catch(() => null);
    return ppl;
  });
  const people = await page.evaluate(() => rpc('tfd_payroll', { p_from: '2026-01-01', p_to: '2026-12-31' }));
  const ally = people.people.find(p => p.name === 'Ally').profile_id, pat = people.people.find(p => p.name === 'Pat').profile_id;
  // finalized show: Ally streams 2h ending now, one $100 sale
  const t = await page.evaluate(async ({ ally }) => {
    const s = await rpc('tfd_show_save', { p_id: null, p: { type: 'live', platform: 'tiktok', name: 'Pay night', fees: { pct_sale_bp: 600, pct_ship_bp: 600, fixed_cents: 0 },
      people: [{ profile_id: ally, role: 'streamer', hourly_cents: 3000, commission_bp: 100 }] } });
    const sid = typeof s === 'object' ? (s.id || s.show_id) : s;
    await rpc('tfd_scan', { p_show: sid, p_sku: '100001' });
    await new Promise(r => setTimeout(r, 1200));
    await rpc('tfd_show_end', { p_show: sid, p_confirm: 'SHOW OVER' });
    await rpc('tfd_show_import', { p_show: sid, p_file_name: 'x.csv', p_file_path: null, p_rows: [{ line: 1, order_id: 'PAY1', product_name: 'Part 1', part: 1, pull_no: 1, sale_cents: 10000, ship_cents: 0, tracking: 'T9', package_key: 'T9' }] });
    const end = new Date(); end.setSeconds(0, 0); const start = new Date(end - 2 * 3600e3);
    await rpc('tfd_show_hours_save', { p_show: sid, p_start: start.toISOString(), p_end: end.toISOString(), p_shifts: [{ profile_id: ally, start_at: start.toISOString(), end_at: end.toISOString() }] });
    await rpc('tfd_show_finalize', { p_show: sid });
    return { sid, start: start.toISOString(), end: end.toISOString() };
  }, { ally });
  // Pat: 3h packing earlier, entered by admin
  await page.evaluate(async ({ pat, t }) => {
    const e = new Date(new Date(t.start) - 3600e3), s = new Date(e - 3 * 3600e3);
    await rpc('tfd_pay_clock_save', { p_id: null, p_profile: pat, p_in: s.toISOString(), p_out: e.toISOString(), p_reason: 'paper timesheet' });
  }, { pat, t });

  // ---- Payroll tab (This week)
  await page.evaluate(() => { try { localStorage.removeItem('tfd_pay_range'); } catch {} });
  await page.goto(BASE + '/#payroll'); await page.waitForSelector('text=Hours');
  const rowTxt = async n => (await page.locator('tr[data-person]', { hasText: n }).textContent()).replace(/\s+/g, ' ');
  let a = await rowTxt('Ally');
  ok(a.includes('2.00') && a.includes('$60.00') && a.includes('$0.94') && a.includes('$60.94'), 'Ally: 2h, $60 + $0.94 commission = $60.94 · ' + a);
  const patRate = await page.evaluate(({ pat }) => rpc('tfd_pay_person', { p_profile: pat, p_from: '2026-01-01', p_to: '2026-12-31' }).then(x => x.clocks[0].rate_cents), { pat });
  const pr = await rowTxt('Pat');
  ok(pr.includes('3.00') && pr.includes('$' + (patRate * 3 / 100).toFixed(2)), `Pat: 3h at $${patRate / 100}`);
  ok((await page.locator('#main table').nth(1).locator('tr').count()) === 3, 'hours list: show shift + packing clock');
  await shot(page, 'p1-payroll');

  // edit Ally's shift: reason required, then 1h
  await page.locator('[data-es]').first().click(); await page.waitForSelector('#es1');
  const st = await page.inputValue('#es1');
  const d1 = new Date(st); d1.setHours(d1.getHours() + 1); const pad = n => String(n).padStart(2, '0');
  await page.fill('#es2', `${d1.getFullYear()}-${pad(d1.getMonth() + 1)}-${pad(d1.getDate())}T${pad(d1.getHours())}:${pad(d1.getMinutes())}`);
  await page.click('#esy'); await page.waitForTimeout(500);
  ok(/reason/i.test(await page.textContent('#ese')), 'edit needs a reason: ' + await page.textContent('#ese'));
  await page.fill('#esr', 'left early'); await page.click('#esy'); await page.waitForSelector('#es1', { state: 'detached' });
  await page.waitForTimeout(600);
  a = await rowTxt('Ally'); ok(a.includes('1.00') && a.includes('$30.94'), 'after edit: 1h → $30.94');

  // add a $25 bonus
  await page.click('#add'); await page.waitForSelector('#ak');
  await page.selectOption('#ap', String(ally)); await page.selectOption('#ak', 'bonus'); await page.fill('#aa', '25'); await page.fill('#ar', 'great show');
  await page.click('#ay'); await page.waitForSelector('#ak', { state: 'detached' }); await page.waitForTimeout(600);
  a = await rowTxt('Ally'); ok(a.includes('$25.00') && a.includes('$55.94'), 'bonus added → $55.94');

  // mark paid $50: balance $5.94, period locks
  await page.locator('tr[data-person]', { hasText: 'Ally' }).locator('[data-pay]').click(); await page.waitForSelector('#ma');
  ok(await page.inputValue('#ma') === '55.94', 'amount defaults to balance');
  await page.fill('#ma', '50'); await page.click('#my'); await page.waitForSelector('#ma', { state: 'detached' }); await page.waitForTimeout(600);
  a = await rowTxt('Ally'); ok(a.includes('$50.00') && a.includes('$5.94'), 'paid $50 → balance $5.94');
  ok((await page.textContent('#main')).includes('paid'), 'locked tag shown');
  await shot(page, 'p2-paid');

  // CSV export
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#exp')]);
  const csv = fs.readFileSync(await dl.path(), 'utf8');
  ok(/Ally,streamer,1\.00/.test(csv) && csv.includes('55.94') && csv.includes('Zelle'), 'CSV export has Ally and the payment');

  // person page: sales, no profit/cost
  await page.locator('tr[data-person]', { hasText: 'Ally' }).locator('td').first().click(); await page.waitForSelector('text=Pay for these dates');
  const pp = await page.textContent('#main');
  ok(pp.includes('Revenue') && pp.includes('$100.00') && pp.includes('Pay night'), 'person page: sales and the show');
  ok(!/profit|cost/i.test(pp), 'person page: no profit or cost');
  ok(pp.includes('Zelle') && pp.includes('great show'), 'payment + bonus listed');
  await shot(page, 'p3-person');
  // remove the payment → unlocks
  await page.locator('[data-dp]').first().click(); await page.fill('#dr', 'test'); await page.click('#dy'); await page.waitForSelector('#dy', { state: 'detached' }); await page.waitForTimeout(600);
  ok(!(await page.textContent('#main')).includes('Zelle'), 'payment removed');

  // custom range works
  await page.goto(BASE + '/#payroll'); await page.waitForSelector('#pr'); await page.selectOption('#pr', 'custom'); await page.waitForSelector('#pf');
  await page.fill('#pf', '2026-10-04'); await page.dispatchEvent('#pf', 'change'); await page.waitForTimeout(700);
  ok((await page.textContent('#main')).includes('Payroll'), 'custom range renders');

  // packer can't open payroll
  await page.evaluate(async () => { await signOut(); });
  await page.goto(BASE); await page.waitForSelector('#lu'); await page.fill('#lu', 'pat'); await page.fill('#lp', 'password123'); await page.click('#lf button.primary');
  await page.waitForSelector('.tabs');
  ok(!(await page.textContent('.tabs')).includes('Payroll'), 'packer has no Payroll tab');
  await page.goto(BASE + '/#payroll'); await page.waitForTimeout(800);
  ok(!(await page.textContent('#main')).includes('Mark paid'), 'packer sees no payroll data');

  ok(errs.length === 0, 'no page errors ' + errs.join(' | '));
  log('PAY E2E PASSED'); await browser.close(); process.exit(0);
})().catch(e => { log(e.message); process.exit(1); });
