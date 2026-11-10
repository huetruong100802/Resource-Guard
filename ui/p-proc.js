/* p-proc.js - Tiến trình: ai đang chiếm RAM/CPU, dòng thời gian, "nếu đóng ứng dụng này", hạ ưu tiên (đảo ngược được). Không có nút kill. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, GB = 1073741824, MB = 1048576;
  var P = { rows: [], sort: { k: 'ramMB', dir: -1 }, filter: '', group: true, busy: false, logical: 1, sel: null, minutes: 60, pickName: null };
  var COLORS = ['#4e79d6', '#e0803b', '#2fa37a', '#c8527a', '#8a6fd1', '#c9a227', '#2fa3b8'];

  function heat(v, max) { var a = Math.min(60, Math.round(Math.min(1, v / max) * 70)); return 'background:color-mix(in srgb,var(--cpu) ' + a + '%,transparent)'; }
  function groupRows(rows) {
    var m = {};
    rows.forEach(function (r) {
      var g = m[r.name] || (m[r.name] = { name: r.name, pid: 0, n: 0, cpu: 0, ramMB: 0, group: r.group, agent: false, protected: r.protected, lowered: false });
      g.n++; g.cpu += r.cpu; g.ramMB += r.ramMB; g.agent = g.agent || r.agent; g.lowered = g.lowered || r.lowered; g.pid = g.n === 1 ? r.pid : 0;
    });
    return Object.keys(m).map(function (k) { m[k].cpu = Math.round(m[k].cpu * 10) / 10; return m[k]; });
  }
  function totalRamMB() { return (S.live && S.live.totalRamGB ? S.live.totalRamGB * 1024 : 0); }
  function ramBar(gainMB) {
    var l = S.live; if (!l) return;
    var t = S.thr && S.thr.ramAvailGB;
    V.impactBar($('#pRamBar'), { totalBytes: l.totalRamGB * GB, freeBytes: l.availRamGB * GB, gainBytes: (gainMB || 0) * MB, label: 'RAM',
      cautionBytes: t ? t.cautionFrom * GB : null, normalBytes: t ? t.normalAbove * GB : null, stateFn: function (b) { return RG.ramState(b / GB); } });
  }

  /* ----- Bảng ----- */
  function drawBody() {
    var tb = $('#procBody'); if (!tb) return;
    var rows = P.group ? groupRows(P.rows) : P.rows.slice(), f = P.filter.trim().toLowerCase(), tot = totalRamMB();
    if (f) rows = rows.filter(function (r) { return r.name.indexOf(f) >= 0 || String(r.pid) === f || (r.group || '').indexOf(f) >= 0; });
    var k = P.sort.k, d = P.sort.dir;
    rows.sort(function (a, b) { var x = a[k], y = b[k]; if (typeof x === 'string') return x.localeCompare(y) * d; return ((x || 0) - (y || 0)) * d; });
    var maxRam = Math.max.apply(null, rows.map(function (r) { return r.ramMB; }).concat([1]));
    tb.innerHTML = rows.slice(0, 300).map(function (r, i) {
      var pct = tot ? r.ramMB / tot * 100 : 0;
      return '<tr class="row clk" tabindex="0" data-name="' + esc(r.name) + '"><td><b>' + esc(r.name) + '</b>' + (P.group && r.n > 1 ? ' <span class="mut small">(' + r.n + ')</span>' : '') + (r.agent ? ' <span class="pill keep">agent</span>' : '') + (r.lowered ? ' <span class="pill ask" title="Resource Guard đã hạ ưu tiên CPU">đang hạ ưu tiên</span>' : '') + '</td>' +
        '<td class="num mut">' + (P.group && r.n > 1 ? '–' : r.pid) + '</td><td class="r"><span class="heat num" style="' + heat(r.cpu, 40) + '">' + r.cpu.toFixed(1) + '%</span></td>' +
        '<td class="r"><span class="heat num" style="' + heat(r.ramMB, maxRam).replace('var(--cpu)', 'var(--disk)') + '">' + RG.fmtBytes(r.ramMB * MB) + '</span></td>' +
        '<td class="pcell"><span class="num small">' + pct.toFixed(1).replace('.', ',') + '%</span><span class="minibar"><i style="width:' + Math.min(100, pct * 2).toFixed(1) + '%;background:var(--disk)"></i></span></td>' +
        '<td><span class="pill">' + esc(r.group) + '</span></td>' +
        '<td class="r"><button class="icon-btn ' + (r.protected ? 'on' : '') + '" data-prot="' + esc(r.name) + '" aria-pressed="' + !!r.protected + '" aria-label="' + (r.protected ? 'Bỏ bảo vệ ' : 'Bảo vệ ') + esc(r.name) + ' khỏi tự dọn" title="' + (r.protected ? 'Đang được bảo vệ khỏi tự dọn' : 'Bảo vệ khỏi tự dọn') + '">' + RG.icon('shield') + '</button></td></tr>';
    }).join('') || '<tr><td colspan="7" class="mut" style="text-align:center;padding:20px">Không có kết quả.</td></tr>';
    $('#procCount').textContent = rows.length + ' / ' + (P.group ? groupRows(P.rows).length : P.rows.length);
    RG.$$('#procBody [data-prot]').forEach(function (b) { b.onclick = function (e) { e.stopPropagation(); RG.toggleProtect('process', b.dataset.prot, b.getAttribute('aria-pressed') !== 'true'); }; });
    RG.$$('#procBody tr.clk').forEach(function (tr) { var go = function () { openProc(tr.dataset.name); }; tr.onclick = go; tr.onkeydown = function (e) { if (e.key === 'Enter') { e.preventDefault(); go(); } }; });
    RG.$$('#procHead th.sort').forEach(function (th) { th.setAttribute('aria-sort', th.dataset.k === k ? (d < 0 ? 'descending' : 'ascending') : 'none'); th.querySelector('i').textContent = th.dataset.k === k ? (d < 0 ? ' ▼' : ' ▲') : ''; });
  }
  function fetchProcs() {
    if (P.busy) return; P.busy = true;
    RG.api('/api/processes').then(function (j) { P.rows = j.procs; P.logical = j.logical; drawBody(); if (P.sel) refreshDrawerMembers(); }).catch(function () { }).then(function () { P.busy = false; });
  }

  /* ----- Miền xếp chồng RAM theo nhóm tiến trình ----- */
  function drawStack() {
    var svg = $('#pStack'); if (!svg) return;
    var hist = S.hist.slice(-150).filter(function (h) { return h.procTop && h.procTop.length; }), tot = totalRamMB();
    if (hist.length < 2) { svg.innerHTML = '<text x="38" y="80">Đang thu thập dữ liệu theo tiến trình…</text>'; $('#pLegend').innerHTML = ''; return; }
    var agg = {}; hist.forEach(function (h) { h.procTop.forEach(function (p) { agg[p.name] = (agg[p.name] || 0) + p.ramMB; }); });
    var names = Object.keys(agg).sort(function (a, b) { return agg[b] - agg[a]; }).slice(0, 6), series = names.map(function (n, i) { return { name: n, color: COLORS[i], points: [] }; }), other = { name: 'Khác', color: '#9aa4b5', points: [] };
    hist.forEach(function (h) {
      var used = Math.max(0, (h.totalRamGB - h.availRamGB) * 1024), sum = 0;
      names.forEach(function (n, i) { var p = h.procTop.filter(function (x) { return x.name === n; })[0], v = p ? p.ramMB : 0; sum += v; series[i].points.push({ t: h.ts, v: v }); });
      other.points.push({ t: h.ts, v: Math.max(0, used - sum) });
    });
    series.push(other);
    V.stackArea(svg, { series: series, max: tot || undefined, unit: ' MB', yfmt: function (v) { return Math.round(v / 102.4) / 10 + 'G'; }, xfmt: function (t) { return String(t).slice(11, 16); }, onPick: function (n) { if (n !== 'Khác') openProc(n); } });
    $('#pLegend').innerHTML = series.map(function (s) { return '<button class="lg" data-n="' + esc(s.name) + '"' + (s.name === 'Khác' ? ' disabled' : '') + '><span class="sw" style="background:' + s.color + '"></span>' + esc(s.name) + '</button>'; }).join('');
    RG.$$('#pLegend .lg').forEach(function (b) { b.onclick = function () { openProc(b.dataset.n); }; });
  }
  function drawCpu() {
    var markers = (S.events || []).filter(function (e) { return e.event === 'proc-priority'; }).map(function (e) { return { ts: e.ts, type: e.event, label: RG.human.event(e), e: e }; });
    RG.lineChart($('#cpuBig'), S.hist, { key: 'cpuPct', color: RG.css('--cpu'), min: 0, max: 100, area: true, readout: 'roCpu2', unit: '%', n: 120, markers: markers, onMarker: function (m) { RG.eventDrawer(m.e); } });
  }

  /* ----- Ngăn kéo một tiến trình ----- */
  function members(name) { return P.rows.filter(function (r) { return r.name === name; }); }
  function memberRows(name) {
    var ms = members(name).sort(function (a, b) { return b.ramMB - a.ramMB; });
    return ms.slice(0, 12).map(function (m) {
      var act = m.lowered ? '<button class="btn sm" data-lv="normal" data-pid="' + m.pid + '" data-start="' + esc(m.start) + '">Trả về bình thường</button>' :
        (m.canLower ? '<button class="btn sm" data-lv="below" data-pid="' + m.pid + '" data-start="' + esc(m.start) + '">Hạ ưu tiên</button>' : '<span class="small mut" title="' + esc(m.whyNot) + '">' + RG.icon('info') + ' ' + esc(m.whyNot || 'Không hạ được') + '</span>');
      return '<tr><td class="num">' + m.pid + '</td><td class="r num">' + m.cpu.toFixed(1) + '%</td><td class="r num">' + RG.fmtBytes(m.ramMB * MB) + '</td><td>' + (m.lowered ? '<span class="pill ask">đang hạ</span> ' : '') + act + '</td></tr>';
    }).join('') + (ms.length > 12 ? '<tr><td colspan="4" class="small mut">… và ' + (ms.length - 12) + ' tiến trình khác cùng tên</td></tr>' : '');
  }
  function drawerHtml(name) {
    var ms = members(name), ram = ms.reduce(function (a, m) { return a + m.ramMB; }, 0), cpu = ms.reduce(function (a, m) { return a + m.cpu; }, 0), prot = ms.length && ms[0].protected, ledger = ms.some(function (m) { return m.agent; });
    return '<div class="small mut" style="margin-bottom:6px">' + ms.length + ' tiến trình · CPU ' + cpu.toFixed(1).replace('.', ',') + '% · ' + RG.fmtBytes(ram * MB) + ' (' + (totalRamMB() ? (ram / totalRamMB() * 100).toFixed(1).replace('.', ',') : '–') + '% RAM máy)</div>' +
      '<h4 class="dh">Dòng thời gian <span class="seg sm" role="group" aria-label="Khoảng thời gian">' + [[60, '1 giờ'], [360, '6 giờ'], [1440, '24 giờ']].map(function (x) { return '<button data-min="' + x[0] + '" aria-pressed="' + (P.minutes === x[0]) + '">' + x[1] + '</button>'; }).join('') + '</span></h4>' +
      '<div class="small mut">CPU (%)</div><svg id="dCpu" class="chart" style="height:80px" role="img" aria-label="CPU của ' + esc(name) + ' theo thời gian"></svg><div class="small mut">RAM (MB)</div><svg id="dRam" class="chart" style="height:80px" role="img" aria-label="RAM của ' + esc(name) + ' theo thời gian"></svg><div class="small mut" id="dNote"></div>' +
      '<h4 class="dh">Nếu đóng ứng dụng này</h4><div id="dWhat"></div><p class="hint">Ước tính theo bộ nhớ đang dùng (working set); số thực tế có thể khác. Resource Guard không tự đóng ứng dụng này' + (ledger ? ' (chỉ tiến trình agent đã đăng ký và mất chủ mới có thể bị dọn, qua trang Dọn dẹp)' : '') + ': muốn giải phóng RAM, hãy tự đóng ứng dụng sau khi lưu việc đang làm.</p>' +
      '<h4 class="dh">Ưu tiên CPU</h4><table class="small"><thead><tr><th>PID</th><th class="r">CPU</th><th class="r">RAM</th><th></th></tr></thead><tbody id="dMem">' + memberRows(name) + '</tbody></table>' +
      '<p class="hint">Hạ ưu tiên: nhường CPU cho việc khác; <b>không giải phóng RAM</b>. Hoàn tác bất cứ lúc nào bằng “Trả về bình thường”.</p>' +
      '<div class="field"><button class="btn sm' + (prot ? ' primary' : '') + '" id="dProt" aria-pressed="' + !!prot + '">' + RG.icon('shield') + (prot ? ' Đang bảo vệ khỏi tự dọn (bấm để bỏ)' : ' Bảo vệ khỏi tự dọn') + '</button></div>';
  }
  function bindDrawer(name) {
    RG.$$('.drawer [data-min]').forEach(function (b) { b.onclick = function () { P.minutes = +b.dataset.min; RG.$$('.drawer [data-min]').forEach(function (x) { x.setAttribute('aria-pressed', x === b); }); loadHistory(name); }; });
    var pr = $('#dProt'); if (pr) pr.onclick = function () { RG.toggleProtect('process', name, pr.getAttribute('aria-pressed') !== 'true').then(function () { fetchProcs(); setTimeout(function () { if (P.sel === name) reopen(name); }, 400); }); };
    bindMembers(name);
  }
  function bindMembers(name) {
    RG.$$('.drawer [data-lv]').forEach(function (b) {
      b.onclick = function () {
        b.disabled = true;
        RG.api('/api/process/priority', { method: 'POST', body: { pid: +b.dataset.pid, start: b.dataset.start, level: b.dataset.lv } }).then(function (j) {
          RG.toast((b.dataset.lv === 'below' ? 'Đã hạ ưu tiên ' : 'Đã trả ưu tiên bình thường cho ') + (j.name || name) + ' (PID ' + b.dataset.pid + ').', 'ok');
          RG.loadEvents().catch(function () { }).then(function () { drawCpu(); });
          fetchProcs();
        }).catch(function (e) { RG.toast(e.message, 'err', 8000); b.disabled = false; });
      };
    });
  }
  function refreshDrawerMembers() {
    var m = $('#dMem'); if (!m || !P.sel) return; m.innerHTML = memberRows(P.sel); bindMembers(P.sel);
    var ram = members(P.sel).reduce(function (a, x) { return a + x.ramMB; }, 0); ramBar(ram); drawWhat(ram);
  }
  function drawWhat(ram) {
    var l = S.live, el = $('#dWhat'); if (!el || !l) return;
    V.impactBar(el, { totalBytes: l.totalRamGB * GB, freeBytes: l.availRamGB * GB, gainBytes: ram * MB, label: 'RAM', stateFn: function (b) { return RG.ramState(b / GB); } });
  }
  function loadHistory(name) {
    RG.api('/api/process/history?name=' + encodeURIComponent(name) + '&min=' + P.minutes).then(function (j) {
      if (P.sel !== name) return;
      var pts = j.points || [];
      RG.lineChart($('#dCpu'), pts, { key: 'cpu', color: RG.css('--cpu'), min: 0, area: true, unit: '%', xfmt: function (t) { return String(t).slice(11, 16); } });
      RG.lineChart($('#dRam'), pts, { key: 'ramMB', color: RG.css('--disk'), min: 0, area: true, unit: ' MB', xfmt: function (t) { return String(t).slice(11, 16); } });
      var n = $('#dNote'); if (n) n.textContent = pts.length < 2 ? 'Chưa đủ dữ liệu: ứng dụng này chưa nằm trong nhóm chiếm nhiều nhất đủ lâu.' : (pts.length < P.minutes / 20 ? 'Dữ liệu thưa: chỉ có ' + pts.length + ' điểm vì ứng dụng không phải lúc nào cũng nằm trong nhóm chiếm nhiều nhất.' : '');
    }).catch(function () { });
  }
  function reopen(name) { openProc(name); }
  function openProc(name) {
    var ms = members(name); if (!ms.length) { RG.toast('Tiến trình “' + name + '” không còn chạy.', 'err'); return; }
    var dr = RG.drawer({ title: name, html: drawerHtml(name), actions: [{ label: 'Đóng' }], onClose: function () { if (P.sel === name) { P.sel = null; ramBar(0); } } });
    P.sel = name;
    var ram = ms.reduce(function (a, m) { return a + m.ramMB; }, 0);
    bindDrawer(name); loadHistory(name); ramBar(ram); drawWhat(ram);
    return dr;
  }

  RG.pages.cpu = {
    title: 'Tiến trình',
    render: function (el) {
      el.innerHTML = '<div class="card"><h2>Ai đang chiếm RAM<span class="ro">bấm một dải để xem chi tiết</span></h2><div id="pRamBar"></div>' +
        '<svg id="pStack" class="chart tall" role="img" aria-label="RAM theo nhóm tiến trình theo thời gian" style="margin-top:8px"></svg><div class="p-legend" id="pLegend"></div></div>' +
        '<div class="cpu-head mt"><div class="card"><h2>Mức sử dụng CPU<span class="ro" id="roCpu2"></span></h2><svg id="cpuBig" class="chart" role="img" aria-label="Biểu đồ CPU tổng"></svg>' +
        '<div class="small mut">% sử dụng theo thời gian · chấm tròn = lần Resource Guard hạ/trả ưu tiên một tiến trình</div></div>' +
        '<div class="card"><h2>Thông tin</h2><dl class="kv" id="cpuInfo"></dl></div></div>' +
        '<details class="card mt"><summary class="h-sum">Từng nhân logic</summary><div class="cores" id="coreGrid" style="margin-top:8px"></div></details>' +
        '<div class="card mt"><h2>Tiến trình <span class="pill" id="procCount">–</span><span class="sp"></span>' +
        '<input id="procFilter" type="text" placeholder="Lọc theo tên / PID / nhóm" aria-label="Lọc tiến trình" style="width:220px">' +
        '<span class="seg sm" role="group" aria-label="Kiểu hiển thị"><button id="gName" aria-pressed="true">Gộp theo tên</button><button id="gPid" aria-pressed="false">Từng PID</button></span></h2>' +
        '<div class="tbl-wrap"><table><thead><tr id="procHead">' +
        '<th class="sort" data-k="name">Tên<i></i></th><th class="sort" data-k="pid">PID<i></i></th><th class="sort r" data-k="cpu">CPU<i></i></th><th class="sort r" data-k="ramMB">Bộ nhớ<i></i></th><th class="sort" data-k="ramMB">% RAM máy<i></i></th><th class="sort" data-k="group">Nhóm<i></i></th><th class="r">Bảo vệ</th>' +
        '</tr></thead><tbody id="procBody"><tr><td colspan="7" class="mut">Đang tải…</td></tr></tbody></table></div>' +
        '<p class="hint">Bấm một dòng để xem dòng thời gian và tác động nếu đóng ứng dụng. Resource Guard chỉ liệt kê và có thể <b>hạ ưu tiên CPU</b> (đảo ngược được); bảng này không có nút kết thúc tiến trình.</p></div>';
      $('#procFilter').value = P.filter;
      $('#procFilter').oninput = function () { P.filter = this.value; drawBody(); };
      $('#gName').onclick = function () { P.group = true; $('#gName').setAttribute('aria-pressed', 'true'); $('#gPid').setAttribute('aria-pressed', 'false'); drawBody(); };
      $('#gPid').onclick = function () { P.group = false; $('#gPid').setAttribute('aria-pressed', 'true'); $('#gName').setAttribute('aria-pressed', 'false'); drawBody(); };
      RG.$$('#procHead th.sort').forEach(function (th) { th.onclick = function () { var k = th.dataset.k; P.sort = { k: k, dir: P.sort.k === k ? -P.sort.dir : (k === 'name' || k === 'group' ? 1 : -1) }; drawBody(); }; });
      RG.pages.cpu.live(); this.refresh();
    },
    refresh: function () { RG.loadEvents().catch(function () { }).then(function () { if (RG.cur === 'cpu') drawCpu(); }); fetchProcs(); },
    live: function () {
      var r = S.live; if (!r || !$('#cpuBig')) return;
      if (!P.sel) ramBar(0);
      drawStack(); drawCpu();
      var ci = r.cpuInfo || {}, cores = r.cores || [];
      $('#cpuInfo').innerHTML = '<dt>Hiện tại</dt><dd><b>' + (r.cpuPct == null ? '–' : r.cpuPct + '%') + '</b></dd><dt>Bộ xử lý</dt><dd title="' + esc(ci.name) + '">' + esc(ci.name || '–') + '</dd>' +
        '<dt>Tốc độ tối đa</dt><dd>' + (ci.mhz ? (ci.mhz / 1000).toFixed(2).replace('.', ',') + ' GHz' : '–') + '</dd><dt>Nhân vật lý</dt><dd>' + (ci.physical || '–') + '</dd><dt>Nhân logic</dt><dd>' + (ci.logical || cores.length || '–') + '</dd>' +
        '<dt>Tiến trình</dt><dd>' + (r.procCount || '–') + '</dd><dt>Thời gian chạy</dt><dd>' + RG.fmtDur(r.uptimeSec) + '</dd><dt>Tác vụ nặng</dt><dd>' + (r.heavy || 0) + '</dd>';
      var g = $('#coreGrid');
      if (cores.length) {
        if (g.children.length !== cores.length) g.innerHTML = cores.map(function (_, i) { return '<div class="core"><div class="t"><span>Nhân ' + i + '</span><b class="num" id="cv' + i + '">–</b></div><svg id="cs' + i + '" role="img" aria-label="Nhân ' + i + '"></svg></div>'; }).join('');
        cores.forEach(function (v, i) {
          $('#cv' + i).textContent = v + '%';
          RG.lineChart($('#cs' + i), S.hist, { fn: function (h) { return h.cores && h.cores[i] != null ? h.cores[i] : null; }, color: RG.css('--cpu'), min: 0, max: 100, area: true, axes: false, n: 60 });
        });
      } else g.innerHTML = '<span class="mut">Chưa có dữ liệu từng nhân (cần ít nhất hai lần lấy mẫu).</span>';
      fetchProcs();
    }
  };
})();
