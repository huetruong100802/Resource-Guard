/* core.js - hạ tầng dùng chung: tiện ích, API, biểu đồ, modal/toast, theo dõi job nền, thao tác chính sách. */
(function () {
  'use strict';
  var RG = window.RG = {
    pages: {}, cur: 'overview',
    S: { hist: [], live: null, thr: null, settings: null, policy: null, draft: null, dirty: false, pinConfigured: false, kinds: [],
      jobs: {}, disk: null, drives: [], roots: [], driveSel: null, cands: null, autoLast: null, agent: null, cleanupLast: null, selected: {}, events: [] }
  };
  var S = RG.S;

  RG.$ = function (s, el) { return (el || document).querySelector(s); };
  RG.$$ = function (s, el) { return Array.prototype.slice.call((el || document).querySelectorAll(s)); };
  RG.esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  RG.clone = function (o) { return JSON.parse(JSON.stringify(o)); };
  RG.fmtBytes = function (b) {
    if (b == null || isNaN(b)) return '–';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, v = +b;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i >= 3 ? v.toFixed(v >= 100 ? 0 : 1) : (i === 2 ? v.toFixed(v >= 100 ? 0 : 1) : Math.round(v))) + ' ' + u[i];
  };
  RG.fmtAge = function (d) { if (d == null) return '–'; if (d < 1) return 'hôm nay'; if (d < 60) return d + ' ngày'; if (d < 730) return Math.round(d / 30) + ' tháng'; return (d / 365).toFixed(1) + ' năm'; };
  RG.daysSince = function (iso) { if (!iso) return null; var t = Date.parse(iso); return isNaN(t) ? null : Math.max(0, Math.floor((Date.now() - t) / 864e5)); };
  RG.hhmm = function (ts) { return (ts || '').slice(11, 19); };
  RG.fmtDur = function (sec) { sec = Math.max(0, Math.round(sec || 0)); var d = Math.floor(sec / 86400), h = Math.floor(sec % 86400 / 3600), m = Math.floor(sec % 3600 / 60); return d ? d + ' ngày ' + h + ' giờ' : (h ? h + ' giờ ' + m + ' phút' : m + ' phút'); };
  RG.css = function (n) { return getComputedStyle(document.documentElement).getPropertyValue(n).trim(); };
  RG.timeAgo = function (iso) { if (!iso) return '–'; var s = (Date.now() - Date.parse(iso)) / 1000; if (s < 60) return 'vừa xong'; if (s < 3600) return Math.round(s / 60) + ' phút trước'; if (s < 86400) return Math.round(s / 3600) + ' giờ trước'; return Math.round(s / 86400) + ' ngày trước'; };

  var ICONS = {
    shield: '<path d="M12 3l7 3v5c0 4.5-3 8.2-7 10-4-1.8-7-5.5-7-10V6l7-3z"/>',
    home: '<path d="M3 11l9-8 9 8M5 10v10h14V10"/>',
    cpu: '<rect x="6" y="6" width="12" height="12" rx="2"/><path d="M9 2v4M15 2v4M9 18v4M15 18v4M2 9h4M2 15h4M18 9h4M18 15h4"/>',
    disk: '<circle cx="12" cy="12" r="9"/><path d="M12 3v9l6.4 6.4"/>',
    trash: '<path d="M4 7h16M10 11v6M14 11v6M6 7l1 13h10l1-13M9 7V4h6v3"/>',
    policy: '<path d="M4 6h10M18 6h2M4 12h4M12 12h8M4 18h12M20 18h0"/><circle cx="16" cy="6" r="2"/><circle cx="10" cy="12" r="2"/><circle cx="18" cy="18" r="2"/>',
    spark: '<path d="M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3zM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8L19 16z"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M19 12a7 7 0 00-.1-1.2l2-1.5-2-3.4-2.3.9a7 7 0 00-2-1.2L14 3h-4l-.6 2.6a7 7 0 00-2 1.2l-2.3-.9-2 3.4 2 1.5A7 7 0 005 12c0 .4 0 .8.1 1.2l-2 1.5 2 3.4 2.3-.9a7 7 0 002 1.2L10 21h4l.6-2.6a7 7 0 002-1.2l2.3.9 2-3.4-2-1.5c.1-.4.1-.8.1-1.2z"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2v2M12 20v2M2 12h2M20 12h2M5 5l1.5 1.5M17.5 17.5L19 19M5 19l1.5-1.5M17.5 6.5L19 5"/>',
    moon: '<path d="M21 13a9 9 0 11-10-10 7 7 0 0010 10z"/>',
    chev: '<path d="M9 6l6 6-6 6"/>', refresh: '<path d="M20 11a8 8 0 10-2.3 5.7M20 4v7h-7"/>',
    x: '<path d="M6 6l12 12M18 6L6 18"/>', up: '<path d="M6 15l6-6 6 6"/>', down: '<path d="M6 9l6 6 6-6"/>',
    play: '<path d="M7 4l13 8-13 8V4z"/>', eye: '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>', inbox: '<path d="M3 13l3-8h12l3 8v6H3v-6zM3 13h5l1 3h6l1-3h5"/>'
  };
  RG.icon = function (n, cls) { return '<svg class="' + (cls || '') + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + (ICONS[n] || '') + '</svg>'; };

  /* ---------- API ---------- */
  RG.api = function (path, opt) {
    opt = opt || {};
    var o = { method: opt.method || 'GET', headers: {} };
    if (o.method !== 'GET') { o.headers['Content-Type'] = 'application/json'; o.headers['X-RG-Client'] = 'ui'; o.body = JSON.stringify(opt.body || {}); }
    return fetch(path, o).then(function (r) {
      return r.json().catch(function () { return {}; }).then(function (j) {
        if (!r.ok) { var e = new Error((j && j.error) || ('HTTP ' + r.status)); e.data = j; throw e; }
        return j;
      });
    });
  };

  /* ---------- Toast / Modal ---------- */
  RG.toast = function (msg, type, ms) {
    var el = document.createElement('div'); el.className = 'toast ' + (type || ''); el.setAttribute('role', 'status'); el.textContent = msg;
    RG.$('#toasts').appendChild(el);
    setTimeout(function () { if (el.parentNode) el.parentNode.removeChild(el); }, ms || 5000);
  };
  RG.modal = function (o) {
    var root = RG.$('#modalRoot'), prev = document.activeElement;
    var bg = document.createElement('div'); bg.className = 'modal-bg';
    var m = document.createElement('div'); m.className = 'modal'; m.setAttribute('role', 'dialog'); m.setAttribute('aria-modal', 'true'); m.setAttribute('aria-label', o.title || 'Hộp thoại');
    m.innerHTML = '<h3>' + RG.esc(o.title || '') + '</h3><div class="body">' + (o.html || '') + '</div><div class="acts"></div>';
    var acts = RG.$('.acts', m);
    function close(v) { document.removeEventListener('keydown', onKey, true); if (bg.parentNode) bg.parentNode.removeChild(bg); if (prev && prev.focus) prev.focus(); if (o.onClose) o.onClose(v); }
    function onKey(e) {
      if (e.key === 'Escape') { e.stopPropagation(); close(null); }
      if (e.key === 'Tab') { var f = RG.$$('button,input,select,[tabindex]', m).filter(function (x) { return !x.disabled; }); if (!f.length) return; var a = f[0], z = f[f.length - 1]; if (e.shiftKey && document.activeElement === a) { z.focus(); e.preventDefault(); } else if (!e.shiftKey && document.activeElement === z) { a.focus(); e.preventDefault(); } }
    }
    (o.actions || []).forEach(function (a) {
      var b = document.createElement('button'); b.className = 'btn ' + (a.cls || ''); b.textContent = a.label;
      b.onclick = function () { var r = a.onClick ? a.onClick(m, close) : undefined; if (r !== false) close(a.value); };
      acts.appendChild(b);
    });
    bg.appendChild(m); root.appendChild(bg);
    bg.addEventListener('mousedown', function (e) { if (e.target === bg) close(null); });
    document.addEventListener('keydown', onKey, true);
    var first = RG.$('input,select', m) || RG.$('.btn.primary,.btn.danger', m) || RG.$('.btn', m); if (first) first.focus();
    return { close: close, el: m };
  };
  RG.confirm = function (title, html, okLabel, danger) {
    return new Promise(function (res) {
      RG.modal({ title: title, html: html, onClose: function (v) { res(v === true); },
        actions: [{ label: 'Huỷ', value: false }, { label: okLabel || 'Đồng ý', cls: danger ? 'danger' : 'primary', value: true }] });
    });
  };
  RG.askPin = function (msg) {
    return new Promise(function (res) {
      var got = null;
      RG.modal({ title: 'Nhập PIN', html: '<p class="mut">' + RG.esc(msg || 'Thao tác này cần PIN.') + '</p><input id="pinIn" type="password" autocomplete="off" inputmode="numeric" style="width:100%" aria-label="PIN">',
        onClose: function () { res(got); },
        actions: [{ label: 'Huỷ', value: null }, { label: 'Xác nhận', cls: 'primary', onClick: function (m) { got = RG.$('#pinIn', m).value; } }] });
      setTimeout(function () { var i = RG.$('#pinIn'); if (i) i.addEventListener('keydown', function (e) { if (e.key === 'Enter') { var b = RG.$('.modal .btn.primary'); if (b) b.click(); } }); }, 0);
    });
  };

  /* ---------- Trạng thái theo ngưỡng ---------- */
  RG.stateColor = function (st) { return { Normal: 'var(--normal)', Caution: 'var(--caution)', Restricted: 'var(--restricted)', Critical: 'var(--critical)' }[st] || 'var(--normal)'; };
  RG.ramState = function (a) { var t = S.thr && S.thr.ramAvailGB; if (!t) return 'Normal'; return a > t.normalAbove ? 'Normal' : (a >= t.cautionFrom ? 'Caution' : (a >= t.restrictedFrom ? 'Restricted' : 'Critical')); };
  RG.diskState = function (f) { var t = S.thr && S.thr.diskFreeGB; if (!t) return 'Normal'; return f > t.normalAbove ? 'Normal' : (f >= t.cautionFrom ? 'Caution' : 'Critical'); };
  RG.commitState = function (p) { var t = S.thr && S.thr.commitPct; if (!t) return 'Normal'; return p >= t.critical ? 'Critical' : (p >= t.restricted ? 'Restricted' : 'Normal'); };

  /* ---------- Biểu đồ đường ---------- */
  // opts: {key|fn, color, min, max, lines:[{v,c}], area, axes, readout:id, unit, n, fmt}
  RG.lineChart = function (svg, data, o) {
    if (!svg) return;
    var W = Math.max(120, svg.clientWidth || 560), H = Math.max(24, svg.clientHeight || 132);
    var axes = o.axes !== false, pl = axes ? 34 : 1, pb = axes ? 14 : 1, pt = axes ? 6 : 1, pr = axes ? 4 : 1;
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    var get = o.fn || function (r) { return r[o.key]; };
    var pts = data.filter(function (r) { return get(r) != null; });
    if (o.n && pts.length > o.n) pts = pts.slice(-o.n);
    if (pts.length < 2) { svg.innerHTML = axes ? '<text x="' + pl + '" y="' + (H / 2) + '">Đang thu thập dữ liệu…</text>' : ''; svg.__ctx = null; return; }
    var min = o.min || 0, hi = o.max;
    if (hi == null) { hi = 0; pts.forEach(function (r) { hi = Math.max(hi, +get(r)); }); (o.lines || []).forEach(function (l) { hi = Math.max(hi, l.v); }); hi = hi * 1.1 || 1; }
    var X = function (i) { return pl + i * (W - pl - pr) / (pts.length - 1); };
    var Y = function (v) { return pt + (H - pt - pb) * (1 - (Math.min(Math.max(v, min), hi) - min) / (hi - min)); };
    var s = '';
    if (axes) [0, 0.5, 1].forEach(function (f) { var v = min + (hi - min) * f; s += '<line x1="' + pl + '" x2="' + (W - pr) + '" y1="' + Y(v) + '" y2="' + Y(v) + '" stroke="' + RG.css('--line') + '"/><text x="2" y="' + (Y(v) + 3) + '">' + (Math.round(v * 10) / 10) + '</text>'; });
    (o.lines || []).forEach(function (l) { s += '<line x1="' + pl + '" x2="' + (W - pr) + '" y1="' + Y(l.v) + '" y2="' + Y(l.v) + '" stroke="' + l.c + '" stroke-dasharray="4 3"/>'; });
    var p = pts.map(function (r, i) { return X(i).toFixed(1) + ',' + Y(+get(r)).toFixed(1); }).join(' ');
    if (o.area) s += '<polygon points="' + pl + ',' + (H - pb) + ' ' + p + ' ' + X(pts.length - 1).toFixed(1) + ',' + (H - pb) + '" fill="' + o.color + '" opacity=".16"/>';
    s += '<polyline fill="none" stroke="' + o.color + '" stroke-width="' + (axes ? 2 : 1.4) + '" stroke-linejoin="round" points="' + p + '"/>';
    if (axes) s += '<text x="' + pl + '" y="' + (H - 2) + '">' + RG.hhmm(pts[0].ts) + '</text><text x="' + (W - pr) + '" y="' + (H - 2) + '" text-anchor="end">' + RG.hhmm(pts[pts.length - 1].ts) + '</text>';
    s += '<line class="xh" x1="0" x2="0" y1="' + pt + '" y2="' + (H - pb) + '" stroke="' + RG.css('--mut') + '" opacity="0"/>';
    svg.innerHTML = s;
    svg.__ctx = { pts: pts, get: get, o: o, pl: pl, pr: pr, W: W };
    if (o.readout && !svg.__bound) {
      svg.__bound = true;
      svg.addEventListener('mousemove', function (e) {
        var c = svg.__ctx; if (!c) return; var r = svg.getBoundingClientRect();
        var x = (e.clientX - r.left) * c.W / r.width, i = Math.round((x - c.pl) / (c.W - c.pl - c.pr) * (c.pts.length - 1));
        i = Math.max(0, Math.min(c.pts.length - 1, i));
        var xp = c.pl + i * (c.W - c.pl - c.pr) / (c.pts.length - 1), ln = svg.querySelector('.xh');
        if (ln) { ln.setAttribute('x1', xp); ln.setAttribute('x2', xp); ln.setAttribute('opacity', '.6'); }
        var el = document.getElementById(c.o.readout), v = +c.get(c.pts[i]);
        if (el) el.textContent = RG.hhmm(c.pts[i].ts) + ' · ' + (c.o.fmt ? c.o.fmt(v) : (Math.round(v * 10) / 10) + (c.o.unit || ''));
      });
      svg.addEventListener('mouseleave', function () { var ln = svg.querySelector('.xh'); if (ln) ln.setAttribute('opacity', '0'); var c = svg.__ctx; var el = c && document.getElementById(c.o.readout); if (el) el.textContent = ''; });
    }
  };

  /* ---------- Chính sách ---------- */
  RG.loadPolicy = function () {
    return RG.api('/api/policy').then(function (j) {
      S.policy = j.policy; S.pinConfigured = j.pinConfigured; S.kinds = j.kinds;
      if (!S.draft || !S.dirty) { S.draft = RG.clone(j.policy); S.dirty = false; }
      return j;
    });
  };
  RG.savePolicy = function (pol, pin) {
    return RG.api('/api/policy', { method: 'POST', body: { policy: pol, pin: pin || '' } }).then(function (j) {
      S.policy = j.policy; S.pinConfigured = j.pinConfigured; return j;
    }).catch(function (e) {
      var c = e.data && e.data.code;
      if (c === 'pin-required' || c === 'pin-wrong') {
        return RG.askPin(c === 'pin-wrong' ? 'PIN không đúng. Nhập lại:' : 'Thay đổi này nới lỏng chế độ tự động nên cần PIN.').then(function (p) { if (!p) throw new Error('Đã huỷ.'); return RG.savePolicy(pol, p); });
      }
      if (c === 'pin-not-set') {
        RG.modal({ title: 'Chưa đặt PIN', html: '<p>Chế độ <b>Bật</b> (tự xoá thật) cần PIN để chặn người khác hoặc script tự bật.</p><p>Đặt PIN ở terminal (không qua trình duyệt):</p><pre class="json">powershell -File scripts\\resource-manager.ps1 serve setpin</pre>', actions: [{ label: 'Đã hiểu', cls: 'primary' }] });
        throw new Error('Cần đặt PIN trước.');
      }
      throw e;
    });
  };
  RG.toggleProtect = function (kind, value, on) {
    var base = RG.clone(S.policy), key = kind === 'path' ? 'protectPaths' : 'protectProcesses';
    base[key] = (base[key] || []).filter(function (x) { return x.toLowerCase() !== String(value).toLowerCase(); });
    if (on) base[key].push(value);
    return RG.savePolicy(base).then(function (j) {
      if (S.dirty) { S.draft[key] = j.policy[key].slice(); } else { S.draft = RG.clone(j.policy); }
      RG.toast(on ? 'Đã đưa vào vùng bảo vệ: ' + value : 'Đã bỏ bảo vệ: ' + value, 'ok');
      if (RG.pages[RG.cur] && RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh();
      return j;
    }).catch(function (e) { RG.toast(e.message, 'err'); });
  };
  RG.isPathProtected = function (p) {
    p = String(p || '').replace(/\\+$/, '').toLowerCase();
    return ((S.policy && S.policy.protectPaths) || []).some(function (x) { x = x.replace(/\\+$/, '').toLowerCase(); return p === x || p.indexOf(x + '\\') === 0 || x.indexOf(p + '\\') === 0; });
  };
  RG.isProcProtected = function (n) {
    n = String(n || '').toLowerCase();
    return ((S.policy && S.policy.protectProcesses) || []).some(function (x) {
      x = x.toLowerCase().replace(/\.exe$/, '');
      var re = new RegExp('^' + x.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*').replace(/\?/g, '.') + '$');
      return re.test(n);
    });
  };

  /* ---------- Job nền ---------- */
  var NAMES = ['breakdown', 'candidates', 'cleanup', 'auto', 'agent'], jobTimer = null;
  RG.anyRunning = function () { return NAMES.some(function (n) { return S.jobs[n] && S.jobs[n].status === 'running'; }); };
  RG.watchJobs = function () {
    if (jobTimer) return;
    (function tick() {
      jobTimer = null;
      RG.api('/api/jobs').then(function (j) {
        NAMES.forEach(function (n) {
          var prev = S.jobs[n], cur = j[n];
          S.jobs[n] = cur;
          if (prev && prev.status === 'running' && cur && cur.status !== 'running') RG.onJobDone(n, cur);
        });
        if (RG.pages[RG.cur] && RG.pages[RG.cur].jobs) RG.pages[RG.cur].jobs();
        RG.updateNavBadges();
        if (RG.anyRunning()) jobTimer = setTimeout(tick, 1500);
      }).catch(function () { jobTimer = setTimeout(tick, 4000); });
    })();
  };
  RG.onJobDone = function (n, cur) {
    var bad = cur.status === 'error';
    if (n === 'breakdown') { var dn = cur.drive ? 'ổ ' + cur.drive + ':' : 'ổ đĩa'; RG.toast(bad ? 'Quét ' + dn + ' lỗi: ' + cur.message : 'Quét ' + dn + ' xong.', bad ? 'err' : 'ok'); RG.loadDrives().catch(function () { }); RG.loadDisk().then(function () { if (RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh(); }); }
    if (n === 'candidates') { RG.toast(bad ? 'Quét ứng viên lỗi: ' + cur.message : 'Quét ứng viên xong: ' + cur.message, bad ? 'err' : 'ok'); RG.loadCands().then(function () { if (RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh(); }); }
    if (n === 'cleanup') {
      RG.toast(bad ? 'Dọn dẹp lỗi: ' + cur.message : 'Dọn dẹp xong: ' + cur.message, bad ? 'err' : 'ok', 8000);
      RG.api('/api/cleanup/last').then(function (j) { S.cleanupLast = j.last; S.selected = {}; return RG.loadCands(); }).then(function () { if (RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh(); });
    }
    if (n === 'auto') { RG.toast(bad ? 'Chạy tự dọn lỗi: ' + cur.message : 'Chạy thử tự dọn xong.', bad ? 'err' : 'ok'); RG.loadAuto().then(function () { if (RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh(); }); }
    if (n === 'agent') { RG.toast(bad ? 'Agent lỗi: ' + cur.message : 'Agent đã đánh giá xong.', bad ? 'err' : 'ok'); RG.loadAgent().then(function () { if (RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh(); }); }
  };
  RG.startJob = function (path, body, okMsg) {
    return RG.api(path, { method: 'POST', body: body || {} }).then(function (j) {
      if (okMsg) RG.toast(j.already ? 'Tác vụ này đang chạy.' : okMsg);
      var n = { '/api/disk/scan': 'breakdown', '/api/candidates/scan': 'candidates', '/api/cleanup/apply': 'cleanup', '/api/cleanup/elevate': 'cleanup', '/api/archive/restore': 'cleanup','/api/auto/run': 'auto', '/api/agent/run': 'agent' }[path];
      if (n) S.jobs[n] = { status: 'running', pct: 0, message: 'đang khởi động…', startedUtc: new Date().toISOString() };
      RG.watchJobs();
      if (RG.pages[RG.cur] && RG.pages[RG.cur].jobs) RG.pages[RG.cur].jobs();
      return j;
    }).catch(function (e) { RG.toast(e.message, 'err'); throw e; });
  };

  /* ---------- Loaders ---------- */
  RG.loadDisk = function (drive) {
    var d = drive || S.driveSel || '';
    return RG.api('/api/disk' + (d ? '?drive=' + encodeURIComponent(d) : '')).then(function (j) { S.disk = j.breakdown; S.driveSel = j.drive; if (j.progress) S.jobs.breakdown = j.progress; });
  };
  RG.loadDrives = function () { return RG.api('/api/drives').then(function (j) { S.drives = j.drives || []; S.roots = j.workspaceRoots || []; if (!S.driveSel) S.driveSel = j.primary; return j; }); };
  /* Danh sách ổ: ưu tiên dữ liệu realtime (SSE, mỗi chu kỳ), rồi tới /api/drives (có ngưỡng, chính sách, lần quét). Gộp theo chữ cái. */
  RG.driveList = function () {
    var live = (S.live && S.live.drives) || [], meta = {};
    (S.drives || []).forEach(function (d) { meta[d.drive] = d; });
    var out = live.map(function (d) { var m = meta[d.drive] || {}; return Object.assign({}, m, d); });
    return out.length ? out : (S.drives || []);
  };
  RG.driveInfo = function (L) { var l = RG.driveList().filter(function (d) { return d.drive === L; }); return l[0] || null; };
  RG.loadCands = function () { return RG.api('/api/candidates').then(function (j) { S.cands = j; if (j.progress) S.jobs.candidates = j.progress; }); };
  RG.loadAuto = function () { return RG.api('/api/auto/last').then(function (j) { S.autoLast = j.last; if (j.progress) S.jobs.auto = j.progress; }); };
  RG.loadAgent = function () { return RG.api('/api/agent/last').then(function (j) { S.agent = j.last; if (j.progress) S.jobs.agent = j.progress; }); };

  RG.updateNavBadges = function () {
    var el = RG.$('#navCleanCnt'); if (!el) return;
    var n = S.cands ? S.cands.items.filter(function (i) { return i.action !== 'report' && !i.protected; }).length : 0;
    el.textContent = n; el.hidden = n === 0;
  };
})();
