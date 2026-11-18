// End-to-end: finalized show → Fulfillment queue, pick list, scanner cards; packer signs in, clocks in, scans label + items, photo (fake camera),
// finish; problem → admin resolves; lookup with photo; unfinalize blocked. Synthetic data only.
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
const OUT = __dirname; const BASE = 'http://localhost:8899';
const H = JSON.parse(fs.readFileSync(path.join(OUT, 'headers.json'), 'utf8'));
const shot = (page, n) => page.screenshot({ path: path.join(OUT, n + '.png'), fullPage: true });
const ok = (c, m) => { if (!c) throw new Error('FAILED: ' + m); console.log('ok -', m); };
const q = v => /[",\n]/.test(String(v)) ? '"' + String(v).replace(/"/g, '""') + '"' : String(v);
const csvOf = (head, rows) => '﻿' + [head, ...rows.map(r => head.map(h => r[h] ?? ''))].map(r => r.map(q).join(',')).join('\r\n');

(async () => {
  const browser = await chromium.launch({ args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream'] });
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 900 }, permissions: ['camera'] });
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
  fs.writeFileSync(lot, 'Supplier,Invoice #,Date,Brand,Model #,Color Code,Lens Size,UPC,Product Name,Color Name,Invoiced Qty,Received Qty,Unit Cost,Retail Price,Weight (oz),Category,Subcategory,Specs,Image URL,Bin\r\n' + [
    'Designer Eyes,INV-1,2026-11-10,Ray-Ban,RB3025,001,58,8053672000001,Aviator Classic Gold,Gold/Green,6,6,50.00,163.00,1.5,Bags & Accessories,Sunglasses,,,Q-01',
    'Designer Eyes,INV-1,2026-11-10,Gucci,GG0061S,001,56,889652000003,Gucci Square,Black/Grey,6,6,85.00,390.00,1.3,Bags & Accessories,Sunglasses,,,Q-03'].join('\r\n'));
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr'); await page.click('#newr'); await page.setInputFiles('#rf', lot); await page.click('#rgo');
  await page.waitForSelector('#confirm:not([disabled])'); await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');

  // show: 3 pulls → 2 packages (buyer A gets 2 items under one tracking #)
  await page.goto(BASE + '/#shows/new'); await page.waitForSelector('#ty'); await page.click('#addp'); await page.fill('#nm', 'Pack night'); await page.click('#sv'); await page.waitForSelector('#scan');
  for (const sk of ['100001', '100002', '100001']) { await page.fill('#scan', sk); await page.press('#scan', 'Enter'); await page.waitForTimeout(3100); }
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  await page.click('#end'); await page.click('#ey'); await page.waitForSelector('#cgo');
  const now = new Date();
  const p = n => String(n).padStart(2, '0');
  const tt = o => ({ 'Order ID': o.id + '\t', 'Order Status': 'To ship', 'Seller SKU': String(o.pull), 'Variation': String(o.pull), 'Product Name': 'Part 1 Pack Night', 'Quantity': '1',
    'SKU Subtotal Before Discount': '60', 'SKU Seller Discount': '0', 'Original Shipping Fee': '0', 'Shipping Fee Seller Discount': '0',
    'Created Time': `${p(now.getMonth() + 1)}/${p(now.getDate())}/${now.getFullYear()} 1:00:00 PM\t`, 'Tracking ID': o.trk, 'Package ID': 'PKG' + o.trk.slice(-3) + '\t', 'Buyer Username': o.buyer, 'Recipient': o.name });
  const f = path.join(OUT, 'To_Ship_pack.csv');
  fs.writeFileSync(f, csvOf(H.tiktok, [tt({ id: 'O1', pull: 1, trk: '9400111111111111111111', buyer: 'ann_l', name: 'Ann Lee' }), tt({ id: 'O2', pull: 2, trk: '9400111111111111111111', buyer: 'ann_l', name: 'Ann Lee' }),
    tt({ id: 'O3', pull: 3, trk: '9400222222222222222222', buyer: 'bo_k', name: 'Bo Kim' })]));
  await page.setInputFiles('#cf', f); await page.click('#cgo'); await page.waitForSelector('#otab');
  const dd = (await page.inputValue('#sst')).slice(0, 10);
  await page.fill('#sst', dd + 'T10:00'); await page.fill('#sen', dd + 'T12:00');
  while (await page.locator('#hrs [data-rm]').count()) await page.locator('#hrs [data-rm]').first().click();
  await page.click('#hs'); await page.waitForTimeout(900);
  await page.waitForSelector('#fz:not([disabled])'); await page.click('#fz'); await page.click('#fy'); await page.waitForSelector('#unf');
  const showUrl = page.url();

  // admin: queue, pick list, cards
  await page.goto(BASE + '/#fulfillment'); await page.waitForSelector('text=Queue');
  ok(/Packages left\s*2/.test(await page.textContent('.stats')), 'queue: 2 packages left');
  ok((await page.textContent('#main')).includes('Pack night'), 'left by show lists the show');
  await shot(page, 'f1-queue');
  await page.goto(BASE + '/#fulfillment/picklist'); await page.waitForSelector('text=Pick list ·');
  const pl = await page.textContent('.printable');
  ok(pl.includes('100001') && pl.includes('Q-01') && /\b2\b/.test(pl), 'pick list: 2 × 100001 from Q-01');
  await page.goto(BASE + '/#fulfillment/cards'); await page.waitForSelector('.pcardx svg');
  ok((await page.locator('.pcardx svg').count()) === 4, '4 scanner cards drawn');
  await shot(page, 'f2-cards');
  await page.evaluate(() => rpc('tfd_set_on_stage', { p_sku: '100001', p_on: true }));

  // packer
  await page.evaluate(async () => { await signOut(); });
  await page.goto(BASE); await page.waitForSelector('#lu'); await page.fill('#lu', 'pat'); await page.fill('#lp', 'password123'); await page.click('#lf button.primary');
  await page.waitForSelector('.tabs');
  const tabs = await page.textContent('.tabs');
  ok(tabs.includes('Fulfillment') && !tabs.includes('Inventory') && !tabs.includes('Shows'), 'packer sees Fulfillment only: ' + tabs.trim().replace(/\s+/g, ' '));
  await page.goto(BASE + '/#fulfillment'); await page.waitForSelector('.packst #scan');
  await page.waitForSelector('text=Clock in?'); ok(true, 'asked to clock in (not required)'); await page.click('#cn');
  ok((await page.textContent('#clk')).includes('Not clocked in') && (await page.textContent('#cout')) === 'Clock in', 'packing screen opens without clocking in');
  ok((await page.locator('#pq tr').count()) === 3, 'packer sees the whole queue (2 packages)');
  await page.click('#cout'); await page.waitForFunction(() => document.querySelector('#cout').textContent === 'Clock out');
  ok((await page.textContent('#clk')).includes('Clocked in'), 'clock in is its own button');
  const sc = async v => { await page.fill('#scan', v); await page.press('#scan', 'Enter'); await page.waitForTimeout(500); };
  await sc('9999999999');
  ok((await page.textContent('#msg')).includes('No unpacked package'), 'unknown label');
  await sc('420100019400111111111111111111');           // USPS-style scan: prefix + tracking
  ok((await page.textContent('#pkg')).includes('Ann Lee'), 'label scan opens Ann Lee\'s package');
  ok(!(await page.textContent('#pkg')).includes('$'), 'no prices on the packing screen');
  await sc('100099');                                     // wrong item
  ok((await page.textContent('#msg')).includes('WRONG ITEM'), 'wrong item blocked');
  await sc('100001');
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  await sc('100001');
  ok((await page.textContent('#msg')).includes('TOO MANY'), 'one too many blocked');
  await sc('8056597000002'.slice(0, 0) + '100002'); await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  ok(await page.isDisabled('#fin'), 'finish locked until there is a photo');
  await sc('TFD-DONE');
  ok((await page.textContent('#msg')).toLowerCase().includes('photo'), 'FINISH card refuses without a photo');
  await page.waitForFunction(() => document.querySelector('#vid') && document.querySelector('#vid').videoWidth > 0, null, { timeout: 10000 });
  await sc('TFD-SNAP'); await page.waitForTimeout(1500);
  ok((await page.textContent('#msg')).includes('Photo saved'), 'TAKE PICTURE card takes the photo');
  await shot(page, 'f3-packing');
  await sc('TFD-DONE'); await page.waitForTimeout(800);
  ok((await page.textContent('#msg')).includes('packed'), 'FINISH card packs it');
  // Bo Kim: problem
  await sc('9400222222222222222222');
  ok((await page.textContent('#pkg')).includes('stage table'), 'stage sample note shows on the item');
  await sc('TFD-PROBLEM'); await page.waitForSelector('#pn'); await page.fill('#pn', 'Item damaged: scratched lens'); await page.click('#py'); await page.waitForTimeout(700);
  ok((await page.textContent('#msg')).includes('Problem'), 'problem sent to Kenny');
  await page.setViewportSize({ width: 820, height: 1180 }); await sc('9400222222222222222222'); await shot(page, 'f4-ipad'); await page.setViewportSize({ width: 1280, height: 900 });
  await page.click('#leave');
  await page.click('#cout'); await page.waitForFunction(() => document.querySelector('#cout').textContent === 'Clock in');
  // open from the queue (no label scan)
  await page.locator('#pq [data-oq]').first().click(); await page.waitForTimeout(300);
  ok((await page.textContent('#pkg')).includes('Bo Kim') && (await page.textContent('#pq')).includes('Open'), 'open a package from the queue');
  await page.click('#leave');

  // admin again
  await page.evaluate(async () => { await signOut(); });
  await page.goto(BASE); await page.waitForSelector('#lu'); await page.fill('#lu', 'kenny@example.com'); await page.fill('#lp', 'password123'); await page.click('#lf button.primary');
  await page.waitForSelector('.tabs'); await page.goto(BASE + '/#fulfillment'); await page.waitForSelector('text=Queue');
  ok(/Problems\s*1/.test(await page.textContent('.stats')) && (await page.textContent('#main')).includes('scratched lens'), 'problem shows for Kenny');
  await page.click('[data-rs]'); await page.fill('#rn', 'Swapped the pair'); await page.click('#ry'); await page.waitForTimeout(700);
  ok(/Problems\s*0/.test(await page.textContent('.stats')), 'resolved');
  await page.fill('#lq', 'O1'); await page.click('#lgo'); await page.waitForSelector('#lres img[data-ph]');
  await page.waitForFunction(() => { const i = document.querySelector('#lres img[data-ph]'); return i && i.naturalWidth > 0; }, null, { timeout: 8000 });
  ok(true, 'lookup by order # shows the packing photo');
  await shot(page, 'f5-lookup');
  // stock shows sold-not-packed for Bo's unit; unfinalize blocked
  const st = await page.evaluate(() => rpc('tfd_stock').then(r => r.find(x => x.sku === '100001')));
  ok(st.sold_not_packed === 1 && st.in_bin === st.on_hand + 1, 'stock: 1 sold-not-packed, still in the bin');
  await page.goto(showUrl); await page.waitForSelector('#unf'); await page.click('#unf'); await page.fill('#ur', 'test'); await page.click('#uy'); await page.waitForTimeout(600);
  ok((await page.textContent('#ue')).includes('Packing has started'), 'unfinalize blocked once packing started');
  // admin bulk pack: select all → mark packed
  await page.evaluate(() => document.querySelectorAll('.modal-bg').forEach(m => m.remove()));
  await page.goto(BASE + '/#fulfillment'); await page.waitForSelector('#selall');
  ok(await page.isDisabled('#bulk'), 'bulk button off until something is picked');
  await page.check('#selall'); ok((await page.textContent('#bulk')) === 'Mark 1 packed', 'select all picks the queue');
  await page.click('#bulk'); await page.click('#by'); await page.waitForSelector('text=Zero pending');
  ok(/Packages left\s*0/.test(await page.textContent('.stats')), 'bulk packed: queue empty');
  ok(!errs.length, 'no page errors ' + JSON.stringify(errs));
  await browser.close(); console.log('PACK E2E PASSED');
})().catch(e => { console.error(e.message); process.exit(1); });
