// End-to-end test of the Shows tab (flow v2) against the fake Supabase stack.
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
const OUT = __dirname; const BASE = 'http://localhost:8899';
const shot = (page, n) => page.screenshot({ path: path.join(OUT, n + '.png'), fullPage: false });
const ok = (c, m) => { if (!c) throw new Error('FAILED: ' + m); console.log('ok -', m); };

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 }, acceptDownloads: true });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => { errs.push(e.message); console.log('STACK', e.stack.split('\n').slice(0,4).join(' / ')); });
  page.on('console', m => { if (m.text().includes('LOGINERR')) console.log(m.text()); });
  await page.goto(BASE);
  await page.fill('#sn', 'Kenny'); await page.fill('#se_', 'kenny@example.com'); await page.fill('#sp', 'password123'); await page.click('#sb');
  await page.waitForSelector('.tabs');
  await page.evaluate(() => server('POST', '/api/users', { name: 'Ally', login: 'ally', password: 'password123', role: 'streamer' }));
  await page.evaluate(() => server('POST', '/api/users', { name: 'Bea', login: 'bea', password: 'password123', role: 'assistant' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'platform.tiktok', p_value: { label: 'TikTok', pct_sale_bp: 600, pct_ship_bp: 600, fixed_cents: 0, typical_ship_cents: 800 }, p_effective_from: null, p_reason: 'test' }));
  await page.evaluate(() => rpc('tfd_set_setting', { p_key: 'inventory', p_value: { required_fields: ['received_qty'], show_suggest_max_units: 5, show_suggest_min_shows: 8, low_stock_default: 2 }, p_effective_from: null, p_reason: 'test' }));

  const csv = path.join(OUT, 'lot.csv');
  fs.writeFileSync(csv, 'Supplier,Invoice #,Date,Brand,Model #,Color Code,Lens Size,UPC,Product Name,Color Name,Invoiced Qty,Received Qty,Unit Cost,Retail Price,Weight (oz),Category,Subcategory,Specs,Image URL,Bin\r\n' + [
    'Designer Eyes,INV-1,2026-11-10,Ray-Ban,RB3025,001,58,8053672000001,Aviator Classic Gold,Gold/Green,5,5,50.00,163.00,1.5,Bags & Accessories,Sunglasses,Polarized,,Q-01',
    'Designer Eyes,INV-1,2026-11-10,Prada,PR 17WS,1AB5S0,49,8056597000002,Prada Symbole,Black,1,1,90.00,430.00,1.2,Bags & Accessories,Sunglasses,,,Q-02',
    'Designer Eyes,INV-1,2026-11-10,Gucci,GG0061S,001,56,889652000003,Gucci Square,Black/Grey,4,4,85.00,390.00,1.3,Bags & Accessories,Sunglasses,,,Q-03'].join('\r\n'));
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr'); await page.click('#newr'); await page.setInputFiles('#rf', csv); await page.click('#rgo');
  await page.waitForSelector('#confirm:not([disabled])'); await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');

  // Settings: Whatnot starting price is a typed number
  await page.goto(BASE + '/#settings/whatnot'); await page.waitForSelector('#wn_p');
  ok((await page.getAttribute('#wn_p', 'type')) === 'number' && (await page.inputValue('#wn_p')) === '1.00', 'Whatnot starting price box, default $1.00');

  // new show: TikTok live mapping with a 0% promo fee → straight to live screen
  await page.goto(BASE + '/#shows'); await page.waitForSelector('text=New show'); await page.click('text=New show');
  await page.waitForSelector('#ty');
  ok((await page.inputValue('#f_sale')) === '6', 'fee prefilled from Settings (6%)');
  await page.fill('#f_sale', '0'); await page.fill('#f_ship', '0');
  await page.click('#addp'); await page.click('#addp'); await page.waitForTimeout(200);
  ok((await page.locator('#ppl tr').count()) === 3, 'streamer + assistant in lineup');
  await page.fill('#nm', 'Promo night'); await shot(page, '1-setup');
  await page.click('#sv'); await page.waitForSelector('#scan');
  ok(!(await page.locator('#clk').count()) && !(await page.locator('#pz').count()) && !(await page.locator('#air').count()), 'no clock / pause / on-air');
  ok((await page.textContent('.live')).includes('Fee 0% of sale'), 'live screen shows the show fee');

  // stock can change mid-live
  ok((await page.evaluate(() => rpc('tfd_adjust', { p_sku: '100001', p_direction: 'in', p_qty: 1, p_reason: 'count correction' }).then(r => r.ok ? 'ok' : 'no', e => e.message))) === 'ok', 'adjust allowed while live');
  await page.evaluate(() => renderShows()); await page.waitForSelector('#scan');

  const scan = async sku => { await page.fill('#scan', sku); await page.press('#scan', 'Enter'); await page.waitForTimeout(500); };
  await scan('100001');
  ok((await page.textContent('#card')).includes('Pull #1') && (await page.textContent('#card')).includes('FLOOR'), 'pull #1 card with floor');
  ok(!(await page.textContent('#card')).toLowerCase().includes('cost'), 'no cost on the live screen');
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  // live mapping: the same item back to back is normal, no "scanned twice?" prompt
  await scan('100001'); await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  ok(!(await page.isVisible('text=Scanned twice?')) && (await page.textContent('#nxt')) === '#3', 'same SKU twice in a row: no warning, next #3');
  ok(!(await page.isDisabled('#again')) && (await page.textContent('#againl')).includes('100001'), 'Run again offers the last item');
  await page.click('#again'); await page.waitForTimeout(500); await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  ok((await page.textContent('#nxt')) === '#4' && (await page.textContent('#card')).includes('Pull #3'), 'Run again records the same item as the next pull');
  await scan('100002');                       // last unit of Prada
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved');
  ok(await page.isDisabled('#again') && (await page.textContent('#againl')).includes('out of stock'), 'Run again greyed out when the last item is out of stock');
  await scan('100002');
  ok((await page.textContent('#msg')).includes('Out of stock'), 'out of stock blocked');
  await scan('999999');
  ok((await page.textContent('#msg')).includes('Unknown SKU'), 'unknown SKU');
  await shot(page, '2-live');
  // undo + new part
  await page.click('#un'); await page.click('#ay'); await page.waitForTimeout(700);
  ok((await page.textContent('#nxt')) === '#4', 'undo frees #4');
  await page.click('#np'); await page.click('#ay'); await page.waitForTimeout(700);
  ok((await page.textContent('#prt')) === '2' && (await page.textContent('#nxt')) === '#1', 'Part 2 starts at #1');
  // offline
  await ctx.setOffline(true);
  await scan('100003'); await page.waitForTimeout(3100); await scan('100003');
  ok((await page.textContent('#sync')).includes('waiting') || (await page.textContent('#sync')).includes('Offline'), 'offline: scans queued');
  ok((await page.textContent('#nxt')) === '#3', 'offline numbering keeps going');
  await ctx.setOffline(false); await page.evaluate(() => window.dispatchEvent(new Event('online')));
  await page.waitForFunction(() => document.querySelector('#sync').textContent === 'All saved', null, { timeout: 15000 });
  ok((await page.textContent('#pl')).includes('P2 #2'), 'queued scans saved as Part 2 #1, #2');

  // conclude → hours
  await page.click('#end'); await page.click('#ey');
  await page.waitForSelector('text=Step 2 · Hours');
  ok((await page.locator('#hrs tr').count()) === 3, 'one hours row per person prefilled');
  const d = new Date(); const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
  await page.fill('#sst', day + 'T00:00'); await page.fill('#sen', day + 'T23:59');
  const ins = page.locator('#hrs input[type="datetime-local"]');
  await ins.nth(0).fill(day + 'T19:00'); await ins.nth(1).fill(day + 'T21:00');
  await ins.nth(2).fill(day + 'T19:00'); await ins.nth(3).fill(day + 'T22:30');
  await page.click('#addh'); await page.waitForTimeout(200);
  const ins2 = page.locator('#hrs input[type="datetime-local"]');
  await page.locator('#hrs select').nth(2).selectOption({ label: 'Ally' }); await page.waitForTimeout(200);
  const ins3 = page.locator('#hrs input[type="datetime-local"]');
  await ins3.nth(4).fill(day + 'T21:30'); await ins3.nth(5).fill(day + 'T22:00'); await page.waitForTimeout(200);
  await page.click('#hs'); await page.waitForTimeout(800);
  ok((await page.textContent('#hrs')).includes('Ally 2.50h') && (await page.textContent('#hrs')).includes('Bea 3.50h') && !(await page.textContent('#he')), 'hours saved with totals: ' + (await page.textContent('#hrs')).match(/Totals:.*/)?.[0]);
  await shot(page, '3-concluded-hours');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#dl')]);
  ok(fs.readFileSync(await dl.path(), 'utf8').split('\n').length >= 5, 'mapping file downloaded');

  // listed show on TikTok: export with starting price, lookups, Record win
  await page.goto(BASE + '/#shows/new'); await page.waitForSelector('#ty');
  await page.click('#ty button[data-v="listed"]'); await page.click('#addp'); await page.click('#sv'); await page.waitForSelector('#scan');
  await page.click('#ex'); await page.waitForTimeout(600);
  if (await page.locator('#yu').count()) { await page.click('#yu'); await page.waitForTimeout(400); }
  await page.waitForSelector('#xp'); await page.fill('#xp', '2');
  const [d2] = await Promise.all([page.waitForEvent('download'), page.click('#xg')]);
  const exp = fs.readFileSync(await d2.path(), 'utf8').split('\r\n');
  const hdr = exp[0].split(','), row = exp[1].split(',');
  ok(row[hdr.indexOf('Price')] === '2.00' && row[hdr.indexOf('Condition')] === '', 'export price = starting price, condition blank');
  await scan('100003');
  ok((await page.textContent('#card')).includes('AVAILABLE'), 'listed: scan is a lookup');
  await page.click('#wm'); await scan('100001'); await page.waitForTimeout(600);
  ok((await page.textContent('#msg')).includes('Win #1'), 'Record win: win #1');
  await shot(page, '4-listed-live');
  await page.click('#end'); await page.click('#ey'); await page.waitForSelector('text=Step 2 · Hours');

  // delete both shows from the list, then restore one
  await page.goto(BASE + '/#shows'); await page.waitForSelector('#dsel');
  await page.check('#sall'); await page.click('#dsel'); await page.click('#dy'); await page.waitForTimeout(300);
  ok((await page.textContent('#de')).includes('reason'), 'delete needs a reason');
  await page.fill('#dr', 'test shows'); await page.click('#dy'); await page.waitForTimeout(800);
  ok((await page.locator('tr[data-show]').count()) === 0, 'shows hidden');
  ok((await page.evaluate(() => rpc('tfd_stock').then(r => r.reduce((a, x) => a + x.held, 0)))) === 0, 'held units freed');
  await page.click('text=Deleted'); await page.waitForSelector('[data-rs]'); await shot(page, '5-deleted');
  await page.locator('[data-rs]').first().click(); await page.fill('#rr', 'oops'); await page.click('#ry'); await page.waitForTimeout(800);
  ok(/#shows\/\d+$/.test(page.url()), 'restored show opens');

  // streamer view: can open shows, never sees pay or cost
  await page.evaluate(async () => { await signOut(); });
  await page.goto(BASE); await page.waitForSelector('#lu'); await page.fill('#lu', 'ally'); await page.fill('#lp', 'password123'); await page.click('#lf button.primary');
  await page.waitForSelector('.tabs');
  const tabs = await page.textContent('.tabs');
  ok(tabs.includes('Shows') && !tabs.includes('Inventory') && !tabs.includes('Settings'), 'streamer sees Shows, not Inventory/Settings');
  await page.goto(BASE + '/#shows'); await page.waitForSelector('table'); ok(!(await page.locator('#dsel').count()), 'streamer cannot delete');

  // phone
  await page.setViewportSize({ width: 390, height: 844 });
  await page.evaluate(async () => { await signOut(); });
  await page.goto(BASE); await page.waitForSelector('#lu'); await page.fill('#lu', 'kenny@example.com'); await page.fill('#lp', 'password123'); await page.click('#lf button.primary');
  await page.waitForSelector('.mbot'); await page.goto(BASE + '/#shows/new'); await page.waitForSelector('#ty'); await page.click('#addp'); await page.click('#sv'); await page.waitForSelector('#scan');
  await scan('100003'); await page.waitForTimeout(500); await shot(page, '6-phone-live');
  await page.click('#end'); await page.click('#ey'); await page.waitForSelector('text=Step 2 · Hours'); await shot(page, '7-phone-hours');

  ok(!errs.length, 'no page errors ' + JSON.stringify(errs));
  await browser.close(); console.log('SHOWS E2E PASSED');
})().catch(e => { console.error(e.message); process.exit(1); });
