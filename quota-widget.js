/*
 * Mirasim Quota Widget — Apple 菜单栏风格的额度监视器(水墨黑版)
 * 数据源: ws://127.0.0.1:4970/ws → {type:"getRelay"} (Claude 5h/7d usedPercent)
 * 额度积分 = usedPercent × budget ÷ 100 ÷ 100(budget 默认 5h=42560 / 7d=560000,可用 localStorage 覆盖)
 * 均速参考: 按窗口已流逝时间比例在进度条上打参考标,并给出 领先/超速 差值
 * 注入方式: renderer/index.html 与 web/index.html 追加 <script type="module" src="./assets/quota-widget.js">
 */
(() => {
  'use strict';
  if (window.__mirasimQuotaWidget) return;
  window.__mirasimQuotaWidget = true;

  /* ------------------------------ 配置 ------------------------------ */
  const LS = { host: 'mqw.host', right: 'mqw.right', top: 'mqw.top', b5: 'mqw.budget5h', b7: 'mqw.budget7d' };
  const isHttp = /^https?:$/.test(location.protocol);
  const HOSTS = [
    localStorage.getItem(LS.host),
    isHttp ? location.host : null,
    '127.0.0.1:4970',
  ].filter(Boolean);
  const POLL_MS = 30000;
  const WIN_LEN = { '5h': 5 * 3600e3, '7d': 7 * 86400e3 };            // 窗口时长 ms
  const BUDGET = {
    '5h': parseFloat(localStorage.getItem(LS.b5)) || 42560,           // 单位(积分×100)
    '7d': parseFloat(localStorage.getItem(LS.b7)) || 560000,
  };
  // 总额度自动校准: 计划任务定期把路由 /v1/limits 的原始 budget 写成静态 JSON,这里定时拉取。
  // 优先级: localStorage 手动覆盖 > 自动校准值 > 内置默认
  async function fetchBudget() {
    try {
      const h = localStorage.getItem(LS.host) || '127.0.0.1:4970';
      const r = await fetch('http://' + h + '/quota-budget.json?t=' + Date.now(), { cache: 'no-store' });
      if (!r.ok) return;
      const j = await r.json();
      if (!j || !j.windows) return;
      let changed = false;
      for (const [k, key] of [['5h', LS.b5], ['7d', LS.b7]]) {
        if (localStorage.getItem(key)) continue;                      // 手动覆盖优先
        const b = j.windows[k] && Number(j.windows[k].budget);
        if (Number.isFinite(b) && b > 0 && b !== BUDGET[k]) { BUDGET[k] = b; changed = true; }
      }
      if (changed) render();
    } catch {}
  }

  /* ------------------------------ 状态 ------------------------------ */
  const S = { connected: false, claude: null, asOf: 0, open: false };
  let ws = null, backoff = 1500, pollTimer = 0, hostIdx = 0;

  /* ------------------------------ 数据层 ------------------------------ */
  function connect() {
    const host = HOSTS[Math.min(hostIdx, HOSTS.length - 1)];
    try { ws = new WebSocket('ws://' + host + '/ws'); } catch { return scheduleReconnect(); }
    ws.onopen = () => {
      S.connected = true; backoff = 1500;
      localStorage.setItem(LS.host, host);
      poll();
      clearInterval(pollTimer);
      pollTimer = setInterval(poll, POLL_MS);
      render();
    };
    ws.onmessage = (e) => {
      let m; try { m = JSON.parse(e.data); } catch { return; }
      if (m.type === 'relay' && m.relay) {
        const r = m.relay;
        S.claude = {
          windows: (r.usage && r.usage.windows) || [],
          ok: !!(r.usage && r.usage.ok),
          threshold: r.threshold, on5h: r.on5h, on7d: r.on7d,
          engaged: !!r.engaged, relayStatus: r.relayStatus || 'ok',
        };
        S.asOf = Date.now(); render();
      }
    };
    ws.onclose = () => { S.connected = false; render(); scheduleReconnect(); };
    ws.onerror = () => { try { ws.close(); } catch {} };
  }
  function scheduleReconnect() {
    clearInterval(pollTimer);
    hostIdx++;
    setTimeout(connect, backoff);
    backoff = Math.min(backoff * 1.7, 30000);
  }
  function poll() {
    if (!ws || ws.readyState !== 1) return;
    try { ws.send(JSON.stringify({ type: 'getRelay' })); } catch {}
  }

  /* ------------------------------ 工具 ------------------------------ */
  const $ = (root, sel) => root.querySelector(sel);
  const clamp = (v, a, b) => Math.max(a, Math.min(b, v));
  const winOf = (label) => S.claude && S.claude.windows ? S.claude.windows.find(w => w.label === label) : null;
  // 积分 = usedPercent% × budget ÷ 100
  const credits = (label, pct) => pct == null ? null : pct / 100 * BUDGET[label] / 100;
  const creditTotal = (label) => BUDGET[label] / 100;
  const fmtCred = (v, total) => v == null ? '—' : (total >= 1000 ? Math.round(v).toLocaleString() : v.toFixed(1));
  // 均速参考: 窗口已流逝时间比例(0~100)
  function pacePct(label, resetAt) {
    if (!resetAt) return null;
    const remain = new Date(resetAt).getTime() - Date.now();
    if (!Number.isFinite(remain)) return null;
    return clamp((1 - remain / WIN_LEN[label]) * 100, 0, 100);
  }
  function fmtEta(resetAt) {
    if (!resetAt) return '';
    const ms = new Date(resetAt).getTime() - Date.now();
    if (!(ms > 0)) return '即将重置';
    const s = Math.floor(ms / 1000), d = Math.floor(s / 86400), h = Math.floor(s % 86400 / 3600),
      m = Math.floor(s % 3600 / 60), ss = s % 60;
    if (d > 0) return `${d} 天 ${h} 小时后重置`;
    if (h > 0) return `${h}:${String(m).padStart(2, '0')}:${String(ss).padStart(2, '0')} 后重置`;
    return `${m}:${String(ss).padStart(2, '0')} 后重置`;
  }
  const fmtClock = (t) => { const x = new Date(t); return `${String(x.getHours()).padStart(2,'0')}:${String(x.getMinutes()).padStart(2,'0')}:${String(x.getSeconds()).padStart(2,'0')}`; };

  /* ------------------------------ UI 骨架 ------------------------------ */
  const host = document.createElement('div');
  host.id = 'mirasim-quota-widget';
  host.className = 'no-drag';
  const sh = host.attachShadow({ mode: 'open' });

  const css = `
  :host { all: initial; }
  * { box-sizing: border-box; margin: 0; padding: 0; -webkit-user-select: none; user-select: none; }
  .root {
    --f: -apple-system, "SF Pro Text", "Segoe UI Variable", "Segoe UI", "PingFang SC", "Microsoft YaHei UI", sans-serif;
    font-family: var(--f); font-synthesis: none;
    -webkit-font-smoothing: antialiased; text-rendering: optimizeLegibility;
  }
  /* ---- 水墨主题: 浅色界面用黑,深色界面用白,无彩色 ---- */
  .root { /* dark 默认 */
    --ink: rgba(255,255,255,.9); --ink2: rgba(255,255,255,.55); --ink3: rgba(255,255,255,.34);
    --pill-bg: rgba(255,255,255,.07); --pill-bg-h: rgba(255,255,255,.14); --pill-bd: rgba(255,255,255,.1);
    --pop-bg: rgba(28,28,30,.82); --pop-bd: rgba(255,255,255,.12); --hair: rgba(255,255,255,.09);
    --track: rgba(255,255,255,.14); --btn: rgba(255,255,255,.08); --btn-h: rgba(255,255,255,.15);
    --shadow: 0 0 0 .5px rgba(0,0,0,.4), 0 18px 50px rgba(0,0,0,.5), 0 4px 14px rgba(0,0,0,.35);
  }
  .root.light {
    --ink: rgba(0,0,0,.88); --ink2: rgba(0,0,0,.52); --ink3: rgba(0,0,0,.34);
    --pill-bg: rgba(0,0,0,.05); --pill-bg-h: rgba(0,0,0,.1); --pill-bd: rgba(0,0,0,.08);
    --pop-bg: rgba(248,248,248,.85); --pop-bd: rgba(0,0,0,.1); --hair: rgba(0,0,0,.08);
    --track: rgba(0,0,0,.1); --btn: rgba(0,0,0,.05); --btn-h: rgba(0,0,0,.1);
    --shadow: 0 0 0 .5px rgba(0,0,0,.08), 0 18px 50px rgba(0,0,0,.16), 0 4px 14px rgba(0,0,0,.08);
  }
  /* ---- 胶囊(菜单栏项) ---- */
  .pill {
    display: flex; align-items: center; gap: 8px; height: 24px; padding: 0 10px;
    border-radius: 12px; background: var(--pill-bg); border: .5px solid var(--pill-bd);
    color: var(--ink); font-size: 11px; cursor: default; line-height: 1;
    backdrop-filter: blur(20px) saturate(140%); -webkit-backdrop-filter: blur(20px) saturate(140%);
    transition: background .18s ease, transform .12s ease;
  }
  .pill:hover { background: var(--pill-bg-h); }
  .pill:active { transform: scale(.97); }
  .dot { width: 6px; height: 6px; border-radius: 3px; background: var(--ink); flex: none; }
  .dot.off { background: transparent; border: 1px solid var(--ink3); }
  .dot.pulse { animation: mqwPulse 1.6s ease-in-out infinite; }
  @keyframes mqwPulse { 50% { opacity: .3; } }
  .seg { display: flex; align-items: center; gap: 5px; }
  .seg .lb { color: var(--ink2); font-weight: 600; letter-spacing: .2px; }
  .seg .num { font-weight: 600; font-variant-numeric: tabular-nums; }
  .seg .num i { font-style: normal; color: var(--ink3); font-weight: 500; }
  .cap { width: 26px; height: 7px; border-radius: 3.5px; background: var(--track); overflow: hidden; position: relative; }
  .cap i { position: absolute; inset: 0; right: auto; width: 0%; border-radius: 3.5px;
    background: var(--ink); transition: width .6s cubic-bezier(.32,.72,0,1); }
  .sep { width: .5px; height: 12px; background: var(--hair); }
  .root.compact .cap { display: none; }
  .root.compact .pill { padding: 0 8px; gap: 5px; }
  .root.compact .seg { gap: 3px; }

  /* ---- Popover ---- */
  .pop {
    position: fixed; width: 292px; border-radius: 14px; z-index: 2147483646;
    background: var(--pop-bg); border: .5px solid var(--pop-bd); box-shadow: var(--shadow);
    backdrop-filter: blur(36px) saturate(170%); -webkit-backdrop-filter: blur(36px) saturate(170%);
    color: var(--ink); font-size: 12px; overflow: hidden;
    opacity: 0; transform: scale(.96) translateY(-4px); transform-origin: top right;
    pointer-events: none; transition: opacity .16s ease, transform .18s cubic-bezier(.32,.72,0,1);
  }
  .pop.on { opacity: 1; transform: none; pointer-events: auto; }
  .hd { display: flex; align-items: center; gap: 7px; padding: 11px 14px 7px; }
  .hd .t { font-size: 12px; font-weight: 600; letter-spacing: .1px; }
  .hd .asof { margin-left: auto; color: var(--ink3); font-size: 10.5px; font-variant-numeric: tabular-nums; }
  .banner { margin: 0 14px 8px; padding: 6px 9px; border-radius: 8px; font-size: 11px;
    background: var(--btn); color: var(--ink2); display: none; }
  .banner.on { display: block; }
  .w { padding: 6px 14px 10px; }
  .w + .w { border-top: .5px solid var(--hair); padding-top: 10px; }
  .w .top { display: flex; align-items: baseline; gap: 7px; }
  .w .wl { font-size: 11px; font-weight: 700; color: var(--ink2); letter-spacing: .3px; }
  .w .big { font-size: 19px; font-weight: 650; font-variant-numeric: tabular-nums; letter-spacing: -.2px; }
  .w .big i { font-style: normal; font-size: 12px; font-weight: 500; color: var(--ink3); }
  .w .pct { margin-left: auto; font-size: 12px; font-weight: 600; color: var(--ink2); font-variant-numeric: tabular-nums; }
  .barwrap { position: relative; margin: 8px 0 3px; }
  .bar { height: 6px; border-radius: 3px; background: var(--track); position: relative; overflow: visible; }
  .bar .fill { position: absolute; inset: 0; right: auto; width: 0%; border-radius: 3px; background: var(--ink);
    transition: width .6s cubic-bezier(.32,.72,0,1); }
  /* 均速参考标识: 细线 + 上方小三角 */
  .pace { position: absolute; top: -5px; bottom: -3px; width: 0; border-left: 1.5px solid var(--ink);
    transition: left .6s cubic-bezier(.32,.72,0,1); }
  .pace::before { content: ''; position: absolute; top: -3px; left: -3.75px; border: 3px solid transparent;
    border-top: 4px solid var(--ink); }
  .meta { display: flex; justify-content: space-between; color: var(--ink3); font-size: 10.5px;
    font-variant-numeric: tabular-nums; margin-top: 6px; }
  .meta .pacetxt b { font-weight: 600; color: var(--ink2); }
  .ft { display: flex; align-items: center; gap: 8px; padding: 9px 14px 11px; border-top: .5px solid var(--hair); }
  .ft .st { color: var(--ink3); font-size: 10.5px; flex: 1; }
  button.rf { font: 600 11px var(--f); color: var(--ink); background: var(--btn); border: .5px solid var(--pill-bd);
    border-radius: 7px; padding: 4.5px 11px; cursor: default; transition: background .15s ease, transform .1s ease; }
  button.rf:hover { background: var(--btn-h); } button.rf:active { transform: scale(.96); }
  @media (prefers-reduced-motion: reduce) { * { transition: none !important; animation: none !important; } }
  `;

  const winRow = (id, label) => `
    <div class="w" id="w${id}">
      <div class="top"><span class="wl">${label}</span><span class="big"><span id="u${id}">—</span><i> / <span id="t${id}"></span></i></span><span class="pct" id="p${id}">—</span></div>
      <div class="barwrap"><div class="bar"><div class="fill" id="f${id}"></div><span class="pace" id="k${id}"></span></div></div>
      <div class="meta"><span class="pacetxt" id="m${id}"></span><span id="e${id}"></span></div>
    </div>`;

  sh.innerHTML = `<style>${css}</style>
  <div class="root" part="root">
    <div class="pill" title="额度 — 点击查看详情">
      <span class="dot" id="dot"></span>
      <span class="seg"><span class="lb">5h</span><span class="cap"><i id="c5"></i></span><span class="num" id="n5">—</span></span>
      <span class="sep"></span>
      <span class="seg"><span class="lb">7d</span><span class="cap"><i id="c7"></i></span><span class="num" id="n7">—</span></span>
    </div>
    <div class="pop" id="pop" role="dialog" aria-label="额度详情">
      <div class="hd"><span class="dot" id="dot2"></span><span class="t">额度</span><span class="asof" id="asof"></span></div>
      <div class="banner" id="banner">已达阈值,流量正经由中继备用通道</div>
      ${winRow('5', '5 小时')}
      ${winRow('7', '7 天')}
      <div class="ft"><span class="st" id="st">连接中…</span><button class="rf" id="rf">刷新</button></div>
    </div>
  </div>`;

  const R = $(sh, '.root'), pill = $(sh, '.pill'), pop = $(sh, '#pop');

  /* ------------------------------ 主题跟随 ------------------------------ */
  function applyTheme() {
    const dt = (document.documentElement.dataset.theme || '').toLowerCase();
    const light = dt ? dt.includes('light') : matchMedia('(prefers-color-scheme: light)').matches;
    R.classList.toggle('light', light);
  }
  applyTheme();
  new MutationObserver(applyTheme).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'class'] });
  matchMedia('(prefers-color-scheme: light)').addEventListener('change', applyTheme);

  /* ------------------------------ 挂载与定位(碰撞感知) ------------------------------ */
  function bandRect() {
    const drag = document.querySelector('.drag-region');
    if (drag) {
      const r = drag.getBoundingClientRect();
      if (r.width > innerWidth * 0.4 && r.height >= 18 && r.height <= 90 && r.top < 120) return r;
    }
    return null;
  }
  function usableRight() {
    // WCO 场景下排除原生窗口按钮区
    const probe = document.createElement('div');
    probe.dataset.mqwProbe = '1';
    probe.style.cssText = 'position:fixed;top:0;left:env(titlebar-area-x,-1px);width:env(titlebar-area-width,-1px);visibility:hidden;pointer-events:none';
    document.body.appendChild(probe);
    const pr = probe.getBoundingClientRect();
    probe.remove();
    if (pr.width > 0) return Math.min(innerWidth - 8, pr.left + pr.width - 4);
    return innerWidth - (isHttp ? 12 : 156);
  }
  // 在标题栏横带内收集真实障碍物(几何遍历,不受 z 层/宽容器/内嵌面板欺骗),
  // 合并为区间后从右向左找能放下胶囊的空档
  const EMBED = new Set(['IFRAME', 'WEBVIEW', 'EMBED', 'OBJECT', 'CANVAS', 'VIDEO', 'IMG']);
  function findSpot(pillW, band) {
    const R2 = usableRight();
    const L = Math.max(band.left + 8, innerWidth * 0.25);
    const bandH = band.height;
    const obs = [];
    for (const el of document.querySelectorAll('body *')) {
      if (el === host || el.dataset && 'mqwProbe' in el.dataset) continue;
      const r = el.getBoundingClientRect();
      if (!(r.width > 0 && r.height > 0)) continue;
      const overlap = Math.min(r.bottom, band.bottom) - Math.max(r.top, band.top);
      if (overlap < 6) continue;                            // 与横带垂直不相交
      const embed = EMBED.has(el.tagName);
      // 小型控件(标签/按钮/图标)或内嵌不透明内容视为障碍;结构性大容器忽略
      if (!embed && !(r.width < innerWidth * 0.5 && r.height <= bandH * 1.8)) continue;
      if (r.right < L || r.left > R2) continue;
      obs.push({ l: r.left - 4, r: r.right + 4 });
    }
    obs.sort((a, b) => a.l - b.l);
    const merged = [];
    for (const o of obs) {
      const m = merged[merged.length - 1];
      if (m && o.l <= m.r + 4) m.r = Math.max(m.r, o.r); else merged.push({ l: o.l, r: o.r });
    }
    let edgeR = R2;
    for (let i = merged.length - 1; i >= -1; i--) {
      const gapL = i >= 0 ? merged[i].r : L;
      if (edgeR - gapL >= pillW + 10) {
        return { top: band.top + (band.height - 24) / 2, right: innerWidth - edgeR + 5 };
      }
      if (i >= 0) edgeR = Math.min(edgeR, merged[i].l);
    }
    return null;
  }
  let lastPos = { top: -1, right: -1 };
  function place() {
    // 手动覆盖优先
    const mTop = parseFloat(localStorage.getItem(LS.top));
    const mRight = parseFloat(localStorage.getItem(LS.right));
    if (Number.isFinite(mTop) || Number.isFinite(mRight)) {
      applyPos(Number.isFinite(mTop) ? mTop : 5, Number.isFinite(mRight) ? mRight : 156, false);
      return;
    }
    const band = bandRect();
    if (!band) { applyPos(isHttp ? 8 : 5, innerWidth - usableRight() + 5, false); return; }
    const pillW = pill.offsetWidth || 230;
    let spot = findSpot(pillW, band);
    let compact = false;
    if (!spot) {                       // 放不下 → 压缩胶囊再试
      compact = true;
      spot = findSpot(150, band);
    }
    if (spot) applyPos(spot.top, spot.right, compact);
    else applyPos(band.bottom + 6, innerWidth - usableRight() + 5, false);   // 最后退路:栏下方
  }
  function applyPos(top, right, compact) {
    R.classList.toggle('compact', !!compact);
    if (Math.abs(top - lastPos.top) < 3 && Math.abs(right - lastPos.right) < 3) return;
    lastPos = { top, right };
    host.style.cssText = `position:fixed;top:${top}px;right:${right}px;z-index:2147483645;-webkit-app-region:no-drag;`;
  }
  let placeT = 0;
  const requestPlace = () => { clearTimeout(placeT); placeT = setTimeout(place, 350); };

  function mount() {
    if (!document.body) return setTimeout(mount, 50);
    document.body.appendChild(host);
    place();
    setTimeout(place, 1200);                    // 应用首帧渲染后再校准一次
    addEventListener('resize', requestPlace);
    new MutationObserver((muts) => {
      // 忽略自己(挂载点/探针)引起的变动,避免自循环
      const own = n => n === host || (n && n.dataset && 'mqwProbe' in n.dataset);
      if (muts.every(m => [...m.addedNodes, ...m.removedNodes].every(own))) return;
      requestPlace();
    }).observe(document.body, { childList: true, subtree: true });
    setInterval(place, 15000);                  // 兜底周期校准
    connect();
    fetchBudget();
    setInterval(fetchBudget, 600000);           // 每 10 分钟拉一次总额度校准
    setInterval(tick, 1000);
  }

  /* ------------------------------ 渲染 ------------------------------ */
  function render() {
    for (const [label, id] of [['5h', '5'], ['7d', '7']]) {
      const w = winOf(label);
      const pct = w ? w.usedPercent : null;
      const used = credits(label, pct), total = creditTotal(label);
      // 胶囊
      $(sh, '#c' + id).style.width = (pct == null ? 0 : clamp(pct, 0, 100)) + '%';
      $(sh, '#n' + id).innerHTML = used == null ? '—'
        : `${fmtCred(used, total)}<i>/${total >= 1000 ? total.toLocaleString() : total}</i>`;
      // 弹层
      $(sh, '#u' + id).textContent = used == null ? '—' : fmtCred(used, total);
      $(sh, '#t' + id).textContent = total >= 1000 ? total.toLocaleString() : total;
      $(sh, '#p' + id).textContent = pct == null ? '' : pct.toFixed(1) + '%';
      $(sh, '#f' + id).style.width = (pct == null ? 0 : clamp(pct, 0, 100)) + '%';
    }
    // 状态点: 实心=在线, 空心=断开, 呼吸=failover
    for (const id of ['#dot', '#dot2']) {
      $(sh, id).className = 'dot' + (S.connected ? '' : ' off') + (S.claude && S.claude.engaged ? ' pulse' : '');
    }
    $(sh, '#banner').classList.toggle('on', !!(S.claude && S.claude.engaged));
    $(sh, '#st').textContent = S.connected ? '本地实时 · ws://' + (localStorage.getItem(LS.host) || '') : '已断开,重连中…';
    tick();
    requestPlace();   // 数值变化可能改变胶囊宽度,重新避让
  }

  // 每秒: 倒计时 + 均速参考标(随时间流逝移动)
  function tick() {
    for (const [label, id] of [['5h', '5'], ['7d', '7']]) {
      const w = winOf(label);
      $(sh, '#e' + id).textContent = w ? fmtEta(w.resetAt) : '';
      const pace = w ? pacePct(label, w.resetAt) : null;
      const k = $(sh, '#k' + id), m = $(sh, '#m' + id);
      if (pace == null) { k.style.display = 'none'; m.textContent = ''; continue; }
      k.style.display = '';
      k.style.left = pace + '%';
      const diff = (w.usedPercent ?? 0) - pace;
      m.innerHTML = `均速 ${pace.toFixed(0)}% · ` + (diff <= 0
        ? `<b>低于均速 ${(-diff).toFixed(1)}%</b>`
        : `<b>超出均速 ${diff.toFixed(1)}%</b>`);
    }
    $(sh, '#asof').textContent = S.asOf ? fmtClock(S.asOf) : '';
  }

  /* ------------------------------ 交互 ------------------------------ */
  function positionPop() {
    const r = pill.getBoundingClientRect();
    pop.style.top = (r.bottom + 8) + 'px';
    pop.style.right = Math.max(8, innerWidth - r.right) + 'px';
  }
  function setOpen(v) {
    S.open = v;
    if (v) { positionPop(); poll(); }
    pop.classList.toggle('on', v);
  }
  pill.addEventListener('click', (e) => { e.stopPropagation(); setOpen(!S.open); });
  $(sh, '#rf').addEventListener('click', (e) => { e.stopPropagation(); poll(); });
  addEventListener('click', (e) => { if (S.open && !e.composedPath().includes(host)) setOpen(false); });
  addEventListener('keydown', (e) => { if (e.key === 'Escape') setOpen(false); });
  addEventListener('resize', () => { if (S.open) positionPop(); });

  /* ------------------------------ 启动 ------------------------------ */
  if (document.readyState === 'loading') addEventListener('DOMContentLoaded', mount);
  else mount();
})();
