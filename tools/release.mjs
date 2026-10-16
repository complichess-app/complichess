// Usage: node tools/release.mjs 2.2.0 "מה חדש בעברית" ["What's new in English"]
// Bumps APP_VERSION in index.html and version.json. Commit + push, and every player gets it.
import fs from 'node:fs';
const [, , ver, he, en] = process.argv;
if (!/^\d+\.\d+\.\d+$/.test(ver || '')) { console.error('Give a version like 2.2.0'); process.exit(1); }
const html = fs.readFileSync('index.html', 'utf8');
const next = html.replace(/const APP_VERSION = '[^']*';/, `const APP_VERSION = '${ver}';`);
if (next === html) { console.error('APP_VERSION not found in index.html'); process.exit(1); }
fs.writeFileSync('index.html', next);
const v = JSON.parse(fs.readFileSync('version.json', 'utf8'));
v.version = ver;
if (he) v.notes = Object.assign({}, en ? { en } : {}, { he });
fs.writeFileSync('version.json', JSON.stringify(v, null, 2) + '\n');
console.log('Released v' + ver + ' — now commit and push.');
