/* core.js - hạ tầng dùng chung: tiện ích, API, biểu đồ, modal/toast, theo dõi job nền, thao tác chính sách. */
(function () {
  'use strict';
  var RG = window.RG = {
    pages: {}, cur: 'home',
    S: { hist: [], live: null, thr: null, settings: null, policy: null, draft: null, dirty: false, pinConfigured: false, kinds: [],
      jobs: {}, disk: null, drives: [], roots: [], driveSel: null, cands: null, autoLast: null, agent: null, cleanupLast: null, selected: {}, events: [] }
  };
  var S = RG.S;

  RG.$ = function (s, el) { return (el || document).querySelector(s); };
  RG.$$ = function (s, el) { return Array.prototype.slice.call((el || document).querySelectorAll(s)); };
  RG.esc = function (s) { return String(s == null ? '' : s).replace(/[&<>"']/g, function (c) { return { '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]; }); };
  RG.clone = function (o) { return JSON.parse(JSON.stringify(o)); };
  /* Số có dấu phẩy thập phân kiểu Việt Nam, đúng d chữ số lẻ. Mọi chỗ in số cho người dùng đi qua đây. */
  RG.fmtNum = function (v, d) {
    if (v == null || isNaN(v)) return '–';
    d = d == null ? 1 : d;
    var k = Math.pow(10, d), r = Math.round(Math.abs(+v) * k), s = String(Math.floor(r / k)), f = String(r % k);
    while (f.length < d) f = '0' + f;
    return (v < 0 && r ? '-' : '') + s + (d ? ',' + f : '');
  };
  /* Số cho thuộc tính SVG: dấu chấm, làm tròn 1 chữ số lẻ. */
  RG.n1 = function (x) { return String(Math.round(+x * 10) / 10); };
  RG.fmtBytes = function (b) {
    if (b == null || isNaN(b)) return '–';
    var u = ['B', 'KB', 'MB', 'GB', 'TB'], i = 0, v = +b;
    while (v >= 1024 && i < u.length - 1) { v /= 1024; i++; }
    return (i >= 2 ? RG.fmtNum(v, v >= (i === 2 ? 10 : 100) ? 0 : 1) : String(Math.round(v))) + ' ' + u[i];
  };
  /* Gigabyte; dưới 0,05 GB đổi sang MB để không bao giờ in "0 GB" cho số khác 0. */
  RG.fmtGB = function (g) {
    if (g == null || isNaN(g)) return '–';
    if (g === 0) return '0 GB';
    if (Math.abs(g) < 0.05) return RG.fmtBytes(g * 1073741824);
    return RG.fmtNum(g, 1) + ' GB';
  };
  RG.fmtPct = function (n) { if (n == null || isNaN(n)) return '–'; return (n > 0 && n < 10 ? RG.fmtNum(n, 1) : String(Math.round(n))) + '%'; };
  RG.pad2 = function (n) { return (n < 10 ? '0' : '') + n; };
  /* Mốc thời gian -> ms. Chuỗi "yyyy-MM-dd HH:mm:ss" (metrics) là giờ địa phương; chuỗi ISO có Z là UTC. */
  RG.tsMs = function (ts) { if (ts == null) return NaN; if (typeof ts === 'number') return ts; var s = String(ts); return Date.parse(/^\d{4}-\d\d-\d\d \d\d:\d\d/.test(s) ? s.replace(' ', 'T') : s); };
  /* Giờ địa phương dd/MM HH:mm cho mọi kiểu mốc thời gian. */
  RG.fmtLocal = function (ts) { var t = RG.tsMs(ts); if (isNaN(t)) return '–'; var d = new Date(t); return RG.pad2(d.getDate()) + '/' + RG.pad2(d.getMonth() + 1) + ' ' + RG.pad2(d.getHours()) + ':' + RG.pad2(d.getMinutes()); };
  RG.fmtAge = function (d) { if (d == null) return '–'; if (d < 1) return 'hôm nay'; if (d < 60) return d + ' ngày'; if (d < 730) return Math.round(d / 30) + ' tháng'; return RG.fmtNum(d / 365, 1) + ' năm'; };
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
    play: '<path d="M7 4l13 8-13 8V4z"/>', eye: '<path d="M2 12s4-7 10-7 10 7 10 7-4 7-10 7S2 12 2 12z"/><circle cx="12" cy="12" r="3"/>', inbox: '<path d="M3 13l3-8h12l3 8v6H3v-6zM3 13h5l1 3h6l1-3h5"/>',
    check: '<path d="M5 12.5l4.5 4.5L19 7.5"/>', alert: '<path d="M12 4l9 16H3L12 4zM12 10v4M12 17.5v.5"/>', clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    back: '<path d="M15 6l-6 6 6 6"/>', info: '<circle cx="12" cy="12" r="9"/><path d="M12 11v5M12 8v.5"/>'
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

  /* ---------- Ngôn ngữ cho người dùng (không lộ Normal/Caution/commit/ứng viên) ---------- */
  RG.human = {
    stateNames: { Normal: 'Ổn', Caution: 'Cần chú ý', Restricted: 'Hạn chế', Critical: 'Nguy cấp' },
    state: function (st) { return RG.human.stateNames[st] || st || '–'; },
    kinds: {
      'temp-entry': { l: 'File tạm', d: 'Thư mục/tệp trong %TEMP% lâu không đụng tới; chương trình tự tạo lại khi cần.' },
      'dotnet-artifact': { l: 'bin/obj (.NET)', d: 'Kết quả build, sinh lại ở lần build kế tiếp.' },
      'cache-aged': { l: 'Cache dev', d: 'NuGet/npm/pnpm: chỉ file không dùng ≥ N ngày; tải lại khi cần (cần mạng).' },
      'node_modules': { l: 'node_modules', d: 'Gỡ gói npm của dự án lâu không mở; cài lại bằng package manager.' },
      'process': { l: 'Tiến trình', d: 'Chỉ tiến trình agent đã đăng ký và đã mất chủ; mọi tiến trình khác chỉ báo cáo.' },
      'stale-repo': { l: 'Repo cũ', d: 'Repo git không sửa file nguồn ≥ 90 ngày và mọi thứ đã có trên remote. Nên nén zip trước khi xoá.' },
      'large-item': { l: 'Mục lớn', d: 'File/thư mục ≥ 500 MB trong Downloads, Videos không đụng ≥ 60 ngày. Có thể nén zip trước khi xoá.' },
      'app': { l: 'Ứng dụng', d: 'Ứng dụng cài đặt lâu không ghi file. Chỉ báo cáo: gỡ bằng Cài đặt > Ứng dụng của Windows.' }
    },
    kind: function (k) { return RG.human.kinds[k] || { l: k, d: '' }; },
    regens: { auto: 'Tự tạo lại', rebuild: 'Build lại', redownload: 'Tải lại (cần mạng)', 'restore-zip': 'Giải nén bản zip', none: 'Không lấy lại được' },
    regen: function (r) { return RG.human.regens[r] || r || '–'; },
    risks: { low: 'Rủi ro thấp', medium: 'Rủi ro vừa', high: 'Rủi ro cao' },
    risk: function (r) { return RG.human.risks[r] || r || '–'; },
    // Vai trò tiến trình (identity.role, hợp đồng P2) và nhóm cũ (group) bằng tiếng Việt; không in giá trị thô.
    roles: { build: 'Build', test: 'Kiểm thử', devserver: 'Máy chủ dev', compiler: 'Trình biên dịch', langserver: 'Dịch vụ ngôn ngữ', packagemgr: 'Trình quản lý gói',
      'runtime-app': 'Ứng dụng đang chạy', browser: 'Trình duyệt', editor: 'Trình soạn thảo', agent: 'Trợ lý AI', infra: 'Hạ tầng', system: 'Hệ thống Windows',
      security: 'Bảo mật', app: 'Ứng dụng', unknown: 'Chưa nhận diện' },
    role: function (r) { return RG.human.roles[r] || 'Khác'; },
    groups: { agent: 'Trợ lý AI', infra: 'Hạ tầng', test: 'Kiểm thử', build: 'Build', dev: 'Công cụ lập trình', other: 'Khác', app: 'Ứng dụng', system: 'Hệ thống' },
    group: function (g) { return RG.human.groups[g] || 'Khác'; },
    // Lý do trạng thái kèm màn liên quan: [{ text, go }]. `go` là tên trang để badge dẫn tới.
    reasonItems: function (l) {
      var out = []; if (!l) return out;
      if (RG.ramState(l.availRamGB) !== 'Normal') out.push({ text: 'RAM còn ' + RG.fmtGB(l.availRamGB) + ' trong tổng ' + RG.fmtGB(l.totalRamGB), go: 'mem' });
      RG.driveList().forEach(function (d) { if (d.state && d.state !== 'Normal') out.push({ text: 'Ổ ' + d.drive + ' còn ' + RG.fmtGB(d.freeGB), go: 'disk' }); });
      if (RG.commitState(l.commitPct) !== 'Normal') out.push({ text: 'Bộ nhớ cam kết đã dùng ' + RG.fmtPct(l.commitPct), go: 'mem' });
      return out;
    },
    // Câu cho người dùng dựng từ số liệu có cấu trúc của `live` (không phân tích chuỗi reasons tiếng Anh).
    reasons: function (l) { return RG.human.reasonItems(l).map(function (x) { return x.text; }); }
  };

  /* Biểu tượng "?" có giải thích dài (title + aria-label); thay cho đoạn hướng dẫn trên màn hình. */
  RG.help = function (text) { var t = RG.esc(text); return '<span class="help" tabindex="0" role="img" title="' + t + '" aria-label="' + t + '">?</span>'; };
  /* Trạng thái trống thống nhất. o = { icon, title, action:{ label, onClick }, compact }. */
  RG.empty = function (el, o) {
    o = o || {};
    el.innerHTML = '<div class="empty-state' + (o.compact ? ' compact' : '') + '">' + (o.icon && !o.compact ? RG.icon(o.icon) : '') + '<div class="et">' + RG.esc(o.title || '') + '</div>' +
      (o.action ? '<button class="btn sm">' + RG.esc(o.action.label) + '</button>' : '') + '</div>';
    if (o.action) { var b = RG.$('button', el); if (b) b.onclick = o.action.onClick; }
    return el;
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
    // Ít điểm hơn minPoints (mặc định 12): thay biểu đồ bằng một dòng trạng thái thu thập (L5), không vẽ đường phẳng chiếm chỗ.
    var minPts = Math.max(2, o.minPoints == null ? (axes ? 12 : 2) : o.minPoints), holder = svg.parentNode;
    var note = holder && holder.querySelector ? holder.querySelector('.chart-empty[data-for="' + (svg.id || '') + '"]') : null;
    if (pts.length < minPts) {
      svg.__ctx = null; svg.innerHTML = '';
      if (axes && holder) {
        if (!note) { note = document.createElement('div'); note.className = 'chart-empty'; note.setAttribute('data-for', svg.id || ''); holder.insertBefore(note, svg); }
        RG.empty(note, { title: 'Đang thu thập dữ liệu (' + pts.length + '/' + minPts + ' mẫu)', compact: true });
        svg.style.display = 'none';
      }
      return;
    }
    svg.style.display = '';
    if (note && note.parentNode) note.parentNode.removeChild(note);
    var min = o.min || 0, hi = o.max;
    if (o.fit && o.min == null && o.max == null) {   // trục Y co quanh dữ liệu để dao động nhỏ vẫn nhìn thấy
      var lo2 = Infinity, hi2 = -Infinity; pts.forEach(function (r) { var v = +get(r); if (v < lo2) lo2 = v; if (v > hi2) hi2 = v; });
      var pad = Math.max((hi2 - lo2) * 0.15, Math.abs(hi2) * 0.02, 0.1); min = Math.max(0, lo2 - pad); hi = hi2 + pad;
    }
    if (hi == null) { hi = 0; pts.forEach(function (r) { hi = Math.max(hi, +get(r)); }); (o.lines || []).forEach(function (l) { hi = Math.max(hi, l.v); }); if (o.dragLine) hi = Math.max(hi, o.dragLine.v); hi = hi * 1.1 || 1; }
    var X = function (i) { return pl + i * (W - pl - pr) / (pts.length - 1); };
    var Y = function (v) { return pt + (H - pt - pb) * (1 - (Math.min(Math.max(v, min), hi) - min) / (hi - min)); };
    var s = '';
    if (axes) [0, 0.5, 1].forEach(function (f) { var v = min + (hi - min) * f; s += '<line x1="' + pl + '" x2="' + (W - pr) + '" y1="' + Y(v) + '" y2="' + Y(v) + '" stroke="' + RG.css('--line') + '"/><text x="2" y="' + (Y(v) + 3) + '">' + RG.fmtNum(v, Math.abs(v) >= 10 ? 0 : 1) + (o.unit === '%' ? '%' : '') + '</text>'; });
    (o.lines || []).forEach(function (l) { s += '<line x1="' + pl + '" x2="' + (W - pr) + '" y1="' + Y(l.v) + '" y2="' + Y(l.v) + '" stroke="' + l.c + '" stroke-dasharray="4 3"/>'; });
    var p = pts.map(function (r, i) { return RG.n1(X(i)) + ',' + RG.n1(Y(+get(r))); }).join(' ');
    if (o.area) s += '<polygon points="' + pl + ',' + (H - pb) + ' ' + p + ' ' + RG.n1(X(pts.length - 1)) + ',' + (H - pb) + '" fill="' + o.color + '" opacity=".16"/>';
    s += '<polyline fill="none" stroke="' + o.color + '" stroke-width="' + (axes ? 2 : 1.4) + '" stroke-linejoin="round" points="' + p + '"/>';
    var xf = o.xfmt || RG.hhmm;
    if (axes) s += '<text x="' + pl + '" y="' + (H - 2) + '">' + xf(pts[0].ts) + '</text><text x="' + (W - pr) + '" y="' + (H - 2) + '" text-anchor="end">' + xf(pts[pts.length - 1].ts) + '</text>';
    s += '<line class="xh" x1="0" x2="0" y1="' + pt + '" y2="' + (H - pb) + '" stroke="' + RG.css('--mut') + '" opacity="0"/>';
    // Điểm đánh dấu sự kiện: vạch dọc + chấm tròn ở đỉnh; chỉ vẽ mốc nằm trong khoảng dữ liệu (lệch tối đa một bước lấy mẫu).
    if (o.markers && o.markers.length) {
      var tms = pts.map(function (r) { return RG.tsMs(r.ts); }), step = (tms[tms.length - 1] - tms[0]) / Math.max(1, tms.length - 1);
      var mcol = { 'auto-run': '--normal', 'manual-cleanup': '--normal', 'policy-change': '--accent', 'proc-priority': '--cpu' };
      o.markers.forEach(function (m, mi) {
        var t = RG.tsMs(m.ts); if (isNaN(t) || t < tms[0] - step || t > tms[tms.length - 1] + step) return;
        var bi = 0, bd = Infinity; for (var q = 0; q < tms.length; q++) { var dd = Math.abs(tms[q] - t); if (dd < bd) { bd = dd; bi = q; } }
        var mx = RG.n1(X(bi)), c = RG.css(mcol[m.type] || '--mut') || RG.css('--mut');
        s += '<g class="mk" data-mi="' + mi + '" tabindex="0" role="button" aria-label="' + RG.esc(m.label || m.type) + '" style="cursor:pointer"><title>' + RG.esc(m.label || m.type) + '</title>' +
          '<line x1="' + mx + '" x2="' + mx + '" y1="' + (pt + 8) + '" y2="' + (H - pb) + '" stroke="' + c + '" stroke-dasharray="2 3" opacity=".7"/>' +
          '<circle cx="' + mx + '" cy="' + (pt + 6) + '" r="5.5" fill="' + c + '" stroke="var(--panel)" stroke-width="1.5"/><rect x="' + (mx - 9) + '" y="' + pt + '" width="18" height="' + (H - pt - pb) + '" fill="transparent"/></g>';
      });
    }
    // Đường ngưỡng kéo được (chuột + phím mũi tên).
    var dl = o.dragLine;
    if (dl) {
      var dy = Y(dl.v), dc = dl.color || RG.css('--accent');
      s += '<g class="dl" tabindex="0" role="slider" aria-label="' + RG.esc(dl.label || 'Ngưỡng') + '" aria-valuemin="' + dl.min + '" aria-valuemax="' + dl.max + '" aria-valuenow="' + dl.v + '" aria-valuetext="' + RG.esc(dl.text || (dl.v + (o.unit || ''))) + '" style="cursor:ns-resize">' +
        '<rect x="' + pl + '" y="' + (dy - 8) + '" width="' + (W - pl - pr) + '" height="16" fill="transparent"/><line x1="' + pl + '" x2="' + (W - pr) + '" y1="' + dy + '" y2="' + dy + '" stroke="' + dc + '" stroke-width="2"/>' +
        '<circle cx="' + (W - pr - 10) + '" cy="' + dy + '" r="6" fill="' + dc + '" stroke="var(--panel)" stroke-width="2"/><text x="' + (pl + 4) + '" y="' + (dy - 4) + '" style="fill:' + dc + ';font-weight:600">' + RG.esc(dl.text || (dl.v + (o.unit || ''))) + '</text></g>';
    }
    svg.innerHTML = s;
    svg.__ctx = { pts: pts, get: get, o: o, pl: pl, pr: pr, W: W, H: H, pt: pt, pb: pb, lo: min, hi: hi };
    if (svg.__keepFocus) { var fg = svg.querySelector('.dl'); if (fg) fg.focus(); }
    if (!svg.__evBound) {
      svg.__evBound = true;
      var drag = null;
      var valAt = function (e) {
        var c = svg.__ctx, r = svg.getBoundingClientRect(), y = (e.clientY - r.top) * c.H / r.height, d = c.o.dragLine;
        var v = c.lo + (c.hi - c.lo) * (1 - (y - c.pt) / (c.H - c.pt - c.pb)); v = Math.round(v / (d.step || 1)) * (d.step || 1);
        return Math.max(d.min, Math.min(d.max, v));
      };
      svg.addEventListener('pointerdown', function (e) {
        var c = svg.__ctx; if (!c) return;
        var t = e.target.closest ? e.target.closest('.dl') : null;
        if (t && c.o.dragLine) { drag = true; try { svg.setPointerCapture(e.pointerId); } catch (x) { } e.preventDefault(); }
      });
      svg.addEventListener('pointermove', function (e) {
        var c = svg.__ctx; if (!drag || !c || !c.o.dragLine) return;
        var v = valAt(e), d = c.o.dragLine; if (v === d.v) return; d.v = v; if (d.onChange) d.onChange(v);
      });
      var end = function (e) { if (drag) { drag = null; try { svg.releasePointerCapture(e.pointerId); } catch (x) { } } };
      svg.addEventListener('pointerup', end); svg.addEventListener('pointercancel', end);
      svg.addEventListener('click', function (e) {
        var c = svg.__ctx, g = e.target.closest ? e.target.closest('.mk') : null;
        if (g && c && c.o.onMarker) c.o.onMarker(c.o.markers[+g.dataset.mi]);
      });
      svg.addEventListener('keydown', function (e) {
        var c = svg.__ctx; if (!c) return;
        var g = e.target.closest ? e.target.closest('.dl') : null, m = e.target.closest ? e.target.closest('.mk') : null;
        if (m && (e.key === 'Enter' || e.key === ' ') && c.o.onMarker) { e.preventDefault(); c.o.onMarker(c.o.markers[+m.dataset.mi]); return; }
        if (!g || !c.o.dragLine) return;
        var d = c.o.dragLine, dv = { ArrowUp: 1, ArrowRight: 1, ArrowDown: -1, ArrowLeft: -1 }[e.key]; if (!dv) return;
        e.preventDefault(); var v = Math.max(d.min, Math.min(d.max, d.v + dv * (d.step || 1) * (e.shiftKey ? 5 : 1)));
        if (v !== d.v) { d.v = v; svg.__keepFocus = true; if (d.onChange) d.onChange(v); }
      });
      svg.addEventListener('focusout', function () { setTimeout(function () { if (!svg.contains(document.activeElement)) svg.__keepFocus = false; }, 0); });
    }
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
          // vừa bấm chạy: bản ghi job của server có thể còn là lượt trước (đã 'done'); chưa coi là xong lượt này
          if (prev && prev.pending && Date.now() - prev.t0 < 20000 && (!cur || (cur.status !== 'running' && Date.parse(cur.startedUtc || 0) < prev.t0 - 1000))) cur = prev;
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
      var n = { '/api/disk/scan': 'breakdown', '/api/candidates/scan': 'candidates', '/api/cleanup/apply': 'cleanup', '/api/cleanup/elevate': 'cleanup', '/api/archive/restore': 'cleanup','/api/auto/run': 'auto', '/api/agent/run': 'agent', '/api/assistant/act': 'cleanup' }[path];
      if (n) S.jobs[n] = { status: 'running', pct: 0, message: 'đang khởi động…', startedUtc: new Date().toISOString(), pending: true, t0: Date.now() };
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
  /* Ngưỡng dung lượng trống của một ổ (GB): { normalAbove, cautionFrom }. /api/drives trả tên khoá có hậu tố GB, /api/settings thì không. */
  RG.diskThr = function (L) {
    var d = RG.driveInfo(L), t = d && d.thresholds;
    if (t) return { normalAbove: t.normalAboveGB != null ? t.normalAboveGB : t.normalAbove, cautionFrom: t.cautionFromGB != null ? t.cautionFromGB : t.cautionFrom };
    return (S.thr && S.thr.diskFreeGB) || { normalAbove: 20, cautionFrom: 10 };
  };
  RG.driveInfo = function (L) { var l = RG.driveList().filter(function (d) { return d.drive === L; }); return l[0] || null; };
  RG.loadCands = function () { return RG.api('/api/candidates').then(function (j) { S.cands = j; if (j.progress) S.jobs.candidates = j.progress; }); };
  RG.loadInsight = function () { return RG.api('/api/insight').then(function (j) { S.insight = j; return j; }); };
  RG.loadAdvice = function () { return RG.api('/api/advice').then(function (j) { S.advice = j; return j; }); };
  RG.loadEvents = function () { return RG.api('/api/events?max=200').then(function (j) { S.events = j || []; return S.events; }); };
  /* Câu một dòng mô tả sự kiện (chưa escape). */
  RG.human.modes = { off: 'Tắt', 'dry-run': 'Chạy thử', on: 'Bật' };
  RG.human.event = function (e) {
    var d = e.data || {}, H = RG.human;
    switch (e.event) {
      case 'state-change': return 'Trạng thái ' + H.state(d.from) + ' → ' + H.state(d.to);
      case 'would-kill-orphans': return 'Có ' + (d.items || []).length + ' tiến trình mồ côi của agent';
      case 'settings-change': return 'Đổi chu kỳ lấy mẫu: ' + d.intervalSec + ' giây';
      case 'watcher-start': case 'server-start': return 'Resource Guard khởi động';
      case 'auto-run': return (d.mode === 'dry-run' ? 'Chạy thử tự dọn: sẽ dọn ' : 'Tự dọn: ') + d.items + ' mục' + (d.mode === 'dry-run' ? '' : ', giải phóng ' + RG.fmtBytes(d.freedBytes));
      case 'manual-cleanup': return 'Dọn tay: ' + d.items + ' mục, giải phóng ' + RG.fmtBytes(d.freedBytes);
      case 'policy-change': return 'Đổi chính sách (chế độ ' + (H.modes[d.mode] || d.mode) + ')';
      case 'thresholds-change': return 'Đổi ngưỡng trạng thái (RAM, ổ đĩa, bộ nhớ cam kết)';
      case 'proc-priority': return (String(d.to) === 'Normal' ? 'Trả ưu tiên bình thường: ' : 'Hạ ưu tiên: ') + d.name;
      case 'agent-eval': return 'Trợ lý AI đánh giá xong';
      default: return e.event;
    }
  };
  /* Gộp các sự kiện liền nhau giống hệt (cùng câu) thành "… (×11)". Đầu vào mới → cũ. */
  RG.groupEvents = function (list) {
    var out = [];
    (list || []).forEach(function (e) {
      var tx = RG.human.event(e), last = out[out.length - 1];
      if (last && last.text === tx) last.n++; else out.push({ e: e, text: tx, n: 1 });
    });
    return out;
  };
  RG.loadAuto = function () { return RG.api('/api/auto/last').then(function (j) { S.autoLast = j.last; if (j.progress) S.jobs.auto = j.progress; }); };
  RG.loadAgent = function () { return RG.api('/api/agent/last').then(function (j) { S.agent = j.last; if (j.progress) S.jobs.agent = j.progress; }); };

  RG.updateNavBadges = function () {
    var el = RG.$('#navDiskCnt'); if (!el) return;
    var n = S.cands ? S.cands.items.filter(function (i) { return i.action !== 'report' && !i.protected; }).length : 0;
    el.textContent = n; el.hidden = n === 0;
  };
})();
