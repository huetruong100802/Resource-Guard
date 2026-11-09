/* p-overview.js - Tổng quan, CPU & Tiến trình (kiểu Task Manager), Cài đặt. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;

  /* ====================== Tổng quan ====================== */
  function stat(k, v, sub, st, pct) {
    return '<div class="card stat" style="--st:' + RG.stateColor(st) + '"><div class="k">' + k + '</div><div class="v num">' + v + '</div><div class="small mut">' + sub + '</div>' +
      '<div class="bar"><i style="width:' + Math.max(0, Math.min(100, pct || 0)) + '%"></i></div></div>';
  }
  function evText(e) {
    var d = e.data || {};
    switch (e.event) {
      case 'state-change': return 'Trạng thái ' + esc(d.from) + ' → <b>' + esc(d.to) + '</b>';
      case 'would-kill-orphans': return 'Có ' + (d.items || []).length + ' tiến trình mồ côi (agent đã đăng ký)';
      case 'settings-change': return 'Đổi chu kỳ lấy mẫu: ' + esc(d.intervalSec) + 's';
      case 'watcher-start': case 'server-start': return 'Khởi động';
      case 'auto-run': return 'Tự dọn (' + esc(d.mode) + '): ' + esc(d.items) + ' mục, ' + RG.fmtBytes(d.freedBytes);
      case 'manual-cleanup': return 'Dọn thủ công: ' + esc(d.items) + ' mục, ' + RG.fmtBytes(d.freedBytes);
      case 'policy-change': return 'Đổi chính sách (chế độ ' + esc(d.mode) + ')';
      case 'agent-eval': return 'Agent đánh giá xong';
      default: return esc(e.event);
    }
  }
  var overview = RG.pages.overview = {
    title: 'Tổng quan',
    render: function (el) {
      el.innerHTML = '<div id="ovBanner"></div><div class="grid g4" id="ovStats"></div>' +
        '<div class="grid g2 mt">' +
        '<div class="card"><h2>RAM trống (GB)<span class="ro" id="roRam"></span></h2><svg id="cRam" class="chart" role="img" aria-label="Biểu đồ RAM trống"></svg></div>' +
        '<div class="card"><h2>Ổ đĩa trống (GB)<span class="ro" id="roDisk"></span></h2><svg id="cDisk" class="chart" role="img" aria-label="Biểu đồ dung lượng ổ đĩa trống"></svg></div>' +
        '<div class="card"><h2>Commit (%)<span class="ro" id="roCommit"></span></h2><svg id="cCommit" class="chart" role="img" aria-label="Biểu đồ commit"></svg></div>' +
        '<div class="card"><h2>CPU (%)<span class="ro" id="roCpu"></span></h2><svg id="cCpu" class="chart" role="img" aria-label="Biểu đồ CPU"></svg></div></div>' +
        '<div class="grid g2 mt"><div class="card"><h2>Tự dọn nền</h2><div id="ovAuto"></div></div>' +
        '<div class="card"><h2>Sự kiện gần đây</h2><div id="ovEvents" class="small"></div></div></div>';
      overview.live(); overview.refresh();
    },
    refresh: function () {
      RG.api('/api/events').then(function (ev) {
        S.events = ev; var el = $('#ovEvents'); if (!el) return;
        el.innerHTML = ev.length ? ev.slice(0, 12).map(function (e) { return '<div style="padding:3px 0"><span class="mut">' + esc((e.ts || '').replace('T', ' ').slice(5, 16)) + ' UTC</span> · ' + evText(e) + '</div>'; }).join('') : '<span class="mut">Chưa có sự kiện.</span>';
      }).catch(function () { });
      RG.loadAuto().then(drawAuto).catch(function () { });
    },
    live: function () {
      var r = S.live; if (!r || !$('#ovStats')) return;
      var ramUsed = r.totalRamGB ? (1 - r.availRamGB / r.totalRamGB) * 100 : 0;
      var dk = RG.diskState(r.diskFreeGB), rs = RG.ramState(r.availRamGB), cs = RG.commitState(r.commitPct);
      var cpuSt = r.cpuPct >= 90 ? 'Critical' : (r.cpuPct >= 75 ? 'Caution' : 'Normal');
      $('#ovStats').innerHTML =
        stat('RAM trống', r.availRamGB + ' <small>/ ' + r.totalRamGB + ' GB</small>', 'đã dùng ' + Math.round(ramUsed) + '%', rs, ramUsed) +
        stat('CPU', (r.cpuPct == null ? '–' : r.cpuPct + '<small>%</small>'), r.procCount ? r.procCount + ' tiến trình · tác vụ nặng: ' + r.heavy : '&nbsp;', cpuSt, r.cpuPct) +
        stat('Commit', r.commitPct + '<small>%</small>', 'bộ nhớ ảo đã cấp phát', cs, r.commitPct) +
        stat('Ổ ' + esc(r.diskDrive) + ': trống', r.diskFreeGB + ' <small>GB</small>', S.disk ? 'đã dùng ' + RG.fmtBytes(S.disk.usedBytes) + ' / ' + RG.fmtBytes(S.disk.totalBytes) : 'chưa quét chi tiết', dk,
          S.disk ? S.disk.usedBytes / S.disk.totalBytes * 100 : 0);
      var bad = r.state === 'Critical' || r.state === 'Restricted';
      var mode = S.policy ? S.policy.mode : 'off';
      $('#ovBanner').innerHTML = (bad || (r.reasons && r.reasons.length)) ?
        '<div class="alert ' + (bad ? 'warn' : 'info') + '" style="margin-bottom:14px"><div><b>' + esc(r.state) + '</b> — ' + (r.reasons || []).map(esc).join('; ') +
        (bad && mode === 'off' ? '<div class="small mut">Tự dọn đang <b>tắt</b>. Bạn có thể dọn tay hoặc bật chính sách tự động.</div>' : '') +
        '</div><div style="display:flex;gap:6px;flex-wrap:wrap"><button class="btn sm" data-go="disk">Xem ổ đĩa</button><button class="btn sm" data-go="clean">Dọn dẹp</button><button class="btn sm primary" data-go="agent">Nhờ agent đánh giá</button></div></div>' :
        '<div class="alert ok" style="margin-bottom:14px"><b>Bình thường</b> — mọi chỉ số trong ngưỡng.</div>';
      RG.$$('#ovBanner [data-go]').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.go); }; });
      var t = S.thr || { ramAvailGB: { cautionFrom: 3, restrictedFrom: 2 }, diskFreeGB: { cautionFrom: 10 }, commitPct: { restricted: 90, critical: 97 } };
      var c = RG.css('--caution'), o = RG.css('--restricted'), k = RG.css('--critical');
      RG.lineChart($('#cRam'), S.hist, { key: 'availRamGB', color: RG.css('--ram'), min: 0, max: r.totalRamGB, area: true, readout: 'roRam', unit: ' GB', lines: [{ v: t.ramAvailGB.cautionFrom, c: c }, { v: t.ramAvailGB.restrictedFrom, c: o }] });
      RG.lineChart($('#cDisk'), S.hist, { key: 'diskFreeGB', color: RG.css('--disk'), min: 0, area: true, readout: 'roDisk', unit: ' GB', lines: [{ v: t.diskFreeGB.cautionFrom, c: k }] });
      RG.lineChart($('#cCommit'), S.hist, { key: 'commitPct', color: RG.css('--commit'), min: 0, max: 100, area: true, readout: 'roCommit', unit: '%', lines: [{ v: t.commitPct.restricted, c: o }, { v: t.commitPct.critical, c: k }] });
      RG.lineChart($('#cCpu'), S.hist, { key: 'cpuPct', color: RG.css('--cpu'), min: 0, max: 100, area: true, readout: 'roCpu', unit: '%' });
    }
  };
  function drawAuto() {
    var el = $('#ovAuto'); if (!el) return;
    var p = S.policy || { mode: 'off' }, l = S.autoLast;
    var modeTxt = { off: '<span class="pill">Tắt</span>', 'dry-run': '<span class="pill ask">Chạy thử (chỉ ghi nhận)</span>', on: '<span class="pill auto">Bật (dọn thật)</span>' }[p.mode];
    el.innerHTML = '<div>Chế độ: ' + modeTxt + ' <button class="btn sm" data-go="policy" style="margin-left:6px">Cấu hình</button></div>' +
      (l ? '<div class="small mut" style="margin-top:8px">Lượt gần nhất ' + RG.timeAgo(l.finishedUtc) + ' (' + esc(l.mode) + '): ' + (l.items || []).length + ' mục, giải phóng ' + RG.fmtBytes(l.freedBytes) + '.</div>' :
        '<div class="small mut" style="margin-top:8px">Chưa có lượt tự dọn nào. Khi ổ đĩa/RAM chạm ngưỡng kích hoạt, tiến trình nền sẽ tự chạy mà không cần mở giao diện.</div>');
    RG.$$('#ovAuto [data-go]').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.go); }; });
  }

  /* ====================== CPU & Tiến trình ====================== */
  var P = { rows: [], sort: { k: 'cpu', dir: -1 }, filter: '', group: true, busy: false, logical: 1 };
  function heat(v, max) { var a = Math.min(60, Math.round(Math.min(1, v / max) * 70)); return 'background:color-mix(in srgb,var(--cpu) ' + a + '%,transparent)'; }
  function groupRows(rows) {
    var m = {};
    rows.forEach(function (r) {
      var g = m[r.name] || (m[r.name] = { name: r.name, pid: 0, n: 0, cpu: 0, ramMB: 0, group: r.group, agent: false, protected: r.protected });
      g.n++; g.cpu += r.cpu; g.ramMB += r.ramMB; g.agent = g.agent || r.agent; g.pid = g.n === 1 ? r.pid : 0;
    });
    return Object.keys(m).map(function (k) { m[k].cpu = Math.round(m[k].cpu * 10) / 10; return m[k]; });
  }
  function drawProcBody() {
    var tb = $('#procBody'); if (!tb) return;
    var rows = P.group ? groupRows(P.rows) : P.rows.slice();
    var f = P.filter.trim().toLowerCase();
    if (f) rows = rows.filter(function (r) { return r.name.indexOf(f) >= 0 || String(r.pid) === f || (r.group || '').indexOf(f) >= 0; });
    var k = P.sort.k, d = P.sort.dir;
    rows.sort(function (a, b) { var x = a[k], y = b[k]; if (typeof x === 'string') return x.localeCompare(y) * d; return ((x || 0) - (y || 0)) * d; });
    var maxRam = Math.max.apply(null, rows.map(function (r) { return r.ramMB; }).concat([1]));
    tb.innerHTML = rows.slice(0, 300).map(function (r) {
      return '<tr class="row"><td><b>' + esc(r.name) + '</b>' + (P.group && r.n > 1 ? ' <span class="mut small">(' + r.n + ')</span>' : '') + (r.agent ? ' <span class="pill keep">agent</span>' : '') + '</td>' +
        '<td class="num mut">' + (P.group && r.n > 1 ? '–' : r.pid) + '</td><td class="r"><span class="heat num" style="' + heat(r.cpu, 40) + '">' + r.cpu.toFixed(1) + '%</span></td>' +
        '<td class="r"><span class="heat num" style="' + heat(r.ramMB, maxRam).replace('var(--cpu)', 'var(--disk)') + '">' + RG.fmtBytes(r.ramMB * 1048576) + '</span></td>' +
        '<td><span class="pill">' + esc(r.group) + '</span></td>' +
        '<td class="r"><button class="icon-btn ' + (r.protected ? 'on' : '') + '" data-name="' + esc(r.name) + '" aria-pressed="' + !!r.protected + '" aria-label="' + (r.protected ? 'Bỏ bảo vệ ' : 'Bảo vệ ') + esc(r.name) + ' khỏi tự dọn" title="' + (r.protected ? 'Đang được bảo vệ khỏi tự dọn' : 'Bảo vệ khỏi tự dọn') + '">' + RG.icon('shield') + '</button></td></tr>';
    }).join('') || '<tr><td colspan="6" class="mut" style="text-align:center;padding:20px">Không có kết quả.</td></tr>';
    $('#procCount').textContent = rows.length + ' / ' + (P.group ? groupRows(P.rows).length : P.rows.length);
    RG.$$('#procBody [data-name]').forEach(function (b) { b.onclick = function () { RG.toggleProtect('process', b.dataset.name, b.getAttribute('aria-pressed') !== 'true'); }; });
    RG.$$('#procHead th.sort').forEach(function (th) { th.setAttribute('aria-sort', th.dataset.k === k ? (d < 0 ? 'descending' : 'ascending') : 'none'); th.querySelector('i').textContent = th.dataset.k === k ? (d < 0 ? ' ▼' : ' ▲') : ''; });
  }
  function fetchProcs() {
    if (P.busy) return; P.busy = true;
    RG.api('/api/processes').then(function (j) { P.rows = j.procs; P.logical = j.logical; drawProcBody(); }).catch(function () { }).then(function () { P.busy = false; });
  }
  RG.pages.cpu = {
    title: 'CPU & Tiến trình',
    render: function (el) {
      el.innerHTML = '<div class="cpu-head"><div class="card"><h2>Mức sử dụng CPU<span class="ro" id="roCpu2"></span></h2><svg id="cpuBig" class="chart tall" role="img" aria-label="Biểu đồ CPU tổng"></svg>' +
        '<div class="small mut">% sử dụng theo thời gian · mỗi điểm là một lần lấy mẫu</div></div>' +
        '<div class="card"><h2>Thông tin</h2><dl class="kv" id="cpuInfo"></dl></div></div>' +
        '<div class="card mt"><h2>Từng nhân logic</h2><div class="cores" id="coreGrid"></div></div>' +
        '<div class="card mt"><h2>Tiến trình <span class="pill" id="procCount">–</span><span class="sp"></span>' +
        '<input id="procFilter" type="text" placeholder="Lọc theo tên / PID / nhóm" aria-label="Lọc tiến trình" style="width:220px">' +
        '<span class="seg sm" role="group" aria-label="Kiểu hiển thị"><button id="gName" aria-pressed="true">Gộp theo tên</button><button id="gPid" aria-pressed="false">Từng PID</button></span></h2>' +
        '<div class="tbl-wrap"><table><thead><tr id="procHead">' +
        '<th class="sort" data-k="name">Tên<i></i></th><th class="sort" data-k="pid">PID<i></i></th><th class="sort r" data-k="cpu">CPU<i></i></th><th class="sort r" data-k="ramMB">Bộ nhớ<i></i></th><th class="sort" data-k="group">Nhóm<i></i></th><th class="r">Bảo vệ</th>' +
        '</tr></thead><tbody id="procBody"><tr><td colspan="6" class="mut">Đang tải…</td></tr></tbody></table></div>' +
        '<p class="hint">Tool chỉ liệt kê. Bảo vệ một tiến trình nghĩa là engine tự dọn sẽ không bao giờ kill nó. Bảng này không có nút kill: kill chỉ áp dụng cho tiến trình agent đã đăng ký, qua tab Dọn dẹp.</p></div>';
      $('#procFilter').value = P.filter;
      $('#procFilter').oninput = function () { P.filter = this.value; drawProcBody(); };
      $('#gName').onclick = function () { P.group = true; $('#gName').setAttribute('aria-pressed', 'true'); $('#gPid').setAttribute('aria-pressed', 'false'); drawProcBody(); };
      $('#gPid').onclick = function () { P.group = false; $('#gPid').setAttribute('aria-pressed', 'true'); $('#gName').setAttribute('aria-pressed', 'false'); drawProcBody(); };
      RG.$$('#procHead th.sort').forEach(function (th) { th.onclick = function () { var k = th.dataset.k; P.sort = { k: k, dir: P.sort.k === k ? -P.sort.dir : (k === 'name' || k === 'group' ? 1 : -1) }; drawProcBody(); }; });
      RG.pages.cpu.live();
    },
    refresh: function () { fetchProcs(); },
    live: function () {
      var r = S.live; if (!r || !$('#cpuBig')) return;
      RG.lineChart($('#cpuBig'), S.hist, { key: 'cpuPct', color: RG.css('--cpu'), min: 0, max: 100, area: true, readout: 'roCpu2', unit: '%', n: 120 });
      var ci = r.cpuInfo || {}, cores = r.cores || [];
      $('#cpuInfo').innerHTML = '<dt>Hiện tại</dt><dd><b>' + (r.cpuPct == null ? '–' : r.cpuPct + '%') + '</b></dd><dt>Bộ xử lý</dt><dd title="' + esc(ci.name) + '">' + esc(ci.name || '–') + '</dd>' +
        '<dt>Tốc độ tối đa</dt><dd>' + (ci.mhz ? (ci.mhz / 1000).toFixed(2) + ' GHz' : '–') + '</dd><dt>Nhân vật lý</dt><dd>' + (ci.physical || '–') + '</dd><dt>Nhân logic</dt><dd>' + (ci.logical || cores.length || '–') + '</dd>' +
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

  /* ====================== Cài đặt ====================== */
  RG.pages.settings = {
    title: 'Cài đặt',
    render: function (el) {
      var s = S.settings || { intervalSec: 15, minSec: 2, maxSec: 300, defaultSec: 15 }, t = S.thr;
      el.innerHTML = '<div class="grid g2"><div class="card"><h2>Chu kỳ lấy mẫu</h2>' +
        '<div class="field"><label for="iv">Lấy mẫu mỗi (giây)</label><input id="iv" type="number" min="' + s.minSec + '" max="' + s.maxSec + '" step="1" value="' + s.intervalSec + '"><button class="btn primary" id="ivSave">Lưu</button></div>' +
        '<div class="field">' + [5, 15, 30, 60].map(function (v) { return '<button class="btn sm" data-v="' + v + '">' + v + 's' + (v === s.defaultSec ? ' (mặc định)' : '') + '</button>'; }).join('') + '</div>' +
        '<p class="hint">Từ ' + s.minSec + ' đến ' + s.maxSec + ' giây, có hiệu lực ngay. Chu kỳ ngắn phản ứng nhanh hơn nhưng tốn CPU hơn một chút; bảng tiến trình luôn làm mới tối đa mỗi 30 giây.</p><div id="ivMsg" class="small"></div></div>' +
        '<div class="card"><h2>Ngưỡng trạng thái <span class="ro">chỉnh trong config.json</span></h2>' + (t ? '<table><tbody>' +
          '<tr><td>RAM trống (GB)</td><td class="r small">Normal &gt; ' + t.ramAvailGB.normalAbove + ' · Caution ≥ ' + t.ramAvailGB.cautionFrom + ' · Restricted ≥ ' + t.ramAvailGB.restrictedFrom + ' · dưới nữa Critical</td></tr>' +
          '<tr><td>Ổ đĩa trống (GB)</td><td class="r small">Normal &gt; ' + t.diskFreeGB.normalAbove + ' · Caution ≥ ' + t.diskFreeGB.cautionFrom + ' · dưới nữa Critical</td></tr>' +
          '<tr><td>Commit (%)</td><td class="r small">Restricted ≥ ' + t.commitPct.restricted + ' · Critical ≥ ' + t.commitPct.critical + '</td></tr></tbody></table>' : '') +
        '<p class="hint">Trạng thái được giữ có trễ (hysteresis): lên mức xấu hơn ngay lập tức, về mức tốt hơn sau khoảng 45 giây ổn định để không nhấp nháy.</p></div>' +
        '<div class="card"><h2>An toàn</h2><ul class="small" style="margin:0;padding-left:18px"><li>Chỉ nghe <b>localhost</b>; mọi thao tác ghi cần header riêng chống CSRF/DNS-rebinding.</li><li>Giao diện chỉ gửi <b>key</b> của mục dọn, không gửi đường dẫn; engine kiểm lại allowlist trước khi xoá.</li><li>PIN (băm PBKDF2) chỉ đặt được ở terminal: <span class="mono">resource-manager.ps1 serve setpin</span>. ' + (S.pinConfigured ? '<span class="pill auto">đã đặt</span>' : '<span class="pill ask">chưa đặt</span>') + '</li><li>Agent chỉ nhận metadata (tên, kích thước, tuổi), không nhận nội dung file.</li></ul></div>' +
        '<div class="card"><h2>Giao diện</h2><div class="field"><label>Chủ đề</label><span class="seg" role="group" aria-label="Chủ đề"><button data-th="auto">Theo hệ thống</button><button data-th="light">Sáng</button><button data-th="dark">Tối</button></span></div></div></div>';
      RG.$$('[data-v]').forEach(function (b) { b.onclick = function () { $('#iv').value = b.dataset.v; }; });
      $('#ivSave').onclick = function () {
        var v = parseInt($('#iv').value, 10);
        RG.api('/api/settings', { method: 'POST', body: { intervalSec: v } }).then(function (j) { S.settings.intervalSec = j.intervalSec; $('#ivMsg').className = 'small ok'; $('#ivMsg').textContent = 'Đã lưu: lấy mẫu mỗi ' + j.intervalSec + ' giây.'; RG.nextAt = Date.now() + j.intervalSec * 1000; })
          .catch(function (e) { $('#ivMsg').className = 'small warn'; $('#ivMsg').textContent = 'Lỗi: ' + e.message; });
      };
      var cur = RG.theme();
      RG.$$('[data-th]').forEach(function (b) { b.setAttribute('aria-pressed', b.dataset.th === cur); b.onclick = function () { RG.theme(b.dataset.th); RG.$$('[data-th]').forEach(function (x) { x.setAttribute('aria-pressed', x.dataset.th === b.dataset.th); }); }; });
    }
  };
})();
