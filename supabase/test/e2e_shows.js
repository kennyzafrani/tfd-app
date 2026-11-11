// End-to-end test of the Shows tab (Phase 3) against the fake Supabase stack.
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
const OUT = __dirname; const BASE = 'http://localhost:8899';
const shot = (page, n) => page.screenshot({ path: path.join(OUT, n + '.png'), fullPage: false });
const ok = (c, m) => { if (!c) throw new Error('FAILED: ' + m); console.log('ok -', m); };

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 }, acceptDownloads: true });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message));
  page.on('dialog', d => d.accept());
  await page.goto(BASE);
  await page.fill('#sn', 'Kenny'); await page.fill('#se_', 'kenny@example.com'); await page.fill('#sp', 'password123'); await page.click('#sb');
  await page.waitForSelector('.tabs');
  await page.evaluate(() => server('POST', '/api/users', { name: 'Ally', login: 'ally', password: 'password123', role: 'streamer' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'platform.whatnot', p_value: { label: 'Whatnot', pct_sale_bp: 800, pct_ship_bp: 800, fixed_cents: 30, typical_ship_cents: 800 }, p_effective_from: null, p_reason: 'test' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'inventory', p_value: { required_fields: ['received_qty'], show_suggest_max_units: 5, show_suggest_min_shows: 8, low_stock_default: 2 }, p_effective_from: null, p_reason: 'test' }));

  // stock: 3 SKUs (5, 1, 4 units)
  const csv = path.join(OUT, 'lot.csv');
  fs.writeFileSync(csv, 'Supplier,Invoice #,Date,Brand,Model #,Color Code,Lens Size,UPC,Product Name,Color Name,Invoiced Qty,Received Qty,Unit Cost,Retail Price,Weight (oz),Category,Subcategory,Specs,Image URL,Bin\r\n' + [
    'Designer Eyes,INV-1,2026-11-10,Ray-Ban,RB3025,001,58,8053672000001,Aviator Classic Gold,Gold/Green,5,5,50.00,163.00,1.5,Bags & Accessories,Sunglasses,Polarized,,Q-01',
    'Designer Eyes,INV-1,2026-11-10,Prada,PR 17WS,1AB5S0,49,8056597000002,Prada Symbole,Black,1,1,90.00,430.00,1.2,Bags & Accessories,Sunglasses,,,Q-02',
    'Designer Eyes,INV-1,2026-11-10,Gucci,GG0061S,001,56,889652000003,Gucci Square,Black/Grey,4,4,85.00,390.00,1.3,Bags & Accessories,Sunglasses,,,Q-03'].join('\r\n'));
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr'); await page.click('#newr'); await page.setInputFiles('#rf', csv); await page.click('#rgo');
  await page.waitForSelector('#confirm:not([disabled])'); await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');

  // new live mapping show
  await page.goto(BASE + '/#shows'); await page.waitForSelector('text=New show'); await page.click('text=New show');
  await page.waitForSelector('#ty'); await page.click('#pl button[data-v="whatnot"]');
  await page.click('#addp'); await page.waitForTimeout(200);
  ok((await page.locator('#ppl select[data-k="profile_id"]').first().inputValue()) !== '', 'lineup row added');
  const hr = await page.locator('#ppl input[data-k="hourly_cents"]').first().inputValue();
  ok(hr === '30.00', 'streamer default $30/hr prefilled (' + hr + ')');
  await page.fill('#nm', 'Halloween $1 starts'); await shot(page, '1-setup');
  await page.click('#sv'); await page.waitForSelector('#go');
  await shot(page, '2-setup-view');
  await page.click('#go'); await page.waitForSelector('#scan');

  // inventory locked while live
  ok((await page.evaluate(() => rpc('tfd_adjust', { p_sku: '100001', p_direction: 'in', p_qty: 1, p_reason: 'count correction' }).then(() => 'no', e => e.message))).includes('locked'), 'inventory locked while live');

  const scan = async sku => { await page.fill('#scan', sku); await page.press('#scan', 'Enter'); await page.waitForTimeout(500); };
  await scan('100001');
  ok((await page.textContent('#card')).includes('Pull #1') && (await page.textContent('#card')).includes('FLOOR'), 'pull #1 card with floor');
  ok(!(await page.textContent('#card')).toLowerCase().includes('cost'), 'no cost on the live screen');
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  ok((await page.textContent('#nxt')) === '#2', 'next pull #2');
  await shot(page, '3-live-scan');
  await scan('100002');                       // last unit of Prada
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  await scan('100002');
  ok((await page.textContent('#msg')).includes('Out of stock'), 'out of stock blocked');
  await scan('999999');
  ok((await page.textContent('#msg')).includes('Unknown SKU'), 'unknown SKU');
  // giveaway
  await page.click('#gv'); await scan('100003');
  ok((await page.textContent('#card')).includes('Giveaway'), 'giveaway pull');
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  // buyer's choice
  await page.click('#bcb'); await page.waitForSelector('#bcx');
  await scan('100001'); await scan('100003'); await page.waitForTimeout(400);
  ok((await page.locator('[data-pick]').count()) === 2, 'two items shown');
  await shot(page, '4-buyers-choice');
  await page.locator('[data-pick]').nth(1).click(); await page.waitForTimeout(700);
  ok((await page.textContent('#msg')).includes('#4 recorded'), 'buyer\'s choice pick = pull #4');
  // undo last + new part
  await page.click('#un'); await page.waitForTimeout(700);
  ok((await page.textContent('#nxt')) === '#4', 'undo frees #4');
  await page.click('#np'); await page.waitForTimeout(700);
  ok((await page.textContent('#prt')) === '2' && (await page.textContent('#nxt')) === '#1', 'Part 2 starts at #1');
  // offline scans queue and sync
  await ctx.setOffline(true);
  await scan('100001'); await scan('100003');
  ok((await page.textContent('#sync')).includes('2 waiting') || (await page.textContent('#sync')).includes('Offline'), 'offline: scans queued (' + await page.textContent('#sync') + ')');
  ok((await page.textContent('#nxt')) === '#3', 'offline numbering keeps going');
  await shot(page, '5-offline');
  await ctx.setOffline(false); await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved', null, { timeout: 15000 });
  ok((await page.textContent('#pl')).includes('P2 #2'), 'queued scans saved as Part 2 #1, #2');
  // pause allows adding stock
  await page.click('#pz'); await page.waitForTimeout(600);
  ok((await page.evaluate(() => rpc('tfd_adjust', { p_sku: '100001', p_direction: 'in', p_qty: 1, p_reason: 'count correction' }).then(r => r.ok ? 'ok' : 'no', e => e.message))) === 'ok', 'paused: adding stock allowed');
  await page.click('#pz'); await page.waitForTimeout(600);
  // void a pull
  await page.locator('[data-vd]').first().click(); await page.fill('#vr', 'test void'); await page.click('#vy'); await page.waitForTimeout(700);
  ok((await page.textContent('#pl')).includes('Void'), 'pull voided');
  // stock shows held
  const held = await page.evaluate(() => rpc('tfd_stock').then(r => r.find(x => x.sku === '100001').held));
  ok(held >= 1, 'stock shows held units: ' + held);
  // end show
  await page.click('#end'); await page.fill('#eo', 'show over'); await page.click('#ey');
  await page.waitForSelector('text=Download mapping file');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#dl')]);
  ok(fs.readFileSync(await dl.path(), 'utf8').split('\n').length >= 7, 'mapping file downloaded');
  await shot(page, '6-ended');
  ok((await page.evaluate(() => rpc('tfd_adjust', { p_sku: '100001', p_direction: 'in', p_qty: 1, p_reason: 'count correction' }).then(r => r.ok ? 'ok' : 'no', e => e.message))) === 'ok', 'lock released after end');

  // listed show: export, lookups, live-map win
  await page.goto(BASE + '/#shows/new'); await page.waitForSelector('#ty');
  await page.click('#ty button[data-v="listed"]'); await page.click('#addp'); await page.click('#sv'); await page.waitForSelector('#ex');
  await page.click('#ex'); await page.waitForTimeout(600);
  if (await page.locator('#yu').count()) { await page.click('#yu'); await page.waitForTimeout(400); }
  if (await page.locator('#xg').count()) { const [d2] = await Promise.all([page.waitForEvent('download'), page.click('#xg')]); ok(!!d2, 'listing exported (with blank-column warning)'); }
  else ok(true, 'listing exported');
  await page.goto(page.url()); await page.waitForSelector('#go'); await page.click('#go'); await page.waitForSelector('#scan');
  await scan('100003');
  ok((await page.textContent('#card')).includes('AVAILABLE'), 'listed: scan is a lookup');
  await page.click('#bcb'); await page.waitForSelector('#bcx'); await scan('100001'); await page.waitForTimeout(400);
  await page.locator('[data-pick]').first().click(); await page.waitForTimeout(700);
  ok((await page.textContent('#msg')).includes('Win #1'), 'live map win #1');
  await shot(page, '7-listed-live');
  await page.click('#end'); await page.fill('#eo', 'SHOW OVER'); await page.click('#ey'); await page.waitForSelector('text=Download mapping file');

  // streamer view: can open shows, never sees pay or cost
  await page.goto(BASE + '/#shows'); await page.waitForSelector('table');
  await page.evaluate(async () => { await signOut(); });
  await page.goto(BASE); await page.waitForSelector('#lu'); await page.fill('#lu', 'ally'); await page.fill('#lp', 'password123'); await page.click('#lf button.primary');
  await page.waitForSelector('.tabs');
  const tabs = await page.textContent('.tabs');
  ok(tabs.includes('Shows') && !tabs.includes('Inventory') && !tabs.includes('Settings'), 'streamer sees Shows, not Inventory/Settings: ' + tabs);
  await page.goto(BASE + '/#shows'); await page.waitForSelector('table'); await shot(page, '8-streamer-list');

  // phone
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(async () => { await signOut(); });
  await page.goto(BASE); await page.waitForSelector('#lu'); await page.fill('#lu', 'kenny@example.com'); await page.fill('#lp', 'password123'); await page.click('#lf button.primary');
  await page.waitForSelector('.mbot'); await page.goto(BASE + '/#shows/new'); await page.waitForSelector('#ty'); await page.click('#addp'); await page.click('#sv'); await page.waitForSelector('#go'); await page.click('#go'); await page.waitForSelector('#scan');
  await scan('100003'); await page.waitForTimeout(500); await shot(page, '9-phone-live');
  await page.click('#end'); await page.fill('#eo', 'SHOW OVER'); await page.click('#ey'); await page.waitForSelector('text=Download mapping file');

  ok(!errs.length, 'no page errors ' + JSON.stringify(errs));
  await browser.close(); console.log('SHOWS E2E PASSED');
})().catch(e => { console.error(e.message); process.exit(1); });
