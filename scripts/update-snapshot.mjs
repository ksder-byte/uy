#!/usr/bin/env node
// Refreshes the data baked into landing/index.html from the cabinet API:
// tariffs/prices snapshot, static numbers (hero, advantages, FAQ), meta tags and JSON-LD.
// The page also refreshes itself from the API on every visit; this script keeps the HTML
// that search engines, link previews and the first paint see in sync with real prices.
//
//   node scripts/update-snapshot.mjs                         # fetch from https://www.durdenvpn.org
//   node scripts/update-snapshot.mjs --base http://127.0.0.1:8080
//   node scripts/update-snapshot.mjs --from-file landing.json # offline, from a saved API response
//
// Run it after changing tariffs, prices or payment methods in the admin panel (or from cron).
import { readFile, writeFile } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';

const args = Object.fromEntries(
  process.argv.slice(2).reduce((acc, a, i, all) => (a.startsWith('--') ? [...acc, [a.slice(2), all[i + 1]]] : acc), [])
);
const base = (args.base || 'https://www.durdenvpn.org').replace(/\/+$/, '');
const slug = args.slug || 'landing';
const htmlPath = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', 'landing', 'index.html');

async function getJson(url) {
  const res = await fetch(url, { headers: { Accept: 'application/json' } });
  if (!res.ok) throw new Error(`${url}: HTTP ${res.status}`);
  return res.json();
}

const cfg = args['from-file']
  ? JSON.parse(await readFile(args['from-file'], 'utf8'))
  : await getJson(`${base}/api/cabinet/landing/${slug}?lang=ru`);
if (!Array.isArray(cfg.tariffs)) throw new Error('Unexpected landing config: no tariffs');
delete cfg.footer_text; // the footer is static HTML now (the SPA sanitizer used to strip its markup)
delete cfg.custom_css;

let verification = null;
if (!args['from-file']) {
  try { verification = await getJson(`${base}/api/cabinet/public/site-verification`); } catch { /* optional */ }
}

let html = await readFile(htmlPath, 'utf8');

// Reuse the page's own pure helpers so the numbers match what the browser renders.
const block = html.match(/\/\*derive:start\*\/([\s\S]*?)\/\*derive:end\*\//);
if (!block) throw new Error('derive block not found in index.html');
const lib = new Function(`${block[1]}; return { texts, derive, rub, periodLabel, niceName };`)();

const esc = (s) => String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
const strip = (s) => s.replace(/<[^>]+>/g, '').replace(/&nbsp;/g, ' ').replace(/\s+/g, ' ').trim();
const between = (name, body) => {
  const re = new RegExp(`(<!--lp:${name}-->)[\\s\\S]*?(<!--/lp:${name}-->)`);
  if (!re.test(html)) throw new Error(`marker lp:${name} not found`);
  html = html.replace(re, (_, a, b) => `${a}\n${body}\n${b}`);
};

// 1. Snapshot JSON (escape "<" so no value can close the <script> element).
between('data', `<script id="lp-data" type="application/json">${JSON.stringify(cfg).replace(/</g, '\\u003c')}</script>`);

// 2. Static numbers and texts marked with data-d="…".
const t = lib.texts(cfg, 'ru');
html = html.replace(/(<([a-z0-9]+)\b[^>]*\bdata-d="(\w+)"[^>]*>)([^<]*)(<\/\2>)/g, (m, open, _tag, key, _old, close) =>
  t[key] != null ? open + esc(t[key]) + close : m
);

// 3. Optional FAQ items depend on the config.
const hasWhite = cfg.tariffs.some((x) => /бел\S* интернет|white internet/i.test(`${x.name} ${x.description}`));
const toggle = (id, show) => {
  html = html.replace(new RegExp(`(<details name="faq" id="${id}")( hidden)?`), (_, a) => a + (show ? '' : ' hidden'));
};
toggle('faq-white', hasWhite);
toggle('faq-gift', !!cfg.gift_enabled);

// 4. Meta tags from the landing settings.
const setMeta = (re, value) => { if (value) html = html.replace(re, (_, a, b) => a + esc(value) + b); };
setMeta(/(<title>)[^<]*(<\/title>)/, cfg.meta_title);
setMeta(/(<meta name="description" content=")[^"]*(")/, cfg.meta_description);
setMeta(/(<meta property="og:title" content=")[^"]*(")/, cfg.meta_title);

// 5. Payment-provider site verification tag (the SPA injected it with JS, which crawlers miss).
between('verification', verification && verification.apay_tag ? `<meta name="apay-tag" content="${esc(verification.apay_tag)}">` : '');

// 6. JSON-LD: organization, product with real price range, FAQ that matches the visible answers.
const d = lib.derive(cfg);
const offers = [];
for (const tr of cfg.tariffs) {
  for (const p of tr.periods || []) {
    offers.push({
      '@type': 'Offer',
      name: `${lib.niceName(tr.name)} — ${lib.periodLabel(p.days, 'ru')}`,
      price: (p.price_kopeks / 100).toFixed(2),
      priceCurrency: 'RUB',
      availability: 'https://schema.org/InStock',
      url: `https://www.durdenvpn.org/buy/${slug}`,
    });
  }
}
const faq = [];
for (const m of html.matchAll(/<details name="faq"(?![^>]*hidden)[^>]*><summary[^>]*>([\s\S]*?)<\/summary><p[^>]*>([\s\S]*?)<\/p><\/details>/g)) {
  faq.push({ '@type': 'Question', name: strip(m[1]), acceptedAnswer: { '@type': 'Answer', text: strip(m[2]) } });
}
const ld = {
  '@context': 'https://schema.org',
  '@graph': [
    {
      '@type': 'Organization',
      '@id': 'https://www.durdenvpn.org/#org',
      name: 'DurdenVPN',
      url: 'https://www.durdenvpn.org/',
      logo: 'https://www.durdenvpn.org/lp/logo-256.webp',
      sameAs: ['https://t.me/durden_vpn'],
      contactPoint: [{ '@type': 'ContactPoint', contactType: 'customer support', url: 'https://t.me/durdenvpn_support', email: 'support@durdenvpn.org' }],
    },
    {
      '@type': 'Product',
      name: 'DurdenVPN',
      description: cfg.meta_description || 'VPN без регистрации',
      brand: { '@id': 'https://www.durdenvpn.org/#org' },
      image: 'https://www.durdenvpn.org/lp/og-image.jpg',
      offers: { '@type': 'AggregateOffer', priceCurrency: 'RUB', lowPrice: (d.low / 100).toFixed(2), highPrice: (d.high / 100).toFixed(2), offerCount: offers.length, offers },
    },
    { '@type': 'FAQPage', mainEntity: faq },
  ],
};
between('jsonld', `<script type="application/ld+json">${JSON.stringify(ld).replace(/</g, '\\u003c')}</script>`);

await writeFile(htmlPath, html);
console.log(
  `landing/index.html updated: ${cfg.tariffs.length} tariffs, ${offers.length} offers, ${faq.length} FAQ items, from ${t.minPrice}/month`
);
