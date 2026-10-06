// End-to-end checks for landing/index.html against a mocked cabinet API.
//   npm install && npm test
// Uses Playwright's Chromium. No network access is needed: the API is served from tests/fixtures.
import http from 'node:http';
import { readFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';

const require = createRequire(import.meta.url);
let chromium;
try { ({ chromium } = require('playwright')); } catch { ({ chromium } = require('@playwright/test')); }

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const fixture = JSON.parse(await readFile(path.join(root, 'tests/fixtures/landing.json'), 'utf8'));

// ---- mock server --------------------------------------------------------------------------
const state = { purchases: [], configRequests: [], configStatus: 200, purchaseReply: null };
const types = { '.webp': 'image/webp', '.png': 'image/png', '.jpg': 'image/jpeg', '.ico': 'image/x-icon' };
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, 'http://x');
  const send = (code, body, type = 'application/json') => {
    res.writeHead(code, { 'Content-Type': type });
    res.end(typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body));
  };
  if (url.pathname === '/buy/landing') return send(200, await readFile(path.join(root, 'landing/index.html')), 'text/html; charset=utf-8');
  if (url.pathname.startsWith('/lp/')) {
    try { return send(200, await readFile(path.join(root, 'landing', url.pathname)), types[path.extname(url.pathname)]); } catch { return send(404, 'nope', 'text/plain'); }
  }
  if (url.pathname === '/api/cabinet/landing/landing') {
    state.configRequests.push(url.searchParams.get('lang'));
    return state.configStatus === 200 ? send(200, fixture) : send(state.configStatus, { detail: 'down' });
  }
  if (url.pathname === '/api/cabinet/branding/analytics') return send(200, { yandex_metrika_id: '', google_ads_id: '' });
  if (url.pathname === '/api/cabinet/landing/landing/purchase' && req.method === 'POST') {
    let raw = '';
    for await (const chunk of req) raw += chunk;
    state.purchases.push({ body: JSON.parse(raw), headers: req.headers });
    if (state.purchaseReply) return send(...state.purchaseReply);
    return send(200, { payment_url: '/paid', purchase_token: 'tok' });
  }
  if (url.pathname === '/paid') return send(200, '<!doctype html><title>paid</title>ok', 'text/html');
  send(404, { detail: 'not found' });
});
await new Promise((r) => server.listen(0, '127.0.0.1', r));
const BASE = `http://localhost:${server.address().port}`;

// ---- helpers ------------------------------------------------------------------------------
const browser = await chromium.launch();
const results = [];
async function test(name, fn) {
  try { await fn(); results.push(['ok', name]); console.log(`  ✓ ${name}`); }
  catch (e) { results.push(['fail', name]); console.log(`  ✗ ${name}\n    ${e.message.split('\n').join('\n    ')}`); }
}
async function open(opts = {}, query = '') {
  const ctx = await browser.newContext({ viewport: { width: 1280, height: 860 }, locale: 'ru-RU', ...opts });
  const page = await ctx.newPage();
  const errors = [];
  page.on('pageerror', (e) => errors.push(e.message));
  page.on('console', (m) => { if (m.type() === 'error') errors.push(m.text()); });
  await page.route(/googletagmanager|google-analytics|mc\.yandex/, (r) => r.fulfill({ status: 200, contentType: 'application/javascript', body: '' }));
  await page.goto(`${BASE}/buy/landing${query}`, { waitUntil: 'networkidle' });
  return { ctx, page, errors };
}
const checked = (page, name) => page.$eval(`input[name="${name}"]:checked`, (i) => i.value);

// ---- tests ----------------------------------------------------------------------------------
console.log('landing/index.html');

await test('renders hero, stats, tariffs, periods and payment options without errors', async () => {
  const { ctx, page, errors } = await open();
  assert.match(await page.textContent('h1'), /DURDENVPN/);
  assert.equal((await page.textContent('[data-d="minPrice"]')).replace(/\s/g, ' '), '99 ₽');
  assert.equal(await page.locator('input[name="tariff"]').count(), 2);
  assert.equal(await page.locator('input[name="period"]').count(), 4);
  assert.deepEqual(await page.$$eval('.m-label', (n) => n.map((x) => x.textContent)), ['Карта', 'СБП', 'Крипта']);
  assert.equal(await checked(page, 'tariff'), '5', 'operator order: first tariff preselected');
  assert.match(await page.textContent('#pay'), /Оплатить 299/);
  assert.match(await page.textContent('.t-desc'), /1000 ГБ Обычного VPN/);
  assert.doesNotMatch(await page.textContent('#tariffs'), /устройств\b.*3 устройств/, 'plural forms');
  assert.match(await page.textContent('#tariffs'), /3 устройства/);
  assert.deepEqual(errors, []);
  await ctx.close();
});

await test('payment methods below their minimum amount are disabled with a reason', async () => {
  const { ctx, page } = await open();
  await page.check('input[name="tariff"][value="2"]', { force: true });
  await page.check('input[name="period"][value="30"]', { force: true });
  assert.equal(await page.isDisabled('input[value="lava_card"]'), true);
  assert.equal(await page.isDisabled('input[value="lava_sbp"]'), true);
  assert.match((await page.textContent('#methods')).replace(/\u00a0/g, ' '), /от 100 ₽/);
  assert.equal(await checked(page, 'method'), 'heleket');
  await page.check('input[name="period"][value="60"]', { force: true });
  assert.equal(await page.isDisabled('input[value="lava_card"]'), false);
  await ctx.close();
});

await test('validates the contact before sending anything', async () => {
  const { ctx, page } = await open();
  const before = state.purchases.length;
  await page.click('#pay');
  assert.equal(await page.isVisible('#contact-err'), true);
  assert.equal(await page.evaluate(() => document.activeElement.id), 'contact');
  await page.fill('#contact', 'not-an-email@');
  await page.click('#pay');
  assert.match(await page.textContent('#contact-err'), /Проверьте адрес/);
  assert.equal(state.purchases.length, before);
  await ctx.close();
});

await test('sends the same purchase payload as the cabinet SPA, with CSRF and attribution', async () => {
  const { ctx, page } = await open({}, '?campaign=promo_1&subid=abc42&utm_source=tg');
  assert.equal(new URL(page.url()).search, '?subid=abc42&utm_source=tg', 'campaign param is consumed like in the SPA');
  await page.check('input[name="tariff"][value="5"]', { force: true });
  await page.check('input[name="period"][value="360"]', { force: true });
  await page.check('input[name="method"][value="lava_sbp"]', { force: true });
  await page.fill('#contact', 'https://t.me/durden_test');
  await page.click('#pay');
  await page.waitForURL('**/paid');
  const { body, headers } = state.purchases.at(-1);
  assert.deepEqual(body, {
    tariff_id: 5, period_days: 360, contact_type: 'telegram', contact_value: '@durden_test',
    payment_method: 'lava_sbp', language: 'ru', is_gift: false, subid: 'abc42', campaign_slug: 'promo_1',
  });
  assert.match(headers['x-csrf-token'], /^[0-9a-f]{64}$/);
  assert.match(headers.cookie || '', new RegExp(`csrf_token=${headers['x-csrf-token']}`));
  await ctx.close();
});

await test('remembers the contact and accepts ?contact= prefill', async () => {
  const { ctx, page } = await open({}, '?contact=user%40mail.ru');
  assert.equal(await page.inputValue('#contact'), 'user@mail.ru');
  assert.equal(new URL(page.url()).search, '');
  await page.click('#pay');
  await page.waitForURL('**/paid');
  assert.equal(state.purchases.at(-1).body.contact_type, 'email');
  await page.goto(`${BASE}/buy/landing`, { waitUntil: 'networkidle' });
  assert.equal(await page.inputValue('#contact'), 'user@mail.ru');
  await ctx.close();
});

await test('shows the API error message next to the pay button', async () => {
  state.purchaseReply = [400, { detail: 'Сумма меньше минимальной' }];
  const { ctx, page } = await open();
  await page.fill('#contact', 'user@mail.ru');
  await page.click('#pay');
  await page.waitForSelector('#pay-err:not([hidden])');
  assert.equal(await page.textContent('#pay-err'), 'Сумма меньше минимальной');
  assert.equal(await page.isEnabled('#pay'), true);
  state.purchaseReply = null;
  await ctx.close();
});

await test('works from the baked-in snapshot when the API is down', async () => {
  state.configStatus = 500;
  const { ctx, page } = await open();
  assert.equal(await page.locator('input[name="tariff"]').count(), 2);
  assert.match(await page.textContent('#pay'), /Оплатить 299/);
  state.configStatus = 200;
  await ctx.close();
});

await test('switches to English and shares the choice with the cabinet', async () => {
  const { ctx, page } = await open();
  await page.click('[data-lang="en"]');
  assert.equal(await page.getAttribute('html', 'lang'), 'en');
  assert.equal(await page.textContent('#checkout-title'), 'Choose a plan');
  assert.match(await page.textContent('#pay'), /^Pay /);
  assert.equal(await page.evaluate(() => localStorage.getItem('cabinet_language')), 'en');
  await page.waitForTimeout(200);
  assert.equal(state.configRequests.at(-1), 'en');
  await ctx.close();
});

await test('mobile: no horizontal scroll at 320px, sticky pay bar appears below the hero', async () => {
  const { ctx, page, errors } = await open({ viewport: { width: 320, height: 640 }, isMobile: true, hasTouch: true });
  assert.equal(await page.evaluate(() => document.documentElement.scrollWidth), 320);
  assert.equal(await page.$eval('#paybar', (b) => b.classList.contains('on')), false);
  await page.evaluate(() => document.getElementById('why').scrollIntoView());
  await page.waitForTimeout(400);
  assert.equal(await page.$eval('#paybar', (b) => b.classList.contains('on')), true);
  await page.click('#pb-btn');
  await page.waitForTimeout(900);
  assert.ok(await page.$eval('#checkout', (s) => s.getBoundingClientRect().top < 120));
  assert.deepEqual(errors, []);
  await ctx.close();
});

await test('accessibility basics: zoom allowed, labelled controls, one h1, lang set', async () => {
  const { ctx, page } = await open();
  assert.doesNotMatch(await page.getAttribute('meta[name="viewport"]', 'content'), /user-scalable=no|maximum-scale/);
  assert.equal(await page.locator('h1').count(), 1);
  const unlabeled = await page.$$eval('input:not([type=hidden]),textarea', (els) => els.filter((e) => !(e.labels && e.labels.length) && !e.getAttribute('aria-label')).map((e) => e.outerHTML.slice(0, 80)));
  assert.deepEqual(unlabeled, []);
  const imgsWithoutAlt = await page.$$eval('img', (els) => els.filter((e) => !e.hasAttribute('alt')).length);
  assert.equal(imgsWithoutAlt, 0);
  assert.equal(await page.getAttribute('[data-i18n="footChannel"]', 'href'), 'https://t.me/durden_vpn');
  await ctx.close();
});

await test('content is readable without JavaScript', async () => {
  const { ctx, page } = await open({ javaScriptEnabled: false });
  assert.match(await page.textContent('#why'), /Без регистрации/);
  assert.match(await page.textContent('#faq'), /Как продлить подписку/);
  assert.match(await page.textContent('[data-d="minPrice"]'), /99/);
  assert.match(await page.content(), /"@type":"FAQPage"/);
  await ctx.close();
});

await browser.close();
server.close();
const failed = results.filter((r) => r[0] === 'fail').length;
console.log(`\n${results.length - failed} passed, ${failed} failed`);
process.exit(failed ? 1 : 0);
