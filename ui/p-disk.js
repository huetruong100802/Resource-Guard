/* p-disk.js - Ổ đĩa: biểu đồ tròn theo nhóm + liệt kê đầy đủ nhân tố chiếm dung lượng. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;
  var LABEL = {
    'system-windows': 'Windows', 'programs': 'Chương trình đã cài', 'program-data': 'ProgramData', 'app-data': 'Dữ liệu ứng dụng (AppData)',
    'user-other': 'Hồ sơ người dùng khác', 'documents': 'Tài liệu & Media', 'downloads': 'Downloads', 'temp': 'Thư mục tạm',
    'dev-cache': 'Cache công cụ dev', 'repos': 'Mã nguồn (repos)', 'node-modules': 'node_modules', 'build-output': 'Build output (bin/obj, dist)',
    'git-data': 'Dữ liệu .git', 'vm-disks': 'Ổ ảo (VHDX/WSL/Docker)', 'recycle-bin': 'Thùng rác', 'system-files': 'File hệ thống (pagefile/hiberfil…)', 'other': 'Khác',
    '__free': 'Dung lượng trống', '__unscanned': 'Chưa phân loại / không đọc được'
  };
  var NOTE = {
    'system-files': 'pagefile.sys, hiberfil.sys, swapfile.sys: chỉ giảm được bằng cấu hình Windows, tool không đụng tới.',
    'repos': 'Mã nguồn của bạn. Phần node_modules/bin/obj bên trong được tách riêng ở tab Dọn dẹp.',
    'downloads': 'File cá nhân: tool chỉ liệt kê, không bao giờ tự xoá.', 'documents': 'File cá nhân: tool chỉ liệt kê, không bao giờ tự xoá.',
    'vm-disks': 'Ổ ảo chỉ nén thủ công (docker builder prune, wsl --manage … --set-sparse true).'
  };
  var PALETTE = ['#4e79d6', '#e0803b', '#2fa37a', '#c8527a', '#8a6fd1', '#c9a227', '#2fa3b8', '#d6584c', '#7f9a2e', '#a0689a', '#3f51b5', '#8d6e63', '#00897b', '#f4a582', '#607d8b', '#b5651d', '#9ccc65', '#ec407a'];
  var D = { view: 'group', hl: null, open: {} };

  function color(cat, i) { if (cat === '__free') return RG.css('--free'); if (cat === '__unscanned') return 'url(#hatch)'; return PALETTE[i % PALETTE.length]; }
  function segs(d) {
    var a = d.categories.map(function (c, i) { return { cat: c.cat, bytes: c.bytes, col: PALETTE[i % PALETTE.length] }; });
    if (d.unscannedBytes > 0) a.push({ cat: '__unscanned', bytes: d.unscannedBytes, col: RG.css('--mut') });
    a.push({ cat: '__free', bytes: d.freeBytes, col: RG.css('--free') });
    return a;
  }
  function donut(d, list) {
    var R = 96, C = 2 * Math.PI * R, off = 0, total = d.totalBytes;
    var s = '<svg class="donut" id="donut" viewBox="0 0 260 260" role="img" aria-label="Biểu đồ tròn dung lượng ổ ' + esc(d.drive) + '"><g transform="rotate(-90 130 130)">';
    list.forEach(function (x, i) {
      var len = Math.max(0, x.bytes / total * C - 1.2);
      s += '<circle class="seg" data-cat="' + esc(x.cat) + '" cx="130" cy="130" r="' + R + '" stroke="' + x.col + '" stroke-dasharray="' + len.toFixed(2) + ' ' + (C - len).toFixed(2) + '" stroke-dashoffset="' + (-off).toFixed(2) + '"' + (x.cat === '__unscanned' ? ' opacity=".55"' : '') + '><title>' + esc(LABEL[x.cat] || x.cat) + ': ' + RG.fmtBytes(x.bytes) + '</title></circle>';
      off += x.bytes / total * C;
    });
    s += '</g><text class="c1" x="130" y="126" text-anchor="middle" id="dC1">' + RG.fmtBytes(d.usedBytes) + '</text><text class="c2" x="130" y="146" text-anchor="middle" id="dC2">đã dùng / ' + RG.fmtBytes(total) + '</text></svg>';
    return s;
  }
  function setHl(cat) {
    D.hl = cat;
    var dn = $('#donut'); if (!dn) return;
    dn.classList.toggle('dim', !!cat);
    RG.$$('#donut circle.seg').forEach(function (c) { c.classList.toggle('hl', c.dataset.cat === cat); });
    RG.$$('.legend .li').forEach(function (l) { l.classList.toggle('hl', l.dataset.cat === cat); });
    var d = S.disk; if (!d) return;
    if (cat) {
      var x = segs(d).filter(function (y) { return y.cat === cat; })[0];
      if (x) { $('#dC1').textContent = RG.fmtBytes(x.bytes); $('#dC2').textContent = (LABEL[cat] || cat) + ' · ' + (x.bytes / d.totalBytes * 100).toFixed(1) + '%'; }
    } else { $('#dC1').textContent = RG.fmtBytes(d.usedBytes); $('#dC2').textContent = 'đã dùng / ' + RG.fmtBytes(d.totalBytes); }
  }
  function itemRow(it, catBytes, col, showCat) {
    var key = String(it.key), age = RG.daysSince(it.newestUtc), isPath = /^[A-Za-z]:\\/.test(key), prot = isPath && RG.isPathProtected(key);
    return '<tr class="row"><td><span class="ellipsis mono" title="' + esc(key) + '">' + esc(key) + '</span>' + (showCat ? ' <span class="pill">' + esc(LABEL[it.cat] || it.cat) + '</span>' : '') +
      '<div class="minibar"><i style="width:' + Math.min(100, it.bytes / Math.max(1, catBytes) * 100).toFixed(1) + '%;background:' + col + '"></i></div></td>' +
      '<td class="r num">' + RG.fmtBytes(it.bytes) + '</td><td class="r num mut">' + (it.bytes / Math.max(1, catBytes) * 100).toFixed(1) + '%</td>' +
      '<td class="r num mut" title="Lần ghi gần nhất trong thư mục này">' + (age == null ? '–' : RG.fmtAge(age)) + '</td>' +
      '<td class="r">' + (isPath ? '<button class="icon-btn ' + (prot ? 'on' : '') + '" data-path="' + esc(key) + '" aria-pressed="' + prot + '" aria-label="' + (prot ? 'Bỏ bảo vệ' : 'Bảo vệ') + ' ' + esc(key) + '" title="' + (prot ? 'Đang được bảo vệ khỏi tự dọn' : 'Bảo vệ khỏi tự dọn') + '">' + RG.icon('shield') + '</button>' : '') + '</td></tr>';
  }
  function itemTable(rows) {
    return '<div class="tbl-wrap" style="max-height:420px"><table><thead><tr><th>Thư mục / nhân tố</th><th class="r">Dung lượng</th><th class="r">Tỷ lệ</th><th class="r">Không ghi</th><th class="r">Bảo vệ</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
  }
  function groupDetail(d, list) {
    return d.categories.map(function (c, i) {
      var col = PALETTE[i % PALETTE.length], rows = c.items.map(function (it) { return itemRow(it, c.bytes, col, false); }).join('');
      if (c.restBytes > 0) rows += '<tr><td class="mut">… ' + Math.max(0, c.itemCount - c.items.length) + ' mục nhỏ hơn</td><td class="r num mut">' + RG.fmtBytes(c.restBytes) + '</td><td class="r num mut">' + (c.restBytes / Math.max(1, c.bytes) * 100).toFixed(1) + '%</td><td></td><td></td></tr>';
      return '<details class="acc" data-cat="' + esc(c.cat) + '"' + (D.open[c.cat] ? ' open' : '') + '><summary>' + RG.icon('chev', 'chev') + '<span class="sw" style="background:' + col + '"></span><b>' + esc(LABEL[c.cat] || c.cat) + '</b>' +
        '<span class="mut small">' + c.itemCount + ' mục · ' + c.files.toLocaleString('vi-VN') + ' file</span><span style="margin-left:auto" class="num"><b>' + RG.fmtBytes(c.bytes) + '</b></span></summary>' +
        '<div class="inner">' + (NOTE[c.cat] ? '<p class="hint" style="margin:0 0 6px">' + esc(NOTE[c.cat]) + '</p>' : '') + itemTable(rows) + '</div></details>';
    }).join('');
  }
  function flatDetail(d) {
    var all = [], col = {};
    d.categories.forEach(function (c, i) { col[c.cat] = PALETTE[i % PALETTE.length]; c.items.forEach(function (it) { all.push({ key: it.key, bytes: it.bytes, newestUtc: it.newestUtc, cat: c.cat }); }); });
    all.sort(function (a, b) { return b.bytes - a.bytes; });
    return itemTable(all.slice(0, 80).map(function (it) { return itemRow(it, d.usedBytes, col[it.cat], true); }).join(''));
  }

  function tabs() {
    var dl = RG.driveList(); if (dl.length < 2) return '';
    return '<div class="seg" role="tablist" aria-label="Chọn ổ đĩa" style="margin-bottom:12px;flex-wrap:wrap">' + dl.map(function (x) {
      var st = x.state || 'Normal';
      return '<button role="tab" data-drive="' + esc(x.drive) + '" aria-pressed="' + (x.drive === S.driveSel) + '" title="' + esc(x.label || '') + '">' + esc(x.drive) + ': <span class="num">' + x.freeGB + ' GB</span>' + (st !== 'Normal' ? ' <span class="pill ' + (st === 'Critical' ? 'ask' : '') + '">' + esc(st) + '</span>' : '') + '</button>';
    }).join('') + '</div>';
  }
  function draw() {
    var el = $('#diskBody'); if (!el) return;
    var sel = S.driveSel, d = S.disk && (!sel || S.disk.drive === sel) ? S.disk : null;
    var j = S.jobs.breakdown, running = j && j.status === 'running', mine = running && (!j.drive || j.drive === sel);
    var head = tabs() + '<div class="field" style="margin-top:0"><button class="btn primary" id="scanBtn"' + (running ? ' disabled' : '') + '>' + RG.icon('refresh') + (d ? 'Quét lại' : 'Quét ổ ' + (sel ? esc(sel) + ':' : 'đĩa')) + '</button>';
    if (running && !mine) head += '<span class="spin"></span><span class="small mut">Đang quét ổ ' + esc(j.drive) + ': (' + (j.pct || 0) + '%). Mỗi lần chỉ quét một ổ.</span>';
    else if (running) head += '<span class="spin"></span><div class="progress" style="flex:1;max-width:320px"><i style="width:' + (j.pct || 0) + '%"></i></div><span class="small mut num">' + (j.pct || 0) + '% · ' + RG.fmtBytes(j.bytes) + ' · ' + (j.files || 0).toLocaleString('vi-VN') + ' file</span>';
    else if (d) head += '<span class="small mut">Quét ' + RG.timeAgo(d.finishedUtc) + ' · ' + d.seconds + ' giây · đọc được ' + (d.scannedBytes / Math.max(1, d.usedBytes) * 100).toFixed(0) + '% dung lượng đã dùng · ' + d.files.toLocaleString('vi-VN') + ' file</span>';
    if (j && j.status === 'error' && (!j.drive || j.drive === sel)) head += '<span class="small warn">Lỗi: ' + esc(j.message) + '</span>';
    head += '</div>';
    if (!d) {
      el.innerHTML = head + '<div class="card empty">' + RG.icon('disk') + '<h3>Chưa có dữ liệu phân tích ổ ' + (sel ? esc(sel) + ':' : 'đĩa') + '</h3><div>Quét mất khoảng một phút, chạy ở tiến trình riêng nên không làm treo giao diện. Chỉ đọc, không xoá gì.</div></div>';
    } else {
      var list = segs(d), pctUsed = d.usedBytes / d.totalBytes * 100, di = RG.driveInfo(d.drive);
      var legend = list.map(function (x, i) {
        var p = x.bytes / d.totalBytes * 100;
        return '<div class="li" data-cat="' + esc(x.cat) + '" tabindex="0" role="button" aria-label="' + esc(LABEL[x.cat] || x.cat) + ' ' + RG.fmtBytes(x.bytes) + '"><span class="sw' + (x.cat === '__unscanned' ? ' hatch' : '') + '" style="' + (x.cat === '__unscanned' ? '' : 'background:' + x.col) + '"></span>' +
          '<span>' + esc(LABEL[x.cat] || x.cat) + '</span><b class="num">' + RG.fmtBytes(x.bytes) + '</b><span class="num mut r">' + p.toFixed(1) + '%</span></div>';
      }).join('');
      el.innerHTML = head +
        (di && di.state && di.state !== 'Normal' ? '<div class="alert warn" style="margin-bottom:14px"><div><b>Ổ ' + esc(d.drive) + ': còn trống ' + di.freeGB + ' GB (' + (100 - pctUsed).toFixed(1) + '%).</b> Xem nhân tố lớn nhất bên dưới, hoặc sang tab <a href="#clean" data-go="clean">Dọn dẹp</a>.</div></div>' : '') +
        '<div class="card"><h2>Ổ ' + esc(d.drive) + ': phân bố dung lượng</h2><div class="donut-wrap">' + donut(d, list) + '<div class="legend">' + legend + '</div></div>' +
        (d.unscannedBytes > d.totalBytes * 0.02 ? '<p class="hint">' + RG.fmtBytes(d.unscannedBytes) + ' không đọc được (file hệ thống đang khoá, quyền truy cập, hoặc dữ liệu OneDrive chưa tải về).</p>' : '') + '</div>' +
        '<div class="card mt"><h2>Tất cả nhân tố chiếm dung lượng<span class="sp"></span><span class="seg sm" role="group" aria-label="Kiểu xem"><button id="vGroup" aria-pressed="' + (D.view === 'group') + '">Theo nhóm</button><button id="vFlat" aria-pressed="' + (D.view === 'flat') + '">Top 80 lớn nhất</button></span></h2>' +
        (D.view === 'group' ? groupDetail(d, list) : flatDetail(d)) + '</div>';
      RG.$$('#donut circle.seg').forEach(function (c) {
        c.onmouseenter = function () { setHl(c.dataset.cat); }; c.onmouseleave = function () { setHl(null); };
        c.onclick = function () { openCat(c.dataset.cat); };
      });
      RG.$$('.legend .li').forEach(function (l) {
        l.onmouseenter = function () { setHl(l.dataset.cat); }; l.onmouseleave = function () { setHl(null); };
        l.onclick = function () { openCat(l.dataset.cat); }; l.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); openCat(l.dataset.cat); } };
      });
      RG.$$('details.acc').forEach(function (x) { x.ontoggle = function () { D.open[x.dataset.cat] = x.open; }; });
      RG.$$('#diskBody [data-path]').forEach(function (b) { b.onclick = function () { RG.toggleProtect('path', b.dataset.path, b.getAttribute('aria-pressed') !== 'true'); }; });
      var vg = $('#vGroup'), vf = $('#vFlat'); if (vg) { vg.onclick = function () { D.view = 'group'; draw(); }; vf.onclick = function () { D.view = 'flat'; draw(); }; }
      RG.$$('#diskBody [data-go]').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); RG.go(a.dataset.go); }; });
    }
    $('#scanBtn').onclick = function () { RG.startJob('/api/disk/scan', sel ? { drive: sel } : {}, 'Bắt đầu quét ổ ' + (sel ? sel + ':' : 'đĩa') + '…').then(function () { if (S.jobs.breakdown) S.jobs.breakdown.drive = sel; }).catch(function () { }); };
    RG.$$('#diskBody [data-drive]').forEach(function (b) {
      b.onclick = function () { if (b.dataset.drive === S.driveSel) return; S.driveSel = b.dataset.drive; S.disk = null; D.open = {}; draw(); RG.loadDisk(b.dataset.drive).then(draw).catch(function () { }); };
    });
  }
  function openCat(cat) {
    if (D.view !== 'group') { D.view = 'group'; }
    D.open[cat] = true; draw();
    var t = document.querySelector('details.acc[data-cat="' + cat + '"]'); if (t) t.scrollIntoView({ behavior: 'smooth', block: 'center' });
  }

  RG.pages.disk = {
    title: 'Ổ đĩa',
    render: function (el) {
      el.innerHTML = '<div id="diskBody"></div>';
      draw(); this.refresh();
    },
    refresh: function () { RG.loadDisk(S.driveSel).then(draw).catch(function () { }); },
    jobs: function () { if (RG.cur === 'disk') draw(); },
    live: function () { }
  };
})();
