// Injects quota-widget.js into an Electron app.asar's dist/renderer.
// Self-contained (no @electron/asar dependency). Rebuilds the archive with
// corrected offsets + integrity. Usage:
//   node asar-inject.js <app.asar> <quota-widget.js> [outPath]
// If outPath omitted, writes <app.asar>.patched next to the input.
const fs = require('fs');
const crypto = require('crypto');

const asarPath = process.argv[2];
const widgetPath = process.argv[3];
const outPath = process.argv[4] || asarPath + '.patched';
if (!asarPath || !widgetPath) { console.error('usage: node asar-inject.js <app.asar> <quota-widget.js> [out]'); process.exit(2); }

const SENTINEL = '<!-- mirasim-quota-widget -->';
const TAG = '    <script type="module" crossorigin src="./assets/quota-widget.js"></script>' + SENTINEL + '\n  </head>';
const BLOCK = 4 * 1024 * 1024;

function integrity(buf) {
  const blocks = [];
  for (let i = 0; i < buf.length; i += BLOCK) blocks.push(crypto.createHash('sha256').update(buf.slice(i, i + BLOCK)).digest('hex'));
  if (blocks.length === 0) blocks.push(crypto.createHash('sha256').update(Buffer.alloc(0)).digest('hex'));
  return { algorithm: 'SHA256', hash: crypto.createHash('sha256').update(buf).digest('hex'), blockSize: BLOCK, blocks };
}

// ---- parse ----
const buf = fs.readFileSync(asarPath);
const jsonLen = buf.readUInt32LE(12);
const dataStart = 16 + jsonLen + ((4 - (jsonLen % 4)) % 4);
const header = JSON.parse(buf.slice(16, 16 + jsonLen).toString('utf8'));

const rend = header.files.dist.files.renderer;
if (!rend) throw new Error('dist/renderer not found in asar');

// ---- collect all file nodes in offset order ----
const files = [];
(function walk(node) {
  for (const v of Object.values(node.files)) {
    if (v.files) walk(v);
    else if (typeof v.offset !== 'undefined') files.push(v);
  }
})(header);
files.sort((a, b) => Number(a.offset) - Number(b.offset));

// ---- read + patch index.html ----
const idx = rend.files['index.html'];
const idxOff = dataStart + Number(idx.offset);
let html = buf.slice(idxOff, idxOff + idx.size).toString('utf8');
if (!html.includes(SENTINEL)) {
  if (!html.includes('</head>')) throw new Error('no </head> in index.html');
  html = html.replace('</head>', TAG);
}
const idxBuf = Buffer.from(html, 'utf8');

// ---- widget file ----
const widgetBuf = fs.readFileSync(widgetPath);
rend.files.assets.files['quota-widget.js'] = { size: widgetBuf.length, offset: '', integrity: integrity(widgetBuf) };
const widgetNode = rend.files.assets.files['quota-widget.js'];

// ---- reassign offsets: keep original file order, substitute index.html buffer, append widget ----
const chunks = [];
let cursor = 0;
for (const node of files) {
  let data;
  if (node === idx) { data = idxBuf; node.size = idxBuf.length; node.integrity = integrity(idxBuf); }
  else { const o = dataStart + Number(node.offset); data = buf.slice(o, o + node.size); }
  node.offset = String(cursor);
  chunks.push(data); cursor += data.length;
}
// append widget last
widgetNode.offset = String(cursor);
chunks.push(widgetBuf); cursor += widgetBuf.length;

// ---- rebuild header pickle ----
const jsonStr = Buffer.from(JSON.stringify(header), 'utf8');
const pad = (4 - (jsonStr.length % 4)) % 4;
const payloadSize = 4 + jsonStr.length + pad;   // strlen field + string + padding
const head = Buffer.alloc(16 + jsonStr.length + pad);
head.writeUInt32LE(4, 0);
head.writeUInt32LE(payloadSize, 4);
head.writeUInt32LE(jsonStr.length, 8);
head.writeUInt32LE(jsonStr.length, 12);
jsonStr.copy(head, 16);

fs.writeFileSync(outPath, Buffer.concat([head, ...chunks]));
console.log('wrote', outPath, '(' + cursor + ' bytes data, header ' + jsonStr.length + ')');
