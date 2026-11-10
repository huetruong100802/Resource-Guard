/* viz.js - thư viện hình ảnh hoá dùng chung: thanh ảnh hưởng, treemap, miền xếp chồng, ngăn kéo, biên lai. Đăng ký vào RG.viz / RG. */
(function () {
  'use strict';
  var RG = window.RG, esc = RG.esc, V = RG.viz = {}, uid = 0;

  /* Màu theo nhóm dung lượng: cố định theo tên nhóm để mọi trang cùng một màu. */
  var PAL = { 'system-windows': '#6b7a99', 'programs': '#8a6fd1', 'program-data': '#a0689a', 'app-data': '#2fa3b8', 'user-other': '#8d6e63', 'documents': '#2fa37a', 'downloads': '#c9a227',
    'temp': '#e0803b', 'dev-cache': '#d6584c', 'repos': '#4e79d6', 'node-modules': '#c8527a', 'build-output': '#7f9a2e', 'git-data': '#3f51b5', 'vm-disks': '#b5651d', 'recycle-bin': '#607d8b', 'system-files': '#78909c', 'other': '#9aa4b5' };
  V.catColor = function (c) { return PAL[c] || '#9aa4b5'; };
  V.CAT_LABEL = { 'system-windows': 'Windows', 'programs': 'Chương trình đã cài', 'program-data': 'ProgramData', 'app-data': 'Dữ liệu ứng dụng (AppData)', 'user-other': 'Hồ sơ người dùng & khác',
    'documents': 'Tài liệu & Media', 'downloads': 'Downloads', 'temp': 'Thư mục tạm', 'dev-cache': 'Cache công cụ dev', 'repos': 'Mã nguồn (repos)', 'node-modules': 'node_modules', 'build-output': 'Build output (bin/obj, dist)',
    'git-data': 'Dữ liệu .git', 'vm-disks': 'Ổ ảo (VHDX/WSL/Docker)', 'recycle-bin': 'Thùng rác', 'system-files': 'File hệ thống (pagefile/hiberfil…)', 'other': 'Khác' };

  /* ---------- Thanh ảnh hưởng ---------- */
  // o: { totalBytes, freeBytes, gainBytes, cautionBytes, normalBytes, label, unit, stateFn(freeBytes) }
  // Trống >= normalBytes: Ổn; >= cautionBytes: Cần chú ý; thấp hơn: Nguy cấp (stateFn ghi đè, vd. RAM có 4 mức). Gọi lại là cập nhật tại chỗ.
  function stateOf(o, free) {
    if (o.stateFn) return o.stateFn(free);
    if (o.normalBytes != null && free > o.normalBytes) return 'Normal';
    if (o.cautionBytes != null && free >= o.cautionBytes) return 'Caution';
    return o.cautionBytes == null && o.normalBytes == null ? 'Normal' : 'Critical';
  }
  V.impactBar = function (el, o) {
    if (!el) return;
    var total = Math.max(1, +o.totalBytes || 1), free = Math.max(0, +o.freeBytes || 0), gain = Math.max(0, Math.min(+o.gainBytes || 0, total - free));
    var used = total - free, usedAfter = used - gain, pc = function (b) { return (Math.max(0, Math.min(total, b)) / total * 100).toFixed(2) + '%'; };
    var s0 = stateOf(o, free), s1 = stateOf(o, free + gain);
    var cap = (o.label ? esc(o.label) + ' ' : '') + 'trống <b class="num">' + RG.fmtBytes(free) + '</b>' + (gain > 0 ? ' → <b class="num">' + RG.fmtBytes(free + gain) + '</b>' : '') +
      ' · <span style="color:' + RG.stateColor(s0) + '">' + RG.human.state(s0) + '</span>' + (gain > 0 && s1 !== s0 ? ' → <span style="color:' + RG.stateColor(s1) + '">' + RG.human.state(s1) + '</span>' : '');
    var aria = (o.label ? o.label + ' ' : '') + 'trống ' + RG.fmtBytes(free) + (gain > 0 ? ', sau khi làm trống ' + RG.fmtBytes(free + gain) : '') + ', ' + RG.human.state(s0) + (gain > 0 && s1 !== s0 ? ' rồi ' + RG.human.state(s1) : '');
    var ticks = '';
    if (o.cautionBytes != null) ticks += '<b class="ib-tick" style="left:' + pc(total - o.cautionBytes) + '" title="Dưới mức này: Nguy cấp"></b>';
    if (o.normalBytes != null) ticks += '<b class="ib-tick ok" style="left:' + pc(total - o.normalBytes) + '" title="Trên mức này: Ổn"></b>';
    var w = el.firstChild;
    if (!w || !w.classList || !w.classList.contains('ib')) {
      el.innerHTML = '<div class="ib"><div class="ib-bar" role="img"><i class="ib-used"></i><i class="ib-gain"></i><span class="ib-tk"></span></div><div class="ib-cap small"></div></div>';
      w = el.firstChild;
    }
    var bar = w.firstChild, kids = bar.children;
    bar.setAttribute('aria-label', aria);
    kids[0].style.width = pc(usedAfter); kids[1].style.left = pc(usedAfter); kids[1].style.width = pc(gain); kids[2].innerHTML = ticks;
    w.lastChild.innerHTML = cap;
  };

  /* ---------- Treemap squarified ---------- */
  function worst(row, side) { var s = 0, mx = 0, mn = Infinity; row.forEach(function (a) { s += a; if (a > mx) mx = a; if (a < mn) mn = a; }); var s2 = s * s, w2 = side * side; return Math.max(w2 * mx / s2, s2 / (w2 * mn)); }
  function squarify(areas, x, y, w, h) {
    var out = [], n = areas.length, i = 0;
    while (i < n) {
      var side = Math.min(w, h), row = [areas[i]], j = i + 1;
      while (j < n && worst(row.concat([areas[j]]), side) <= worst(row, side)) { row.push(areas[j]); j++; }
      var rs = row.reduce(function (a, b) { return a + b; }, 0), k, p;
      if (w >= h) { var cw = rs / h, cy = y; for (k = 0; k < row.length; k++) { var ch = row[k] / cw; out.push([x, cy, cw, ch]); cy += ch; } x += cw; w -= cw; }
      else { var rh = rs / w, cx = x; for (k = 0; k < row.length; k++) { var cw2 = row[k] / rh; out.push([cx, y, cw2, rh]); cx += cw2; } y += rh; h -= rh; }
      i = j;
    }
    return out;
  }
  function kidsOf(node, maxTiles) {
    var kids = (node.children || []).filter(function (c) { return c.bytes > 0; }).sort(function (a, b) { return b.bytes - a.bytes; });
    var sum = 0; kids.forEach(function (c) { sum += c.bytes; });
    var own = Math.max(0, (node.bytes || 0) - sum), res = kids.slice(0, Math.max(1, maxTiles - 1)), rest = kids.slice(res.length), rb = 0, rf = 0;
    rest.forEach(function (c) { rb += c.bytes; rf += c.files || 0; });
    // gộp các nút "(khác)" có sẵn và phần dôi vượt maxTiles thành MỘT ô
    var merged = [], restNode = null;
    res.forEach(function (c) { if (c.rest) { restNode = restNode || { name: '(khác)', path: node.path, bytes: 0, files: 0, rest: true, children: [] }; restNode.bytes += c.bytes; restNode.files += c.files || 0; } else merged.push(c); });
    if (rb > 0) { restNode = restNode || { name: '(khác)', path: node.path, bytes: 0, files: 0, rest: true, children: [] }; restNode.bytes += rb; restNode.files += rf; }
    if (restNode) merged.push(restNode);
    if (own > 0) merged.push({ name: kids.length ? '(file ngay trong thư mục này)' : node.name, path: node.path, bytes: own, own: true, cat: node.cat, zone: node.zone, newestUtc: node.newestUtc, children: [] });
    return merged.sort(function (a, b) { return b.bytes - a.bytes; });
  }
  // el: vùng chứa; rootNode: { name, path, bytes, children }; o: { overlay(node), onPick(node), onDrill(node), maxTiles, height }
  V.treemap = function (el, rootNode, o) {
    o = o || {}; if (!el) return null;
    var st = el.__tm; if (!st) { st = el.__tm = { stack: [], paths: [] }; }
    var maxTiles = o.maxTiles || 60, H = o.height || 380;
    // giữ vị trí đào sâu theo đường dẫn khi nạp lại dữ liệu
    var cur = rootNode, stack = [rootNode];
    st.paths.slice(1).forEach(function (p) { var f = (cur.children || []).filter(function (c) { return !c.rest && c.path === p; })[0]; if (f) { cur = f; stack.push(f); } });
    st.stack = stack; st.paths = stack.map(function (n) { return n.path; }); st.o = o;
    function draw() {
      var node = st.stack[st.stack.length - 1], W = Math.max(280, el.clientWidth || 640), id = ++uid;
      var crumbs = st.stack.map(function (n, i) { return (i ? '<span class="mut">›</span>' : '') + '<button class="btn sm" data-bc="' + i + '"' + (i === st.stack.length - 1 ? ' aria-current="location"' : '') + '>' + esc(i === 0 ? (n.name || n.path) : n.name) + '</button>'; }).join('');
      var html = '<div class="tm-crumbs" aria-label="Đường dẫn">' + (st.stack.length > 1 ? '<button class="btn sm" data-bc="up" aria-label="Lùi một cấp">' + RG.icon('back') + '</button>' : '') + crumbs + '</div>';
      if (!node || !(node.bytes > 0)) { el.innerHTML = html + '<div class="tm-empty mut">Không có dữ liệu dung lượng ở đây.</div>'; bindCrumbs(); return; }
      var tiles = kidsOf(node, maxTiles), total = 0; tiles.forEach(function (t) { total += t.bytes; });
      var rects = squarify(tiles.map(function (t) { return t.bytes / total * W * H; }), 0, 0, W, H);
      var svg = '<svg class="tm" viewBox="0 0 ' + W + ' ' + H + '" style="height:' + H + 'px" role="group" aria-label="Treemap dung lượng ' + esc(node.name) + '"><defs>' +
        '<pattern id="tmh' + id + '" width="9" height="9" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="9" stroke="#1f9d55" stroke-width="3.5" opacity=".8"/></pattern></defs>';
      tiles.forEach(function (t, i) {
        var r = rects[i], ov = o.overlay ? o.overlay(t) : null, fill = t.rest ? 'var(--free)' : (t.unscanned ? 'var(--panel2)' : V.catColor(t.cat)), pct = (t.bytes / Math.max(1, node.bytes) * 100).toFixed(1);
        var drill = !t.rest && !t.own && t.children && t.children.length, label = t.name + ' · ' + RG.fmtBytes(t.bytes) + ' · ' + pct + '%';
        var w = Math.max(0, r[2] - 1.5), h = Math.max(0, r[3] - 1.5);
        var op = ov === 'fixed' || t.zone === 'fixed' ? .45 : 1;
        svg += '<g class="tile' + (drill ? ' drill' : '') + '" data-i="' + i + '" tabindex="0" role="button" aria-label="' + esc(label) + '"><title>' + esc(label) + (ov ? ' · ' + ({ sel: 'đang chọn', cand: 'có mục dọn được', prot: 'được bảo vệ', fixed: 'vùng cố định' }[ov] || '') : '') + '</title>' +
          '<rect x="' + (r[0] + .75).toFixed(1) + '" y="' + (r[1] + .75).toFixed(1) + '" width="' + w.toFixed(1) + '" height="' + h.toFixed(1) + '" rx="3" fill="' + fill + '" opacity="' + op + '"/>';
        if (ov === 'cand') svg += '<rect x="' + (r[0] + .75).toFixed(1) + '" y="' + (r[1] + .75).toFixed(1) + '" width="' + w.toFixed(1) + '" height="' + h.toFixed(1) + '" rx="3" fill="url(#tmh' + id + ')"/>';
        if (ov === 'sel') svg += '<rect x="' + (r[0] + 2).toFixed(1) + '" y="' + (r[1] + 2).toFixed(1) + '" width="' + Math.max(0, w - 2.5).toFixed(1) + '" height="' + Math.max(0, h - 2.5).toFixed(1) + '" rx="2" fill="none" stroke="var(--accent)" stroke-width="3.5"/>';
        if (ov === 'prot') svg += '<rect x="' + (r[0] + 2).toFixed(1) + '" y="' + (r[1] + 2).toFixed(1) + '" width="' + Math.max(0, w - 2.5).toFixed(1) + '" height="' + Math.max(0, h - 2.5).toFixed(1) + '" rx="2" fill="none" stroke="#fff" stroke-width="2.5" stroke-dasharray="6 4"/>' +
          (w > 30 && h > 30 ? '<g transform="translate(' + (r[0] + w - 22).toFixed(1) + ',' + (r[1] + 6).toFixed(1) + ') scale(.7)" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M12 3l7 3v5c0 4.5-3 8.2-7 10-4-1.8-7-5.5-7-10V6l7-3z"/></g>' : '');
        if (w > 74 && h > 30) svg += '<text class="tl' + (op < 1 ? ' fx' : '') + '" x="' + (r[0] + 8).toFixed(1) + '" y="' + (r[1] + 18).toFixed(1) + '">' + esc(clip(t.name, Math.floor(w / 7))) + '</text>' + (h > 46 ? '<text class="ts' + (op < 1 ? ' fx' : '') + '" x="' + (r[0] + 8).toFixed(1) + '" y="' + (r[1] + 33).toFixed(1) + '">' + RG.fmtBytes(t.bytes) + ' · ' + pct + '%</text>' : '');
        svg += '</g>';
      });
      svg += '</svg>';
      el.innerHTML = html + svg;
      bindCrumbs();
      RG.$$('.tile', el).forEach(function (g) {
        var t = tiles[+g.dataset.i];
        g.onclick = function () { if (o.onPick) o.onPick(t, node); };
        g.ondblclick = function () { drillTo(t); };
        g.onkeydown = function (e) { if (e.key === 'Enter') { e.preventDefault(); if (t.children && t.children.length && !t.rest && !t.own) drillTo(t); else if (o.onPick) o.onPick(t, node); } else if (e.key === ' ') { e.preventDefault(); if (o.onPick) o.onPick(t, node); } else if (e.key === 'Escape' || e.key === 'Backspace') { if (st.stack.length > 1) { e.preventDefault(); up(); } } };
      });
    }
    function clip(s, n) { s = String(s || ''); return s.length > n ? s.slice(0, Math.max(1, n - 1)) + '…' : s; }
    function drillTo(t) { if (!t || t.rest || t.own || !t.children || !t.children.length) return; st.stack.push(t); st.paths = st.stack.map(function (n) { return n.path; }); if (o.onDrill) o.onDrill(t); draw(); var f = RG.$('.tile', el); if (f) f.focus(); }
    function up() { if (st.stack.length > 1) { st.stack.pop(); st.paths = st.stack.map(function (n) { return n.path; }); draw(); } }
    function bindCrumbs() {
      RG.$$('[data-bc]', el).forEach(function (b) { b.onclick = function () { if (b.dataset.bc === 'up') return up(); var i = +b.dataset.bc; st.stack = st.stack.slice(0, i + 1); st.paths = st.stack.map(function (n) { return n.path; }); draw(); }; });
    }
    draw();
    return { up: up, redraw: draw, current: function () { return st.stack[st.stack.length - 1]; } };
  };

  /* ---------- Miền xếp chồng ---------- */
  // o: { series: [{ name, color, points: [{ t, v }] }], max, unit, onPick(name), xfmt }. Các chuỗi dùng chung mốc thời gian (hợp các t); thiếu = 0.
  V.stackArea = function (svg, o) {
    if (!svg) return;
    var W = Math.max(160, svg.clientWidth || 560), H = Math.max(60, svg.clientHeight || 180), pl = 38, pb = 14, pt = 6, pr = 4;
    svg.setAttribute('viewBox', '0 0 ' + W + ' ' + H);
    var ts = {}; o.series.forEach(function (s) { s.points.forEach(function (p) { ts[p.t] = 1; }); });
    var times = Object.keys(ts).sort();
    if (times.length < 2) { svg.innerHTML = '<text x="' + pl + '" y="' + (H / 2) + '">Đang thu thập dữ liệu…</text>'; return; }
    var idx = {}; times.forEach(function (t, i) { idx[t] = i; });
    var vals = o.series.map(function (s) { var a = new Array(times.length), i; for (i = 0; i < a.length; i++) a[i] = 0; s.points.forEach(function (p) { a[idx[p.t]] = +p.v || 0; }); return a; });
    var i, mx = 0;
    for (i = 0; i < times.length; i++) { var tot = 0; vals.forEach(function (a) { tot += a[i]; }); if (tot > mx) mx = tot; }
    var hi = o.max || mx * 1.08 || 1;
    var X = function (k) { return pl + k * (W - pl - pr) / (times.length - 1); }, Y = function (v) { return pt + (H - pt - pb) * (1 - Math.min(v, hi) / hi); };
    var s = '';
    [0, .5, 1].forEach(function (f) { var v = hi * f; s += '<line x1="' + pl + '" x2="' + (W - pr) + '" y1="' + Y(v) + '" y2="' + Y(v) + '" stroke="' + RG.css('--line') + '"/><text x="2" y="' + (Y(v) + 3) + '">' + (o.yfmt ? o.yfmt(v) : Math.round(v)) + '</text>'; });
    var cum = new Array(times.length); for (i = 0; i < cum.length; i++) cum[i] = 0;
    o.series.forEach(function (ser, n) {
      var lo = cum.slice(), up = cum.map(function (c, k) { return c + vals[n][k]; });
      var top = up.map(function (v, k) { return X(k).toFixed(1) + ',' + Y(v).toFixed(1); }).join(' '), bot = lo.map(function (v, k) { return X(k).toFixed(1) + ',' + Y(v).toFixed(1); }).reverse().join(' ');
      var last = vals[n][times.length - 1];
      s += '<polygon class="sa" data-n="' + n + '" points="' + top + ' ' + bot + '" fill="' + ser.color + '" opacity=".82" tabindex="0" role="button" aria-label="' + esc(ser.name) + ' ' + (o.yfmt ? o.yfmt(last) : last) + (o.unit || '') + '"><title>' + esc(ser.name) + ' · hiện ' + (o.yfmt ? o.yfmt(last) : Math.round(last)) + (o.unit || '') + '</title></polygon>';
      cum = up;
    });
    var xf = o.xfmt || function (t) { return String(t).slice(11, 16); };
    s += '<text x="' + pl + '" y="' + (H - 2) + '">' + xf(times[0]) + '</text><text x="' + (W - pr) + '" y="' + (H - 2) + '" text-anchor="end">' + xf(times[times.length - 1]) + '</text>';
    svg.innerHTML = s;
    RG.$$('.sa', svg).forEach(function (p) {
      var name = o.series[+p.dataset.n].name;
      p.onclick = function () { if (o.onPick) o.onPick(name); };
      p.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); if (o.onPick) o.onPick(name); } };
    });
  };

  /* ---------- Ngăn kéo bên phải (một ngăn tại một thời điểm) ---------- */
  var openDrawer = null;
  RG.drawer = function (o) {
    if (openDrawer) openDrawer.close(true);
    var prev = document.activeElement, root = document.createElement('aside');
    root.className = 'drawer'; root.setAttribute('role', 'dialog'); root.setAttribute('aria-label', o.title || 'Chi tiết');
    root.innerHTML = '<div class="dr-head"><h3></h3><button class="icon-btn" aria-label="Đóng">' + RG.icon('x') + '</button></div><div class="dr-body"></div><div class="dr-acts"></div>';
    RG.$('h3', root).textContent = o.title || '';
    var body = RG.$('.dr-body', root), acts = RG.$('.dr-acts', root), closed = false;
    body.innerHTML = o.html || '';
    function onKey(e) {
      if (e.key === 'Escape') { e.stopPropagation(); close(); return; }
      if (e.key === 'Tab') { var f = RG.$$('button,input,select,a[href],[tabindex="0"]', root).filter(function (x) { return !x.disabled && x.offsetParent !== null; }); if (!f.length) return; var a = f[0], z = f[f.length - 1]; if (e.shiftKey && document.activeElement === a) { z.focus(); e.preventDefault(); } else if (!e.shiftKey && document.activeElement === z) { a.focus(); e.preventDefault(); } }
    }
    function close(silent) {
      if (closed) return; closed = true; document.removeEventListener('keydown', onKey, true);
      root.classList.remove('on'); setTimeout(function () { if (root.parentNode) root.parentNode.removeChild(root); }, 160);
      if (openDrawer === api) openDrawer = null;
      if (prev && prev.focus && silent !== true) { try { prev.focus(); } catch (e) { } }
      if (o.onClose) o.onClose();
    }
    function setActions(list) {
      acts.innerHTML = ''; (list || []).forEach(function (a) {
        var b = document.createElement('button'); b.className = 'btn ' + (a.cls || ''); b.textContent = a.label; if (a.disabled) b.disabled = true;
        b.onclick = function () { var r = a.onClick ? a.onClick(api) : undefined; if (r !== false && a.close !== false) close(); }; acts.appendChild(b);
      });
    }
    var api = { el: root, body: body, close: close, setHtml: function (h) { body.innerHTML = h; }, setActions: setActions, setTitle: function (t) { RG.$('h3', root).textContent = t; } };
    setActions(o.actions);
    RG.$('.icon-btn', root).onclick = function () { close(); };
    document.body.appendChild(root); document.addEventListener('keydown', onKey, true);
    requestAnimationFrame(function () { root.classList.add('on'); });
    var first = RG.$('.btn.primary', acts) || RG.$('.icon-btn', root); if (first) first.focus();
    openDrawer = api; return api;
  };

  /* ---------- Biên lai: 4 dòng cố định ---------- */
  RG.receipt = function (it) {
    if (!it) return '';
    var what = it.kind === 'process' ? esc(it.name || '') + ' <span class="mut">(PID ' + esc(it.pid) + ')</span>' : '<span class="mono" style="word-break:break-all">' + esc(it.path || it.name || '') + '</span>';
    var size = it.sizeBytes && it.action !== 'kill' ? ' · <b>' + RG.fmtBytes(it.sizeBytes) + '</b>' : '';
    var hint = it.regenHint || RG.human.regen(it.regen);
    var risk = it.riskLevel ? ' <span class="pill ' + ({ low: 'auto', medium: 'ask', high: 'bad' }[it.riskLevel] || '') + '">' + esc(RG.human.risk(it.riskLevel)) + '</span>' : '';
    return '<dl class="rc"><dt>Cái gì</dt><dd>' + what + size + risk + '</dd><dt>Vì sao</dt><dd>' + esc(it.why || it.reason || '–') + '</dd><dt>Ảnh hưởng</dt><dd>' + esc(it.impact || '–') + '</dd><dt>Lấy lại</dt><dd>' + esc(hint) + '</dd></dl>';
  };

  /* ---------- Trang thử #viz-demo (không có trong điều hướng) ---------- */
  RG.pages['viz-demo'] = {
    title: 'Thử thành phần hình ảnh',
    render: function (el) {
      el.innerHTML = '<div class="card"><h2>impactBar</h2><div id="d1"></div><div id="d2" style="margin-top:12px"></div><div id="d3" style="margin-top:12px"></div>' +
        '<div class="field"><label for="dg">Giải phóng (GB)</label><input id="dg" type="range" min="0" max="30" value="8" style="flex:1"></div></div>' +
        '<div class="card mt"><h2>treemap <span class="ro">bấm = chọn · bấm đúp / Enter = đào sâu · Esc = lùi</span></h2><div id="d4"></div><div id="d4b" class="small mut" style="margin-top:6px"></div></div>' +
        '<div class="grid g2 mt"><div class="card"><h2>treemap: 1 nút / 0 byte</h2><div id="d5"></div><div id="d6" style="margin-top:8px"></div></div><div class="card"><h2>treemap: 500 nút</h2><div id="d7"></div></div></div>' +
        '<div class="grid g2 mt"><div class="card"><h2>stackArea</h2><svg id="d8" class="chart tall" role="img" aria-label="Miền xếp chồng mẫu"></svg><div id="d8b" class="small mut"></div></div>' +
        '<div class="card"><h2>lineChart: điểm đánh dấu + ngưỡng kéo được <span class="ro" id="d9r"></span></h2><svg id="d9" class="chart tall" role="img" aria-label="Biểu đồ mẫu"></svg></div></div>' +
        '<div class="card mt"><h2>drawer + receipt</h2><button class="btn" id="d10">Mở ngăn kéo</button></div>';
      var T = 200 * 1073741824;
      function bars() {
        var g = (+RG.$('#dg').value) * 1073741824;
        V.impactBar(RG.$('#d1'), { totalBytes: T, freeBytes: 8.6 * 1073741824, gainBytes: g, cautionBytes: 10 * 1073741824, normalBytes: 20 * 1073741824, label: 'Ổ C' });
        V.impactBar(RG.$('#d2'), { totalBytes: T, freeBytes: 60 * 1073741824, gainBytes: 0, cautionBytes: 10 * 1073741824, normalBytes: 20 * 1073741824, label: 'Ổ D (không có gì để giải phóng)' });
        V.impactBar(RG.$('#d3'), { totalBytes: 16 * 1073741824, freeBytes: 1.6 * 1073741824, gainBytes: Math.min(g, 6 * 1073741824), label: 'RAM', stateFn: function (b) { return RG.ramState(b / 1073741824); } });
      }
      RG.$('#dg').oninput = bars; bars();
      function mk(name, b, kids, extra) { var n = { name: name, path: 'C:\\' + name, bytes: b, files: 10, cat: 'other', children: kids || [] }; for (var k in extra) n[k] = extra[k]; return n; }
      var tree = mk('C:\\', 100 * 1073741824, [
        mk('Windows', 38 * 1073741824, [mk('System32', 20 * 1073741824, [], { cat: 'system-windows', zone: 'fixed' }), mk('WinSxS', 12 * 1073741824, [], { cat: 'system-windows', zone: 'fixed' })], { cat: 'system-windows', zone: 'fixed' }),
        mk('Users', 30 * 1073741824, [mk('Temp', 6 * 1073741824, [], { cat: 'temp' }), mk('.nuget', 8 * 1073741824, [], { cat: 'dev-cache' }), mk('Work', 10 * 1073741824, [], { cat: 'repos' })], { cat: 'user-other' }),
        mk('Program Files', 20 * 1073741824, [], { cat: 'programs', zone: 'fixed' }), mk('Docker', 6 * 1073741824, [], { cat: 'vm-disks' }), mk('(khác)', 2 * 1073741824, [], { rest: true })]);
      var picked = null;
      V.treemap(RG.$('#d4'), tree, { overlay: function (n) { if (picked && n.path === picked.path) return 'sel'; return { 'Temp': 'cand', '.nuget': 'cand', 'Work': 'prot' }[n.name] || (n.zone === 'fixed' ? 'fixed' : null); },
        onPick: function (n) { picked = n; RG.$('#d4b').textContent = 'Đã chọn: ' + n.name + ' · ' + RG.fmtBytes(n.bytes); V.treemap(RG.$('#d4'), tree, V.__last4); }, onDrill: function (n) { RG.$('#d4b').textContent = 'Đào sâu: ' + n.name; } });
      V.__last4 = RG.$('#d4').__tm.o;
      V.treemap(RG.$('#d5'), mk('một nút', 5 * 1073741824, []), {});
      V.treemap(RG.$('#d6'), mk('rỗng', 0, []), {});
      var many = []; for (var i = 0; i < 500; i++) many.push(mk('n' + i, (500 - i) * 1048576, [], { cat: ['temp', 'repos', 'programs', 'documents'][i % 4] }));
      V.treemap(RG.$('#d7'), mk('nhiều nút', 120 * 1073741824, many), { maxTiles: 60 });
      var base = Date.now() - 3600000 * 6, series = [['node', '#4e79d6', 2000], ['chrome', '#e0803b', 1500], ['code', '#2fa37a', 900]].map(function (x, j) {
        var pts = []; for (var k = 0; k < 40; k++) { var t = new Date(base + k * 540000), ts = t.getFullYear() + '-' + RG.pad2(t.getMonth() + 1) + '-' + RG.pad2(t.getDate()) + ' ' + RG.pad2(t.getHours()) + ':' + RG.pad2(t.getMinutes()) + ':00'; pts.push({ t: ts, v: x[2] + Math.sin(k / 4 + j) * 300 + k * 10 }); } return { name: x[0], color: x[1], points: pts };
      });
      V.stackArea(RG.$('#d8'), { series: series, unit: ' MB', onPick: function (n) { RG.$('#d8b').textContent = 'Đã bấm vào dải: ' + n; } });
      var hist = []; for (var q = 0; q < 60; q++) { var tt = new Date(base + q * 360000); hist.push({ ts: tt.getFullYear() + '-' + RG.pad2(tt.getMonth() + 1) + '-' + RG.pad2(tt.getDate()) + ' ' + RG.pad2(tt.getHours()) + ':' + RG.pad2(tt.getMinutes()) + ':00', v: 40 - q * .3 + Math.sin(q) }); }
      var thr = { v: 20, min: 5, max: 40, step: 1, label: 'Ngưỡng kích hoạt', text: 'Ngưỡng 20 GB', onChange: function (v) { thr.v = v; thr.text = 'Ngưỡng ' + v + ' GB'; RG.$('#d9r').textContent = 'ngưỡng = ' + v + ' GB'; draw9(); } };
      function draw9() { RG.lineChart(RG.$('#d9'), hist, { key: 'v', color: RG.css('--disk'), min: 0, area: true, unit: ' GB', dragLine: thr, markers: [{ ts: hist[20].ts, type: 'auto-run', label: 'Tự dọn: 3 mục, 2,1 GB' }, { ts: hist[40].ts, type: 'policy-change', label: 'Đổi chính sách' }], onMarker: function (m) { RG.toast('Điểm đánh dấu: ' + m.label); } }); }
      draw9();
      RG.$('#d10').onclick = function () { RG.drawer({ title: 'Ví dụ biên lai', html: RG.receipt({ kind: 'temp-entry', path: 'C:\\Users\\me\\AppData\\Local\\Temp\\old', sizeBytes: 4e8, why: 'File tạm không được dùng 197 ngày', impact: 'Không ảnh hưởng; chương trình tự tạo lại khi cần', regenHint: 'Tự tạo lại khi cần', riskLevel: 'low' }), actions: [{ label: 'Chọn', cls: 'primary' }, { label: 'Đóng', close: true }] }); };
    },
    live: function () { }
  };
})();
