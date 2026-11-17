// End-to-end: TikTok + Whatnot CSV import, fixes, finalize, unfinalize, remove CSV. Synthetic rows in the real column layouts.
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
const OUT = __dirname; const BASE = 'http://localhost:8899';
const H = JSON.parse(fs.readFileSync(path.join(OUT, 'headers.json'), 'utf8'));
const shot = (page, n) => page.screenshot({ path: path.join(OUT, n + '.png'), fullPage: true });
const ok = (c, m) => { if (!c) throw new Error('FAILED: ' + m); console.log('ok -', m); };
const q = v => /[",\n]/.test(String(v)) ? '"' + String(v).replace(/"/g, '""') + '"' : String(v);
const csvOf = (head, rows) => '﻿' + [head, ...rows.map(r => head.map(h => r[h] ?? ''))].map(r => r.map(q).join(',')).join('\r\n');
const pad = n => String(n).padStart(2, '0');
function etTT(d) {   // TikTok wall clock in Eastern: MM/DD/YYYY h:mm:ss AM
  const p = Object.fromEntries(new Intl.DateTimeFormat('en-US', { timeZone: 'America/New_York', year: 'numeric', month: '2-digit', day: '2-digit', hour: 'numeric', minute: '2-digit', second: '2-digit', hour12: true }).formatToParts(d).map(x => [x.type, x.value]));
  return `${p.month}/${p.day}/${p.year} ${p.hour}:${p.minute}:${p.second} ${p.dayPeriod}\t`;
}
const utcWN = d => d.toISOString().replace('T', ' ').slice(0, 23);

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 }, acceptDownloads: true });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message));
  await page.goto(BASE);
  await page.fill('#sn', 'Kenny'); await page.fill('#se_', 'kenny@example.com'); await page.fill('#sp', 'password123'); await page.click('#sb');
  await page.waitForSelector('.tabs');
  await page.evaluate(() => server('POST', '/api/users', { name: 'Ally', login: 'ally', password: 'password123', role: 'streamer' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'platform.tiktok', p_value: { label: 'TikTok', pct_sale_bp: 600, pct_ship_bp: 600, fixed_cents: 0, typical_ship_cents: 800 }, p_effective_from: null, p_reason: 'test' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'platform.whatnot', p_value: { label: 'Whatnot', pct_sale_bp: 800, pct_ship_bp: 0, fixed_cents: 30, typical_ship_cents: 800 }, p_effective_from: null, p_reason: 'test' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'inventory', p_value: { required_fields: ['received_qty'], show_suggest_max_units: 5, show_suggest_min_shows: 8, low_stock_default: 2 }, p_effective_from: null, p_reason: 'test' }));
  const lot = path.join(OUT, 'lot.csv');
  fs.writeFileSync(lot, 'Supplier,Invoice #,Date,Brand,Model #,Color Code,Lens Size,UPC,Product Name,Color Name,Invoiced Qty,Received Qty,Unit Cost,Retail Price,Weight (oz),Category,Subcategory,Specs,Image URL,Bin\r\n' + [
    'Designer Eyes,INV-1,2026-11-10,Ray-Ban,RB3025,001,58,8053672000001,Aviator Classic Gold,Gold/Green,6,6,50.00,163.00,1.5,Bags & Accessories,Sunglasses,,,Q-01',
    'Designer Eyes,INV-1,2026-11-10,Gucci,GG0061S,001,56,889652000003,Gucci Square,Black/Grey,6,6,85.00,390.00,1.3,Bags & Accessories,Sunglasses,,,Q-03'].join('\r\n'));
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr'); await page.click('#newr'); await page.setInputFiles('#rf', lot); await page.click('#rgo');
  await page.waitForSelector('#confirm:not([disabled])'); await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');
  // Step 2: show times + hours (rows removed except the first, which gets the full show)
  const hoursFull = async () => {
    const dd = (await page.inputValue('#sst')).slice(0, 10), st = dd + 'T10:00', en = dd + 'T12:00';
    await page.fill('#sst', st); await page.fill('#sen', en);
    while (await page.locator('#hrs [data-rm]').count() > 1) { await page.locator('#hrs [data-rm]').last().click(); }
    const ins = page.locator('#hrs input[type="datetime-local"]');
    await ins.nth(0).fill(st); await ins.nth(1).fill(en);
    await page.click('#hs'); await page.waitForTimeout(900);
  };
  const onHand = sku => page.evaluate(s => rpc('tfd_stock').then(r => r.find(x => x.sku === s).on_hand), sku);

  // ---- TikTok live mapping: P1 #1-3, P2 #1
  await page.goto(BASE + '/#shows/new'); await page.waitForSelector('#ty'); await page.click('#addp'); await page.fill('#nm', 'TT import'); await page.click('#sv'); await page.waitForSelector('#scan');
  const scan = async sku => { await page.fill('#scan', sku); await page.press('#scan', 'Enter'); await page.waitForTimeout(3100); };
  for (const sk of ['100001', '100002', '100001']) await scan(sk);
  await page.click('#np'); await page.click('#ay'); await page.waitForTimeout(600);
  await scan('100002');
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  const showUrl = page.url();
  await page.click('#end'); await page.click('#ey'); await page.waitForSelector('#cgo');
  const now = Date.now();
  const tt = (o) => ({ 'Order ID': o.id + '\t', 'Order Status': 'To ship', 'Order Substatus': 'Awaiting collection', 'Seller SKU': String(o.pull), 'Variation': String(o.pull), 'Product Name': `Part ${o.part} Test Night - NO CANCELS`,
    'Quantity': '1', 'SKU Unit Original Price': o.price, 'SKU Subtotal Before Discount': o.price, 'SKU Platform Discount': o.pd || '0', 'SKU Seller Discount': '0', 'SKU Subtotal After Discount': String(o.price - (o.pd || 0)),
    'Shipping Fee After Discount': o.ship, 'Original Shipping Fee': o.ship, 'Shipping Fee Seller Discount': '0', 'Shipping Fee Platform Discount': '0', 'Created Time': etTT(new Date(now + o.min * 60000)),
    'Paid Time': etTT(new Date(now + o.min * 60000)), 'Tracking ID': 'TRK' + o.pkg, 'Package ID': 'PKG' + o.pkg + '\t', 'Buyer Username': o.buyer, 'Recipient': 'T*** B***', 'Order Channel': 'LIVE' });
  const ttRows = [
    tt({ id: 'T1', part: 1, pull: 1, price: 52, ship: '4.29', min: 1, pkg: 1, buyer: 'buyer_a' }),
    tt({ id: 'T2', part: 1, pull: 2, price: 120, ship: '1.30', min: 1, pkg: 2, buyer: 'buyer_b', pd: 5 }),
    tt({ id: 'T3', part: 2, pull: 1, price: 95, ship: '0', min: 2, pkg: 2, buyer: 'buyer_b' }),
    tt({ id: 'T4', part: 1, pull: 9, price: 40, ship: '0', min: 2, pkg: 3, buyer: 'buyer_c' })];
  // P1 #3 has no order → released
  const ttFile = path.join(OUT, 'To_Ship_order-test.csv'); fs.writeFileSync(ttFile, csvOf(H.tiktok, ttRows));
  const wrong = path.join(OUT, 'wrong.csv'); fs.writeFileSync(wrong, csvOf(H.whatnot, [{ order_id: 'x', product_name: 'Random Pull #1' }]));
  await page.setInputFiles('#cf', wrong); await page.click('#cgo'); await page.waitForTimeout(300);
  ok((await page.textContent('#ce')).includes('Whatnot file'), 'wrong platform file rejected');
  const oh1 = await onHand('100001'), oh2 = await onHand('100002');
  await page.setInputFiles('#cf', ttFile); await page.click('#cgo'); await page.waitForSelector('#otab');
  const st = await page.textContent('#imp .stats');
  ok(/Matched\s*3/.test(st) && /Need a match\s*1/.test(st) && /Left out\s*0/.test(st) && /Pulls with no order\s*1/.test(st), 'import summary: 3 matched, 1 needs match, 0 other show, 1 no order: ' + st.replace(/\s+/g, ' '));
  ok(await page.isDisabled('#fz'), 'finalize locked while an order needs a match');
  await shot(page, 'i1-needs-attention');
  // fix: use SKU for T4 (an order whose # was never scanned)
  ok(/Add as P\d+ #\d+|Use SKU/.test(await page.textContent('[data-sko]')) && (await page.textContent('[data-ig]')) === 'Delete', 'fix buttons: add as pull / Delete: ' + await page.textContent('[data-sko]'));
  await page.fill('[data-sk]', '100001'); await page.click('[data-sko]'); await page.waitForSelector('#otab'); await page.waitForTimeout(400);
  ok(!(await page.textContent('#fin')).includes('need a match'), 'match blocker cleared after the fix');
  await page.click('#otab button[data-v="matched"]');
  const mt = await page.textContent('#olist');
  ok(mt.includes('$3.38') && mt.includes('$0.49'), 'T1 fee $3.38 (6% of 52 + 4.29), commission $0.49');
  ok(mt.includes('$7.28'), 'T2 fee uses the pre-discount price (6% of 120 + 1.30 = 7.28)');
  await shot(page, 'i2-matched');
  // finalize
  ok(await page.isDisabled('#fz') && (await page.textContent('#fin')).includes('start and end time'), 'finalize needs the show times');
  // a streamer row past the show end is flagged
  const dd = (await page.inputValue('#sst')).slice(0, 10);
  await page.fill('#sst', dd + 'T10:00'); await page.fill('#sen', dd + 'T12:00');
  { const ins = page.locator('#hrs input[type="datetime-local"]'); await ins.nth(0).fill(dd + 'T10:00'); await ins.nth(1).fill(dd + 'T13:00'); }
  ok((await page.textContent('#hrs')).includes('outside the show') && (await page.textContent('#shr')).includes('2.00'), 'row past the show end flagged on screen; show hours 2.00');
  await page.click('#hs'); await page.waitForTimeout(700); ok((await page.textContent('#he')).includes('Outside the show'), 'save refused: outside the show');
  await hoursFull();
  await page.fill('#ads', '12.50'); await page.click('#adsv'); await page.waitForSelector('#otab'); await page.waitForTimeout(400);
  ok((await page.inputValue('#ads')) === '12.50', 'ad spend saved');
  await page.click('#fz'); await page.waitForSelector('#fy'); await shot(page, 'i3-finalize-confirm'); await page.click('#fy'); await page.waitForSelector('#unf');
  ok((await onHand('100001')) === oh1 - 2 && (await onHand('100002')) === oh2 - 2, `inventory deducted (100001: ${oh1}→${await onHand('100001')}, 100002: ${oh2}→${await onHand('100002')})`);
  ok((await page.textContent('h1')).includes('Finalized'), 'stage Finalized');
  await shot(page, 'i4-finalized');
  // unfinalize
  await page.click('#unf'); await page.click('#uy'); await page.waitForTimeout(300);
  ok((await page.textContent('#ue')).includes('reason'), 'unfinalize needs a reason');
  await page.fill('#ur', 'test'); await page.click('#uy'); await page.waitForSelector('#fz');
  ok((await onHand('100001')) === oh1 && (await onHand('100002')) === oh2, 'units back after unfinalize');
  // remove CSV
  await page.click('#crm'); await page.fill('#xr', 'test'); await page.click('#xy'); await page.waitForSelector('#cgo');
  ok((await page.evaluate(() => rpc('tfd_stock').then(r => r.reduce((a, x) => a + x.held, 0)))) === 4, 'remove CSV: the 4 scanned pulls held again');
  await page.setInputFiles('#cf', ttFile); await page.click('#cgo'); await page.waitForSelector('#otab');
  await page.fill('[data-sk]', '100001'); await page.click('[data-sko]'); await page.waitForTimeout(600);
  await hoursFull(); await page.waitForSelector('#fz:not([disabled])');
  await page.click('#fz'); await page.click('#fy'); await page.waitForSelector('#unf');

  // ---- Whatnot random pull show
  await page.goto(BASE + '/#shows/new'); await page.waitForSelector('#ty'); await page.click('#pl button[data-v="whatnot"]'); await page.click('#addp'); await page.click('#sv'); await page.waitForSelector('#scan');
  await scan('100002'); await scan('100001');
  await page.click('#gv'); await scan('100002');
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  await page.click('#end'); await page.click('#ey'); await page.waitForSelector('#cgo');
  const wn = o => ({ order_id: o.id, order_numeric_id: '1', buyer_username: o.buyer, product_name: o.name, product_description: 'No Cancellations!', product_quantity: '1', original_item_price: o.price,
    placed_at: o.failed ? '' : utcWN(new Date(Date.now() + 60000)), cancelled_or_failed: o.failed || '', bundled: 'False', tracking_code: o.trk || '', shipment_id: o.trk ? 'S' + o.trk : '',
    shipping_address: 'Test Buyer, 1 Main St, Town, NY, 10001, US', postal_code: '10001', sku: '', cost_per_item: '', total_cost: '' });
  const wnFile = path.join(OUT, 'whatnot-test.csv');
  fs.writeFileSync(wnFile, csvOf(H.whatnot, [wn({ id: 'W1', name: 'Random Pull #1', price: '61.0', trk: '9400', buyer: 'wa' }), wn({ id: 'W2', name: 'Random Pull #2', price: '0', failed: 'failed', buyer: 'wb' }),
    wn({ id: 'W2b', name: 'Random Pull #2', price: '58.0', trk: '9401', buyer: 'wc' }), wn({ id: 'W3', name: 'Random Pull #3', price: '0', trk: '9402', buyer: 'wd' }),
    wn({ id: 'W9', name: '$25 Whatnot Gift Card', price: '0', buyer: 'we' })]));
  await page.setInputFiles('#cf', wnFile); await page.click('#cgo'); await page.waitForSelector('#otab');
  const ws = await page.textContent('#imp .stats');
  ok(/Matched\s*3/.test(ws) && /Need a match\s*0/.test(ws) && /Failed \/ cancelled\s*1/.test(ws) && /Left out\s*1/.test(ws), 'Whatnot: 3 matched (incl. giveaway), 1 failed, gift card left out: ' + ws.replace(/\s+/g, ' '));
  await shot(page, 'i5-whatnot');
  await hoursFull(); await page.waitForSelector('#fz:not([disabled])');
  await page.click('#fz'); await page.click('#fy'); await page.waitForSelector('#unf');
  ok((await page.textContent('#imp')).includes('final'), 'Whatnot show finalized');

  // ---- Dashboard
  await page.goto(BASE + '/#dashboard'); await page.waitForTimeout(2500);
  const dt = await page.textContent('.dash');
  ok(dt.includes('$426.00'), 'dashboard revenue = 307 (TikTok) + 119 (Whatnot) = $426.00');
  { const iv = await page.evaluate(() => rpc('tfd_inventory_value').then(v => money(v.cost_cents))); ok(dt.includes('Inventory value') && dt.includes(iv) && !dt.includes('Sold near floor'), 'Inventory value tile ' + iv + ', near-floor tile gone'); }
  ok(!(await page.textContent('h1 + p')).includes('estimates'), 'all finalized: no estimate label');
  await shot(page, 'd1-dashboard');
  await page.click('#btab button[data-v="streamer"]'); await page.waitForTimeout(300);
  await page.locator('#bt tr[data-add="people"]').first().click(); await page.waitForSelector('#svt');
  await page.check('#svt'); await page.waitForSelector('.dash');
  const sv = await page.textContent('.dash');
  ok(sv.includes('Total pay') && !sv.includes('Item profit') && !sv.includes('Cost of goods'), 'streamer view: pay, no profit or cost');
  await shot(page, 'd2-streamer-view');
  await page.click('#fclr'); await page.waitForSelector('.dash');
  await page.selectOption('#fp', 'last7'); await page.waitForSelector('.dash');
  ok((await page.textContent('h1 + p')).includes('compared with'), 'last 7 days compared with the 7 before');
  await page.click('#fsave'); await page.fill('#sn2', 'Last week'); await page.click('#sy2'); await page.waitForTimeout(700);
  ok((await page.textContent('#fsv')).includes('Last week'), 'saved filter');
  await page.setViewportSize({ width: 390, height: 844 }); await page.goto(BASE + '/#dashboard'); await page.waitForSelector('.dash'); await shot(page, 'd3-phone');
  await page.setViewportSize({ width: 1400, height: 900 });
  await page.goto(BASE + '/#inventory/stock'); await page.waitForSelector('#stbl');
  ok(!errs.length, 'no page errors ' + JSON.stringify(errs));
  await browser.close(); console.log('IMPORT E2E PASSED');
})().catch(e => { console.error(e.message); process.exit(1); });
