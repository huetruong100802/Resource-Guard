/* p-home.js - Tổng quan (#home): câu trạng thái + sẵn sàng, mỗi tài nguyên một dòng (donut nhỏ + thanh), "Nên làm gì bây giờ" (tối đa 3 bước),
   "Báo cáo của trợ lý" (cụm tệp: nén / dọn / giữ; UI chỉ gửi clusterId + hành động), 7 ngày qua + dòng thời gian sự kiện.
   "Nên làm gì" không xoá gì: [Xem] chỉ chuyển sang màn Ổ đĩa / Bộ nhớ với mục chọn sẵn. Hành động duy nhất ở đây là trên cụm của trợ lý, có hộp xác nhận. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, GB = 1073741824;
  var H = { hover: null, wl: null, disk: {} };
  var TASK = { build: 'Build', test: 'Test', subagent: 'Agent' };
  var BLOCK = { ram: 'RAM', disk: 'ổ đĩa', commit: 'bộ nhớ cam kết' };
  var STV = { Normal: '--normal', Caution: '--caution', Restricted: '--restricted', Critical: '--critical' };

  function driveInsight(L) { return ((S.insight && S.insight.drives) || []).filter(function (x) { return x.drive === L; })[0]; }
  function daysText(n) { return n == null ? null : (n < 1 ? 'dưới 1 ngày' : 'khoảng ' + n + ' ngày'); }
  function diskStateAt(f, L) { var t = RG.diskThr(L); return f > t.normalAbove ? 'Normal' : (f >= t.cautionFrom ? 'Caution' : 'Critical'); }
  function stateAt(id, f) { return id === 'RAM' ? RG.ramState(f) : diskStateAt(f, id); }

  /* ----- Câu trạng thái + sẵn sàng ----- */
  function statusSentence() {
    var l = S.live; if (!l) return { cls: 'info', text: 'Đang đọc số liệu…', sub: [] };
    var dl = RG.driveList(), bad = dl.filter(function (d) { return d.state && d.state !== 'Normal'; }).sort(function (a, b) { return a.freeGB - b.freeGB; });
    var ins = S.insight, text, cls = 'ok';
    if (bad.length) {
      var d = bad[0], di = driveInsight(d.drive), full = di && di.confidence !== 'low' ? daysText(di.daysToFull) : null;
      text = 'Máy đang thiếu chỗ: ổ ' + d.drive + ' còn ' + RG.fmtGB(d.freeGB) + (full ? ', đầy trong ' + full : '');
      cls = d.state === 'Critical' ? 'warn' : 'caut';
    } else if (RG.ramState(l.availRamGB) !== 'Normal') {
      text = 'Máy đang thiếu RAM: còn ' + RG.fmtGB(l.availRamGB) + ' trống'; cls = RG.ramState(l.availRamGB) === 'Critical' ? 'warn' : 'caut';
    } else if (RG.commitState(l.commitPct) !== 'Normal') {
      text = 'Bộ nhớ cam kết đã dùng ' + RG.fmtPct(l.commitPct) + ': nên đóng bớt ứng dụng'; cls = 'caut';
    } else {
      var soon = ((ins && ins.drives) || []).filter(function (x) { return x.confidence !== 'low' && x.daysToFull != null && x.daysToFull <= 30; }).sort(function (a, b) { return a.daysToFull - b.daysToFull; })[0];
      text = soon ? 'Máy đang ổn, nhưng ổ ' + soon.drive + ' có thể đầy trong ' + daysText(soon.daysToFull) : 'Máy đang ổn. Không cần làm gì.';
      if (soon) cls = 'caut';
    }
    return { cls: cls, text: text, sub: RG.human.reasons(l) || [] };
  }
  function drawStatus() {
    var el = $('#hStatus'); if (!el) return;
    var s = statusSentence(), ins = S.insight;
    var chips = ((ins && ins.readiness) || []).map(function (r) {
      var gap = r.needGB - r.haveGB, why = '';
      if (!r.ok) why = (gap > 0 && r.blocker === 'ram') ? 'thiếu ' + RG.fmtGB(gap) + ' RAM' : ({ ram: 'RAM đang cạn', disk: 'ổ đĩa đang cạn', commit: 'bộ nhớ cam kết gần đầy', concurrency: 'đang chạy quá nhiều việc' }[r.blocker] || 'máy chưa sẵn sàng');
      return '<span class="chip ' + (r.ok ? 'ok' : 'no') + '" title="' + esc('Cần ' + RG.fmtGB(r.needGB) + ', ' + (r.ok ? 'đang có ' : 'chỉ có ') + RG.fmtGB(r.haveGB)) + '">' + RG.icon(r.ok ? 'check' : 'x') + esc(TASK[r.task] || r.task) + (why ? ' <span class="small">' + esc(why) + '</span>' : '') + '</span>';
    }).join('');
    el.innerHTML = '<div class="card h-status ' + s.cls + '"><div class="h-sent" role="status">' + esc(s.text) + (s.sub.length ? ' ' + RG.help(s.sub.join(' · ')) : '') + '</div>' +
      (chips ? '<div class="h-ready"><span class="small mut">Sẵn sàng cho:</span> ' + chips + '</div>' : '') + '</div>';
  }

  /* ----- Tài nguyên: mỗi dòng một donut nhỏ + một thanh; bấm → sang màn tương ứng ----- */
  function resRows() {
    var l = S.live, rows = [], t = S.thr && S.thr.ramAvailGB;
    if (l) rows.push({ id: 'RAM', go: 'mem', name: 'RAM', total: l.totalRamGB, free: Math.min(l.totalRamGB, l.availRamGB), thr: t ? t.normalAbove : null, color: 'var(--ram)', sub: '' });
    RG.driveList().forEach(function (d) {
      var total = d.totalGB || (d.totalBytes ? d.totalBytes / GB : 0); if (!total) return;
      var di = driveInsight(d.drive), sub = '';
      if (di && di.confidence !== 'low' && di.daysToFull != null) sub = 'đủ dùng ' + daysText(di.daysToFull);
      
      rows.push({ id: d.drive, go: 'disk', name: 'Ổ ' + d.drive + ':' + (d.label ? ' ' + d.label : ''), total: total, free: d.freeGB, thr: RG.diskThr(d.drive).normalAbove, color: 'var(--disk)', sub: sub, drive: d.drive });
    });
    return rows;
  }
  /* Đoạn tô màu cho thanh + donut: RAM theo nhóm việc (như màn Bộ nhớ), ổ theo Hệ thống / Của bạn / Dọn được (như màn Ổ đĩa). */
  function cleanGB(L) {
    var a = S.advice, c = S.cands; if (!a || !c) return 0; var m = {};
    (a.steps || []).forEach(function (s) { if (s.resource !== 'ram' && s.drive === L) (s.keys || []).forEach(function (k) { m[k] = 1; }); });
    return (c.items || []).reduce(function (x, i) { return x + (m[i.key] && i.kind !== 'process' && i.action !== 'kill' && i.action !== 'report' ? (i.sizeBytes || 0) : 0); }, 0) / GB;
  }
  function segsFor(r) {
    var used = Math.max(0, r.total - r.free), out = [], one = [{ key: 'used', label: 'Đã dùng', value: used, color: r.color }];
    if (r.id === 'RAM') {
      var sum = 0;
      (H.wl || []).slice().sort(function (a, b) { return b.ramMB - a.ramMB; }).slice(0, 5).forEach(function (w) {
        var v = w.ramMB / 1024; if (v <= 0) return;
        out.push({ key: w.key, label: (w.title || RG.human.role(w.role)) + (w.project ? ' · ' + w.project : ''), value: v, color: 'var(--role-' + (w.role || 'unknown') + ')' }); sum += v;
      });
      if (sum > used && sum > 0) { var k = used / sum; out.forEach(function (s) { s.value *= k; }); sum = used; }
      if (used - sum > 0.01) out.push({ key: 'other', label: 'Khác', value: used - sum, color: 'var(--role-unknown)' });
      return out.length ? out : one;
    }
    var di = H.disk[r.id]; if (!di) return one;
    var sys = Math.min(used, (di.unscannedBytes || 0) / GB), cl = Math.min(Math.max(0, used - sys), cleanGB(r.id)), mine = Math.max(0, used - sys - cl);
    return [{ key: 'sys', label: 'Hệ thống & chương trình', value: sys, color: 'var(--d-system)' }, { key: 'mine', label: 'Dự án & tệp của bạn', value: mine, color: 'var(--d-mine)' },
      { key: 'clean', label: 'Dọn được', value: cl, color: 'var(--normal)', pattern: 'hatch' }].filter(function (x) { return x.value > 0; });
  }
  function barHtml(segs, total) {
    return segs.map(function (s) {
      return '<i class="' + (s.pattern === 'hatch' ? 'hatch' : '') + '" style="width:' + RG.n1(Math.min(100, s.value / total * 100)) + '%;background-color:' + s.color + '" title="' + esc(s.label + ' · ' + RG.fmtGB(s.value)) + '"></i>';
    }).join('');
  }
  var SOFT = { Normal: '--normal-soft', Caution: '--caution-soft', Restricted: '--restricted-soft', Critical: '--critical-soft' };
  function drawRes() {
    var el = $('#hRes'); if (!el) return;
    var rows = resRows(); if (!rows.length) { el.innerHTML = ''; return; }
    var sig = rows.map(function (r) { return r.id; }).join(',');
    if (el.dataset.sig !== sig) {
      el.dataset.sig = sig;
      el.innerHTML = '<div class="card mt"><h2>Tài nguyên<span class="sp"></span><span class="small mut" style="font-weight:400">hình tròn: ai đang chiếm</span></h2>' + rows.map(function (r) {
        return '<div class="hr-row" tabindex="0" role="link" data-go="' + r.go + '" data-drive="' + esc(r.drive || '') + '"><div id="hdn_' + esc(r.id) + '"></div><div class="hr-main"><div class="hr-top"><b>' + esc(r.name) + '</b><span class="small mut" id="hdy_' + esc(r.id) + '"></span></div>' +
          '<div class="rbar" id="hib_' + esc(r.id) + '"></div></div><span class="hr-st" id="hst_' + esc(r.id) + '"></span></div>';
      }).join('') + '</div>';
      RG.$$('#hRes .hr-row').forEach(function (n) {
        var go = function () { if (n.dataset.drive) S.driveSel = n.dataset.drive; RG.go(n.dataset.go); };
        n.onclick = go; n.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); } };
      });
    }
    rows.forEach(function (r) {
      var used = Math.max(0, r.total - r.free), gain = H.hover && H.hover.id === r.id ? Math.min(used, H.hover.gain) : 0, st = stateAt(r.id, r.free), segs = segsFor(r);
      $('#hib_' + r.id).innerHTML = barHtml(segs, r.total);
      V.donut($('#hdn_' + r.id), segs, r.total, { big: Math.round(used / r.total * 100) + '%', small: 'đã dùng' }, 68, 12, { fmt: RG.fmtGB });
      var s = $('#hst_' + r.id); if (s) { var sf = RG.human.state(st); s.innerHTML = '<span class="hr-b" style="background:var(' + SOFT[st] + ');color:var(' + STV[st] + ')">● ' + esc(sf) + '</span>'; }
      var n = $('#hdy_' + r.id);
      if (n) n.textContent = gain > 0.001 ? 'nếu làm tới bước này: trống ' + RG.fmtGB(r.free) + ' → ' + RG.fmtGB(r.free + gain) : 'trống ' + RG.fmtGB(r.free) + ' / ' + RG.fmtGB(r.total) + (r.sub ? ' · ' + r.sub : '');
    });
  }

  /* ----- Nên làm gì bây giờ ----- */
  function planSteps(a) {
    var need = {}, done = {}, out = [];
    (a.goals || []).forEach(function (g) { need[g.drive] = g; });
    (a.steps || []).forEach(function (s) {
      if (out.length >= 3 || !need[s.drive] || done[s.drive] || s.minor) return;
      out.push(s); if (s.reachesGoal) done[s.drive] = true;
    });
    return out;
  }
  function stepRow(s, i) {
    var ram = s.resource === 'ram';
    return '<div class="h-step" tabindex="0" data-id="' + esc(s.id) + '" data-drive="' + esc(s.drive) + '" data-cum="' + (s.cumBytes || s.bytes || 0) + '"><span class="ttl"><span class="mut">' + (i + 1) + '.</span> <b>' + esc(s.title) + '</b></span>' +
      '<span class="num sz">+' + RG.fmtBytes(s.bytes) + (ram ? ' RAM' : '') + '</span><span class="small mut">' + (ram ? 'bạn tự đóng' : 'xem lại rồi mới xoá') + '</span><button class="btn sm" data-view="' + esc(s.id) + '">Xem</button></div>';
  }
  function afterLine(a, shown) {
    var by = {}; shown.forEach(function (s) { by[s.drive] = s; });
    return Object.keys(by).map(function (id) {
      var g = (a.goals || []).filter(function (x) { return x.drive === id; })[0]; if (!g) return '';
      var after = g.freeGB + (by[id].cumBytes || by[id].bytes || 0) / GB, nm = id === 'RAM' ? 'RAM' : 'ổ ' + id;
      return 'Sau ' + shown.filter(function (s) { return s.drive === id; }).length + ' bước: ' + nm + ' trống <b>' + RG.fmtGB(g.freeGB).replace(/ GB$/, '') + ' → ' + RG.fmtGB(after) + '</b> · ' + RG.human.state(stateAt(id, g.freeGB)) + ' → ' + RG.human.state(stateAt(id, after));
    }).filter(Boolean).join('<br>');
  }
  function drawPlan() {
    var el = $('#hPlan'); if (!el) return;
    var a = S.advice, j = S.jobs.candidates, run = j && j.status === 'running';
    var scan = '<button class="btn sm" id="hScan"' + (run ? ' disabled' : '') + '>' + RG.icon('refresh') + ' Quét mục có thể dọn</button>' + (run ? ' <span class="spin"></span>' : '');
    if (!a) { el.innerHTML = '<div class="card mt"><h2>Nên làm gì bây giờ</h2><div class="mut">Đang lập kế hoạch…</div></div>'; return; }
    var steps = a.steps || [], goals = a.goals || [], totalB = steps.reduce(function (x, s) { return x + (s.resource === 'disk' ? s.bytes : 0); }, 0), html;
    if (!goals.length) {
      html = '<div class="card mt h-plan-one">' + (!a.candidatesUtc ? '<span class="mut">Chưa quét các mục có thể dọn.</span> ' + scan :
        (totalB > 0 ? 'Không cần làm gì lúc này. Khi cần, có thể dọn thêm <b>' + RG.fmtBytes(totalB) + '</b> <button class="btn sm" data-go="disk">Mở Ổ đĩa</button>' : '<span class="mut">Không cần làm gì lúc này.</span>')) + '</div>';
    } else {
      var shown = planSteps(a), diskNeed = goals.some(function (g) { return g.resource === 'disk'; });
      html = '<div class="card mt"><h2>Nên làm gì bây giờ' + (a.stale ? '<span class="ro"><span class="pill ask">dữ liệu quét đã cũ</span> ' + scan + '</span>' : '') + '</h2>';
      if (shown.length) html += '<div class="h-steps">' + shown.map(stepRow).join('') + '</div><div class="small h-after">' + afterLine(a, shown) + '</div>';
      else html += '<div class="mut">Chưa có bước nào đề xuất' + (diskNeed && !a.candidatesUtc ? ' vì chưa quét ổ đĩa. ' + scan : '.') + '</div>';
      var short = (a.afterPlan || []).filter(function (x) { return x.shortBytes > 0; });
      if (short.length) html += '<div class="small mut" style="margin-top:8px">Dọn hết vẫn thiếu ' + short.map(function (x) { return (x.resource === 'ram' ? 'RAM' : 'ổ ' + esc(x.drive)) + ' ' + RG.fmtBytes(x.shortBytes); }).join(', ') + ' ' + RG.help((a.beyond || []).map(function (b) { return (V.CAT_LABEL[b.cat] || b.cat) + ': ' + b.hint; }).join(' · ') || 'Phần còn lại cần bạn tự làm.') + '</div>';
      html += '</div>';
    }
    el.innerHTML = html; bindPlan(a);
  }
  function bindPlan(a) {
    var sc = $('#hScan'); if (sc) sc.onclick = function () { RG.startJob('/api/candidates/scan', {}, 'Bắt đầu quét các mục có thể dọn…').then(drawPlan).catch(function () { }); };
    RG.$$('#hPlan [data-go]').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.go); }; });
    RG.$$('#hPlan .h-step').forEach(function (r) {
      var on = function () { H.hover = { id: r.dataset.drive, gain: +r.dataset.cum / GB }; drawRes(); }, off = function () { H.hover = null; drawRes(); };
      r.onmouseenter = on; r.onfocus = on; r.onmouseleave = off; r.onblur = off;
    });
    RG.$$('#hPlan [data-view]').forEach(function (b) {
      b.onclick = function (e) {
        e.stopPropagation(); var s = (a.steps || []).filter(function (x) { return x.id === b.dataset.view; })[0]; if (!s) return;
        if (s.resource === 'ram') { if (RG.memSelect) RG.memSelect(s.workload); RG.go('mem'); return; }
        S.selected = {}; (s.keys || []).forEach(function (k) { S.selected[k] = true; }); S.driveSel = s.drive; RG.go('disk');
      };
    });
  }

  /* ----- 7 ngày qua + dòng thời gian ----- */
  function eventDrawer(e) {
    var d = e.data || {}, t = RG.human.event(e), rows = '';
    if (d.byKind) rows = '<table class="small" style="margin-top:8px"><thead><tr><th>Nhóm</th><th class="r">Mục</th><th class="r">Dung lượng</th></tr></thead><tbody>' + Object.keys(d.byKind).map(function (k) { return '<tr><td>' + esc(RG.human.kind(k).l) + '</td><td class="r num">' + d.byKind[k].items + '</td><td class="r num">' + RG.fmtBytes(d.byKind[k].bytes) + '</td></tr>'; }).join('') + '</tbody></table>';
    var html = '<dl class="rc"><dt>Lúc</dt><dd>' + esc(RG.fmtLocal(e.ts)) + '</dd><dt>Việc gì</dt><dd>' + esc(t) + '</dd>' +
      (d.items != null ? '<dt>Số mục</dt><dd>' + esc(d.items) + '</dd>' : '') + (d.freedBytes != null ? '<dt>Giải phóng</dt><dd>' + RG.fmtBytes(d.freedBytes) + '</dd>' : '') + (d.trigger ? '<dt>Kích hoạt</dt><dd>' + esc(d.trigger) + '</dd>' : '') + '</dl>' + rows;
    RG.drawer({ title: 'Biên lai', html: html, actions: [{ label: 'Đóng' }] });
  }
  RG.eventDrawer = eventDrawer;
  function drawWeek() {
    var el = $('#hWeek'); if (!el) return;
    var w = (S.insight && S.insight.week) || { autoRuns: 0, autoBytes: 0, dryRuns: 0, dryBytes: 0, alerts: 0, manualRuns: 0, manualBytes: 0 };
    var ev = RG.groupEvents(S.events || []);
    var tiles = [[w.autoRuns + ' lượt', 'tự dọn · ' + RG.fmtBytes(w.autoBytes)], [w.dryRuns + ' lượt', 'chạy thử · sẽ dọn ' + RG.fmtBytes(w.dryBytes)], [w.manualRuns + ' lượt', 'bạn dọn tay · ' + RG.fmtBytes(w.manualBytes)], [w.alerts + ' lần', 'cảnh báo']];
    var list = ev.slice(0, 8).map(function (g, i) { return '<div class="h-ev" tabindex="0" role="button" data-i="' + i + '"><span class="mut small">' + esc(RG.fmtLocal(g.e.ts)) + '</span><span>' + esc(g.text) + (g.n > 1 ? ' <span class="mut">(×' + g.n + ')</span>' : '') + '</span></div>'; }).join('') || '<span class="mut">Chưa có sự kiện.</span>';
    el.innerHTML = '<div class="card mt"><h2>7 ngày qua Resource Guard đã' + RG.help('Chấm sự kiện của từng ổ xem ở màn Ổ đĩa. Bấm một dòng để xem biên lai.') + '</h2><div class="hw">' +
      tiles.map(function (t) { return '<div class="hw-t"><b class="num">' + esc(t[0]) + '</b><span class="small mut">' + esc(t[1]) + '</span></div>'; }).join('') + '</div><div class="h-evs">' + list + '</div></div>';
    RG.$$('#hWeek .h-ev').forEach(function (r) { var go = function () { eventDrawer(ev[+r.dataset.i].e); }; r.onclick = go; r.onkeydown = function (e) { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); go(); } }; });
  }

  /* ---------- Báo cáo của trợ lý (D5) ----------
     Cụm tệp do server kiểm kê + gom (metadata, không đọc nội dung). UI chỉ gửi clusterId + hành động (compress | clean | Để sau);
     đường dẫn do server tự giải, mỗi tệp vẫn đi qua plan → approve → apply. File cá nhân tối đa là NÉN (zip có kiểm tra, khôi phục được). */
  var A = { rep: null, scan: null, ask: null, loading: false, timer: null, all: false };
  var VERD = { compress: ['Nén', 'keep'], clean: ['Dọn', 'ask'], keep: ['Giữ nguyên', ''] };
  function assistLoad() {
    return RG.api('/api/assistant/report').then(function (j) { A.rep = j.report; A.scan = j.scan; A.ask = j.ask; }).catch(function () { });
  }
  function scanRunning() { return !!(A.scan && A.scan.status === 'running'); }
  function assistPoll() {
    if (A.timer) return;
    A.timer = setTimeout(function () {
      A.timer = null;
      assistLoad().then(function () { if (RG.cur !== 'home') return; drawAssist(); if (scanRunning() || (S.jobs.cleanup && S.jobs.cleanup.status === 'running')) assistPoll(); });
    }, 1500);
  }
  function clusterRow(c) {
    var v = VERD[c.verdict] || VERD.keep, act = '';
    if (c.actionable && c.verdict === 'compress') act += '<button class="btn sm primary" data-as="compress" data-id="' + esc(c.clusterId) + '">Nén</button> ';
    if (c.actionable && c.verdict === 'clean') act += '<button class="btn sm danger" data-as="clean" data-id="' + esc(c.clusterId) + '">Dọn</button> ';
    if (!c.reportOnly) act += '<button class="btn sm" data-as="later" data-id="' + esc(c.clusterId) + '" title="Ẩn cụm này 30 ngày">Để sau</button>';
    var gain = (c.actionable && c.gainBytes > 0) ? '<b class="num">~' + RG.fmtBytes(c.gainBytes) + '</b><span class="small mut"> giải phóng</span>' : '<span class="small mut">' + RG.fmtBytes(c.totalBytes) + '</span>';
    return '<div class="as-row" data-cl="' + esc(c.clusterId) + '"><div class="as-main"><div class="as-ttl"><span class="pill ' + v[1] + '">' + v[0] + '</span> ' + esc(c.label) +
      (c.reportOnly ? ' <span class="pill" title="Dữ liệu ứng dụng ở góc khuất: chỉ báo cáo, không bao giờ đụng tới">chỉ báo cáo</span>' : '') + '</div>' +
      '<div class="small mut">' + esc(c.verdictReason || '') + ' <span class="pill" title="' + (c.source === 'agent' ? 'Agent đánh giá, đã qua bộ lọc bảo vệ' : 'Luật tất định, không dùng AI') + '">' + (c.source === 'agent' ? 'agent' : 'luật') + '</span></div>' +
      ((c.sample && c.sample.length) ? '<div class="small mut as-smp">Ví dụ: ' + c.sample.slice(0, 3).map(esc).join(', ') + (c.count > 3 ? '…' : '') + '</div>' : '') + '</div>' +
      '<div class="as-side"><div class="as-gain">' + gain + '</div><div class="as-acts">' + act + '</div></div></div>';
  }
  function drawAssist() {
    var el = $('#hAssist'); if (!el) return;
    var r = A.rep, busyClean = S.jobs.cleanup && S.jobs.cleanup.status === 'running', head, body = '';
    var btns = '<button class="btn sm" id="asScan"' + (scanRunning() ? ' disabled' : '') + '>' + RG.icon('refresh') + ' ' + (scanRunning() ? 'Đang xem…' : (r && r.scanned ? 'Quét lại' : 'Xem máy này')) + '</button>' +
      (r && r.agent && r.agent.available ? ' <button class="btn sm" id="asAsk" title="Nhờ agent (claude) đánh giá thêm; chỉ gửi mô tả cụm, không gửi tên file hay đường dẫn">Nhờ agent đánh giá</button>' : '');
    head = '<h2>Báo cáo của trợ lý' + RG.help('Trợ lý xem metadata của Tải xuống, Tài liệu, Màn hình và dữ liệu lớn ở góc khuất (không đọc nội dung tệp), gom thành cụm rồi đề xuất: nén, dọn hoặc giữ. File cá nhân chỉ có thể nén (zip có kiểm tra, khôi phục được), không bao giờ xoá thẳng. Mọi thao tác chờ bạn bấm.') + '<span class="sp"></span>' + btns + '</h2>';
    if (!r || !r.scanned) {
      body = '<div class="small mut" style="margin:8px 0">' + (scanRunning() ? 'Đang xem các thư mục của bạn…' : 'Trợ lý chưa xem máy này. Bấm “Xem máy này”: chỉ đọc tên, dung lượng và ngày sửa, không mở nội dung tệp.') + '</div>';
    } else {
      var cl = (r.clusters || []).slice().sort(function (a, b) { return (b.actionable ? b.gainBytes : 0) - (a.actionable ? a.gainBytes : 0) || b.totalBytes - a.totalBytes; });
      var act = cl.filter(function (c) { return c.actionable; }), rest = cl.filter(function (c) { return !c.actionable; }), sm = r.summary || {};
      body = '<div class="small mut" style="margin:6px 0">' + (act.length ? act.length + ' cụm có thể xử lý · giải phóng được khoảng <b>' + RG.fmtBytes(sm.gainBytes || 0) + '</b>' : 'Chưa có gì cần xử lý') +
        ' · quét ' + esc(RG.fmtLocal(r.builtUtc)) + (r.stale ? ' <span class="pill ask">đã cũ, hãy quét lại</span>' : '') + (r.truncated ? ' <span class="pill ask" title="Quá nhiều tệp: chỉ xem được một phần">xem được một phần</span>' : '') + '</div>';
      if (busyClean) body += '<div class="small" style="margin:6px 0">' + RG.icon('info') + ' Đang xử lý: ' + esc((S.jobs.cleanup && S.jobs.cleanup.message) || '…') + '</div>';
      body += '<div class="as-list">' + act.slice(0, 8).map(clusterRow).join('') + '</div>';
      if (act.length > 8) body += '<div class="small mut">… và ' + (act.length - 8) + ' cụm nhỏ hơn.</div>';
      if (rest.length) body += '<details class="as-more"' + (A.all ? ' open' : '') + '><summary class="small mut">Giữ nguyên / chỉ báo cáo (' + rest.length + ')</summary><div class="as-list">' + rest.slice(0, 20).map(clusterRow).join('') + '</div></details>';
    }
    el.innerHTML = '<div class="card mt">' + head + body + '</div>';
    bindAssist();
  }
  function actConfirm(c, kind) {
    var n = c.count, html = kind === 'compress'
      ? '<p>Nén <b>' + n + ' tệp</b> (' + esc(c.label) + ') thành file zip cạnh bản gốc. Mỗi zip được kiểm tra lại trước khi xoá bản gốc.</p><p class="hint">Khôi phục bất cứ lúc nào ở “Bản đã nén” (màn Ổ đĩa). Tệp mới dùng trong 30 ngày hoặc đang được ứng dụng khác mở sẽ được bỏ qua.</p>'
      : '<p>Xoá <b>' + n + ' tệp</b> (' + esc(c.label) + '). Đây là loại tải lại / tạo lại được (bộ cài, file tạm), <b>không có bản sao</b> sau khi xoá.</p><p class="hint">Tệp mới dùng trong 30 ngày hoặc đang được ứng dụng khác mở sẽ được bỏ qua.</p>';
    return RG.confirm(kind === 'compress' ? 'Nén cụm này?' : 'Dọn cụm này?', html, kind === 'compress' ? 'Nén' : 'Dọn', kind === 'clean');
  }
  function bindAssist() {
    var sc = $('#asScan'); if (sc) sc.onclick = function () {
      sc.disabled = true;
      RG.api('/api/assistant/scan', { method: 'POST', body: {} }).then(function () { A.scan = { status: 'running' }; drawAssist(); assistPoll(); }).catch(function (e) { RG.toast(e.message, 'err'); sc.disabled = false; });
    };
    var ak = $('#asAsk'); if (ak) ak.onclick = function () {
      ak.disabled = true;
      RG.api('/api/assistant/ask', { method: 'POST', body: {} }).then(function () { RG.toast('Agent đang đánh giá các cụm…'); assistPoll(); }).catch(function (e) { RG.toast(e.message, 'err', 8000); ak.disabled = false; });
    };
    RG.$$('#hAssist [data-as]').forEach(function (b) {
      b.onclick = function () {
        var id = b.dataset.id, kind = b.dataset.as, c = ((A.rep && A.rep.clusters) || []).filter(function (x) { return x.clusterId === id; })[0]; if (!c) return;
        if (kind === 'later') { RG.api('/api/assistant/dismiss', { method: 'POST', body: { clusterId: id } }).then(function () { return assistLoad(); }).then(drawAssist).catch(function (e) { RG.toast(e.message, 'err'); }); return; }
        actConfirm(c, kind).then(function (ok) {
          if (!ok) return;
          RG.startJob('/api/assistant/act', { clusterId: id, action: kind }, 'Đang xử lý cụm…').then(function () { drawAssist(); assistPoll(); }).catch(function () { });
        });
      };
    });
  }

  /* ---------- Banner tự động hoá (E3/E4): vẫn quá mốc sau khi tự dọn, đề nghị nâng mức, nút dừng khẩn cấp ---------- */
  var AB = { aut: null };
  function loadAut() { return RG.api('/api/autonomy').then(function (j) { AB.aut = j; }).catch(function () { }); }
  function drawBanner() {
    var el = $('#hBanner'); if (!el) return;
    var a = AB.aut, mode = (a && a.mode) || (S.policy && S.policy.mode) || 'off', h = '';
    if (a && a.banner && a.banner.active) {
      var ds = (a.banner.drives || []).map(function (d) { return 'ổ ' + esc(d.drive) + ': ' + RG.fmtGB(d.freeGB) + ' trống (mục tiêu ' + RG.fmtGB(d.targetFreeGB) + ')'; }).join(' · ');
      h += '<div class="card mt as-banner" role="alert"><b>' + RG.icon('alert') + ' Trợ lý đã dọn nhưng máy vẫn thiếu chỗ.</b> <span class="small">' + esc(a.banner.message) + (ds ? ' ' + ds + '.' : '') + '</span>' +
        '<span class="sp"></span><button class="btn sm" data-bn="disk">Xem việc cần dọn</button> <button class="btn sm" data-bn="snooze">Hoãn 6 giờ</button></div>';
    }
    var prom = a && a.advice && a.advice.promote && a.advice.promote[0];
    if (prom) h += '<div class="card mt"><span class="small">' + RG.icon('spark') + ' Gợi ý: ' + esc(prom.reason) + '</span><span class="sp"></span><button class="btn sm" data-bn="settings">Xem ở Cài đặt</button></div>';
    if (mode !== 'off') h += '<div class="small mut" style="margin-top:8px;text-align:right">Chính sách tự động đang ' + (mode === 'on' ? 'Bật' : 'Chạy thử') + ' · <button class="btn sm danger" data-bn="panic" title="Tắt chính sách tự động và huỷ mọi job nền">Dừng khẩn cấp</button></div>';
    el.innerHTML = h;
    RG.$$('#hBanner [data-bn]').forEach(function (b) {
      b.onclick = function () {
        var k = b.dataset.bn;
        if (k === 'disk' || k === 'settings') RG.go(k);
        else if (k === 'snooze') RG.api('/api/autonomy/snooze', { method: 'POST', body: { hours: 6 } }).then(function () { return loadAut(); }).then(drawBanner).catch(function (e) { RG.toast(e.message, 'err'); });
        else if (k === 'panic' && RG.panic) RG.panic().then(function () { return loadAut(); }).then(drawBanner);
      };
    });
  }

  /* Dữ liệu chia đoạn cho thanh/donut: nhóm việc của RAM, phân tích từng ổ (lỗi → giữ thanh một màu). */
  function loadShares() {
    var ps = [RG.api('/api/processes').then(function (j) { H.wl = j.workloads || []; }).catch(function () { })];
    RG.driveList().forEach(function (d) { ps.push(RG.api('/api/disk?drive=' + encodeURIComponent(d.drive)).then(function (j) { H.disk[d.drive] = j.breakdown; }).catch(function () { })); });
    return Promise.all(ps);
  }
  RG.pages.home = {
    title: 'Tổng quan',
    render: function (el) {
      el.innerHTML = '<div id="hStatus"></div><div id="hBanner"></div><div id="hRes"></div><div id="hPlan"></div><div id="hAssist"></div><div id="hWeek"></div>';
      H.hover = null;
      drawStatus(); drawBanner(); drawRes(); drawPlan(); drawAssist(); drawWeek();
      this.refresh();
    },
    refresh: function () {
      Promise.all([RG.loadInsight().catch(function () { }), RG.loadAdvice().catch(function () { }), RG.loadEvents().catch(function () { }), RG.loadCands().catch(function () { }), RG.loadAuto().catch(function () { }), RG.loadPolicy().catch(function () { }), loadShares(), assistLoad(), loadAut()]).then(function () {
        if (RG.cur !== 'home') return; drawStatus(); drawBanner(); drawRes(); drawPlan(); drawAssist(); drawWeek();
        if (scanRunning()) assistPoll();
      });
    },
    jobs: function () { if (RG.cur === 'home') { drawPlan(); drawAssist(); } },
    live: function () { if (!$('#hStatus')) return; drawStatus(); drawRes(); }
  };
  RG.pages.overview = RG.pages.home;
})();
