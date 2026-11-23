// Pulls the Metabase public question (master query, query.sql), injects the rows into template.html, writes dist/index.html.
// METABASE_URL: public JSON link of the question. If unset, falls back to snapshot.json so the page still builds.
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';

const URL_ = process.env.METABASE_URL || '';
let d;
if (process.env.LOCAL_JSON) d = JSON.parse(readFileSync(process.env.LOCAL_JSON, 'utf8'));   // local testing only
else if (URL_) {
  const res = await fetch(URL_);
  if (!res.ok) throw new Error(`Metabase returned ${res.status}`);
  d = await res.json();
  writeFileSync('snapshot.json', JSON.stringify(d));   // refreshed copy (committed only if you commit it)
} else if (existsSync('snapshot.json')) {
  console.warn('METABASE_URL is not set: building from snapshot.json (stale data).');
  d = JSON.parse(readFileSync('snapshot.json', 'utf8'));
} else throw new Error('Set METABASE_URL to the public JSON link of the question.');

if (!Array.isArray(d) || d.length < 20) throw new Error(`Unexpected response: ${Array.isArray(d) ? d.length + ' rows' : typeof d}`);
const need = ['a2h_date','outlier','csa','a2h_done','live_from_a2h','win','sellers','spend','impressions','clicks','purchases','gmv',
  'video_spend','ad_spend','age_18_44','age_spend','non_lal_spend','adset_spend','ig_spend','plat_spend'];
for (const k of need) if (!(k in d[0])) throw new Error(`Column missing from question: ${k}`);

const W = { D0_6: 0, D7_13: 1, D14_20: 2, D21_27: 3 };
const r = (x, p = 2) => x == null ? null : +(+x).toFixed(p);
const out = d.map(x => [x.a2h_date, x.a2h_done, x.live_from_a2h, x.win ? W[x.win] : -1, x.sellers,
  r(x.spend), x.impressions, x.clicks, x.purchases, r(x.gmv), r(x.video_spend), r(x.ad_spend), r(x.age_18_44), r(x.age_spend),
  r(x.non_lal_spend), r(x.adset_spend), r(x.ig_spend), r(x.plat_spend), x.outlier || 0, x.csa || 0]);

const HEAD = '<!doctype html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n<meta name="viewport" content="width=device-width, initial-scale=1">\n<style>html,body{margin:0}img{max-width:100%}</style>\n';
const built = new Date().toLocaleString('en-GB', { timeZone: 'Asia/Kolkata', dateStyle: 'medium', timeStyle: 'short' }) + ' IST';
const html = HEAD + readFileSync('template.html', 'utf8')
  .replace('/*DATA*/[]', () => JSON.stringify(out))
  .replaceAll('__BUILT__', built);
mkdirSync('dist', { recursive: true });
writeFileSync('dist/index.html', html);
console.log(`Built dist/index.html from ${out.length} rows`);
