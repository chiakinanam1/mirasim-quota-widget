const fs = require('fs');
const p = process.argv[2];
const b = fs.readFileSync(p);
const n = b.readUInt32LE(12);
const h = JSON.parse(b.slice(16, 16 + n).toString('utf8'));
function walk(node, path, depth) {
  const out = [];
  for (const [k, v] of Object.entries(node.files || {})) {
    const fp = path + '/' + k;
    if (v.files) { out.push(fp + '/'); if (depth < 2) out.push(...walk(v, fp, depth + 1)); }
    else out.push(fp + ' (' + v.size + ')');
  }
  return out;
}
console.log(walk(h, '', 0).join('\n'));
