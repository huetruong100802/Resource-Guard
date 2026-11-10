/* p-home.js - Trang chủ: câu trạng thái, sẵn sàng, mỗi ổ một thanh ảnh hưởng, kế hoạch đề xuất, "đã làm gì". Không xoá gì ở đây. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, GB = 1073741824;
  var H = { hover: null, driveSel: null, hist: {}, histAt: {} };
  var TASK = { build: 'Build', test: 'Test', subagent: 'Agent' };
  var BLOCK = { ram: 'RAM', disk: 'ổ đĩa', commit: 'bộ nhớ cam kết' };

  function driveBar(d, gain) {
    var thr = RG.diskThr(d.drive);
    return { totalBytes: (d.totalBytes || (d.totalGB ? d.totalGB * GB : 0)), freeBytes: d.freeGB * GB, gainBytes: gain || 0, cautionBytes: thr.cautionFrom * GB, normalBytes: thr.normalAbove * GB, label: 'Ổ ' + d.drive + ':' };
  }
  function driveInsight(L) { return ((S.insight && S.insight.drives) || []).filter(function (x) { return x.drive === L; })[0]; }
  function daysText(n) { return n == null ? null : (n < 1 ? 'dưới 1 ngày' : 'khoảng ' + n + ' ngày'); }

  /* ----- Câu trạng thái + sẵn sàng ----- */
  function statusSentence() {
    var l = S.live; if (!l) return { cls: 'info', text: 'Đang đọc số liệu…', sub: '' };
    var dl = RG.driveList(), bad = dl.filter(function (d) { return d.state && d.state !== 'Normal'; }).sort(function (a, b) { return a.freeGB - b.freeGB; });
    var ins = S.insight, text, cls = 'ok';
    if (bad.length) {
      var d = bad[0], di = driveInsight(d.drive), full = di && di.confidence !== 'low' ? daysText(di.daysToFull) : null;
      text = 'Máy đang thiếu chỗ: ổ ' + d.drive + ' còn ' + RG.fmtGB(d.freeGB) + (full ? ', đầy trong ' + full : '');
      cls = d.state === 'Critical' ? 'warn' : 'caut';
    } else if (RG.ramState(l.availRamGB) !== 'Normal') {
      text = 'Máy đang thiếu RAM: còn ' + RG.fmtGB(l.availRamGB) + ' trống'; cls = RG.ramState(l.availRamGB) === 'Critical' ? 'warn' : 'caut';
    } else if (RG.commitState(l.commitPct) !== 'Normal') {
      text = 'Bộ nhớ cam kết đã dùng ' + Math.round(l.commitPct) + '%: nên đóng bớt ứng dụng'; cls = 'caut';
    } else {
      var soon = ((ins && ins.drives) || []).filter(function (x) { return x.confidence !== 'low' && x.daysToFull != null && x.daysToFull <= 30; }).sort(function (a, b) { return a.daysToFull - b.daysToFull; })[0];
      text = soon ? 'Máy đang ổn, nhưng ổ ' + soon.drive + ' có thể đầy trong ' + daysText(soon.daysToFull) : 'Máy đang ổn. Không cần làm gì.';
      if (soon) cls = 'caut';
    }
    return { cls: cls, text: text, sub: RG.human.reasons(l) };
  }
  function drawStatus() {
    var el = $('#hStatus'); if (!el) return;
    var s = statusSentence(), ins = S.insight;
    var chips = ((ins && ins.readiness) || []).map(function (r) {
      var why = r.ok ? 'Đủ tài nguyên để chạy' : 'Thiếu ' + RG.fmtGB(Math.max(0, r.needGB - r.haveGB)) + ' ' + (BLOCK[r.blocker] || '');
      return '<span class="chip ' + (r.ok ? 'ok' : 'no') + '" title="' + esc(r.ok ? 'Cần ' + RG.fmtGB(r.needGB) + ', đang có ' + RG.fmtGB(r.haveGB) : 'Cần ' + RG.fmtGB(r.needGB) + ', chỉ có ' + RG.fmtGB(r.haveGB)) + '">' + RG.icon(r.ok ? 'check' : 'x') + esc(TASK[r.task] || r.task) + (r.ok ? '' : ' <span class="small">' + esc(why) + '</span>') + '</span>';
    }).join('');
    el.innerHTML = '<div class="card h-status ' + s.cls + '"><div class="h-sent" role="status">' + esc(s.text) + '</div>' +
      (s.sub && s.sub.length ? '<div class="small mut">' + s.sub.map(esc).join(' · ') + '</div>' : '') +
      (chips ? '<div class="h-ready"><span class="small mut">Sẵn sàng cho:</span> ' + chips + '</div>' : '') + '</div>';
  }

  /* ----- Mỗi ổ một thanh ảnh hưởng ----- */
  function drawDrives() {
    var el = $('#hDrives'); if (!el) return;
    var dl = RG.driveList(); if (!dl.length) { el.innerHTML = ''; return; }
    var sig = dl.map(function (d) { return d.drive; }).join(',');
    if (el.dataset.sig !== sig) {
      el.dataset.sig = sig;
      el.innerHTML = '<div class="card mt"><h2>Dung lượng các ổ</h2>' + dl.map(function (d) { return '<div class="h-drive"><div id="hib_' + esc(d.drive) + '"></div><div class="small mut" id="hdy_' + esc(d.drive) + '"></div></div>'; }).join('') + '</div>';
    }
    dl.forEach(function (d) {
      var gain = H.hover && H.hover.drive === d.drive ? H.hover.bytes : 0;
      V.impactBar($('#hib_' + d.drive), driveBar(d, gain));
      var di = driveInsight(d.drive), t = '';
      if (di && di.confidence !== 'low' && di.daysToFull != null) t = 'Với tốc độ hiện nay, ổ này đủ dùng ' + daysText(di.daysToFull) + ' (độ tin cậy ' + ({ medium: 'vừa', high: 'cao' }[di.confidence] || di.confidence) + ', dựa trên ' + di.sampleDays + ' ngày dữ liệu).';
      else if (di && di.confidence === 'low') t = 'Chưa đủ dữ liệu để ước tính ngày đầy.' + (di.slopeGBPerDay >= 0 ? ' Dung lượng trống đang ổn định hoặc tăng.' : '');
      var n = $('#hdy_' + d.drive); if (n) n.textContent = t;
    });
  }

  /* ----- Kế hoạch đề xuất ----- */
  function planKeys(a) {
    var keys = [], byDrive = {};
    (a.steps || []).forEach(function (s) { (byDrive[s.drive] = byDrive[s.drive] || []).push(s); });
    (a.goals || []).forEach(function (g) {
      var done = false; (byDrive[g.drive] || []).forEach(function (s) { if (done) return; keys = keys.concat(s.keys); if (s.reachesGoal) done = true; });
    });
    return keys;
  }
  function selectedGain(a, drive) {
    var cum = 0, done = false; (a.steps || []).forEach(function (s) { if (s.drive !== drive || done) return; cum = s.cumBytes; if (s.reachesGoal) done = true; }); return cum;
  }
  function stepItems(s) {
    var m = {}; s.keys.forEach(function (k) { m[k] = 1; });
    return ((S.cands && S.cands.items) || []).filter(function (i) { return m[i.key]; }).sort(function (a, b) { return b.sizeBytes - a.sizeBytes; });
  }
  function openStep(s) {
    var its = stepItems(s), rows = its.slice(0, 8).map(function (i) { return '<tr><td><span class="mono ellipsis" style="max-width:260px" title="' + esc(i.path) + '">' + esc(i.path) + '</span></td><td class="r num">' + RG.fmtBytes(i.sizeBytes) + '</td></tr>'; }).join('');
    var html = RG.receipt({ kind: 'step', path: s.title + ' — ' + s.count + ' mục', sizeBytes: s.bytes, why: s.why, impact: s.impact, regenHint: s.regenHint, riskLevel: s.riskLevel }) +
      '<div class="small mut" style="margin:10px 0 4px">Nguồn lời khuyên: <b>' + (s.agent ? 'Trợ lý AI' : 'Quy tắc') + '</b>' + (s.agent ? ' (' + esc(s.agent.verdict) + ': ' + esc(s.agent.reason) + ')' : '') + '</div>' +
      (rows ? '<table class="small"><thead><tr><th>Mục lớn nhất</th><th class="r">Dung lượng</th></tr></thead><tbody>' + rows + '</tbody></table>' + (its.length > 8 ? '<div class="small mut">… và ' + (its.length - 8) + ' mục khác</div>' : '') : '');
    RG.drawer({ title: s.title, html: html, actions: [{ label: 'Chọn bước này và mở Dọn dẹp', cls: 'primary', onClick: function () { S.selected = {}; s.keys.forEach(function (k) { S.selected[k] = true; }); RG.go('clean'); } }, { label: 'Đóng' }] });
  }
  function drawPlan() {
    var el = $('#hPlan'); if (!el) return;
    var a = S.advice, c = S.cands, j = S.jobs.candidates, run = j && j.status === 'running';
    if (!a) { el.innerHTML = '<div class="card mt"><h2>Kế hoạch đề xuất</h2><div class="mut">Đang lập kế hoạch…</div></div>'; return; }
    if (!a.candidatesUtc) {
      el.innerHTML = '<div class="card mt"><h2>Kế hoạch đề xuất</h2><div class="empty" style="padding:18px 0">' + RG.icon('inbox') + '<h3>Chưa có dữ liệu để lập kế hoạch</h3><div>Resource Guard cần quét các mục có thể dọn trước (chỉ đọc, không xoá gì).</div>' +
        '<p><button class="btn primary" id="hScan"' + (run ? ' disabled' : '') + '>' + RG.icon('refresh') + ' Quét mục có thể dọn</button> ' + (run ? '<span class="spin"></span>' : '') + '</p></div></div>';
      bindPlan(a); return;
    }
    var steps = a.steps || [], goals = a.goals || [], totalB = steps.reduce(function (x, s) { return x + s.bytes; }, 0);
    var html = '<div class="card mt"><h2>Kế hoạch đề xuất<span class="ro">' + (a.stale ? '<span class="pill ask">dữ liệu quét đã cũ</span> ' : '') + 'quét ' + RG.timeAgo(a.candidatesUtc) + '</span></h2>';
    if (a.stale) html += '<div class="alert warn" style="margin-bottom:10px"><div>Lượt quét mục có thể dọn đã hơn 6 giờ, kế hoạch có thể lệch. <button class="btn sm" id="hScan"' + (run ? ' disabled' : '') + '>' + RG.icon('refresh') + ' Quét lại</button></div></div>';
    if (!goals.length) {
      html += '<div class="h-plan-one">' + (steps.length ? 'Có thể dọn thêm <b>' + RG.fmtBytes(totalB) + '</b> khi cần (' + steps.length + ' nhóm, rủi ro thấp trước).' : 'Chưa có mục nào đáng dọn.') + '</div>' +
        (steps.length ? '<div class="h-steps">' + steps.map(stepRow).join('') + '</div><p><button class="btn" id="hGoClean">Xem trong Dọn dẹp</button></p>' : '');
    } else {
      goals.forEach(function (g) {
        html += '<div class="h-goal">Mục tiêu: đưa ổ <b>' + esc(g.drive) + '</b> về mức <b>' + RG.human.state(g.toState) + '</b>, cần thêm <b>' + RG.fmtBytes(g.needBytes) + '</b></div><div class="h-steps">' +
          steps.filter(function (s) { return s.drive === g.drive; }).map(stepRow).join('') + '</div>';
      });
      if (a.review && a.review.count) html += '<div class="h-review">' + RG.icon('eye') + '<span><b>' + a.review.count + ' mục</b> cần bạn xem lại (chưa đủ tuổi hoặc cần quyền admin), máy không tự quyết.</span>' + (S.settings && S.settings.agentAvailable ? '<button class="btn sm" id="hAsk">' + RG.icon('spark') + ' Hỏi trợ lý</button>' : '') + '</div>';
      var keys = planKeys(a);
      html += '<div class="h-planbar"><button class="btn primary" id="hDo"' + (keys.length ? '' : ' disabled') + '>Xem và dọn theo kế hoạch</button><span class="small mut">Chỉ chọn sẵn các mục ở trang Dọn dẹp; chưa xoá gì.</span></div><div id="hPlanBars"></div>';
      var short = (a.afterPlan || []).filter(function (x) { return x.shortBytes > 0; });
      if (short.length) {
        html += '<div class="alert info" style="margin-top:12px"><div><b>Dọn hết vẫn thiếu ' + short.map(function (x) { return 'ổ ' + esc(x.drive) + ': ' + RG.fmtBytes(x.shortBytes); }).join(', ') + '.</b> Phần còn lại cần bạn tự làm:' +
          '<ul class="small" style="margin:6px 0 0;padding-left:18px">' + (a.beyond || []).map(function (b) { return '<li>' + esc(V.CAT_LABEL[b.cat] || b.cat) + ' (ổ ' + esc(b.drive) + ': ' + RG.fmtBytes(b.bytes) + '): ' + esc(b.hint) + '</li>'; }).join('') + '</ul></div><button class="btn sm" data-go="disk">Mở trang Ổ đĩa</button></div>';
      }
    }
    html += '</div>';
    el.innerHTML = html; bindPlan(a); drawPlanBars(a);
  }
  function stepRow(s) {
    var gl = s.reachesGoal ? '<span class="pill auto" title="Làm tới bước này là đủ mục tiêu">đủ mục tiêu ở bước này</span>' : '';
    return '<div class="h-step" tabindex="0" data-id="' + esc(s.id) + '" data-drive="' + esc(s.drive) + '" data-b="' + s.bytes + '">' +
      '<span class="ttl"><b>' + esc(s.title) + '</b> <span class="mut small">· ' + s.count + ' mục · ' + esc(RG.human.regen(s.regen)) + '</span> ' + gl + '</span>' +
      '<span class="num sz">' + RG.fmtBytes(s.bytes) + '</span><span class="pill ' + ({ low: 'auto', medium: 'ask', high: 'bad' }[s.riskLevel] || '') + '">' + esc(RG.human.risk(s.riskLevel)) + '</span>' +
      '<span class="pill ' + (s.agent ? 'keep' : '') + '" title="Nguồn lời khuyên">' + (s.agent ? 'Trợ lý AI' : 'Quy tắc') + '</span><button class="btn sm" data-view="' + esc(s.id) + '">Xem</button></div>';
  }
  function drawPlanBars(a) {
    var box = $('#hPlanBars'); if (!box) return; var done = {};
    box.innerHTML = '';
    (a.goals || []).forEach(function (g) {
      var d = RG.driveInfo(g.drive); if (!d || done[g.drive]) return; done[g.drive] = 1;
      var w = document.createElement('div'); w.className = 'h-drive'; box.appendChild(w);
      V.impactBar(w, driveBar(d, selectedGain(a, g.drive)));
    });
  }
  function bindPlan(a) {
    var sc = $('#hScan'); if (sc) sc.onclick = function () { RG.startJob('/api/candidates/scan', {}, 'Bắt đầu quét các mục có thể dọn…').then(drawPlan).catch(function () { }); };
    var gc = $('#hGoClean'); if (gc) gc.onclick = function () { RG.go('clean'); };
    var dd = $('#hDo'); if (dd) dd.onclick = function () { S.selected = {}; planKeys(a).forEach(function (k) { S.selected[k] = true; }); RG.go('clean'); };
    var ak = $('#hAsk'); if (ak) ak.onclick = function () { RG.askAgent(); };
    RG.$$('#hPlan [data-go]').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.go); }; });
    RG.$$('#hPlan .h-step').forEach(function (r) {
      var on = function () { H.hover = { drive: r.dataset.drive, bytes: +r.dataset.b }; drawDrives(); }, off = function () { H.hover = null; drawDrives(); };
      r.onmouseenter = on; r.onfocus = on; r.onmouseleave = off; r.onblur = off;
    });
    RG.$$('#hPlan [data-view]').forEach(function (b) { b.onclick = function (e) { e.stopPropagation(); var s = (a.steps || []).filter(function (x) { return x.id === b.dataset.view; })[0]; if (s) openStep(s); }; });
  }

  /* ----- Resource Guard đã làm gì ----- */
  var MARK = { 'auto-run': 1, 'manual-cleanup': 1, 'policy-change': 1 };
  function eventDrawer(e) {
    var d = e.data || {}, t = RG.human.event(e), rows = '';
    if (d.byKind) rows = '<table class="small" style="margin-top:8px"><thead><tr><th>Nhóm</th><th class="r">Mục</th><th class="r">Dung lượng</th></tr></thead><tbody>' + Object.keys(d.byKind).map(function (k) { return '<tr><td>' + esc(RG.human.kind(k).l) + '</td><td class="r num">' + d.byKind[k].items + '</td><td class="r num">' + RG.fmtBytes(d.byKind[k].bytes) + '</td></tr>'; }).join('') + '</tbody></table>';
    var html = '<dl class="rc"><dt>Lúc</dt><dd>' + esc(RG.fmtLocal(e.ts)) + '</dd><dt>Việc gì</dt><dd>' + esc(t) + '</dd>' +
      (d.items != null ? '<dt>Số mục</dt><dd>' + esc(d.items) + '</dd>' : '') + (d.freedBytes != null ? '<dt>Giải phóng</dt><dd>' + RG.fmtBytes(d.freedBytes) + '</dd>' : '') + (d.trigger ? '<dt>Kích hoạt</dt><dd>' + esc(d.trigger) + '</dd>' : '') + '</dl>' + rows;
    RG.drawer({ title: 'Biên lai', html: html, actions: [{ label: 'Đóng' }] });
  }
  RG.eventDrawer = eventDrawer;
  function drawDid() {
    var el = $('#hDid'); if (!el) return;
    var dl = RG.driveList(); if (!H.driveSel || !dl.some(function (d) { return d.drive === H.driveSel; })) H.driveSel = (S.driveSel && dl.some(function (d) { return d.drive === S.driveSel; })) ? S.driveSel : (dl[0] && dl[0].drive);
    var tabs = dl.length > 1 ? '<span class="seg sm" role="group" aria-label="Chọn ổ">' + dl.map(function (d) { return '<button data-hd="' + esc(d.drive) + '" aria-pressed="' + (d.drive === H.driveSel) + '">' + esc(d.drive) + ':</button>'; }).join('') + '</span>' : '';
    var ev = RG.groupEvents(S.events || []);
    var list = ev.slice(0, 12).map(function (g, i) { return '<div class="h-ev" tabindex="0" role="button" data-i="' + i + '"><span class="mut small">' + esc(RG.fmtLocal(g.e.ts)) + '</span><span>' + esc(g.text) + (g.n > 1 ? ' <span class="mut">(×' + g.n + ')</span>' : '') + '</span></div>'; }).join('') || '<span class="mut">Chưa có sự kiện.</span>';
    var l = S.autoLast, p = S.policy || { mode: 'off' };
    var auto = '<div class="small" style="margin-top:10px">Tự dọn nền: <span class="pill ' + ({ off: '', 'dry-run': 'ask', on: 'auto' }[p.mode]) + '">' + esc(RG.human.modes[p.mode] || p.mode) + '</span> ' +
      (l ? ' · lượt gần nhất ' + RG.timeAgo(l.finishedUtc) + ': ' + (l.items || []).length + ' mục, ' + RG.fmtBytes(l.freedBytes) : ' · chưa có lượt nào') + ' <button class="btn sm" data-go="policy">Tự động hoá</button></div>';
    el.innerHTML = '<div class="card mt"><h2>Resource Guard đã làm gì<span class="sp"></span>' + tabs + '</h2><div class="small mut" style="margin-bottom:4px">Dung lượng trống ổ ' + esc(H.driveSel || '') + ' trong 14 ngày. Chấm tròn = một việc Resource Guard đã làm; bấm để xem biên lai. <span id="hDidNote"></span></div>' +
      '<svg id="hDidChart" class="chart tall" role="img" aria-label="Dung lượng trống 14 ngày kèm các điểm đánh dấu"></svg><div class="h-evs">' + list + '</div>' + auto + '</div>';
    RG.$$('#hDid [data-hd]').forEach(function (b) { b.onclick = function () { H.driveSel = b.dataset.hd; drawDid(); }; });
    RG.$$('#hDid [data-go]').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.go); }; });
    RG.$$('#hDid .h-ev').forEach(function (r) { var go = function () { eventDrawer(ev[+r.dataset.i].e); }; r.onclick = go; r.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); } }; });
    drawDidChart();
  }
  function drawDidChart() {
    var svg = $('#hDidChart'); if (!svg || !H.driveSel) return;
    var L = H.driveSel, pts = H.hist[L];
    if (!pts || Date.now() - (H.histAt[L] || 0) > 600000) {
      H.histAt[L] = Date.now();
      RG.api('/api/drive/history?drive=' + encodeURIComponent(L) + '&days=14').then(function (j) { H.hist[L] = j.points || []; drawDidChart(); }).catch(function () { });
    }
    var thr = RG.diskThr(L);
    var markers = (S.events || []).filter(function (e) { return MARK[e.event]; }).map(function (e) { return { ts: e.ts, type: e.event, label: RG.human.event(e), e: e }; });
    var data = pts || [], fn = null, note = $('#hDidNote');
    if (data.length < 2) {   // chưa đủ lịch sử theo giờ (máy mới cài): dùng số liệu trực tiếp của phiên này
      fn = function (h) { var x = (h.drives || []).filter(function (y) { return y.drive === L; })[0]; return x ? x.freeGB : null; }; data = S.hist;
      if (note) note.textContent = 'Mới có vài phút dữ liệu; biểu đồ 14 ngày sẽ đầy dần theo từng giờ.';
    } else if (note) note.textContent = '';
    RG.lineChart(svg, data, { key: 'freeGB', fn: fn || undefined, color: RG.css('--disk'), min: 0, area: true, unit: ' GB', xfmt: RG.fmtLocal, lines: [{ v: thr.cautionFrom, c: RG.css('--critical') }], markers: markers, onMarker: function (m) { eventDrawer(m.e); } });
  }

  /* ----- Chỉ số chi tiết (gập sẵn): 4 biểu đồ realtime ----- */
  function drawMetrics() {
    var det = $('#hMetrics'); if (!det || !det.open) return;
    var r = S.live; if (!r) return;
    var t = S.thr || { ramAvailGB: { cautionFrom: 3, restrictedFrom: 2 }, diskFreeGB: { cautionFrom: 10 }, commitPct: { restricted: 90, critical: 97 } };
    var c = RG.css('--caution'), o = RG.css('--restricted'), k = RG.css('--critical'), dl = RG.driveList();
    var sig = dl.map(function (d) { return d.drive; }).join(',');
    if (H.sig !== sig) {
      H.sig = sig;
      $('#hmDisks').innerHTML = dl.map(function (d) { return '<div class="card"><h2>Ổ ' + esc(d.drive) + ': trống (GB)<span class="ro" id="roDisk_' + esc(d.drive) + '"></span></h2><svg id="cDisk_' + esc(d.drive) + '" class="chart" role="img" aria-label="Dung lượng trống ổ ' + esc(d.drive) + '"></svg></div>'; }).join('');
    }
    RG.lineChart($('#cRam'), S.hist, { key: 'availRamGB', color: RG.css('--ram'), min: 0, max: r.totalRamGB, area: true, readout: 'roRam', unit: ' GB', lines: [{ v: t.ramAvailGB.cautionFrom, c: c }, { v: t.ramAvailGB.restrictedFrom, c: o }] });
    dl.forEach(function (d) {
      var L = d.drive, thr = RG.diskThr(L);
      RG.lineChart($('#cDisk_' + L), S.hist, { fn: function (h) { var x = (h.drives || []).filter(function (y) { return y.drive === L; })[0]; return x ? x.freeGB : null; }, color: RG.css('--disk'), min: 0, area: true, readout: 'roDisk_' + L, unit: ' GB', lines: [{ v: thr.cautionFrom, c: k }] });
    });
    RG.lineChart($('#cCommit'), S.hist, { key: 'commitPct', color: RG.css('--commit'), min: 0, max: 100, area: true, readout: 'roCommit', unit: '%', lines: [{ v: t.commitPct.restricted, c: o }, { v: t.commitPct.critical, c: k }] });
    RG.lineChart($('#cCpu'), S.hist, { key: 'cpuPct', color: RG.css('--cpu'), min: 0, max: 100, area: true, readout: 'roCpu', unit: '%' });
  }

  var tickN = 0;
  RG.pages.home = {
    title: 'Trang chủ',
    render: function (el) {
      el.innerHTML = '<div id="hStatus"></div><div id="hDrives"></div><div id="hPlan"></div><div id="hDid"></div>' +
        '<details class="card mt" id="hMetrics"><summary class="h-sum">Chỉ số chi tiết <span class="mut small">RAM, ổ đĩa, bộ nhớ cam kết, CPU theo thời gian thực</span></summary>' +
        '<div class="grid g2" style="margin-top:10px"><div class="card"><h2>RAM trống (GB)<span class="ro" id="roRam"></span></h2><svg id="cRam" class="chart" role="img" aria-label="Biểu đồ RAM trống"></svg></div><div id="hmDisks" style="display:contents"></div>' +
        '<div class="card"><h2>Bộ nhớ cam kết (%)<span class="ro" id="roCommit"></span></h2><svg id="cCommit" class="chart" role="img" aria-label="Biểu đồ bộ nhớ cam kết"></svg></div>' +
        '<div class="card"><h2>CPU (%)<span class="ro" id="roCpu"></span></h2><svg id="cCpu" class="chart" role="img" aria-label="Biểu đồ CPU"></svg></div></div></details>';
      H.sig = null; H.hover = null;
      $('#hMetrics').ontoggle = function () { drawMetrics(); };
      drawStatus(); drawDrives(); drawPlan(); drawDid();
      this.refresh();
    },
    refresh: function () {
      Promise.all([RG.loadInsight().catch(function () { }), RG.loadAdvice().catch(function () { }), RG.loadEvents().catch(function () { }), RG.loadCands().catch(function () { }), RG.loadAuto().catch(function () { }), RG.loadPolicy().catch(function () { })]).then(function () {
        if (RG.cur !== 'home') return; drawStatus(); drawDrives(); drawPlan(); drawDid();
      });
    },
    jobs: function () { if (RG.cur === 'home') drawPlan(); },
    live: function () {
      if (!$('#hStatus')) return;
      drawStatus(); drawDrives(); drawMetrics();
      if ($('#hDidChart') && ++tickN % 6 === 0) RG.pages.home.refresh();
    }
  };
  RG.pages.overview = RG.pages.home;
})();
