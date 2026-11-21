// Local preview: serves dist/index.html at http://localhost:4173 (run `node build.mjs` first).
import http from 'node:http';
import fs from 'node:fs';
const f = new URL('./dist/index.html', import.meta.url);
http.createServer((q, s) => { s.setHeader('content-type', 'text/html; charset=utf-8'); s.end(fs.readFileSync(f)); }).listen(4173);
