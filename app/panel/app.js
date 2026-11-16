'use strict';
(() => {
  const NS = 'http://www.w3.org/2000/svg';
  const $ = (sel, root = document) => root.querySelector(sel);
  const esc = (v) => String(v ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const reduceMotion = window.matchMedia('(prefers-reduced-motion: reduce)').matches;
  const KIND = {
    work: { label: 'Работа', long: 'рабочий OpenVPN', order: 0 },
    amnezia: { label: 'Amnezia', long: 'AmneziaVPN', order: 1 },
    direct: { label: 'Напрямую', long: 'напрямую через роутер', order: 2 },
    other: { label: 'Другой', long: 'другой адаптер', order: 3 },
    system: { label: 'Система', long: 'системный маршрут', order: 4 },
    none: { label: 'Нет пути', long: 'маршрут не найден', order: 5 },
  };
  const VIA_HINT = {
    work: (s) => `Адрес пойдёт через рабочий OpenVPN${s ? ` (шлюз ${s.config.workGateway})` : ''}. Для ресурсов, которые открываются только из рабочей сети.`,
    amnezia: () => 'Адрес пойдёт через AmneziaVPN, даже если рабочий VPN тоже его маршрутизирует.',
    direct: (s) => `Адрес пойдёт мимо обоих VPN через ваш роутер${s && s.gateway ? ` (${s.gateway.nextHop})` : ''}. Удобно для банков и госсервисов, которые не любят VPN.`,
  };
  const plural = (n, forms) => {
    const a = Math.abs(n) % 100, b = a % 10;
    if (a > 10 && a < 20) return forms[2];
    if (b > 1 && b < 5) return forms[1];
    if (b === 1) return forms[0];
    return forms[2];
  };

  // ---------- token & api ----------
  // The key arrives once via the shortcut (#t=...) and is remembered by this browser,
  // so later you can simply type the address. It never stays in the address bar.
  let token = null;
  const store = {
    get() { try { return localStorage.getItem('rg-token') || sessionStorage.getItem('rg-token'); } catch (e) { return null; } },
    set(v) { try { localStorage.setItem('rg-token', v); } catch (e) { try { sessionStorage.setItem('rg-token', v); } catch (e2) { /* private mode */ } } },
    clear() { try { localStorage.removeItem('rg-token'); sessionStorage.removeItem('rg-token'); } catch (e) { /* ignore */ } },
  };
  const hashMatch = location.hash.match(/t=([0-9a-f]{32,128})/i);
  if (hashMatch) {
    token = hashMatch[1];
    store.set(token);
    history.replaceState(null, '', location.pathname);
  } else {
    token = store.get();
  }
  const showLock = () => { store.clear(); $('#lock').classList.remove('hidden'); };
  if (!token) showLock();

  async function api(path, opts = {}) {
    const headers = { 'X-Guard-Token': token || '' };
    if (opts.body !== undefined) headers['Content-Type'] = 'application/json';
    const res = await fetch(path, {
      method: opts.method || 'GET', headers, cache: 'no-store',
      body: opts.body !== undefined ? JSON.stringify(opts.body) : undefined,
    });
    let data = null;
    try { data = await res.json(); } catch (e) { data = null; }
    if (res.status === 401) { showLock(); const err = new Error('unauthorized'); err.auth = true; throw err; }
    if (!res.ok) throw new Error((data && data.error) || `Ошибка HTTP ${res.status}`);
    return data;
  }

  function toast(html, isError) {
    const el = document.createElement('div');
    el.className = 'toast' + (isError ? ' err' : '');
    el.innerHTML = html;
    $('#toasts').appendChild(el);
    setTimeout(() => { el.style.opacity = '0'; el.style.transition = 'opacity .4s'; }, 3600);
    setTimeout(() => el.remove(), 4100);
  }

  // ---------- theme ----------
  try {
    const saved = localStorage.getItem('rg-theme');
    if (saved === 'light' || saved === 'dark') document.documentElement.dataset.theme = saved;
  } catch (e) { /* ignore */ }
  $('#themeBtn').addEventListener('click', () => {
    const current = document.documentElement.dataset.theme ||
      (window.matchMedia('(prefers-color-scheme: light)').matches ? 'light' : 'dark');
    const next = current === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = next;
    try { localStorage.setItem('rg-theme', next); } catch (e) { /* ignore */ }
  });

  // ---------- topology ----------
  const ICONS = {
    pc: 'M3 4h18v12H3z M8 20h8 M12 16v4',
    work: 'M4 8h16v11H4z M9 8V5h6v3 M4 13h16',
    amnezia: 'M12 3l8 3v6c0 5-3.5 8-8 9-4.5-1-8-4-8-9V6z M9 12l2 2 4-4',
    direct: 'M2 9a15 15 0 0 1 20 0 M5 12.5a10 10 0 0 1 14 0 M8.5 16a5 5 0 0 1 7 0 M12 19.5h.01',
    office: 'M4 21V6l8-3 8 3v15 M9 9h1 M14 9h1 M9 13h1 M14 13h1 M10 21v-4h4v4',
    globe: 'M12 3a9 9 0 1 0 0 18a9 9 0 1 0 0-18 M3 12h18 M12 3c3.2 3.5 3.2 14.5 0 18 M12 3c-3.2 3.5-3.2 14.5 0 18',
    home: 'M3 11l9-7 9 7 M5 10v10h14V10 M10 20v-5h4v5',
  };
  const LANES = [
    { kind: 'work', y: 60, dest: 'Рабочая сеть', destIcon: 'office' },
    { kind: 'amnezia', y: 165, dest: 'Интернет', destIcon: 'globe' },
    { kind: 'direct', y: 270, dest: 'Домашняя сеть', destIcon: 'home' },
  ];
  const topo = $('#topo');
  const svgEl = (tag, attrs = {}, parent) => {
    const el = document.createElementNS(NS, tag);
    for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
    if (parent) parent.appendChild(el);
    return el;
  };
  const laneEls = {};
  const nodeEls = {};
  function makeNode(id, kind, x, y, w, h, icon, title) {
    const g = svgEl('g', { class: `node k-${kind}${id === 'pc' ? ' pc on' : ''}` }, topo);
    svgEl('rect', { class: 'halo', x, y, width: w, height: h, rx: 16 }, g);
    svgEl('rect', { x, y, width: w, height: h, rx: 16 }, g);
    const ico = svgEl('g', { transform: `translate(${x + 15} ${y + h / 2 - 12})` }, g);
    svgEl('path', { class: 'ico', d: ICONS[icon] }, ico);
    const t = svgEl('text', { class: 't-title', x: x + 50, y: y + h / 2 - 3 }, g);
    t.textContent = title;
    const s = svgEl('text', { class: 't-sub', x: x + 50, y: y + h / 2 + 15 }, g);
    s.textContent = '…';
    nodeEls[id] = { g, title: t, sub: s };
  }
  (function buildTopo() {
    for (const lane of LANES) {
      const d = `M190 165 C 290 165 295 ${lane.y} 395 ${lane.y} L 760 ${lane.y}`;
      const g = svgEl('g', { class: `lane k-${lane.kind}` }, topo);
      svgEl('path', { class: 'lane-base', d }, g);
      svgEl('path', { class: 'lane-flow', d }, g);
      const label = svgEl('text', { class: 't-lane', x: 662, y: lane.y - 10, 'text-anchor': 'middle' }, g);
      laneEls[lane.kind] = { g, d, label };
    }
    svgEl('g', { id: 'packets' }, topo);
    makeNode('pc', 'pc', 30, 123, 160, 84, 'pc', 'Этот ПК');
    for (const lane of LANES) {
      makeNode(`gw-${lane.kind}`, lane.kind, 395, lane.y - 32, 170, 64, lane.kind, { work: 'OpenVPN', amnezia: 'AmneziaVPN', direct: 'Wi-Fi' }[lane.kind]);
      makeNode(`dst-${lane.kind}`, lane.kind, 760, lane.y - 32, 170, 64, lane.destIcon, lane.dest);
    }
  })();
  const fit = (text, max) => (text.length > max ? text.slice(0, max - 1) + '…' : text);
  function setNode(id, on, sub, title) {
    const n = nodeEls[id];
    n.g.classList.toggle('on', !!on);
    n.g.classList.toggle('off', !on);
    n.sub.textContent = fit(sub, 18);
    if (title) n.title.textContent = fit(title, 14);
  }
  function sendPacket(kind, faint) {
    const lane = laneEls[kind];
    if (!lane || reduceMotion) return;
    const dur = faint ? 2.4 : 1.25;
    const c = svgEl('circle', { r: faint ? 3.2 : 5.5, class: `packet k-${kind}${faint ? ' faint' : ''}` });
    const am = svgEl('animateMotion', { dur: `${dur}s`, path: lane.d, begin: 'indefinite', fill: 'freeze', calcMode: 'spline', keyTimes: '0;1', keySplines: '0.45 0 0.25 1' }, c);
    $('#packets', topo).appendChild(c);
    am.beginElement();
    setTimeout(() => c.remove(), dur * 1000 + 80);
    if (!faint) {
      lane.g.classList.add('hit');
      setTimeout(() => lane.g.classList.remove('hit'), 1500);
    }
  }
  setInterval(() => {
    if (document.hidden) return;
    const on = LANES.filter((l) => laneEls[l.kind].g.classList.contains('on'));
    if (on.length) sendPacket(on[Math.floor(Math.random() * on.length)].kind, true);
  }, 1700);

  // ---------- state ----------
  let state = null;
  let lastOkAt = 0;
  let prevRouteKeys = null;
  let routeDelta = '';
  const ui = { kind: 'all', search: '', noise: false, sort: 'kind', asc: true, via: 'work', confirmId: null, confirmTimer: 0, logMode: 'all' };
  const html = {};
  const setHtml = (el, key, value) => { if (html[key] !== value) { html[key] = value; el.innerHTML = value; return true; } return false; };
  const routeKey = (r) => `${r.prefix}|${r.ifIndex}|${r.nextHop}`;

  function ipNum(prefix) {
    const [ip, len] = prefix.split('/');
    const p = ip.split('.').map(Number);
    return ((p[0] << 24) >>> 0) + (p[1] << 16) + (p[2] << 8) + p[3] + (Number(len) || 0) / 100;
  }
  const fmtTime = (d) => d.toLocaleTimeString('ru-RU', { hour: '2-digit', minute: '2-digit' });
  const fmtAge = (sec) => (sec < 90 ? `${Math.round(sec)} с` : sec < 5400 ? `${Math.round(sec / 60)} мин` : `${Math.round(sec / 3600)} ч`);

  function setPulse(kind, text, title) {
    const p = $('#pulse');
    p.dataset.state = kind;
    $('#pulseText').textContent = text;
    if (title) p.title = title;
  }

  function setAlert(kind, title, text) {
    const box = $('#guardAlert');
    if (!kind) { box.classList.add('hidden'); return; }
    box.classList.remove('hidden');
    box.classList.toggle('warn', kind === 'warn');
    $('#guardAlertTitle').textContent = title;
    $('#guardAlertText').textContent = text;
  }

  function renderPulse(s) {
    const st = s.guard && s.guard.status;
    if (!st || !st.time) {
      setPulse('bad', 'Страж не запущен');
      return setAlert('bad', 'Страж маршрутов не запущен', 'Маршруты сейчас никто не защищает. Он должен подняться сам в течение минуты; если нет — запустите 04-Enable.cmd.');
    }
    const age = (Date.parse(s.now) - Date.parse(st.time)) / 1000;
    const poll = st.pollSeconds || 3;
    const started = st.startedAt ? new Date(st.startedAt) : null;
    const title = started ? `Работает с ${started.toLocaleString('ru-RU')}, цикл ${st.cycleMs} мс` : '';
    if (age > poll * 3 + 4) {
      setPulse('bad', `Страж молчит ${fmtAge(age)}`, title);
      return setAlert('bad', `Страж не отвечает уже ${fmtAge(age)}`,
        'Пока он молчит, Amnezia может перехватывать рабочие и домашние адреса, а ваши правила не обновляются. Автоперезапуск срабатывает раз в минуту; если баннер не исчезает — запустите 04-Enable.cmd.');
    }
    if (st.lastError) {
      setPulse('warn', 'Страж: ошибка цикла', title);
      return setAlert('warn', 'Страж работает, но цикл завершается с ошибкой', st.lastError);
    }
    setPulse('ok', `Страж на посту · ${Math.max(0, Math.round(age))} с назад`, title);
    setAlert(null);
  }

  function renderTopo(s) {
    const ifs = new Map(s.interfaces.map((i) => [i.ifIndex, i]));
    const phys = s.gateway ? ifs.get(s.gateway.ifIndex) : null;
    const work = s.activeWorkIds.length ? ifs.get(s.activeWorkIds[0]) : null;
    const amn = s.amneziaIds.length ? ifs.get(s.amneziaIds[0]) : null;
    setNode('pc', true, phys && phys.ipv4[0] ? phys.ipv4[0] : 'нет сети', s.computer || 'Этот ПК');

    setNode('gw-work', !!work, work ? `шлюз ${s.config.workGateway}` : 'не подключён');
    setNode('dst-work', !!work, work ? `${s.workRouteCount} ${plural(s.workRouteCount, ['сеть', 'сети', 'сетей'])}` : 'недоступна');
    laneEls.work.label.textContent = work ? 'туннель OpenVPN' : 'OpenVPN отключён';

    setNode('gw-amnezia', !!amn, amn ? (amn.ipv4[0] || 'подключён') : 'не подключён');
    setNode('dst-amnezia', true, amn ? 'всё остальное' : 'идёт напрямую');
    laneEls.amnezia.label.textContent = amn ? 'маршрут по умолчанию' : 'Amnezia отключена';

    const lan = s.routes.find((r) => r.kind === 'direct' && r.nextHop === '0.0.0.0' && !r.noise && !r.prefix.endsWith('/32'));
    const physTitle = phys ? (/wi-?fi|wireless|wlan|802\.11/i.test(phys.description) ? 'Wi-Fi' : 'Ethernet') : 'Wi-Fi';
    setNode('gw-direct', !!phys, phys ? `роутер ${s.gateway.nextHop}` : 'нет шлюза', physTitle);
    setNode('dst-direct', !!phys, lan ? lan.prefix : 'локальная сеть');
    laneEls.direct.label.textContent = phys ? `${s.lanRouteCount} ${plural(s.lanRouteCount, ['локальная сеть', 'локальные сети', 'локальных сетей'])}` : 'нет подключения';

    laneEls.work.g.classList.toggle('on', !!work);
    laneEls.amnezia.g.classList.toggle('on', !!amn);
    laneEls.direct.g.classList.toggle('on', !!phys);

    const others = s.interfaces.filter((i) => i.status === 'Up' && i.kind === 'other');
    setHtml($('#others'), 'others', others.length
      ? `<span>Ещё активны:</span>${others.map((o) => `<span class="chip-lite">${esc(o.name)}${o.ipv4[0] ? ' · ' + esc(o.ipv4[0]) : ''}</span>`).join('')}`
      : '');
  }

  function animateNumber(el, to) {
    const from = Number(el.dataset.v);
    el.dataset.v = to;
    if (!Number.isFinite(from) || from === to || reduceMotion) { el.textContent = to; return; }
    const start = performance.now();
    const step = (t) => {
      const k = Math.min(1, (t - start) / 600);
      el.textContent = Math.round(from + (to - from) * (1 - Math.pow(1 - k, 3)));
      if (k < 1) requestAnimationFrame(step);
    };
    requestAnimationFrame(step);
  }

  function renderStats(s) {
    animateNumber($('#stWork'), s.workRouteCount);
    animateNumber($('#stLan'), s.lanRouteCount);
    animateNumber($('#stConf'), s.conflicts);
    const tile = $('#tileConflicts');
    tile.classList.toggle('bad', s.conflicts > 0);
    tile.classList.toggle('good', s.conflicts === 0);
    $('#stConfSub').textContent = s.conflicts === 0 ? 'всё чисто' : `исправятся за ${s.config.pollSeconds} с`;
  }

  // ---------- rules ----------
  function ruleStatusMap(s) {
    const map = new Map();
    const list = (s.guard.status && s.guard.status.rules) || [];
    for (const r of list) if (r) map.set(r.id, r);
    return map;
  }
  function renderRules(s) {
    const statuses = ruleStatusMap(s);
    $('#rulesCount').textContent = s.rules.length;
    let out;
    if (!s.rules.length) {
      out = `<li class="empty">Правил пока нет.<br>Например: <b>10.20.0.0/16</b> через работу, <b>chatgpt.com</b> через Amnezia или сайт банка — напрямую.</li>`;
    } else {
      out = s.rules.map((r) => {
        const st = statuses.get(r.id);
        const enabled = r.enabled !== false;
        let pill = '<span class="pill pending">применяется…</span>';
        let reason = '';
        if (!enabled) pill = '<span class="pill off">выключено</span>';
        else if (st) {
          const labels = { applied: '✓ работает', waiting: 'ожидает', error: 'ошибка', off: 'выключено' };
          pill = `<span class="pill ${esc(st.state)}">${labels[st.state] || esc(st.state)}</span>`;
          reason = st.reason ? `<span class="reason">${esc(st.reason)}</span>` : '';
        }
        let chips = '';
        if (st && r.kind === 'host' && st.prefixes && st.prefixes.length) {
          const ips = st.prefixes.map((p) => p.replace('/32', ''));
          chips = ips.slice(0, 6).map((ip) => `<span class="ipchip">${esc(ip)}</span>`).join('') + (ips.length > 6 ? `<span class="ipchip">+${ips.length - 6}</span>` : '');
        }
        const confirm = ui.confirmId === r.id;
        return `<li class="rule k-${esc(r.via)}${enabled ? '' : ' disabled'}" data-id="${esc(r.id)}">
          <div><div class="target">${esc(r.target)}</div>${r.note ? `<div class="note">${esc(r.note)}</div>` : ''}</div>
          <div class="controls">
            <div class="seg small">${['work', 'amnezia', 'direct'].map((v) => `<button type="button" class="seg-btn k-${v}${r.via === v ? ' active' : ''}" data-act="via" data-via="${v}" title="Через: ${KIND[v].label}">${KIND[v].label}</button>`).join('')}</div>
            <label class="switch-label" title="${enabled ? 'Выключить' : 'Включить'}"><input type="checkbox" data-act="toggle"${enabled ? ' checked' : ''}><span class="switch"></span></label>
            <button type="button" class="del${confirm ? ' confirm' : ''}" data-act="del" title="Удалить правило">${confirm ? 'Удалить?' : '<svg viewBox="0 0 24 24" width="15" height="15" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/></svg>'}</button>
          </div>
          <div class="status">${pill}${reason}${chips}</div>
        </li>`;
      }).join('');
    }
    setHtml($('#rulesList'), 'rules', out);
  }

  $('#rulesList').addEventListener('click', async (e) => {
    const btn = e.target.closest('[data-act]');
    if (!btn || btn.dataset.act === 'toggle') return;
    const id = btn.closest('.rule').dataset.id;
    try {
      if (btn.dataset.act === 'via') {
        if (btn.classList.contains('active')) return;
        await api(`/api/rules/${id}`, { method: 'PATCH', body: { via: btn.dataset.via } });
        toast(`Путь изменён: <b>${KIND[btn.dataset.via].label}</b>`);
        kick();
      } else if (btn.dataset.act === 'del') {
        if (ui.confirmId !== id) {
          ui.confirmId = id;
          clearTimeout(ui.confirmTimer);
          ui.confirmTimer = setTimeout(() => { ui.confirmId = null; if (state) renderRules(state); }, 3000);
          renderRules(state);
          return;
        }
        ui.confirmId = null;
        await api(`/api/rules/${id}`, { method: 'DELETE' });
        toast('Правило удалено, маршрут снимется в течение пары секунд');
        kick();
      }
    } catch (err) { if (!err.auth) toast(esc(err.message), true); }
  });
  $('#rulesList').addEventListener('change', async (e) => {
    const input = e.target.closest('[data-act="toggle"]');
    if (!input) return;
    const id = input.closest('.rule').dataset.id;
    try {
      await api(`/api/rules/${id}`, { method: 'PATCH', body: { enabled: input.checked } });
      toast(input.checked ? 'Правило включено' : 'Правило выключено');
      kick();
    } catch (err) { input.checked = !input.checked; if (!err.auth) toast(esc(err.message), true); }
  });

  function setVia(via) {
    ui.via = via;
    for (const b of document.querySelectorAll('#viaSeg .seg-btn')) {
      const on = b.dataset.via === via;
      b.classList.toggle('active', on);
      b.setAttribute('aria-checked', on ? 'true' : 'false');
    }
    updateHint();
  }
  function updateHint() {
    const target = $('#ruleTarget').value.trim();
    let hint = VIA_HINT[ui.via](state);
    if (target && /[a-z]/i.test(target) && !/^\d/.test(target)) hint += ' Домен перепроверяется каждые 5 минут.';
    $('#viaHint').textContent = hint;
  }
  $('#viaSeg').addEventListener('click', (e) => { const b = e.target.closest('.seg-btn'); if (b) setVia(b.dataset.via); });
  $('#ruleTarget').addEventListener('input', updateHint);
  $('#ruleForm').addEventListener('submit', async (e) => {
    e.preventDefault();
    const btn = $('#ruleForm .btn');
    btn.disabled = true;
    try {
      const rule = await api('/api/rules', { method: 'POST', body: { target: $('#ruleTarget').value, via: ui.via, note: $('#ruleNote').value } });
      toast(`Добавлено: <b>${esc(rule.target)}</b> → ${KIND[rule.via].label}. Страж применит за пару секунд.`);
      $('#ruleTarget').value = '';
      $('#ruleNote').value = '';
      updateHint();
      sendPacket(rule.via, false);
      kick();
    } catch (err) { if (!err.auth) toast(esc(err.message), true); }
    finally { btn.disabled = false; }
  });

  // ---------- trace ----------
  function renderExamples(s) {
    const work = s.routes.find((r) => r.kind === 'work' && r.prefix.endsWith('/32') && r.nextHop !== '0.0.0.0');
    const list = [];
    if (work) list.push(work.prefix.replace('/32', ''));
    list.push('youtube.com');
    if (s.gateway) list.push(s.gateway.nextHop);
    list.push('1.1.1.1');
    setHtml($('#traceExamples'), 'examples', list.map((x) => `<button type="button" data-q="${esc(x)}">${esc(x)}</button>`).join(''));
  }
  $('#traceExamples').addEventListener('click', (e) => {
    const b = e.target.closest('[data-q]');
    if (!b) return;
    $('#traceInput').value = b.dataset.q;
    runTrace();
  });
  $('#traceForm').addEventListener('submit', (e) => { e.preventDefault(); runTrace(); });
  async function runTrace() {
    const q = $('#traceInput').value.trim();
    if (!q) return;
    const btn = $('#traceForm .btn');
    btn.disabled = true;
    const box = $('#traceResult');
    try {
      const res = await api('/api/trace', { method: 'POST', body: { target: q } });
      const head = res.host
        ? `<div class="trace-head"><b>${esc(res.host)}</b> → ${res.results.length} ${plural(res.results.length, ['адрес', 'адреса', 'адресов'])}</div>`
        : '';
      box.innerHTML = head + res.results.map((r) => {
        const k = KIND[r.kind] ? r.kind : 'other';
        const hop = r.nextHop && r.nextHop !== '0.0.0.0' ? r.nextHop : 'в той же сети';
        const prefix = r.prefix === '0.0.0.0/0' ? 'по умолчанию (0.0.0.0/0)' : r.prefix;
        const rule = r.rule ? `<div class="rule-note">Сработало ваше правило «${esc(r.rule.target)}» → ${KIND[r.rule.via] ? KIND[r.rule.via].label : esc(r.rule.via)}${r.rule.enabled ? '' : ' (выключено)'}</div>` : '';
        return `<div class="hop k-${k}">
          <span class="ip">${esc(r.ip)}</span>
          <span class="path">→ ${esc(KIND[k].long)}</span>
          <button type="button" class="btn mini" data-add="${esc(res.host || r.ip)}">+ правило</button>
          <div class="meta">${r.error ? `<span>${esc(r.error)}</span>` : `<span>адаптер <b>${esc(r.alias)}</b></span><span>шлюз <b>${esc(hop)}</b></span><span>маршрут <b>${esc(prefix)}</b></span>${r.source ? `<span>с адреса <b>${esc(r.source)}</b></span>` : ''}`}</div>
          ${rule}
        </div>`;
      }).join('');
      [...new Set(res.results.map((r) => r.kind))].forEach((k, i) => setTimeout(() => sendPacket(k, false), i * 350));
    } catch (err) {
      if (!err.auth) box.innerHTML = `<div class="hop k-none"><span class="ip">${esc(q)}</span><span class="path">${esc(err.message)}</span><span></span></div>`;
    } finally { btn.disabled = false; }
  }
  $('#traceResult').addEventListener('click', (e) => {
    const b = e.target.closest('[data-add]');
    if (!b) return;
    $('#ruleTarget').value = b.dataset.add;
    updateHint();
    $('#rulesCard').scrollIntoView({ behavior: reduceMotion ? 'auto' : 'smooth', block: 'center' });
    setTimeout(() => $('#ruleTarget').focus(), 300);
  });

  // ---------- routes table ----------
  const KIND_FILTERS = ['all', 'work', 'amnezia', 'direct', 'other'];
  function renderRoutes(s) {
    const keys = new Set(s.routes.map(routeKey));
    const fresh = new Set();
    if (prevRouteKeys) {
      let added = 0, removed = 0;
      for (const k of keys) if (!prevRouteKeys.has(k)) { fresh.add(k); added++; }
      for (const k of prevRouteKeys) if (!keys.has(k)) removed++;
      if (added || removed) routeDelta = `Последнее изменение в ${fmtTime(new Date())}: +${added} / −${removed}`;
    }
    prevRouteKeys = keys;

    const base = s.routes.filter((r) => ui.noise || !r.noise || r.managed);
    const counts = { all: base.length, work: 0, amnezia: 0, direct: 0, other: 0 };
    for (const r of base) counts[r.kind === 'system' ? 'other' : r.kind] = (counts[r.kind === 'system' ? 'other' : r.kind] || 0) + 1;
    const labels = { all: 'Все', work: 'Работа', amnezia: 'Amnezia', direct: 'Напрямую', other: 'Другие' };
    setHtml($('#kindChips'), 'chips', KIND_FILTERS.map((k) =>
      `<button type="button" class="chip k-${k}${ui.kind === k ? ' active' : ''}" data-kind="${k}">${labels[k]}<span class="n">${counts[k] || 0}</span></button>`).join(''));

    const q = ui.search.toLowerCase();
    let rows = base.filter((r) => {
      if (ui.kind !== 'all' && (r.kind === 'system' ? 'other' : r.kind) !== ui.kind) return false;
      if (q && !(`${r.prefix} ${r.nextHop} ${r.alias}`.toLowerCase().includes(q))) return false;
      return true;
    });
    const dir = ui.asc ? 1 : -1;
    const cmp = {
      kind: (a, b) => (KIND[a.kind].order - KIND[b.kind].order) || (ipNum(a.prefix) - ipNum(b.prefix)),
      prefix: (a, b) => ipNum(a.prefix) - ipNum(b.prefix),
      alias: (a, b) => a.alias.localeCompare(b.alias, 'ru') || (ipNum(a.prefix) - ipNum(b.prefix)),
      nextHop: (a, b) => ipNum(a.nextHop + '/0') - ipNum(b.nextHop + '/0'),
      metric: (a, b) => a.metric - b.metric,
    }[ui.sort];
    rows = rows.slice().sort((a, b) => cmp(a, b) * dir);

    for (const th of document.querySelectorAll('.routes th[data-sort]')) {
      th.classList.toggle('sorted', th.dataset.sort === ui.sort);
      th.classList.toggle('asc', th.dataset.sort === ui.sort && !ui.asc);
    }

    const body = rows.length ? rows.map((r) => {
      const tags = [];
      if (r.conflict) tags.push('<span class="tag conflict">конфликт</span>');
      if (r.managed === 'rule') tags.push('<span class="tag rule">правило</span>');
      if (r.managed === 'guard') tags.push('<span class="tag guard">страж</span>');
      if (r.prefix === '0.0.0.0/0') tags.push('<span class="tag default">по умолчанию</span>');
      const hop = r.nextHop === '0.0.0.0' ? '<span class="muted">в сети</span>' : esc(r.nextHop);
      const k = KIND[r.kind] ? r.kind : 'other';
      return `<tr class="${r.conflict ? 'conflict' : ''}${fresh.has(routeKey(r)) ? ' fresh' : ''}">
        <td class="mono">${esc(r.prefix)}</td>
        <td><span class="badge k-${k}">${KIND[k].label}</span></td>
        <td class="alias" title="${esc(r.alias)}">${esc(r.alias)} <span class="muted small">#${r.ifIndex}</span></td>
        <td class="mono">${hop}</td>
        <td class="num mono">${r.metric}</td>
        <td>${tags.join('')}</td>
      </tr>`;
    }).join('') : '<tr class="routes-empty"><td colspan="6">Под фильтр ничего не попало</td></tr>';
    // Keep fresh-row animation even if markup equals the previous one.
    if (fresh.size) html.routes = null;
    setHtml($('#routesBody'), 'routes', body);
    $('#routesFoot').textContent = `Показано ${rows.length} из ${s.routes.length}${routeDelta ? ' · ' + routeDelta : ''}`;
  }
  $('#kindChips').addEventListener('click', (e) => {
    const c = e.target.closest('[data-kind]');
    if (!c) return;
    ui.kind = c.dataset.kind;
    if (state) renderRoutes(state);
  });
  $('#routeSearch').addEventListener('input', (e) => { ui.search = e.target.value.trim(); if (state) renderRoutes(state); });
  $('#showNoise').addEventListener('change', (e) => { ui.noise = e.target.checked; if (state) renderRoutes(state); });
  document.querySelector('.routes thead').addEventListener('click', (e) => {
    const th = e.target.closest('th[data-sort]');
    if (!th) return;
    if (ui.sort === th.dataset.sort) ui.asc = !ui.asc; else { ui.sort = th.dataset.sort; ui.asc = true; }
    if (state) renderRoutes(state);
  });

  // ---------- log ----------
  let logLines = null;
  function describe(msg) {
    let m;
    if ((m = msg.match(/^Removed Amnezia conflict: ([^|]+)\|/))) return { type: 'conflict', c: 'amnezia', text: 'Убрана конфликтующая копия маршрута Amnezia', code: m[1] };
    if (/^Started/.test(msg)) return { type: 'start', c: 'work', text: 'Страж запущен' };
    if ((m = msg.match(/^Created direct endpoint\/discovery route: ([^|]+)/))) return { type: 'endpoint', c: 'direct', text: 'Прямой маршрут к серверу VPN / обнаружению устройств', code: m[1] };
    if ((m = msg.match(/^Removed old managed endpoint route: ([^|]+)/))) return { type: 'endpoint-old', c: 'other', text: 'Убран устаревший прямой маршрут', code: m[1] };
    if ((m = msg.match(/^Created custom route via (\w+): ([^|]+)/))) return { type: 'rule-add', c: 'ok', text: `Правило применено → ${KIND[m[1]] ? KIND[m[1]].label : m[1]}`, code: m[2] };
    if ((m = msg.match(/^Removed custom route: ([^|]+)/))) return { type: 'rule-del', c: 'other', text: 'Маршрут правила снят', code: m[1] };
    if ((m = msg.match(/^Loaded custom rules: (\d+)/))) return { type: 'rules', c: 'work', text: `Загружены правила: ${m[1]}` };
    if ((m = msg.match(/^Custom route failed: (\S+) - (.*)$/))) return { type: 'error', c: 'danger', text: `Не удалось применить правило: ${m[2]}`, code: m[1].split('|')[0] };
    if (/^Custom rules file is invalid/.test(msg)) return { type: 'error', c: 'danger', text: 'Файл правил повреждён, используются прежние правила' };
    if ((m = msg.match(/^Retry next cycle: (.*)$/))) return { type: 'warn', c: 'warn', text: `Сбой цикла, повтор: ${m[1]}` };
    return { type: 'other', c: 'other', text: msg };
  }
  function parseLog(lines) {
    const out = [];
    for (const line of lines) {
      const m = line.match(/^(\d{4}-\d{2}-\d{2}) (\d{2}:\d{2}:\d{2}) ([+-]\d{2}:\d{2}) (.*)$/);
      if (!m) continue;
      const at = new Date(`${m[1]}T${m[2]}${m[3]}`);
      out.push({ at, ...describe(m[4]) });
    }
    return out;
  }
  function renderLog() {
    const events = parseLog(logLines || []);
    // Sparkline + 24h counter.
    const now = state ? Date.parse(state.now) : Date.now();
    const bins = new Array(48).fill(0);
    let last = null, total = 0;
    for (const ev of events) {
      if (ev.type !== 'conflict') continue;
      const age = now - ev.at.getTime();
      if (age < 0 || age > 864e5) continue;
      total++;
      bins[47 - Math.min(47, Math.floor(age / 18e5))]++;
      last = ev.at;
    }
    animateNumber($('#stFixed'), total);
    $('#stFixedSub').textContent = last ? `за 24 ч · последний в ${fmtTime(last)}` : 'за 24 часа · тишина';
    const max = Math.max(1, ...bins);
    setHtml($('#spark'), 'spark', bins.map((v, i) => {
      const h = v ? Math.max(3, (v / max) * 32) : 2;
      return `<rect x="${i * 5}" y="${34 - h}" width="3.4" height="${h}" rx="1"${v ? '' : ' class="zero"'}></rect>`;
    }).join(''));

    // Group bursts: same type within a minute collapses into one line.
    const groups = [];
    for (const ev of events) {
      if (ui.logMode === 'important' && ev.type === 'conflict') continue;
      const g = groups[groups.length - 1];
      if (g && g.type === ev.type && ['conflict', 'endpoint', 'rule-add', 'rule-del'].includes(ev.type) && ev.at - g.end < 60e3) {
        g.items.push(ev); g.end = ev.at;
      } else groups.push({ type: ev.type, c: ev.c, text: ev.text, at: ev.at, end: ev.at, items: [ev] });
    }
    groups.reverse();
    const colors = { ok: 'var(--ok)', danger: 'var(--danger)', warn: 'var(--warn)' };
    const today = new Date(now).toDateString();
    const yesterday = new Date(now - 864e5).toDateString();
    let day = '';
    const out = [];
    for (const g of groups.slice(0, 160)) {
      const d = g.at.toDateString();
      if (d !== day) {
        day = d;
        out.push(`<li class="day">${d === today ? 'Сегодня' : d === yesterday ? 'Вчера' : g.at.toLocaleDateString('ru-RU', { day: 'numeric', month: 'long' })}</li>`);
      }
      const n = g.items.length;
      let text = g.text;
      if (n > 1 && g.type === 'conflict') text = `Убрано ${n} ${plural(n, ['конфликтующая копия', 'конфликтующие копии', 'конфликтующих копий'])} маршрутов Amnezia`;
      else if (n > 1) text = `${g.text} ×${n}`;
      const codes = g.items.map((i) => i.code).filter(Boolean);
      const code = codes.length ? ` <code>${esc(codes.slice(0, 4).join(', '))}${codes.length > 4 ? ` и ещё ${codes.length - 4}` : ''}</code>` : '';
      const kindClass = KIND[g.c] ? ` k-${g.c}` : '';
      const color = colors[g.c] ? ` data-c="${g.c}"` : '';
      out.push(`<li><span class="time">${g.at.toLocaleTimeString('ru-RU')}</span><span class="ic${kindClass}"${color}></span><span class="msg">${esc(text)}${code}</span></li>`);
    }
    if (!out.length) out.push('<li class="empty">Журнал пуст</li>');
    if (setHtml($('#logList'), 'log', out.join(''))) {
      for (const el of document.querySelectorAll('#logList .ic[data-c]')) el.style.setProperty('--c', colors[el.dataset.c]);
    }
  }
  $('#logSeg').addEventListener('click', (e) => {
    const b = e.target.closest('[data-log]');
    if (!b) return;
    ui.logMode = b.dataset.log;
    for (const x of document.querySelectorAll('#logSeg .seg-btn')) x.classList.toggle('active', x === b);
    renderLog();
  });

  // ---------- loop ----------
  let firstRender = true;
  async function refresh() {
    if (!token) return;
    try {
      const s = await api('/api/state');
      state = s;
      lastOkAt = Date.now();
      renderPulse(s);
      renderTopo(s);
      renderStats(s);
      renderRules(s);
      renderRoutes(s);
      if (firstRender) { firstRender = false; renderExamples(s); updateHint(); }
    } catch (err) {
      if (!err.auth) setPulse('bad', 'Панель не отвечает');
    }
  }
  async function refreshLog() {
    if (!token) return;
    try {
      const res = await api('/api/log');
      const lines = res.lines || [];
      if (!logLines || lines.length !== logLines.length || lines[lines.length - 1] !== logLines[logLines.length - 1]) {
        logLines = lines;
        renderLog();
      }
    } catch (err) { /* state loop reports connectivity */ }
  }
  let kickTimer = 0;
  function kick() {
    refresh();
    clearTimeout(kickTimer);
    kickTimer = setTimeout(() => { refresh(); refreshLog(); }, 3500);
  }
  refresh().then(refreshLog);
  setInterval(() => { if (!document.hidden) refresh(); }, 3000);
  setInterval(() => { if (!document.hidden) refreshLog(); }, 6000);
  document.addEventListener('visibilitychange', () => { if (!document.hidden) { refresh(); refreshLog(); } });
  setInterval(() => {
    $('#footClock').textContent = lastOkAt ? `обновлено ${fmtAge((Date.now() - lastOkAt) / 1000)} назад` : '';
  }, 1000);

  // ---------- hotkeys ----------
  document.addEventListener('keydown', (e) => {
    const typing = /^(INPUT|TEXTAREA|SELECT)$/.test(document.activeElement && document.activeElement.tagName);
    if (e.key === 'Escape' && typing) { document.activeElement.blur(); return; }
    if (typing || e.ctrlKey || e.metaKey || e.altKey) return;
    if (e.key === '/') { e.preventDefault(); $('#routeSearch').focus(); }
    else if (e.key === 't' || e.key === 'T' || e.key === 'е' || e.key === 'Е') { e.preventDefault(); $('#traceInput').focus(); }
  });
})();
