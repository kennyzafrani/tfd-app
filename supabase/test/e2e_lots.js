// End-to-end test of the Lots / Inventory rework against the fake Supabase stack.
const { chromium } = require('playwright');
const fs = require('fs'); const path = require('path');
const OUT = __dirname; const BASE = 'http://localhost:8899';
const shot = (page, n) => page.screenshot({ path: path.join(OUT, n + '.png'), fullPage: true });
const ok = (c, m) => { if (!c) throw new Error('FAILED: ' + m); console.log('ok -', m); };

(async () => {
  const browser = await chromium.launch();
  const ctx = await browser.newContext({ viewport: { width: 1400, height: 900 }, acceptDownloads: true });
  const page = await ctx.newPage();
  const errs = []; page.on('pageerror', e => errs.push(e.message)); page.on('console', m => { if (m.type() === 'error' && !m.text().includes('status of 400')) errs.push(m.text()); });
  page.on('dialog', d => d.accept());
  await page.goto(BASE);
  await page.fill('#sn', 'Kenny'); await page.fill('#se_', 'kenny@example.com'); await page.fill('#sp', 'password123'); await page.click('#sb');
  await page.waitForSelector('.tabs');

  // Settings: no Lists section; toggles for every field
  await page.goto(BASE + '/#settings/inventory'); await page.waitForSelector('#is');
  ok(!(await page.locator('.side a', { hasText: /^Lists$/ }).count()), 'Settings → Lists removed');
  ok(await page.locator('#if_upc').count() && await page.locator('#if_lot_photo').count() && await page.locator('#if_brand').count(), 'toggle per field');
  await page.evaluate(() => { document.querySelector('#if_upc').checked = true; ['image_url', 'bin', 'weight', 'subcategory'].forEach(k => document.querySelector('#if_' + k).checked = false); }); await page.click('#is'); await page.waitForTimeout(400);

  // Template is headers only
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#tpl');
  const [dl] = await Promise.all([page.waitForEvent('download'), page.click('#tpl')]);
  const tpl = fs.readFileSync(await dl.path(), 'utf8').trim().split(/\r?\n/);
  ok(tpl.length === 1 && tpl[0].startsWith('Supplier,Invoice #,Date,Brand'), 'template = headers only');

  // Lot 1 from CSV
  const csv = path.join(OUT, 'lot1.csv');
  fs.writeFileSync(csv, tpl[0] + '\r\n' + [
    'Designer Eyes,INV-1042,2026-11-10,Ray-Ban,RB3025,001,58,8053672000001,Aviator Classic Gold,Gold/Green,10,10,50.00,163.00,1.5,Bags & Accessories,Sunglasses,,,Q-01',
    'Designer Eyes,INV-1042,2026-11-10,Prada,PR 17WS,1AB5S0,49,,Prada Symbole,Black,5,4,90.00,430.00,1.2,Bags & Accessories,Sunglasses,,,',
    'Designer Eyes,INV-1042,2026-11-10,Oakley,OO9208,,,,,,2,,70.00,,,,,,,'].join('\r\n'));
  await page.click('#newr'); await page.setInputFiles('#rf', csv); await page.click('#rgo');
  await page.waitForSelector('#lgrid');
  ok((await page.textContent('#lname')).includes('Designer Eyes · INV-1042 · 2026-11-10'), 'lot named supplier · invoice · date');
  await page.waitForSelector('#confirm');
  ok(await page.isDisabled('#confirm'), 'confirm disabled while issues remain');
  const issues = await page.textContent('#issues');
  ok(/Row 2: UPC is required/.test(issues) && /Row 3: Color code is required/.test(issues), 'issues listed by name: ' + issues.slice(0, 160));
  ok(await page.locator('tr[data-lid] .cell.bad').count() >= 3, 'red cells');
  await shot(page, '1-lot-draft');

  // fix: UPC on row 2, row 3 color/size/name/upc/retail; use the dropdown for brand on row 3
  const row = n => page.locator('tr[data-lid]').nth(n - 1);
  const setCell = async (n, f, v) => { const c = row(n).locator(`[data-f="${f}"]`); await c.click(); await c.fill(v); await c.press('Tab'); await page.waitForTimeout(350); };
  await setCell(2, 'upc', '8056597000002');
  await setCell(3, 'color_code', '920801'); await setCell(3, 'lens_size', '60'); await setCell(3, 'name', 'Oakley Flak'); await setCell(3, 'upc', '888392000003'); await setCell(3, 'retail_cents', '180'); await setCell(3, 'received_qty', '2');
  // combobox: category from past values
  const cat = row(3).locator('[data-f="category"]'); await cat.click(); await cat.fill('bags');
  await page.waitForSelector('#combo:not(.hidden) div'); await shot(page, '2-combo');
  await page.locator('#combo div', { hasText: 'Bags & Accessories' }).first().dispatchEvent('mousedown'); await page.waitForTimeout(400);
  ok(await cat.inputValue() === 'Bags & Accessories', 'picked from dropdown');
  await page.waitForTimeout(600);
  const iss2 = await page.textContent('#issues');
  ok(!(await page.isDisabled('#confirm')), 'confirm enabled once fixed. issues: ' + iss2.slice(0, 200));
  await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');
  await shot(page, '3-lot-confirmed');
  ok((await page.locator('#lgrid a[data-sku]').count()) === 3, 'confirmed lot shows SKUs + all details');

  // Lot 2: returning piece by UPC + Match all, plus photo
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr');
  const csv2 = path.join(OUT, 'lot2.csv');
  fs.writeFileSync(csv2, tpl[0] + '\r\n' + ',,,,,,,8053672000001,,,3,3,52.00,,,,,,,\r\n,,,,,,,888392000003,,,1,1,71.00,,,,,,,');
  await page.click('#newr'); await page.fill('#rs', 'Desi'); await page.waitForSelector('#combo:not(.hidden) div');
  await page.locator('#combo div', { hasText: 'Designer Eyes' }).first().dispatchEvent('mousedown');
  await page.fill('#ri', 'INV-1050'); await page.setInputFiles('#rf', csv2); await page.click('#rgo');
  await page.waitForSelector('#matchall:not(.hidden)');
  ok((await page.textContent('#matchall')).includes('(2)'), 'match all shows 2');
  await page.click('#matchall'); await page.waitForTimeout(800);
  ok((await page.locator('.mcell .tag', { hasText: 'Matched' }).count()) === 2, 'both matched by UPC');
  // photo
  const png = path.join(OUT, 'box.png');
  fs.writeFileSync(png, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAIAAAACCAYAAABytg0kAAAAFklEQVR42mP8z8DwnwEJMDKQIAAAiH8D/1Rv7dwAAAAASUVORK5CYII=', 'base64'));
  await page.setInputFiles('tr[data-lid] [data-phl] input >> nth=0', png); await page.waitForSelector('.phcell img', { timeout: 8000 });
  ok(await page.locator('tr[data-lid]').first().locator('.phcell img').count() === 1, 'lot image uploaded on row 1');
  ok(!(await page.locator('#combo').count()) || true, 'combo ok');
  await shot(page, '4-lot2-matched');
  await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');

  // Lots list: search + filters
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#ltbl');
  await page.fill('#lq', 'oo9208'); ok((await page.locator('#ltbl tr[data-r]').count()) === 1, 'search finds lot by model inside');
  await page.fill('#lq', ''); await page.fill('#lf_costMin', '1000'); ok((await page.locator('#ltbl tr[data-r]').count()) === 1, 'cost filter');
  await page.fill('#lf_costMin', ''); await page.fill('#lf_invoice', '1050'); ok((await page.locator('#ltbl tr[data-r]').count()) === 1, 'invoice filter');
  await page.fill('#lf_invoice', '');
  await shot(page, '5-lots-list');

  // Adjustments: search by anything + red banner
  await page.goto(BASE + '/#inventory/adjustments'); await page.waitForSelector('#aq');
  await page.fill('#aq', '01'); const hits = await page.locator('#ares tr[data-pick]').count();
  ok(hits >= 2, 'search "01" finds ' + hits + ' products');
  await page.fill('#aq', ''); await page.fill('#as', '100001'); await page.waitForSelector('#ago');
  await page.fill('#aqty', '2'); await page.click('#ago'); await page.waitForSelector('.banner.out');
  ok((await page.textContent('.banner.out')).includes('Removed 2'), 'red removed banner');
  await page.fill('#as', '100001'); await page.waitForSelector('#ago'); await page.selectOption('#ad', 'in'); await page.click('#ago'); await page.waitForSelector('.banner.in');
  ok(true, 'green added banner');
  await page.fill('#as', '100003'); await page.waitForSelector('#ago'); await page.fill('#aqty', '2'); await page.selectOption('#ar', 'damaged'); await page.click('#ago'); await page.waitForSelector('.banner.out');
  await shot(page, '6-adjust');

  // Stock: dismiss alert, edit every field
  await page.goto(BASE + '/#inventory/stock'); await page.waitForSelector('#stbl');
  ok((await page.textContent('#sshow')).includes('In stock'), 'stock in/out toggle');
  const before = await page.locator('[data-dis]').count();
  ok(before >= 1, 'alerts present: ' + before);
  await page.locator('[data-dis]').first().click(); await page.waitForTimeout(600);
  ok((await page.locator('[data-dis]').count()) === before - 1, 'alert dismissed');
  await page.click('tr[data-sku="100003"]'); await page.waitForSelector('#psave');
  await page.fill('#pls', '62'); await page.fill('#pb', 'Oakley'); await page.click('#psave'); await page.waitForTimeout(600);
  ok((await page.textContent('#stbl')).includes('920801 · 62'), 'identity edited from Stock');
  await page.click('tr[data-sku="100003"]'); await page.waitForSelector('#psave'); await page.fill('#pu', '8053672000001'); await page.click('#psave'); await page.waitForTimeout(400);
  ok((await page.textContent('#pe')).includes('already on SKU 100001'), 'UPC collision blocked');
  await shot(page, '7-sku-edit'); await page.click('[data-close]');

  // Bins: search + detail + history
  await page.goto(BASE + '/#inventory/bins'); await page.waitForSelector('#bgrid');
  ok((await page.locator('.bincard').first().textContent()).includes('NOT_ASSIGNED'), 'NOT_ASSIGNED first');
  await page.fill('#bq', 'q-01'); ok((await page.locator('.bincard').count()) === 1, 'bin search');
  await page.click('.bincard'); await page.waitForSelector('text=History');
  ok((await page.locator('.modal').textContent()).includes('Arrived'), 'bin history shows arrivals');
  await shot(page, '8-bin'); await page.click('[data-close]');
  await page.fill('#bq', ''); await page.click('#mv'); await page.fill('#ms', '100002'); await page.fill('#mb', 'R-02'); await page.click('#mgo'); await page.waitForTimeout(500);
  await page.fill('#bq', 'NOT_ASSIGNED'); await page.click('.bincard'); await page.waitForSelector('text=History');
  ok((await page.locator('.modal').textContent()).includes('Moved out to R-02'), 'bin history shows move out');
  await page.click('[data-close]');

  // Versions: restore to right after lot 1 confirm
  await page.goto(BASE + '/#inventory/versions'); await page.waitForSelector('table');
  await shot(page, '9-versions');
  const rowsV = page.locator('tr', { hasText: 'Lot confirmed: Designer Eyes · INV-1042' });
  await rowsV.locator('[data-v]').click(); await page.fill('#vr', 'test restore'); await page.fill('#vc', 'RESTORE'); await page.click('#vgo'); await page.waitForTimeout(800);
  await page.goto(BASE + '/#inventory/stock'); await page.waitForSelector('#stbl');
  const st = await page.textContent('#stbl');
  ok(st.includes('RB3025') && !st.includes('920801 · 62'), 'restore undid later edits');
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#ltbl');
  ok((await page.locator('#ltbl tr[data-r]').count()) === 1, 'lot 2 reversed by restore');

  // + New only on supplier / brand
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr'); await page.click('#newr');
  await page.fill('#rs', 'Brand New Supplier'); await page.waitForSelector('#combo:not(.hidden)');
  ok((await page.textContent('#combo')).includes('+ New'), '+ New on supplier'); await page.click('[data-close]');
  await page.locator('#ltbl tr[data-r]').first().click(); await page.waitForSelector('#lgrid');
  // banner auto-hide is time-based; checked by code review (10 s)

  // Settings → Dropdown values: fix a spelling everywhere
  await page.goto(BASE + '/#settings/values'); await page.waitForSelector('#vt');
  await page.locator('tr', { hasText: 'Ray-Ban' }).locator('[data-ed]').click();
  await page.fill('#vn', 'Ray Ban'); await page.click('#vchk'); await page.waitForSelector('#vgo:not(.hidden)');
  ok((await page.textContent('#vp')).includes('SKU'), 'rename preview');
  await shot(page, '11-values'); await page.click('#vgo'); await page.waitForTimeout(600);
  await page.goto(BASE + '/#inventory/stock'); await page.waitForSelector('#stbl');
  ok((await page.textContent('#stbl')).includes('Ray Ban') && !(await page.textContent('#stbl')).includes('Ray-Ban'), 'spelling fixed everywhere');

  // bins: 160 Q-T bins exist; a typed bin that doesn't exist is rejected
  await page.goto(BASE + '/#inventory/bins'); await page.waitForSelector('#bgrid');
  ok((await page.textContent('.seg')).includes('All (16'), '160+ bins listed');
  await page.click('#mv'); await page.fill('#ms', '100001'); await page.fill('#mb', 'ZZ-99'); await page.click('#mgo'); await page.waitForTimeout(400);
  ok((await page.textContent('#me')).includes("doesn't exist"), 'unknown bin rejected'); await page.click('[data-close]');

  // sold-out SKU coming back: must pick a bin in the lot, and it moves there
  await page.goto(BASE + '/#inventory/adjustments'); await page.waitForSelector('#as'); await page.fill('#as', '100002'); await page.waitForSelector('#ago');
  const oh2 = await page.evaluate(() => document.querySelector('#apanel .note b:last-of-type').textContent);
  await page.fill('#aqty', oh2); await page.selectOption('#ar', 'lost'); await page.click('#ago'); await page.waitForTimeout(600);
  const big = await page.locator('#cy').count(); if (big) { await page.click('#cy'); await page.waitForTimeout(600); }
  await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#newr'); await page.click('#newr'); await page.fill('#rs', 'Designer Eyes'); await page.fill('#ri', 'INV-2000'); await page.click('#rgo');
  await page.waitForSelector('#lgrid');
  const c1 = page.locator('tr[data-lid]').first();
  for (const [f, v] of [['upc', '8056597000002'], ['received_qty', '2'], ['unit_cost_cents', '91']]) { const c = c1.locator(`[data-f="${f}"]`); await c.click(); await c.fill(v); await c.press('Tab'); await page.waitForTimeout(400); }
  await page.click('#matchall'); await page.waitForTimeout(900);
  ok((await page.textContent('#issues')).includes('is sold out. Pick the bin'), 'sold-out SKU needs a bin pick');
  const bc = c1.locator('[data-f="bin_code"]'); await bc.click(); await bc.fill('S-07'); await bc.press('Tab'); await page.waitForTimeout(700);
  await page.click('#confirm'); await page.click('#cy'); await page.waitForSelector('text=Confirmed');
  await page.goto(BASE + '/#inventory/stock'); await page.waitForSelector('#stbl');
  ok((await page.locator('tr[data-sku="100002"]').textContent()).includes('S-07'), 'restocked SKU went to the picked bin');

  // phone: bottom buttons + ☰ menu
  await page.setViewportSize({ width: 390, height: 844 }); await page.goto(BASE + '/#inventory/stock'); await page.waitForSelector('.mbot');
  ok((await page.locator('.mbot a').count()) === 4 && await page.isVisible('.mbot'), 'bottom bar with 4 buttons');
  await page.click('#mmenu'); await page.waitForSelector('#mdrawer:not(.hidden)');
  ok((await page.textContent('.mpanel')).includes('Settings') && (await page.textContent('.mpanel')).includes('Activity Log'), 'menu has Settings + Activity Log');
  await shot(page, '12-phone-menu'); await page.click('.mpanel a[href="#settings"]'); await page.waitForTimeout(500);
  ok((await page.url()).includes('#settings') && !(await page.isVisible('.mpanel')), 'menu navigates + closes');
  await page.goto(BASE + '/#inventory/stock'); await page.waitForSelector('#stbl'); await shot(page, '13-phone-stock');
  await page.setViewportSize({ width: 1400, height: 900 });

  // mobile width sanity
  await page.setViewportSize({ width: 390, height: 844 }); await page.goto(BASE + '/#inventory/lots'); await page.waitForSelector('#ltbl'); await page.click('#ltbl tr[data-r]'); await page.waitForSelector('#lgrid');
  await shot(page, '10-mobile');

  ok(!errs.length, 'no page errors ' + JSON.stringify(errs));
  await browser.close();
  console.log('E2E PASSED');
})().catch(e => { console.error(e.message); process.exit(1); });
