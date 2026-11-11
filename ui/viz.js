/* viz.js - thư viện hình ảnh hoá dùng chung: resourceBar, treemap 2 cấp, donut, kênh liên kết, miền xếp chồng, ngăn kéo, biên lai. Đăng ký vào RG.viz / RG. */
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

  /* ---------- Kênh liên kết nhỏ: bản đồ, danh sách, thanh và donut sáng cùng nhau ---------- */
  // RG.link.on('hover'|'select', fn(key, state)) -> hàm huỷ đăng ký; RG.link.emit(channel, key, state).
  var linkSubs = {};
  RG.link = {
    on: function (ch, fn) { (linkSubs[ch] = linkSubs[ch] || []).push(fn); return function () { var a = linkSubs[ch] || [], i = a.indexOf(fn); if (i >= 0) a.splice(i, 1); }; },
    emit: function (ch, key, state) { (linkSubs[ch] || []).slice().forEach(function (fn) { try { fn(key, state); } catch (e) { } }); },
    clear: function (ch) { if (ch) linkSubs[ch] = []; else linkSubs = {}; }
  };

  /* ---------- resourceBar: thanh tài nguyên trước → sau ---------- */
  // o: { total, segments:[{ key, label, value, color, pattern }], free, gain, marks:[{ value, label, drag?:{ min, max, step, onChange(v) } }],
  //      caption (HTML), leftLabel, rightLabel, onHover(key), onPick(key) }
  // Đơn vị tuỳ ý (byte hoặc GB) miễn nhất quán. `marks[].value` là VỊ TRÍ dọc thanh (0..total): vạch "còn trống X" đặt ở total - X.
  // Đoạn gạch chéo `gain` nằm ở cuối vùng đã dùng (phần sẽ được giải phóng). Trả về { update(o), highlight(key) }.
  V.resourceBar = function (el, o) {
    if (!el) return null;
    var inst = el.__rb;
    if (inst) { inst.update(o); return inst; }
    var cur = null, hl = null, dragging = null;
    el.innerHTML = '<div class="rb"><div class="rb-bar" role="img"><span class="rb-gain"></span></div><div class="rb-band"></div><div class="rb-marks"></div><div class="rb-ends small"><span class="rb-l"></span><span class="rb-m"></span><span class="rb-r"></span></div><div class="rb-legend small"></div><div class="rb-ruler"></div><div class="rb-cap small"></div></div>';
    var wrap = el.firstChild, bar = wrap.children[0], gainEl = bar.firstChild, bandEl = wrap.children[1], marksEl = wrap.children[2], ends = wrap.children[3], legEl = wrap.children[4], rulerEl = wrap.children[5], capEl = wrap.children[6];
    function pct(v, total) { return (Math.max(0, Math.min(total, v)) / total * 100); }
    function render(skipMarks) {
      var total = Math.max(1e-9, +cur.total || 1), segs = cur.segments || [], used = 0, free = cur.free == null ? null : Math.max(0, +cur.free), gain = Math.max(0, +cur.gain || 0);
      segs.forEach(function (s) { used += Math.max(0, +s.value || 0); });
      if (free == null) free = Math.max(0, total - used);
      var html = '', acc = 0;
      segs.forEach(function (s) {
        var v = Math.max(0, +s.value || 0); if (v <= 0) return;
        var left = pct(acc, total), w = Math.min(pct(v, total), 100 - left);
        html += '<i class="rb-seg' + (s.pattern === 'hatch' ? ' hatch' : '') + (hl === s.key ? ' hl' : '') + '" data-k="' + esc(s.key || '') + '" style="left:' + RG.n1(left * 100 / 100) + '%;width:' + String(Math.round(w * 100) / 100) + '%;background-color:' + (s.color || 'var(--disk)') + '" title="' + esc((s.label || s.key || '') + ' · ' + (cur.fmt ? cur.fmt(v) : RG.fmtBytes(v))) + '"></i>';
        acc += v;
      });
      // phần trống nằm sau phần đã dùng (nền thanh = màu trống); gain phủ lên cuối vùng đã dùng
      var gainFrom = Math.max(0, total - free - gain), gl = pct(gainFrom, total), gw = Math.min(pct(gain, total), 100 - gl);
      gainEl.style.left = String(Math.round(gl * 100) / 100) + '%'; gainEl.style.width = gain > 0 ? String(Math.round(gw * 100) / 100) + '%' : '0';
      gainEl.style.display = gain > 0 ? '' : 'none';
      var old = bar.querySelectorAll('.rb-seg'), i; for (i = old.length - 1; i >= 0; i--) bar.removeChild(old[i]);
      bar.insertAdjacentHTML('afterbegin', html);
      bar.classList.toggle('hl-on', hl != null);
      // Dải trạng thái mỏng cùng thang với thanh (không chữ; rê chuột mới có giải thích). cur.band = [{ from, to, color, label }] theo vị trí 0..total.
      var bz = cur.band || [];
      bandEl.style.display = bz.length ? '' : 'none';
      bandEl.innerHTML = bz.map(function (z) { var l = pct(z.from, total), w = Math.max(0, pct(z.to, total) - l); return w > 0 ? '<i style="left:' + String(Math.round(l * 100) / 100) + '%;width:' + String(Math.round(w * 100) / 100) + '%;background:' + z.color + '" title="' + esc(z.label || '') + '"></i>' : ''; }).join('');
      wrap.classList.toggle('mk-top', !!cur.marksTop);
      var aria = cur.aria || ((cur.caption || '').replace(/<[^>]+>/g, ''));
      bar.setAttribute('aria-label', aria);
      Array.prototype.forEach.call(bar.querySelectorAll('.rb-seg'), function (n) {
        n.onmouseenter = function () { if (cur.onHover) cur.onHover(n.dataset.k); RG.link.emit('hover', n.dataset.k, true); };
        n.onmouseleave = function () { if (cur.onHover) cur.onHover(null); RG.link.emit('hover', n.dataset.k, false); };
        n.onclick = function () { if (cur.onPick) cur.onPick(n.dataset.k); RG.link.emit('select', n.dataset.k, true); };
      });
      ends.firstChild.textContent = cur.leftLabel != null ? cur.leftLabel : '0';
      ends.children[1].textContent = cur.midLabel || ''; ends.children[1].style.color = 'var(--normal)';
      ends.lastChild.textContent = cur.rightLabel != null ? cur.rightLabel : (cur.fmt ? cur.fmt(total) : RG.fmtBytes(total));
      legEl.innerHTML = cur.legendHtml || ''; legEl.style.display = cur.legendHtml ? '' : 'none';
      capEl.innerHTML = cur.caption || '';
      if (!skipMarks) { renderMarks(total); renderRuler(); }
    }
    // Thước dung lượng trống: cur.ruler = { max, zones:[{from,to,color,label}], pins:[{value,label,color}], handle:{ value, min, max, step, label, onChange(v, final) } } (đơn vị như total)
    function renderRuler() {
      var r = cur.ruler; rulerEl.style.display = r ? '' : 'none'; if (!r) { rulerEl.innerHTML = ''; return; }
      var M = Math.max(1e-9, +r.max || 1), pc = function (v) { return Math.max(0, Math.min(100, v / M * 100)); }, html = '';
      (r.zones || []).forEach(function (z) { html += '<div class="rz" style="left:' + pc(z.from) + '%;width:' + (pc(z.to) - pc(z.from)) + '%;background:' + z.color + '">' + esc(z.label || '') + '</div>'; });
      var pins = r.pins || [], far = pins.length > 1 && Math.abs(pc(pins[0].value) - pc(pins[1].value)) > 14;
      pins.forEach(function (p, i) { html += '<div class="rpin' + (far ? (i === 0 ? ' l' : ' r') : '') + '" style="left:' + pc(p.value) + '%;color:' + (p.color || 'inherit') + '">' + esc(p.label || '') + '</div>'; });
      var h = r.handle;
      if (h) html += '<div class="rhdl" tabindex="0" role="slider" aria-label="' + esc(h.label || 'Ngưỡng') + '" aria-valuemin="' + RG.n1(h.min) + '" aria-valuemax="' + RG.n1(h.max) + '" aria-valuenow="' + RG.n1(h.value) + '" style="left:' + pc(h.value) + '%"><i></i><span>' + esc(h.label || '') + '</span></div>';
      rulerEl.innerHTML = html;
      var node = rulerEl.querySelector('.rhdl'); if (node) bindRuler(node, h, M);
    }
    function bindRuler(node, h, M) {
      var step = h.step || M / 200;
      function setVal(pos, final) {
        pos = Math.max(h.min, Math.min(h.max, pos)); pos = Math.round(pos / step) * step; h.value = pos;
        node.style.left = Math.max(0, Math.min(100, pos / M * 100)) + '%'; node.setAttribute('aria-valuenow', RG.n1(pos));
        if (h.onChange) h.onChange(pos, !!final);
      }
      function fromEvent(e) { var b = rulerEl.getBoundingClientRect(); return (e.clientX - b.left) / Math.max(1, b.width) * M; }
      node.addEventListener('pointerdown', function (e) {
        e.preventDefault(); dragging = true; try { node.setPointerCapture(e.pointerId); } catch (x) { }
        var mv = function (ev) { setVal(fromEvent(ev), false); };
        var up = function (ev) { node.removeEventListener('pointermove', mv); node.removeEventListener('pointerup', up); node.removeEventListener('pointercancel', up); dragging = false; setVal(fromEvent(ev), true); };
        node.addEventListener('pointermove', mv); node.addEventListener('pointerup', up); node.addEventListener('pointercancel', up);
      });
      node.addEventListener('keydown', function (e) {
        var k = e.key, big = e.shiftKey ? 10 : 1, delta = 0;
        if (k === 'ArrowLeft' || k === 'ArrowDown') delta = -step * big; else if (k === 'ArrowRight' || k === 'ArrowUp') delta = step * big; else if (k === 'Home') { e.preventDefault(); return setVal(h.min, true); } else if (k === 'End') { e.preventDefault(); return setVal(h.max, true); }
        if (delta) { e.preventDefault(); setVal(h.value + delta, true); var n2 = rulerEl.querySelector('.rhdl'); if (n2) n2.focus(); }
      });
    }
    function renderMarks(total) {
      var marks = (cur.marks || []).map(function (m, i) { return { m: m, i: i, pos: Math.max(0, Math.min(total, +m.value)) }; }).sort(function (a, b) { return a.pos - b.pos; });
      var W = Math.max(200, marksEl.clientWidth || el.clientWidth || 400), ends = [], rows = 0, html = '';
      marks.forEach(function (k) {
        var px = k.pos / total * W, lw = Math.min(W, String(k.m.label || '').length * 7 + 12), start = Math.max(0, Math.min(W - lw, px - lw / 2)), r = 0;
        while (ends[r] != null && ends[r] > start - 4) r++;
        ends[r] = start + lw; rows = Math.max(rows, r + 1); k.row = r; k.start = start; k.lw = lw;
      });
      if (cur.marksTop) {   // nhãn nằm trên thanh, vạch xuyên qua thanh, tay nắm nằm ngay trên thanh; nhãn gọn khi nghỉ, đầy đủ khi rê/kéo/focus
        var Hm = Math.max(1, rows) * 17 + 4;
        marks.forEach(function (k) {
          var m = k.m, d = m.drag, right = k.pos / total > 0.5;
          html += '<div class="rb-mk top' + (d ? ' drag' : '') + '" data-i="' + k.i + '" style="left:' + String(Math.round(k.pos / total * 10000) / 100) + '%">' +
            '<span class="rb-lab ' + (right ? 'rt' : 'lt') + '" style="top:' + (k.row * 17) + 'px"><span class="mk-s">' + esc(m.label || '') + '</span>' + (m.detail ? '<span class="mk-d">' + m.detail + '</span>' : '') + '</span>' +
            '<b class="rb-line" style="top:' + (k.row * 17 + 17) + 'px;height:' + (Hm - k.row * 17 - 17 + 29) + 'px"></b>' +
            (d ? '<i class="rb-knob" style="top:' + (Hm + 5) + 'px" tabindex="0" role="slider" aria-label="' + esc(m.label || 'Ngưỡng') + '" aria-valuemin="' + RG.n1(d.min) + '" aria-valuemax="' + RG.n1(d.max) + '" aria-valuenow="' + RG.n1(m.value) + '"></i>' : '') + '</div>';
        });
        marksEl.style.height = Hm + 'px';
        marksEl.innerHTML = html;
        Array.prototype.forEach.call(marksEl.querySelectorAll('.rb-mk.drag'), function (n) { bindDrag(n, cur.marks[+n.dataset.i], total); });
        return;
      }
      marks.forEach(function (k) {
        var m = k.m, left = RG.n1(k.pos / total * 100 * 100 / 100), d = m.drag;
        html += '<div class="rb-mk' + (d ? ' drag' : '') + '" data-i="' + k.i + '" style="left:' + String(Math.round(k.pos / total * 10000) / 100) + '%">' +
          '<b class="rb-line" style="height:' + (18 + k.row * 17) + 'px"></b>' +
          (d ? '<i class="rb-knob" tabindex="0" role="slider" aria-label="' + esc(m.label || 'Ngưỡng') + '" aria-valuemin="' + d.min + '" aria-valuemax="' + d.max + '" aria-valuenow="' + RG.n1(k.m.value) + '"></i>' : '') +
          '<span class="rb-lab" style="top:' + (14 + k.row * 17) + 'px;left:' + RG.n1(k.start - k.pos / total * Math.max(200, marksEl.clientWidth || el.clientWidth || 400)) + 'px;transform:none">' + esc(m.label || '') + '</span></div>';
      });
      marksEl.style.height = (rows ? 20 + rows * 17 : 0) + 'px';
      marksEl.innerHTML = html;
      Array.prototype.forEach.call(marksEl.querySelectorAll('.rb-mk.drag'), function (n) { bindDrag(n, cur.marks[+n.dataset.i], total); });
    }
    function bindDrag(node, m, total) {
      var d = m.drag, knob = node.querySelector('.rb-knob'), step = d.step || total / 200;
      function setVal(pos, final) {
        pos = Math.max(d.min, Math.min(d.max, pos)); pos = Math.round(pos / step) * step;
        m.value = pos; node.style.left = String(Math.round(pos / total * 10000) / 100) + '%'; knob.setAttribute('aria-valuenow', RG.n1(pos));
        if (m.detailFn) { var dd = node.querySelector('.mk-d'); if (dd) dd.innerHTML = m.detailFn(pos); }
        if (d.onChange) d.onChange(pos, !!final);
      }
      function fromEvent(e) { var r = marksEl.getBoundingClientRect(); return (e.clientX - r.left) / Math.max(1, r.width) * total; }
      knob.addEventListener('pointerdown', function (e) {
        e.preventDefault(); dragging = true; node.classList.add('on'); try { knob.setPointerCapture(e.pointerId); } catch (x) { }
        var mv = function (ev) { setVal(fromEvent(ev), false); };
        var up = function (ev) { knob.removeEventListener('pointermove', mv); knob.removeEventListener('pointerup', up); knob.removeEventListener('pointercancel', up); dragging = false; node.classList.remove('on'); setVal(fromEvent(ev), true); };
        knob.addEventListener('pointermove', mv); knob.addEventListener('pointerup', up); knob.addEventListener('pointercancel', up);
      });
      knob.addEventListener('keydown', function (e) {
        var k = e.key, big = e.shiftKey ? 10 : 1, delta = 0;
        if (k === 'ArrowLeft' || k === 'ArrowDown') delta = -step * big; else if (k === 'ArrowRight' || k === 'ArrowUp') delta = step * big; else if (k === 'Home') { e.preventDefault(); return setVal(d.min, true); } else if (k === 'End') { e.preventDefault(); return setVal(d.max, true); }
        if (delta) { e.preventDefault(); setVal(m.value + delta, true); knob.focus(); }
      });
    }
    var off = RG.link.on('hover', function (key, state) { inst.highlight(state ? key : null, true); });
    inst = el.__rb = {
      update: function (n) { cur = n; render(!!dragging); },   // đang kéo tay nắm: không dựng lại vạch để không mất con trỏ
      highlight: function (key, fromLink) { hl = key == null ? null : key; bar.classList.toggle('hl-on', hl != null); Array.prototype.forEach.call(bar.querySelectorAll('.rb-seg'), function (s) { s.classList.toggle('hl', hl != null && s.dataset.k === hl); }); },
      destroy: function () { off(); el.__rb = null; }
    };
    cur = o; render();
    return inst;
  };

  // stateOf(o,free): trạng thái theo ngưỡng {cautionBytes,normalBytes} hoặc stateFn.
  function stateOf(o, free) {
    if (o.stateFn) return o.stateFn(free);
    if (o.normalBytes != null && free > o.normalBytes) return 'Normal';
    if (o.cautionBytes != null && free >= o.cautionBytes) return 'Caution';
    return o.cautionBytes == null && o.normalBytes == null ? 'Normal' : 'Critical';
  }
  V.stateOf = stateOf;
   /* ---------- Donut: "cái gì chiếm bao nhiêu" ---------- */
  // segs: [{ key, label, value, color, pattern }]; total; center: { big, small } (HTML cho big, văn bản cho small); size, thick tuỳ chọn. Dùng kênh liên kết 'hover'/'select'.
  V.donut = function (el, segs, total, center, size, thick, o) {
    if (!el) return null;
    o = o || {}; size = size || 132; thick = thick || 24; center = center || {};
    var R = (size - thick) / 2 - 2, C = 2 * Math.PI * R, off = 0, cx = size / 2, uidn = ++uid;
    var s = '<svg width="' + size + '" height="' + size + '" viewBox="0 0 ' + size + ' ' + size + '" role="img" aria-label="' + esc((center.small || '') + '') + '"><defs><pattern id="dh' + uidn + '" width="6" height="6" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="6" stroke="var(--panel)" stroke-width="2.4"/></pattern></defs>' +
      '<circle cx="' + cx + '" cy="' + cx + '" r="' + R + '" fill="none" stroke="var(--free)" stroke-width="' + thick + '"/>';
    (segs || []).forEach(function (g) {
      var v = Math.max(0, +g.value || 0); if (v <= 0 || !(total > 0)) return;
      var len = Math.max(0.6, v / total * C), a = 'fill="none" cx="' + cx + '" cy="' + cx + '" r="' + R + '" stroke-width="' + thick + '" stroke-dasharray="' + RG.n1(len) + ' ' + RG.n1(C - len) + '" stroke-dashoffset="' + RG.n1(-off) + '" transform="rotate(-90 ' + cx + ' ' + cx + ')"';
      s += '<circle class="dseg" data-k="' + esc(g.key || '') + '" ' + a + ' stroke="' + (g.color || 'var(--disk)') + '"><title>' + esc((g.label || g.key || '') + ': ' + (o.fmt ? o.fmt(v) : RG.fmtBytes(v))) + '</title></circle>';
      if (g.pattern === 'hatch') s += '<circle class="dseg" data-k="' + esc(g.key || '') + '" ' + a + ' stroke="url(#dh' + uidn + ')" style="pointer-events:none"/>';
      off += len;
    });
    s += '</svg><div class="ctr"><b>' + (center.big == null ? '' : center.big) + '</b><span>' + esc(center.small || '') + '</span></div>';
    el.innerHTML = s; el.classList.add('donut'); el.classList.toggle('mini', size < 90);
    el.style.width = size + 'px'; el.style.height = size + 'px';
    var hlKey = null;
    function mark(key) { hlKey = key; el.classList.toggle('hl-on', key != null); Array.prototype.forEach.call(el.querySelectorAll('.dseg[data-k]'), function (n) { n.classList.toggle('hl', key != null && n.dataset.k === key); }); }
    Array.prototype.forEach.call(el.querySelectorAll('.dseg[data-k]'), function (n) {
      n.onmouseenter = function () { RG.link.emit('hover', n.dataset.k, true); if (o.onHover) o.onHover(n.dataset.k); };
      n.onmouseleave = function () { RG.link.emit('hover', n.dataset.k, false); if (o.onHover) o.onHover(null); };
      n.onclick = function () { RG.link.emit('select', n.dataset.k, true); if (o.onPick) o.onPick(n.dataset.k); };
    });
    if (el.__dnOff) el.__dnOff();
    el.__dnOff = RG.link.on('hover', function (key, st) { mark(st ? key : null); });
    return { highlight: mark };
  };
  /* Chú giải một dòng cho mỗi màu/hoạ tiết: rows = [{ key, label, value, color, pattern }]. */
  V.legend = function (el, rows, o) {
    if (!el) return;
    o = o || {}; el.classList.add('legend');
    el.innerHTML = (rows || []).map(function (r) { return '<div class="lg" data-k="' + esc(r.key || '') + '"><i class="' + (r.pattern === 'hatch' ? 'hatch' : '') + '" style="background-color:' + (r.color || 'var(--disk)') + '"></i><span class="n">' + esc(r.label || r.key || '') + '</span><span class="v num">' + (o.fmt ? o.fmt(r.value) : RG.fmtBytes(r.value)) + '</span></div>'; }).join('');
    Array.prototype.forEach.call(el.querySelectorAll('.lg'), function (n) {
      n.onmouseenter = function () { RG.link.emit('hover', n.dataset.k, true); };
      n.onmouseleave = function () { RG.link.emit('hover', n.dataset.k, false); };
      n.onclick = function () { RG.link.emit('select', n.dataset.k, true); if (o.onPick) o.onPick(n.dataset.k); };
    });
    if (el.__lgOff) el.__lgOff();
    el.__lgOff = RG.link.on('hover', function (key, st) { Array.prototype.forEach.call(el.querySelectorAll('.lg'), function (n) { n.classList.toggle('hl', !!st && n.dataset.k === key); }); });
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
    res.forEach(function (c) { if (c.rest) { restNode = restNode || { name: '(khác)', path: node.path, key: String(node.key || node.path) + '#rest', bytes: 0, files: 0, rest: true, children: [] }; restNode.bytes += c.bytes; restNode.files += c.files || 0; } else merged.push(c); });
    if (rb > 0) { restNode = restNode || { name: '(khác)', path: node.path, key: String(node.key || node.path) + '#rest', bytes: 0, files: 0, rest: true, children: [] }; restNode.bytes += rb; restNode.files += rf; }
    if (restNode) merged.push(restNode);
    if (own > 0) merged.push({ name: kids.length ? '(file ngay trong thư mục này)' : node.name, path: node.path, key: String(node.key || node.path) + '#own', bytes: own, ownTile: true, cat: node.cat, zone: node.zone, newestUtc: node.newestUtc, children: [] });
    return merged.sort(function (a, b) { return b.bytes - a.bytes; });
  }
  // el: vùng chứa; rootNode: { name, path, bytes, children }
  // o: { overlay(node), onPick(node, parent), onDrill(node), maxTiles, height, depth (mặc định 2: ô cha có tiêu đề, ô con bên trong), exclude(node) -> true thì không vẽ (vùng cố định) }
  // Trả về { up, redraw, current, highlight(keys), select(keys) }; key của ô = node.key || node.path.
  V.treemap = function (el, rootNode, o) {
    o = o || {}; if (!el) return null;
    var st = el.__tm; if (!st) { st = el.__tm = { stack: [], paths: [], hl: null, sel: null }; }
    var maxTiles = o.maxTiles || 60, H = o.height || 380, depth = o.depth == null ? 2 : o.depth;
    // giữ vị trí đào sâu theo đường dẫn khi nạp lại dữ liệu
    var cur = rootNode, stack = [rootNode];
    st.paths.slice(1).forEach(function (p) { var f = (cur.children || []).filter(function (c) { return !c.rest && c.path === p; })[0]; if (f) { cur = f; stack.push(f); } });
    st.stack = stack; st.paths = stack.map(function (n) { return n.path; }); st.o = o;
    function keyOf(n) { return String(n.key || n.path || n.name); }
    // bản nhìn của một nút sau khi bỏ các con bị loại (vùng cố định): bytes trừ phần bị loại để không thành "file ngay trong thư mục"
    function view(n) {
      if (!o.exclude || !n.children || !n.children.length) return n;
      var ex = 0, keep = n.children.filter(function (c) { if (o.exclude(c)) { ex += c.bytes || 0; return false; } return true; });
      if (!ex) return n;
      var c2 = {}, k; for (k in n) c2[k] = n[k]; c2.children = keep; c2.bytes = Math.max(0, (n.bytes || 0) - ex); return c2;
    }
    // chuỗi thư mục chỉ có một nhánh chiếm ≥90% (Users → HueTruong) gộp vào tiêu đề để ô cha có con để vẽ
    function descend(t) {
      var cur = t, chain = '', ks;
      for (var n = 0; n < 6; n++) {
        var kv = view(cur); ks = (kv.children || []).filter(function (c) { return c.bytes > 0 && !c.rest; });
        if (ks.length === 1 && ks[0].children && ks[0].children.length && ks[0].bytes >= 0.9 * Math.max(1, kv.bytes || 0)) { chain += '\\' + ks[0].name; cur = ks[0]; } else break;
      }
      return { node: cur, chain: chain };
    }
    function layout(node, x, y, w, h, level, out) {
      var v = view(node), tiles = kidsOf(v, level === 0 ? maxTiles : 12), total = 0; tiles.forEach(function (t) { total += t.bytes; });
      if (!(total > 0) || w < 8 || h < 8) return;
      var rects = squarify(tiles.map(function (t) { return t.bytes / total * w * h; }), x, y, w, h);
      tiles.forEach(function (t, i) {
        var r = rects[i], it = { node: t, r: r, level: level, parent: v, kids: false };
        out.push(it);
        if (level + 1 < depth && !t.rest && !t.ownTile && t.children && t.children.length && r[2] > 96 && r[3] > 64) { var dn = descend(t); it.kids = true; it.label = t.name + dn.chain; layout(dn.node, r[0] + 2, r[1] + 19, r[2] - 4, r[3] - 21, level + 1, out); }
      });
    }
    function draw() {
      var node = st.stack[st.stack.length - 1], W = Math.max(280, el.clientWidth || 640), id = ++uid;
      var crumbs = st.stack.map(function (n, i) { return (i ? '<span class="mut">›</span>' : '') + '<button class="btn sm" data-bc="' + i + '"' + (i === st.stack.length - 1 ? ' aria-current="location"' : '') + '>' + esc(i === 0 ? (n.name || n.path) : n.name) + '</button>'; }).join('');
      var html = '<div class="tm-crumbs" aria-label="Đường dẫn">' + (st.stack.length > 1 ? '<button class="btn sm" data-bc="up" aria-label="Lùi một cấp">' + RG.icon('back') + '</button>' : '') + crumbs + '</div>';
      var vnode = view(node);
      if (!node || !(vnode.bytes > 0)) { el.innerHTML = html + '<div class="tm-empty mut">Không có dữ liệu dung lượng ở đây.</div>'; bindCrumbs(); return; }
      var items = []; layout(node, 0, 0, W, H, 0, items);
      var svg = '<svg class="tm" viewBox="0 0 ' + W + ' ' + H + '" style="height:' + H + 'px" role="group" aria-label="Treemap dung lượng ' + esc(node.name) + '"><defs>' +
        '<pattern id="tmh' + id + '" width="9" height="9" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="9" stroke="#1f9d55" stroke-width="3.5" opacity=".8"/></pattern>' +
        '<pattern id="tmp' + id + '" width="9" height="9" patternUnits="userSpaceOnUse" patternTransform="rotate(45)"><line x1="0" y1="0" x2="0" y2="9" stroke="var(--panel)" stroke-width="3.5" opacity=".9"/></pattern></defs>';
      items.forEach(function (it, i) {
        var t = it.node, r = it.r, ov = o.overlay ? o.overlay(t) : null; if (it.kids && ov === 'cand') ov = null;   // ô cha chỉ làm khung; gạch chéo thuộc về ô con
        var fill = t.freeTile ? 'none' : t.rest ? 'var(--free)' : t.sys ? 'var(--d-system)' : (t.unscanned || t.zone === 'fixed' ? 'var(--panel2)' : (o.neutral === false ? V.catColor(t.cat) : (o.baseFill || 'var(--tm-fill)'))), base = Math.max(1, it.parent.bytes);
        var parts = o.parts && !it.kids && !t.freeTile && !t.sys ? o.parts(t) : null;   // các dải màu theo nhóm donut (đáy lên), diện tích tỷ lệ số byte
        var pct = RG.fmtNum(t.bytes / base * 100, 1);
        var drill = !t.rest && !t.ownTile && t.children && t.children.length, label = t.name + ' · ' + RG.fmtBytes(t.bytes) + ' · ' + pct + '%';
        var w = Math.max(0, r[2] - 1.5), h = Math.max(0, r[3] - 1.5), x = RG.n1(r[0] + .75), y = RG.n1(r[1] + .75), ws = RG.n1(w), hs = RG.n1(h);
        var op = t.sys || t.freeTile ? 1 : (ov === 'fixed' || t.zone === 'fixed' ? .45 : (it.kids ? .38 : 1));
        svg += '<g class="tile' + (drill ? ' drill' : '') + (it.kids ? ' parent' : '') + (t.freeTile ? ' ftile' : '') + '" data-i="' + i + '" data-k="' + esc(keyOf(t)) + '" tabindex="0" role="button" aria-label="' + esc(label) + '"><title>' + esc(label) + (ov ? ' · ' + ({ sel: 'đang chọn', cand: 'có mục dọn được', prot: 'được bảo vệ', fixed: 'vùng cố định' }[ov] || '') : '') + '</title>' +
          '<rect class="main" x="' + x + '" y="' + y + '" width="' + ws + '" height="' + hs + '" rx="3" fill="' + fill + '" opacity="' + op + '"/>';
        if (parts) {
          var used = 0, yb = r[1] + .75 + h;
          parts.forEach(function (pt) {
            if (!(pt.bytes > 0)) return;
            var ph = Math.min(h - used, Math.max(Math.min(h, 8), h * Math.min(1, pt.bytes / Math.max(1, t.bytes))));
            if (!(ph > 0)) return;
            yb -= ph; used += ph;
            svg += '<rect x="' + x + '" y="' + RG.n1(yb) + '" width="' + ws + '" height="' + RG.n1(ph) + '" rx="3" fill="' + pt.color + '" style="pointer-events:none"/>' +
              (pt.pattern === 'hatch' ? '<rect x="' + x + '" y="' + RG.n1(yb) + '" width="' + ws + '" height="' + RG.n1(ph) + '" rx="3" fill="url(#tmp' + id + ')" style="pointer-events:none"/>' : '');
          });
        } else if (ov === 'cand' || ov === 'sel') {   // gạch chéo chỉ phủ phần dọn được (dải đáy theo tỷ lệ), không phủ cả ô
          var cb = o.cleanBytes ? o.cleanBytes(t) : t.bytes, fr = Math.max(0, Math.min(1, cb / Math.max(1, t.bytes))), hh = fr >= .98 ? h : Math.max(Math.min(h, 10), h * fr);
          if (cb > 0) svg += '<rect x="' + x + '" y="' + RG.n1(r[1] + .75 + h - hh) + '" width="' + ws + '" height="' + RG.n1(hh) + '" rx="3" fill="url(#tmh' + id + ')" style="pointer-events:none"/>';
        }
        if (ov === 'sel') svg += '<rect x="' + RG.n1(r[0] + 2) + '" y="' + RG.n1(r[1] + 2) + '" width="' + RG.n1(Math.max(0, w - 2.5)) + '" height="' + RG.n1(Math.max(0, h - 2.5)) + '" rx="2" fill="none" stroke="var(--accent)" stroke-width="3.5" style="pointer-events:none"/>';
        if (ov === 'prot') svg += '<rect x="' + RG.n1(r[0] + 2) + '" y="' + RG.n1(r[1] + 2) + '" width="' + RG.n1(Math.max(0, w - 2.5)) + '" height="' + RG.n1(Math.max(0, h - 2.5)) + '" rx="2" fill="none" stroke="#fff" stroke-width="2.5" stroke-dasharray="6 4" style="pointer-events:none"/>' +
          (w > 30 && h > 30 ? '<g transform="translate(' + RG.n1(r[0] + w - 22) + ',' + RG.n1(r[1] + 6) + ') scale(.7)" fill="none" stroke="#fff" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round" style="pointer-events:none"><path d="M12 3l7 3v5c0 4.5-3 8.2-7 10-4-1.8-7-5.5-7-10V6l7-3z"/></g>' : '');
        if (it.kids) svg += '<text class="tl hd" x="' + RG.n1(r[0] + 7) + '" y="' + RG.n1(r[1] + 14) + '">' + esc(clip(it.label || t.name, Math.floor(w / 7) - 8)) + ' · ' + RG.fmtBytes(t.bytes) + '</text>';
        else if (w > 74 && h > 30) svg += '<text class="tl' + (op < 1 || t.freeTile ? ' fx' : '') + '" x="' + RG.n1(r[0] + 8) + '" y="' + RG.n1(r[1] + 18) + '">' + esc(clip(t.name, Math.floor(w / 7))) + '</text>' + (h > 46 ? '<text class="ts' + (op < 1 || t.freeTile ? ' fx' : '') + '" x="' + RG.n1(r[0] + 8) + '" y="' + RG.n1(r[1] + 33) + '">' + RG.fmtBytes(t.bytes) + ' · ' + pct + '%</text>' : '');
        svg += '</g>';
      });
      svg += '</svg>';
      el.innerHTML = html + svg;
      bindCrumbs();
      RG.$$('.tile', el).forEach(function (g) {
        var it = items[+g.dataset.i], t = it.node, parent = it.parent;
        g.onclick = function () { if (o.onPick) o.onPick(t, parent); RG.link.emit('select', keyOf(t), true); };
        g.onmouseenter = function () { RG.link.emit('hover', keyOf(t), true); };
        g.onmouseleave = function () { RG.link.emit('hover', keyOf(t), false); };
        g.ondblclick = function () { drillTo(t); };
        g.onkeydown = function (e) { if (e.key === 'Enter') { e.preventDefault(); if (t.children && t.children.length && !t.rest && !t.ownTile) drillTo(t); else if (o.onPick) o.onPick(t, parent); } else if (e.key === ' ') { e.preventDefault(); if (o.onPick) o.onPick(t, parent); } else if (e.key === 'Escape' || e.key === 'Backspace') { if (st.stack.length > 1) { e.preventDefault(); up(); } } };
      });
      applyMarks();
    }
    function toSet(keys) { if (keys == null) return null; var a = Array.isArray(keys) ? keys : [keys], s = {}; a.forEach(function (k) { s[String(k)] = 1; }); return s; }
    function applyMarks() {
      var svgEl = RG.$('svg.tm', el); if (!svgEl) return;
      svgEl.classList.toggle('hl-on', !!st.hl);
      RG.$$('.tile', svgEl).forEach(function (g) { var k = g.dataset.k; g.classList.toggle('hl', !!(st.hl && st.hl[k])); g.classList.toggle('sel', !!(st.sel && st.sel[k])); });
    }
    function clip(s, n) { s = String(s || ''); return s.length > n ? s.slice(0, Math.max(1, n - 1)) + '…' : s; }
    function drillTo(t) { if (!t || t.rest || t.ownTile || !t.children || !t.children.length) return; st.stack.push(t); st.paths = st.stack.map(function (n) { return n.path; }); if (o.onDrill) o.onDrill(t); draw(); var f = RG.$('.tile', el); if (f) f.focus(); }
    function up() { if (st.stack.length > 1) { st.stack.pop(); st.paths = st.stack.map(function (n) { return n.path; }); draw(); } }
    function bindCrumbs() {
      RG.$$('[data-bc]', el).forEach(function (b) { b.onclick = function () { if (b.dataset.bc === 'up') return up(); var i = +b.dataset.bc; st.stack = st.stack.slice(0, i + 1); st.paths = st.stack.map(function (n) { return n.path; }); draw(); }; });
    }
    draw();
    if (st.off) st.off();
    st.off = RG.link.on('hover', function (key, on) { st.hl = on ? toSet(key) : null; if (!el.isConnected) return; applyMarks(); });
    return { up: up, redraw: draw, current: function () { return st.stack[st.stack.length - 1]; },
      highlight: function (keys) { st.hl = toSet(keys); applyMarks(); }, select: function (keys) { st.sel = toSet(keys); applyMarks(); } };
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
      var top = up.map(function (v, k) { return RG.n1(X(k)) + ',' + RG.n1(Y(v)); }).join(' '), bot = lo.map(function (v, k) { return RG.n1(X(k)) + ',' + RG.n1(Y(v)); }).reverse().join(' ');
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
      el.innerHTML = '<div class="card"><h2>treemap <span class="ro">bấm = chọn · bấm đúp / Enter = đào sâu · Esc = lùi</span></h2><div id="d4"></div><div id="d4b" class="small mut" style="margin-top:6px"></div></div>' +
        '<div class="grid g2 mt"><div class="card"><h2>treemap: 1 nút / 0 byte</h2><div id="d5"></div><div id="d6" style="margin-top:8px"></div></div><div class="card"><h2>treemap: 500 nút</h2><div id="d7"></div></div></div>' +
        '<div class="grid g2 mt"><div class="card"><h2>stackArea</h2><svg id="d8" class="chart tall" role="img" aria-label="Miền xếp chồng mẫu"></svg><div id="d8b" class="small mut"></div></div>' +
        '<div class="card"><h2>lineChart: điểm đánh dấu + ngưỡng kéo được <span class="ro" id="d9r"></span></h2><svg id="d9" class="chart tall" role="img" aria-label="Biểu đồ mẫu"></svg></div></div>' +
        '<div class="card mt"><h2>drawer + receipt</h2><button class="btn" id="d10">Mở ngăn kéo</button></div>' +
        '<div class="card mt"><h2>resourceBar: nhãn tại vạch, tay nắm kéo được <span class="ro" id="r1r"></span></h2><div id="r1"></div><div id="r2" style="margin-top:28px"></div></div>' +
        '<div class="grid g2 mt"><div class="card"><h2>donut + chú giải (rê chuột liên kết)</h2><div style="display:flex;gap:16px;align-items:center"><div id="r3"></div><div id="r4" style="flex:1"></div></div></div>' +
        '<div class="card"><h2>lineChart: ít dữ liệu (3 mẫu) và đủ dữ liệu</h2><div><svg id="r5" class="chart" role="img" aria-label="Biểu đồ ít dữ liệu"></svg></div><div><svg id="r6" class="chart tall" role="img" aria-label="Biểu đồ co trục"></svg></div></div></div>' +
        '<div class="card mt"><h2>treemap 2 cấp + exclude vùng cố định + highlight</h2><div id="r7"></div><div class="small mut" style="margin-top:6px">Rê vào chú giải donut: ô tương ứng sáng.</div></div>';
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
      var GB = 1073741824, rTotal = 200 * GB, rThr = 10 * GB;
      function rbars() {
        V.resourceBar(RG.$('#r1'), { total: rTotal, segments: [{ key: 'mine', label: 'Của bạn', value: 100 * GB, color: 'var(--disk)' }, { key: 'sys', label: 'Hệ thống', value: 52 * GB, color: 'var(--role-system)' }, { key: 'rv', label: 'Cần xem lại', value: 39.4 * GB, color: 'var(--caution)' }],
          free: 8.6 * GB, gain: 11.4 * GB, leftLabel: 'Đã dùng ' + RG.fmtBytes(191.4 * GB), rightLabel: 'Tổng ' + RG.fmtBytes(rTotal),
          marks: [{ value: rTotal - rThr, label: 'Tự dọn khi còn dưới ' + RG.fmtBytes(rThr), drag: { min: rTotal - 60 * GB, max: rTotal - 2 * GB, step: GB, onChange: function (v) { rThr = rTotal - v; RG.$('#r1r').textContent = 'ngưỡng = ' + RG.fmtBytes(rThr); rbars(); } } },
            { value: rTotal - 20 * GB, label: 'Ổn từ ' + RG.fmtBytes(20 * GB) }, { value: rTotal - 19 * GB, label: 'vạch sát nhau' }],
          caption: 'Trống <b class="num">' + RG.fmtBytes(8.6 * GB) + '</b> → <b class="num">' + RG.fmtBytes(20 * GB) + '</b> · Nguy cấp → Ổn' });
        V.resourceBar(RG.$('#r2'), { total: 16, segments: [{ key: 'b', label: 'Trình duyệt', value: 2.1, color: 'var(--role-browser)' }, { key: 'd', label: 'Build', value: 1.4, color: 'var(--role-build)' }, { key: 'c', label: 'VS Code', value: 1.1, color: 'var(--role-editor)' }, { key: 'w', label: 'Windows', value: 1.6, color: 'var(--role-system)' }],
          free: 2.4, fmt: function (v) { return RG.fmtGB(v); }, marks: [{ value: 16 - 5, label: 'Ổn từ 5 GB' }, { value: 16 - 2, label: 'Nguy cấp dưới 2 GB' }], caption: 'Thanh RAM chia theo việc đang chạy; rê vào đoạn để sáng cả donut và bản đồ' });
      }
      rbars();
      var dsegs = [{ key: 'b', label: 'Trình duyệt', value: 2.1, color: 'var(--role-browser)' }, { key: 'd', label: 'Build', value: 1.4, color: 'var(--role-build)', pattern: 'hatch' }, { key: 'c', label: 'VS Code', value: 1.1, color: 'var(--role-editor)' }, { key: 'w', label: 'Windows', value: 1.6, color: 'var(--role-system)' }];
      V.donut(RG.$('#r3'), dsegs, 7.8, { big: RG.fmtGB(2.4), small: 'trống' }, 132, 24, { fmt: function (v) { return RG.fmtGB(v); } });
      V.legend(RG.$('#r4'), dsegs, { fmt: function (v) { return RG.fmtGB(v); } });
      var few = []; for (var f = 0; f < 3; f++) few.push({ ts: '2026-11-11 10:0' + f + ':00', v: 3 + f });
      RG.lineChart(RG.$('#r5'), few, { key: 'v', color: RG.css('--disk') });
      var ramp = []; for (var g = 0; g < 30; g++) ramp.push({ ts: '2026-11-11 10:' + RG.pad2(g) + ':00', v: 5.1 + Math.sin(g / 3) * .05 });
      RG.lineChart(RG.$('#r6'), ramp, { key: 'v', color: RG.css('--disk'), fit: true });
      var tt = { name: 'C:', path: 'C:', bytes: 100 * GB, children: [mk('Windows', 38 * GB, [], { cat: 'system-windows', zone: 'fixed' }), mk('Users', 40 * GB, [mk('Temp', 6 * GB, [], { cat: 'temp' }), mk('.nuget', 8 * GB, [], { cat: 'dev-cache' }), mk('Work', 20 * GB, [mk('dxwms', 12 * GB, [], { cat: 'repos' }), mk('web', 8 * GB, [], { cat: 'node-modules' })], { cat: 'repos' })], { cat: 'user-other' }), mk('Docker', 22 * GB, [], { cat: 'vm-disks' })] };
      V.treemap(RG.$('#r7'), tt, { depth: 2, exclude: function (n) { return n.zone === 'fixed'; }, height: 300 });
      RG.$('#d10').onclick = function () { RG.drawer({ title: 'Ví dụ biên lai', html: RG.receipt({ kind: 'temp-entry', path: 'C:\\Users\\me\\AppData\\Local\\Temp\\old', sizeBytes: 4e8, why: 'File tạm không được dùng 197 ngày', impact: 'Không ảnh hưởng; chương trình tự tạo lại khi cần', regenHint: 'Tự tạo lại khi cần', riskLevel: 'low' }), actions: [{ label: 'Chọn', cls: 'primary' }, { label: 'Đóng', close: true }] }); };
    },
    live: function () { }
  };
})();
