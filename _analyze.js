const fs = require('fs');
const asar = process.env.LOCALAPPDATA + '\\Programs\\@mirasimdesktop\\resources\\app.asar';
const b = fs.readFileSync(asar);
const n = b.readUInt32LE(12);
const ds = 16 + n + ((4 - (n % 4)) % 4);
const h = JSON.parse(b.slice(16, 16 + n).toString('utf8'));
const mn = h.files.dist.files['main.cjs'];
const m = b.slice(ds + Number(mn.offset), ds + Number(mn.offset) + mn.size).toString('utf8');
const out = [];
// va definition (va.abi is shell ABI). find "va="
for (const pat of ['va=', 'va =', 'abi:', "abi'", '"abi"', 'abi=']) {
  let p = 0, c = 0;
  while ((p = m.indexOf(pat, p)) >= 0 && c < 4) { out.push(`[${pat}@${p}] ` + m.slice(p - 40, p + 80)); p += pat.length; c++; }
}
// resources dir (potential restore source)
const resDir = process.env.LOCALAPPDATA + '\\Programs\\@mirasimdesktop\\resources';
out.push('\n[resources dir]');
for (const f of fs.readdirSync(resDir)) { const st = fs.statSync(resDir + '\\' + f); out.push(`  ${f} ${st.isDirectory() ? '<dir>' : st.size + 'B'} ${st.mtime.toISOString()}`); }
// programs root
const progDir = process.env.LOCALAPPDATA + '\\Programs\\@mirasimdesktop';
out.push('\n[program dir]');
for (const f of fs.readdirSync(progDir)) { const st = fs.statSync(progDir + '\\' + f); if (st.size > 1000000 || st.isDirectory() || /asar|\.json|\.yml/.test(f)) out.push(`  ${f} ${st.isDirectory() ? '<dir>' : (st.size/1e6).toFixed(1)+'MB'} ${st.mtime.toISOString()}`); }
fs.writeFileSync(process.env.USERPROFILE + '\\mirasim-quota-widget\\_out.txt', out.join('\n'));
console.log('ok');
