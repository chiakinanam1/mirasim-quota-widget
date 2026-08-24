// Verifies a patched asar changed ONLY index.html and added quota-widget.js.
// Usage: node asar-diff.js <orig> <patched>
const fs = require('fs');
const crypto = require('crypto');
function load(p) {
  const buf = fs.readFileSync(p);
  const jsonLen = buf.readUInt32LE(12);
  const dataStart = 16 + jsonLen + ((4 - (jsonLen % 4)) % 4);
  const h = JSON.parse(buf.slice(16, 16 + jsonLen).toString('utf8'));
  const map = {};
  (function walk(node, path) {
    for (const [k, v] of Object.entries(node.files)) {
      const fp = path + '/' + k;
      if (v.files) walk(v, fp);
      else if (typeof v.offset !== 'undefined') {
        const o = dataStart + Number(v.offset);
        map[fp] = crypto.createHash('sha256').update(buf.slice(o, o + v.size)).digest('hex');
      }
    }
  })(h, '');
  return map;
}
const a = load(process.argv[2]), b = load(process.argv[3]);
const changed = [], added = [], removed = [];
for (const k of Object.keys(a)) { if (!(k in b)) removed.push(k); else if (a[k] !== b[k]) changed.push(k); }
for (const k of Object.keys(b)) if (!(k in a)) added.push(k);
let same = 0; for (const k of Object.keys(a)) if (k in b && a[k] === b[k]) same++;
console.log('orig:', Object.keys(a).length, 'patched:', Object.keys(b).length, 'identical:', same);
console.log('changed:', JSON.stringify(changed));
console.log('added:', JSON.stringify(added));
console.log('removed:', JSON.stringify(removed));
const ok = changed.length === 1 && changed[0].endsWith('/index.html') && added.length === 1 && added[0].endsWith('/quota-widget.js') && removed.length === 0;
console.log(ok ? 'VERDICT: PASS' : 'VERDICT: FAIL');
