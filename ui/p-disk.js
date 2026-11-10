/* p-disk.js - Ổ đĩa: thanh tóm tắt theo nhóm + treemap đào sâu có lớp phủ hành động; tab phụ "Top lớn nhất". */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, GB = 1073741824;
  var LABEL = V.CAT_LABEL;
  var NOTE = {
    'system-files': 'pagefile.sys, hiberfil.sys, swapfile.sys: chỉ giảm được bằng cấu hình Windows, tool không đụng tới.',
    'repos': 'Mã nguồn của bạn. Phần node_modules/bin/obj bên trong được tách riêng ở trang Dọn dẹp.',
    'downloads': 'File cá nhân: tool chỉ liệt kê, không bao giờ tự xoá.', 'documents': 'File cá nhân: tool chỉ liệt kê, không bao giờ tự xoá.',
    'vm-disks': 'Ổ ảo chỉ nén thủ công (docker builder prune, wsl --manage … --set-sparse true).'
  };
  var D = { view: 'tree', tree: {}, treeBusy: {}, pick: null };

  function lc(p) { return String(p || '').replace(/\\+$/, '').toLowerCase(); }
  function candsIn(path) {
    var p = lc(path); if (!p || !S.cands) return [];
    return S.cands.items.filter(function (i) { if (!i.path || i.action === 'report' || i.kind === 'process') return false; var q = lc(i.path); return q === p || q.indexOf(p + '\\') === 0; });
  }
  function overlay(n) {
    if (!n || n.own) return n && n.zone === 'fixed' ? 'fixed' : null;   // ô "file ngay trong thư mục": không thừa hưởng lớp phủ của thư mục con
    if (n.rest || !n.path) return n && n.zone === 'fixed' ? 'fixed' : null;
    var c = candsIn(n.path).filter(function (i) { return i.sizeBytes > 0; });
    if (c.some(function (i) { return S.selected[i.key]; })) return 'sel';
    if (RG.isPathProtected(n.path) && n.path.length > 3) return 'prot';
    if (c.length) return 'cand';
    return n.zone === 'fixed' ? 'fixed' : null;
  }

  function tabs() {
    var dl = RG.driveList(); if (dl.length < 2) return '';
    return '<div class="seg" role="tablist" aria-label="Chọn ổ đĩa" style="margin-bottom:12px;flex-wrap:wrap">' + dl.map(function (x) {
      var st = x.state || 'Normal';
      return '<button role="tab" data-drive="' + esc(x.drive) + '" aria-pressed="' + (x.drive === S.driveSel) + '" title="' + esc(x.label || '') + '">' + esc(x.drive) + ': <span class="num">' + RG.fmtGB(x.freeGB) + '</span>' + (st !== 'Normal' ? ' <span class="pill ' + (st === 'Critical' ? 'ask' : '') + '">' + esc(RG.human.state(st)) + '</span>' : '') + '</button>';
    }).join('') + '</div>';
  }
  // Thanh tóm tắt MỘT dòng theo nhóm (stacked) + chú giải bấm được. cats: [{cat,bytes,carried,scannedUtc}]
  function summaryBar(d, cats, total, live) {
    var parts = cats.map(function (c) { return { cat: c.cat, bytes: c.bytes, c: c }; });
    if (!live && d.unscannedBytes > 0) parts.push({ cat: '__unscanned', bytes: d.unscannedBytes });
    var free = d.freeBytes != null ? d.freeBytes : 0; parts.push({ cat: '__free', bytes: free });
    var seg = parts.map(function (x) {
      var w = Math.max(0, x.bytes / Math.max(1, total) * 100), col = x.cat === '__free' ? 'var(--free)' : (x.cat === '__unscanned' ? 'var(--mut)' : V.catColor(x.cat)), nm = x.cat === '__free' ? 'Dung lượng trống' : (x.cat === '__unscanned' ? 'Hệ thống & chương trình (chưa quét chi tiết)' : (LABEL[x.cat] || x.cat));
      return '<i class="sb-seg' + (x.cat === '__unscanned' ? ' hatch' : '') + '" style="width:' + w.toFixed(2) + '%;background:' + col + '" title="' + esc(nm + ': ' + RG.fmtBytes(x.bytes)) + '"></i>';
    }).join('');
    var legend = parts.filter(function (x) { return x.bytes > total * 0.004; }).map(function (x) {
      var nm = x.cat === '__free' ? 'Dung lượng trống' : (x.cat === '__unscanned' ? 'Hệ thống & chương trình (chưa quét chi tiết)' : (LABEL[x.cat] || x.cat)), col = x.cat === '__free' ? 'var(--free)' : (x.cat === '__unscanned' ? 'var(--mut)' : V.catColor(x.cat));
      var note = x.c && x.c.carried ? ' <span class="small mut" title="Vùng cố định không quét lại ở “Quét nhanh”">số liệu từ lượt quét đầy đủ ' + esc(RG.fmtLocal(x.c.scannedUtc)) + '</span>' : '';
      return '<span class="sb-lg"><span class="sw' + (x.cat === '__unscanned' ? ' hatch' : '') + '" style="' + (x.cat === '__unscanned' ? '' : 'background:' + col) + '"></span>' + esc(nm) + ' <b class="num">' + RG.fmtBytes(x.bytes) + '</b>' + note + '</span>';
    }).join('');
    return '<div class="sb" role="img" aria-label="Phân bố dung lượng ổ ' + esc(d.drive) + ' theo nhóm">' + seg + '</div><div class="sb-legend">' + legend + '</div>';
  }

  function loadTree(L, force) {
    if (!L || D.treeBusy[L]) return;
    if (D.tree[L] && !force) return;
    D.treeBusy[L] = true;
    RG.api('/api/disk/tree?drive=' + encodeURIComponent(L)).then(function (j) { D.tree[L] = j; }).catch(function () { D.tree[L] = { none: true }; }).then(function () { D.treeBusy[L] = false; if (RG.cur === 'disk') draw(); });
  }

  function itemRow(it, catBytes, col) {
    var key = String(it.key), age = RG.daysSince(it.newestUtc), isPath = /^[A-Za-z]:\\/.test(key), prot = isPath && RG.isPathProtected(key);
    return '<tr class="row"><td><span class="ellipsis mono" title="' + esc(key) + '">' + esc(key) + '</span> <span class="pill">' + esc(LABEL[it.cat] || it.cat) + '</span>' +
      '<div class="minibar"><i style="width:' + Math.min(100, it.bytes / Math.max(1, catBytes) * 100).toFixed(1) + '%;background:' + col + '"></i></div></td>' +
      '<td class="r num">' + RG.fmtBytes(it.bytes) + '</td><td class="r num mut">' + (it.bytes / Math.max(1, catBytes) * 100).toFixed(1).replace('.', ',') + '%</td><td class="r num mut" title="Lần ghi gần nhất trong thư mục này">' + (age == null ? '–' : RG.fmtAge(age)) + '</td>' +
      '<td class="r">' + (isPath ? '<button class="icon-btn ' + (prot ? 'on' : '') + '" data-path="' + esc(key) + '" aria-pressed="' + prot + '" aria-label="' + (prot ? 'Bỏ bảo vệ' : 'Bảo vệ') + ' ' + esc(key) + '" title="' + (prot ? 'Đang được bảo vệ khỏi tự dọn' : 'Bảo vệ khỏi tự dọn') + '">' + RG.icon('shield') + '</button>' : '') + '</td></tr>';
  }
  function flatDetail(d) {
    var all = [], col = {};
    d.categories.forEach(function (c) { col[c.cat] = V.catColor(c.cat); c.items.forEach(function (it) { all.push({ key: it.key, bytes: it.bytes, newestUtc: it.newestUtc, cat: c.cat }); }); });
    all.sort(function (a, b) { return b.bytes - a.bytes; });
    return '<div class="tbl-wrap" style="max-height:520px"><table><thead><tr><th>Thư mục / nhân tố</th><th class="r">Dung lượng</th><th class="r">Tỷ lệ</th><th class="r">Không ghi</th><th class="r">Bảo vệ</th></tr></thead><tbody>' +
      all.slice(0, 80).map(function (it) { return itemRow(it, d.usedBytes, col[it.cat]); }).join('') + '</tbody></table></div>' +
      d.categories.filter(function (c) { return NOTE[c.cat]; }).map(function (c) { return '<p class="hint"><b>' + esc(LABEL[c.cat] || c.cat) + ':</b> ' + esc(NOTE[c.cat]) + '</p>'; }).join('');
  }

  function openNode(n, parent) {
    if (!n) return;
    D.pick = n.path;
    var d = S.disk, used = (d && d.usedBytes) || 1, cs = (n.rest || n.own) ? [] : candsIn(n.path), cb = cs.reduce(function (a, i) { return a + (i.sizeBytes || 0); }, 0), prot = !n.rest && n.path && n.path.length > 3 && RG.isPathProtected(n.path);
    var nsel = cs.filter(function (i) { return S.selected[i.key]; }).length;
    var html = '<dl class="rc"><dt>Đường dẫn</dt><dd><span class="mono" style="word-break:break-all">' + esc(n.rest ? (parent ? parent.path : '') + ' (các mục nhỏ gộp lại)' : n.path) + '</span></dd>' +
      '<dt>Dung lượng</dt><dd><b>' + RG.fmtBytes(n.bytes) + '</b> · ' + (n.bytes / used * 100).toFixed(1).replace('.', ',') + '% dung lượng đã dùng' + (n.files ? ' · ' + n.files.toLocaleString('vi-VN') + ' file' : '') + '</dd>' +
      '<dt>Ghi lần cuối</dt><dd>' + (n.newestUtc ? esc(RG.fmtLocal(n.newestUtc)) + ' (' + RG.timeAgo(n.newestUtc) + ')' : '–') + '</dd>' +
      '<dt>Thuộc nhóm</dt><dd>' + esc(LABEL[n.cat] || n.cat || '–') + (n.zone === 'fixed' ? ' <span class="pill">vùng cố định, không dọn được</span>' : '') + '</dd>' +
      '<dt>Dọn được</dt><dd>' + (cs.length ? '<b>' + cs.length + ' mục</b> dọn được ở đây (' + RG.fmtBytes(cb) + ')' + (nsel ? ' · đã chọn ' + nsel : '') : 'Không có mục nào dọn được ở đây.') + (prot ? ' <span class="pill keep">đang được bảo vệ</span>' : '') + '</dd></dl>' +
      (n.zone === 'fixed' ? '<p class="hint">Vùng hệ thống & chương trình: Resource Guard chỉ cho bạn xem, không bao giờ dọn. Gỡ chương trình ở Cài đặt > Ứng dụng của Windows.</p>' : '') + (NOTE[n.cat] ? '<p class="hint">' + esc(NOTE[n.cat]) + '</p>' : '');
    var acts = [];
    if (cs.length) acts.push({ label: nsel === cs.length ? 'Bỏ chọn các mục này' : 'Chọn ' + cs.length + ' mục để dọn (' + RG.fmtBytes(cb) + ')', cls: 'primary', onClick: function () { var off = nsel === cs.length; cs.forEach(function (i) { if (i.protected) return; if (off) delete S.selected[i.key]; else S.selected[i.key] = true; }); RG.toast(off ? 'Đã bỏ chọn.' : 'Đã chọn ' + cs.filter(function (i) { return !i.protected; }).length + ' mục. Sang trang Dọn dẹp để xem và xác nhận.', 'ok'); draw(); } });
    if (!n.rest && n.path && n.path.length > 3 && n.zone !== 'fixed') acts.push({ label: prot ? 'Bỏ bảo vệ thư mục này' : 'Bảo vệ thư mục này', onClick: function () { RG.toggleProtect('path', n.path, !prot).then(function () { RG.loadCands().then(draw); }); } });
    acts.push({ label: 'Đóng' });
    RG.drawer({ title: n.name || n.path, html: html, actions: acts, onClose: function () { D.pick = null; } });
  }

  function draw() {
    var el = $('#diskBody'); if (!el) return;
    var sel = S.driveSel, d = S.disk && (!sel || S.disk.drive === sel) ? S.disk : null;
    var j = S.jobs.breakdown, running = j && j.status === 'running', mine = running && (!j.drive || j.drive === sel);
    var nsel = Object.keys(S.selected).length;
    var head = tabs() + '<div class="field" style="margin-top:0"><button class="btn primary" id="scanFast"' + (running ? ' disabled' : '') + ' title="Bỏ qua vùng hệ thống & chương trình (không dọn được), lấy số từ lượt quét đầy đủ gần nhất">' + RG.icon('refresh') + ' Quét nhanh</button>' +
      '<button class="btn" id="scanFull"' + (running ? ' disabled' : '') + ' title="Quét toàn bộ ổ, kể cả vùng hệ thống">Quét đầy đủ</button>';
    if (running && !mine) head += '<span class="spin"></span><span class="small mut">Đang quét ổ ' + esc(j.drive) + ': (' + (j.pct || 0) + '%). Mỗi lần chỉ quét một ổ.</span>';
    else if (running) head += '<span class="spin"></span><div class="progress" style="flex:1;max-width:320px"><i style="width:' + (j.pct || 0) + '%"></i></div><span class="small mut num">' + (j.pct || 0) + '% · ' + RG.fmtBytes(j.bytes) + ' · ' + (j.files || 0).toLocaleString('vi-VN') + ' file · ' + (j.scope === 'full' ? 'đầy đủ' : 'nhanh') + '</span>';
    else if (d) head += '<span class="small mut">Quét ' + (d.scope === 'focus' ? 'nhanh' : 'đầy đủ') + ' ' + RG.timeAgo(d.finishedUtc) + ' · ' + d.seconds + ' giây · ' + d.files.toLocaleString('vi-VN') + ' file</span>';
    if (nsel) head += '<span class="sp"></span><button class="btn sm" data-go="clean">Đã chọn ' + nsel + ' mục → Dọn dẹp</button>';
    if (j && j.status === 'error' && (!j.drive || j.drive === sel)) head += '<span class="small warn">Lỗi: ' + esc(j.message) + '</span>';
    head += '</div>';
    var di = RG.driveInfo(sel || (d && d.drive));
    // Đang quét: vẽ dần từ cats của tiến độ.
    if (mine && j.cats && j.cats.length && (!d || d.scope !== 'x')) {
      var dd = di || { drive: sel, freeBytes: 0 };
      var total = di ? (di.totalBytes || (di.totalGB ? di.totalGB * GB : 0)) : Math.max(1, j.bytes);
      var free = di ? di.freeGB * GB : 0;
      el.innerHTML = head + '<div class="card"><h2>Đang quét ổ ' + esc(sel) + ': kết quả tạm</h2>' + summaryBar({ drive: sel, freeBytes: free, unscannedBytes: 0 }, j.cats.slice().sort(function (a, b) { return b.bytes - a.bytes; }), total, true) +
        '<p class="hint">Số liệu cập nhật khoảng mỗi giây. Treemap sẽ hiện khi quét xong.</p></div>';
      bindHead(sel); return;
    }
    if (!d) {
      el.innerHTML = head + '<div class="card empty">' + RG.icon('disk') + '<h3>Chưa có dữ liệu phân tích ổ ' + (sel ? esc(sel) + ':' : 'đĩa') + '</h3><div>Quét chạy ở tiến trình riêng nên không làm treo giao diện. Chỉ đọc, không xoá gì. “Quét nhanh” bỏ qua vùng hệ thống nên nhanh hơn nhiều.</div></div>';
      bindHead(sel); return;
    }
    var pctUsed = d.usedBytes / d.totalBytes * 100;
    var h = head + (di && di.state && di.state !== 'Normal' ? '<div class="alert warn" style="margin-bottom:14px"><div><b>Ổ ' + esc(d.drive) + ': còn trống ' + RG.fmtGB(di.freeGB) + ' (' + (100 - pctUsed).toFixed(1).replace('.', ',') + '%).</b> Bấm vào ô lớn nhất bên dưới để xem chi tiết, hoặc sang trang <a href="#clean" data-go="clean">Dọn dẹp</a>.</div></div>' : '');
    h += '<div class="card"><h2>Ổ ' + esc(d.drive) + ': phân bố theo nhóm<span class="ro">' + RG.fmtBytes(d.usedBytes) + ' đã dùng / ' + RG.fmtBytes(d.totalBytes) + '</span></h2>' + summaryBar(d, d.categories, d.totalBytes, false) +
      (d.unscannedBytes > d.totalBytes * 0.02 && d.scope === 'full' ? '<p class="hint">' + RG.fmtBytes(d.unscannedBytes) + ' không đọc được (file hệ thống đang khoá, quyền truy cập, hoặc dữ liệu OneDrive chưa tải về).</p>' : '') + '</div>';
    h += '<div class="card mt"><h2>Chi tiết theo thư mục<span class="sp"></span><span class="seg sm" role="group" aria-label="Kiểu xem"><button id="vTree" aria-pressed="' + (D.view === 'tree') + '">Treemap</button><button id="vFlat" aria-pressed="' + (D.view === 'flat') + '">Top lớn nhất</button></span></h2>';
    if (D.view === 'flat') h += flatDetail(d);
    else {
      h += '<div class="tm-legend small"><span><i class="lg-sw cand"></i>Có mục dọn được</span><span><i class="lg-sw sel"></i>Đang chọn để dọn</span><span><i class="lg-sw prot"></i>Được bảo vệ</span><span><i class="lg-sw fixed"></i>Vùng cố định (không dọn được)</span><span class="mut">Bấm = xem chi tiết · bấm đúp hoặc Enter = đào sâu · Esc = lùi</span></div><div id="tmBox"></div>';
    }
    h += '</div>';
    el.innerHTML = h; bindHead(sel);
    var vt = $('#vTree'), vf = $('#vFlat'); if (vt) { vt.onclick = function () { D.view = 'tree'; draw(); }; vf.onclick = function () { D.view = 'flat'; draw(); }; }
    RG.$$('#diskBody [data-path]').forEach(function (b) { b.onclick = function () { RG.toggleProtect('path', b.dataset.path, b.getAttribute('aria-pressed') !== 'true'); }; });
    if (D.view === 'tree') {
      var t = D.tree[d.drive], box = $('#tmBox');
      if (!t) { box.innerHTML = '<div class="mut" style="padding:20px"><span class="spin"></span> Đang tải cây thư mục…</div>'; loadTree(d.drive); }
      else if (t.none || !t.root) box.innerHTML = '<div class="mut" style="padding:20px">Chưa có cây thư mục cho ổ này. Bấm “Quét nhanh” hoặc “Quét đầy đủ”.</div>';
      else V.treemap(box, t.root, { overlay: overlay, onPick: openNode, maxTiles: 60, height: 400 });
    }
  }
  function bindHead(sel) {
    RG.$$('#diskBody [data-go]').forEach(function (a) { a.onclick = function (e) { e.preventDefault(); RG.go(a.dataset.go); }; });
    var go = function (scope) { RG.startJob('/api/disk/scan', sel ? { drive: sel, scope: scope } : { scope: scope }, 'Bắt đầu quét ' + (scope === 'full' ? 'đầy đủ' : 'nhanh') + ' ổ ' + (sel ? sel + ':' : 'đĩa') + '…').then(function () { if (S.jobs.breakdown) S.jobs.breakdown.drive = sel; }).catch(function () { }); };
    var f = $('#scanFast'); if (f) f.onclick = function () { go('focus'); };
    var u = $('#scanFull'); if (u) u.onclick = function () { go('full'); };
    RG.$$('#diskBody [data-drive]').forEach(function (b) {
      b.onclick = function () { if (b.dataset.drive === S.driveSel) return; S.driveSel = b.dataset.drive; S.disk = null; draw(); RG.loadDisk(b.dataset.drive).then(draw).catch(function () { }); loadTree(b.dataset.drive); };
    });
  }

  RG.pages.disk = {
    title: 'Ổ đĩa',
    render: function (el) { el.innerHTML = '<div id="diskBody"></div>'; draw(); this.refresh(); },
    refresh: function () { Promise.all([RG.loadDisk(S.driveSel), RG.loadCands().catch(function () { }), RG.loadPolicy().catch(function () { })]).then(function () { D.tree = {}; draw(); }).catch(function () { }); },
    jobs: function () { if (RG.cur === 'disk') draw(); },
    live: function () { }
  };
})();
