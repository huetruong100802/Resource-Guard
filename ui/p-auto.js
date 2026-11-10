/* p-auto.js - Tự động hoá: "nó sẽ làm gì" (một câu) → "hiệu quả ra sao" (trước → sau, số lần chạm 14 ngày) → "tôi chỉnh thế nào" (kéo ngưỡng, công tắc theo nhóm). */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, GB = 1073741824;
  var OUT = { done: 'Đã xoá', skipped: 'Bỏ qua', failed: 'Thất bại', 'would-run': 'Sẽ chạy' };
  var MODEHELP = {
    'off': 'Không làm gì tự động. Bạn dọn tay ở trang Dọn dẹp.',
    'dry-run': 'Khi có áp lực, tiến trình nền chỉ ghi nhận việc SẼ làm (xem ở “Lượt tự dọn gần nhất”). Không xoá gì. Nên chạy chế độ này vài ngày trước khi bật thật.',
    'on': 'Khi có áp lực và hết thời gian nghỉ, tiến trình nền tự dọn đúng các nhóm đặt “Tự động”, tránh mọi thứ trong vùng bảo vệ. Cần PIN để bật/nới lỏng.'
  };
  var IMPACT = { 'temp-entry': 'Không ảnh hưởng; chương trình tự tạo lại khi cần', 'dotnet-artifact': 'Lần build kế tiếp của dự án chậm hơn vì build lại từ đầu', 'node_modules': 'Phải chạy lại lệnh cài gói trước khi chạy dự án; cần mạng',
    'cache-aged': 'Lần restore sau tải lại gói còn thiếu; cần mạng', 'stale-repo': 'Mã đã có trên remote, clone lại khi cần; có bản zip nếu chọn nén', 'large-item': 'Không tự tạo lại được; có bản zip nếu chọn nén', 'process': 'Tiến trình bị kết thúc; việc chưa lưu trong tiến trình đó sẽ mất', 'app': 'Chỉ báo cáo; Resource Guard không xoá loại này' };
  var SET = { auto: 'Tự động', ask: 'Hỏi tôi', keep: 'Luôn giữ' };
  var A = { drive: null, pv: null, pvBusy: false, timer: null, seq: 0 };
  // Ba mức sẵn: chỉ điền bản nháp (vẫn phải Lưu). Nhóm rủi ro cao (repo cũ, mục lớn, tiến trình) không bao giờ đặt "Tự động" ở mức sẵn.
  var PRESETS = {
    careful: { label: 'Thận trọng', diskTrigger: 'Critical', maxGBPerRun: 5, cooldownMin: 120, auto: ['temp-entry'] },
    balanced: { label: 'Cân bằng', diskTrigger: 'Critical', maxGBPerRun: 10, cooldownMin: 60, auto: ['temp-entry', 'dotnet-artifact'] },
    active: { label: 'Chủ động', diskTrigger: 'Caution', maxGBPerRun: 20, cooldownMin: 30, auto: ['temp-entry', 'dotnet-artifact', 'cache-aged'] }
  };

  function seg(name, val, opts, dis) { return RG.seg(name, val, opts, dis); }
  function tags(list, type) { return '<div class="tags">' + (list.length ? list.map(function (x) { return '<span class="tag"><span class="mono">' + esc(x) + '</span><button data-rm="' + type + '" data-v="' + esc(x) + '" aria-label="Gỡ ' + esc(x) + '">×</button></span>'; }).join('') : '<span class="small mut">Chưa có.</span>') + '</div>'; }
  function setDrive(p, L, key, val) { var o = p.drives[L] || {}; if (val == null) delete o[key]; else o[key] = val; if (Object.keys(o).length) p.drives[L] = o; else delete p.drives[L]; }
  function markDirty() { S.dirty = JSON.stringify(S.draft) !== JSON.stringify(S.policy); var b = $('#polBar'); if (b) b.hidden = !S.dirty; schedulePreview(); }
  function drvOf(p, L) { var o = (p.drives && p.drives[L]) || {}; return { trigger: o.diskTrigger || p.diskTrigger, target: o.targetFreeGB != null ? o.targetFreeGB : p.targetFreeGB }; }
  function thrOf(L) { return RG.diskThr(L); }
  function trigGB(level, L) { var t = thrOf(L); return level === 'Caution' ? t.normalAbove : (level === 'Critical' ? t.cautionFrom : 0); }
  function levelFor(v, L) {
    var t = thrOf(L), c = [['off', 0], ['Critical', t.cautionFrom], ['Caution', t.normalAbove]], best = c[0];
    c.forEach(function (x) { if (Math.abs(x[1] - v) < Math.abs(best[1] - v)) best = x; });
    return best[0];
  }
  function lc(s) { return s.charAt(0).toLowerCase() + s.slice(1); }
  function list(a) { return a.length <= 1 ? a.join('') : a.slice(0, -1).join(', ') + ' và ' + a[a.length - 1]; }

  /* ----- Khối 1: một câu ----- */
  function sentence(p, L) {
    var kinds = (S.kinds || []).filter(function (k) { return k !== 'process'; }), by = function (v) { return kinds.filter(function (k) { return p.categories[k] === v; }).map(function (k) { return lc(RG.human.kind(k).l); }); };
    var auto = by('auto'), ask = by('ask'), keep = by('keep'), d = drvOf(p, L), parts = [];
    if (!L) parts.push('Chưa có ổ nào để áp dụng.');
    else if (d.trigger === 'off') parts.push('Tôi không tự dọn file theo dung lượng ổ ' + L + '.');
    else {
      var t = trigGB(d.trigger, L);
      parts.push('Khi ổ ' + L + ' còn dưới <b>' + t + ' GB</b>, ' + (auto.length ? 'tôi dọn <b>' + esc(list(auto)) + '</b> cho tới khi trống <b>' + d.target + ' GB</b>, tối đa <b>' + p.maxGBPerRun + ' GB</b> mỗi lượt.' : 'tôi không tự dọn nhóm nào (mọi nhóm đang ở “Hỏi tôi” hoặc “Luôn giữ”).'));
    }
    if (ask.length) parts.push(esc(list(ask)).replace(/^./, function (c) { return c.toUpperCase(); }) + ': tôi hỏi bạn trước.');
    if (keep.length) parts.push(esc(list(keep)).replace(/^./, function (c) { return c.toUpperCase(); }) + ': luôn giữ.');
    if (p.ramTrigger !== 'off' && p.maxKillsPerRun > 0 && p.categories.process === 'auto') parts.push('Khi RAM xuống mức ' + RG.human.state(p.ramTrigger) + ', tôi kết thúc tối đa ' + p.maxKillsPerRun + ' tiến trình agent mồ côi.');
    var note = { off: 'Đang <b>Tắt</b>: chưa làm gì cả.', 'dry-run': 'Đang <b>Chạy thử</b>: chỉ ghi nhận việc sẽ làm, không xoá gì.', on: 'Đang <b>Bật</b>: sẽ dọn thật khi đủ điều kiện.' }[p.mode];
    return parts.join(' ') + ' <span class="mut">' + note + '</span>';
  }

  /* ----- Xem trước (debounce 300 ms) ----- */
  function schedulePreview() {
    if (A.timer) clearTimeout(A.timer);
    A.pvBusy = true; drawEffect();
    A.timer = setTimeout(function () {
      var seq = ++A.seq;
      RG.api('/api/auto/preview', { method: 'POST', body: { policy: S.draft } }).then(function (j) { if (seq !== A.seq) return; A.pv = j; A.pvBusy = false; drawEffect(); drawGroups(); })
        .catch(function (e) { if (seq !== A.seq) return; A.pvBusy = false; A.pv = { error: e.message }; drawEffect(); });
    }, 300);
  }
  function pvDrive(L) { return A.pv && A.pv.forced && ((A.pv.forced.perDrive || []).filter(function (d) { return d.drive === L; })[0]); }
  function drawEffect() {
    var el = $('#aEffect'); if (!el) return;
    var p = S.draft, L = A.drive, pv = A.pv; if (!p || !L) { el.innerHTML = ''; return; }
    var d = drvOf(p, L), t = thrOf(L), di = RG.driveInfo(L), thrNow = trigGB(d.trigger, L);
    var bar = '<div id="aBar"></div>';
    var txt = '';
    if (A.pvBusy && !pv) txt = '<span class="spin"></span> <span class="small mut">đang tính…</span>';
    else if (pv && pv.error) txt = '<div class="alert warn"><div class="small">Không xem trước được: ' + esc(pv.error) + '</div></div>';
    else if (pv) {
      var tr = ((pv.triggers14d || []).filter(function (x) { return x.drive === L; })[0]) || { count: 0 };
      txt = '<div class="small">' + (d.trigger === 'off' ? 'Ổ này đang tắt tự dọn nên không có lần kích hoạt.' : '14 ngày qua, ngưỡng này đã chạm <b>' + tr.count + ' lần</b>' + (tr.lastUtc ? ' (gần nhất ' + RG.timeAgo(tr.lastUtc) + ')' : '') + '.') + '</div>' +
        '<div class="small mut">Hiện tại: ' + esc((pv.now && pv.now.because) || '') + '</div>';
      var sel = (pv.forced && pv.forced.selected || []).filter(function (s) { return s.drive === L; }), g = {};
      sel.forEach(function (s) { var o = g[s.kind] = g[s.kind] || { n: 0, b: 0 }; o.n++; o.b += s.sizeBytes || 0; });
      var ks = Object.keys(g).sort(function (a, b) { return g[b].b - g[a].b; });
      txt += '<div class="a-list"><div class="small mut" style="margin:8px 0 4px">Nếu ổ ' + esc(L) + ' chạm ngưỡng ngay bây giờ, tôi sẽ dọn:</div>' +
        (ks.length ? ks.map(function (k) { return '<div class="a-row"><span>' + esc(RG.human.kind(k).l) + '</span><span class="mut small">' + g[k].n + ' mục</span><b class="num">' + RG.fmtBytes(g[k].b) + '</b></div>'; }).join('') : '<div class="small mut">Không có mục nào (nhóm “Tự động” trống hoặc không có gì đủ điều kiện).</div>') + '</div>' +
        (pv.forced && pv.forced.kills ? '<div class="small mut">Và kết thúc ' + pv.forced.kills + ' tiến trình agent mồ côi.</div>' : '');
    }
    el.innerHTML = '<div class="a-effect-top">' + bar + '</div>' + txt;
    var pd = pvDrive(L), tot = di ? (di.totalBytes || (di.totalGB ? di.totalGB * GB : 0)) : 0;
    if (di && tot) V.impactBar($('#aBar'), { totalBytes: tot, freeBytes: (pd ? pd.freeGB : di.freeGB) * GB, gainBytes: pd ? Math.max(0, (pd.afterGB - pd.freeGB) * GB) : 0, cautionBytes: t.cautionFrom * GB, normalBytes: t.normalAbove * GB, label: 'Ổ ' + L + ':' });
    drawChart();
  }
  function drawChart() {
    var svg = $('#aChart'); if (!svg || !A.drive) return;
    var L = A.drive, p = S.draft, d = drvOf(p, L), t = thrOf(L);
    A.hist = A.hist || {};
    if (!A.hist[L] || Date.now() - (A.histAt || 0) > 600000) {
      A.histAt = Date.now();
      RG.api('/api/drive/history?drive=' + encodeURIComponent(L) + '&days=14').then(function (j) { A.hist[L] = j.points || []; drawChart(); }).catch(function () { A.hist[L] = A.hist[L] || []; });
    }
    var dl = { v: trigGB(d.trigger, L), min: 0, max: t.normalAbove, step: Math.max(1, t.normalAbove - t.cautionFrom), label: 'Ngưỡng kích hoạt (kéo để đổi)', color: RG.css('--critical'),
      text: d.trigger === 'off' ? 'Không tự dọn' : 'Kích hoạt khi còn dưới ' + trigGB(d.trigger, L) + ' GB',
      onChange: function (v) {
        var lv = levelFor(v, L);
        if (lv !== drvOf(S.draft, L).trigger) { setDrive(S.draft, L, 'diskTrigger', lv === S.draft.diskTrigger ? null : lv); markDirty(); drawSentence(); }
        else drawChart();   // về lại vạch cũ (kéo chưa đủ gần mức khác)
      } };
    var data = A.hist[L] || [], fn;
    if (data.length < 2) { fn = function (h) { var x = (h.drives || []).filter(function (y) { return y.drive === L; })[0]; return x ? x.freeGB : null; }; data = S.hist; }   // chưa đủ lịch sử theo giờ: dùng số liệu của phiên này
    RG.lineChart(svg, data, { key: 'freeGB', fn: fn, color: RG.css('--disk'), min: 0, area: true, unit: ' GB', xfmt: RG.fmtLocal, dragLine: dl, lines: [{ v: d.target, c: RG.css('--normal') }] });
  }
  function drawSentence() { var s = $('#aSent'); if (s) s.innerHTML = sentence(S.draft, A.drive); }

  /* ----- Khối 3: từng nhóm ----- */
  function drawGroups() {
    var el = $('#aGroups'); if (!el) return; var p = S.draft; if (!p) return;
    var ev = {}; ((A.pv && A.pv.evidence) || []).forEach(function (e) { ev[e.kind] = e; });
    el.innerHTML = (S.kinds || []).map(function (k) {
      var kd = RG.human.kind(k), e = ev[k], cur = p.categories[k];
      var evid = e ? '<div class="small mut">' + e.dryRuns + ' lượt chạy thử: ' + e.items + ' mục, ' + RG.fmtBytes(e.bytes) + (e.sinceUtc ? ' (từ ' + esc(RG.fmtLocal(e.sinceUtc)) + ')' : '') + '</div>' : '<div class="small mut">Chưa có lượt chạy thử nào chọn nhóm này.</div>';
      var sug = e && cur === 'ask' && e.dryRuns >= 3 && k !== 'process' && k !== 'stale-repo' && k !== 'large-item' ? '<button class="btn sm" data-toauto="' + esc(k) + '">Chuyển sang Tự động</button> <span class="small mut">đã chạy thử ' + e.dryRuns + ' lần</span>' : '';
      return '<div class="card a-grp"><div class="a-gh"><b>' + esc(kd.l) + '</b>' + seg('cat:' + k, cur, [['auto', 'Tự động'], ['ask', 'Hỏi tôi'], ['keep', 'Luôn giữ']]) + '</div><div class="small">' + esc(IMPACT[k] || kd.d) + '</div>' + evid + (sug ? '<div style="margin-top:6px">' + sug + '</div>' : '') + '</div>';
    }).join('');
    bindGroups();
  }
  function bindGroups() {
    var p = S.draft;
    RG.$$('#aGroups [data-set]').forEach(function (b) { b.onclick = function () { p.categories[b.dataset.set.slice(4)] = b.dataset.val; markDirty(); drawSentence(); drawGroups(); }; });
    RG.$$('#aGroups [data-toauto]').forEach(function (b) { b.onclick = function () { p.categories[b.dataset.toauto] = 'auto'; markDirty(); drawSentence(); drawGroups(); }; });
  }

  /* ----- Lượt tự dọn gần nhất ----- */
  function drawAutoLast() {
    var el = $('#autoLast'); if (!el) return;
    var l = S.autoLast, j = S.jobs.auto, run = j && j.status === 'running';
    var h = '<div class="field" style="margin-top:0"><button class="btn" id="dryRun"' + (run ? ' disabled' : '') + '>' + RG.icon('play') + ' Chạy thử ngay (không xoá)</button>' + (run ? '<span class="spin"></span><span class="small mut">đang quét và mô phỏng…</span>' : '') + '</div>';
    if (!l) { el.innerHTML = h + '<p class="small mut">Chưa có lượt nào. “Chạy thử” cho bạn thấy engine SẼ chọn gì với chính sách hiện tại (giả định có áp lực), không xoá gì.</p>'; bindAuto(); return; }
    var rows = (l.items || []).map(function (r) { return '<tr><td>' + esc(RG.human.kind(r.kind).l) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td class="r num">' + (r.sizeBytes ? RG.fmtBytes(r.sizeBytes) : '') + '</td><td><span class="pill ' + (r.outcome === 'done' ? 'auto' : (r.outcome === 'failed' ? 'bad' : 'ask')) + '">' + (OUT[r.outcome] || esc(r.outcome)) + '</span></td><td class="small mut">' + esc(r.detail || '') + '</td></tr>'; }).join('');
    var sk = (l.skipped || []).map(function (r) { return '<tr><td>' + esc(RG.human.kind(r.kind).l) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td class="small mut">' + esc(r.reason) + '</td></tr>'; }).join('');
    var sd = ((l.stress && l.stress.drives) || []).filter(function (d) { return d && d.drive; });
    var diskTxt = sd.length ? 'Ổ ' + sd.map(function (d) { return esc(d.drive) + ': ' + esc(RG.human.state(d.state)) + ' (' + RG.fmtGB(d.freeGB) + ' trống' + (d.stress ? ', có áp lực' : '') + ')'; }).join('; ') : '';
    el.innerHTML = h + '<div class="small mut">Lượt ' + RG.timeAgo(l.finishedUtc) + ' · chế độ <b>' + esc(RG.human.modes[l.mode] || l.mode) + '</b> · kích hoạt: ' + esc(l.trigger) + ' · ' + diskTxt + ' · ' + l.candidateCount + ' mục có thể dọn · giải phóng ' + RG.fmtBytes(l.freedBytes) + '</div>' +
      (rows ? '<div class="tbl-wrap" style="margin-top:8px"><table><tbody>' + rows + '</tbody></table></div>' : '<p class="small mut">Không có mục nào được chọn.</p>') +
      (sk ? '<details style="margin-top:8px"><summary class="small" style="cursor:pointer">Mục bị bỏ qua (' + (l.skipped || []).length + ')</summary><div class="tbl-wrap" style="margin-top:6px"><table><tbody>' + sk + '</tbody></table></div></details>' : '');
    bindAuto();
  }
  function bindAuto() { var b = $('#dryRun'); if (b) b.onclick = function () { RG.startJob('/api/auto/run', {}, 'Đang chạy thử…').then(drawAutoLast).catch(function () { }); }; }

  /* ----- Trang ----- */
  function draw() {
    var el = $('#polBody'); if (!el) return;
    var p = S.draft; if (!p) { el.innerHTML = '<div class="empty">Đang tải…</div>'; return; }
    if (!p.drives || Array.isArray(p.drives)) p.drives = {};
    var dl = RG.driveList(); if (!A.drive || !dl.some(function (d) { return d.drive === A.drive; })) A.drive = dl[0] ? dl[0].drive : null;
    var noPin = p.mode === 'on' && !S.pinConfigured, L = A.drive, d = L ? drvOf(p, L) : { target: p.targetFreeGB };
    var tabs = dl.length > 1 ? '<span class="seg sm" role="group" aria-label="Chọn ổ">' + dl.map(function (x) { return '<button data-ad="' + esc(x.drive) + '" aria-pressed="' + (x.drive === L) + '">' + esc(x.drive) + ': ' + RG.fmtGB(x.freeGB) + '</button>'; }).join('') + '</span>' : '';
    var prio = p.priority.map(function (k, i) {
      return '<div class="prio"><span class="n">' + (i + 1) + '</span><span style="flex:1">' + esc(RG.human.kind(k).l) + ' ' + (p.categories[k] ? '<span class="pill ' + p.categories[k] + '">' + SET[p.categories[k]] + '</span>' : '') + '</span>' +
        '<button class="icon-btn" data-mv="' + i + '" data-d="-1" aria-label="Chuyển lên"' + (i === 0 ? ' disabled' : '') + '>' + RG.icon('up') + '</button><button class="icon-btn" data-mv="' + i + '" data-d="1" aria-label="Chuyển xuống"' + (i === p.priority.length - 1 ? ' disabled' : '') + '>' + RG.icon('down') + '</button></div>';
    }).join('');
    var drvRows = dl.map(function (x) {
      var o = p.drives[x.drive] || {};
      return '<tr><td><b>' + esc(x.drive) + ':</b>' + (x.label ? ' <span class="small mut">' + esc(x.label) + '</span>' : '') + '<div class="small mut">' + RG.fmtGB(x.freeGB) + ' trống</div></td>' +
        '<td>' + seg('dtrig:' + x.drive, o.diskTrigger || '', [['', 'Theo chung (' + RG.human.state(p.diskTrigger === 'off' ? 'Normal' : p.diskTrigger).replace('Ổn', 'không') + ')'], ['off', 'Không'], ['Caution', 'Cần chú ý'], ['Critical', 'Nguy cấp']]) + '</td>' +
        '<td class="r"><input type="number" min="1" max="10000" data-dnum="' + esc(x.drive) + '" value="' + (o.targetFreeGB != null ? o.targetFreeGB : '') + '" placeholder="' + p.targetFreeGB + '" aria-label="Dừng khi ổ ' + esc(x.drive) + ' đạt trống (GB)" style="width:90px"></td></tr>';
    }).join('');
    el.innerHTML =
      '<div class="card a-sent-card"><h2>Nó sẽ làm gì<span class="sp"></span>' + seg('mode', p.mode, [['off', 'Tắt'], ['dry-run', 'Chạy thử'], ['on', 'Bật']]) + '</h2>' +
      '<p class="a-sent" id="aSent">' + sentence(p, L) + '</p><p class="hint">' + esc(MODEHELP[p.mode]) + '</p>' +
      (noPin ? '<div class="alert warn" style="margin-top:8px"><div>Chưa đặt PIN. Chạy ở terminal: <span class="mono">rg pin</span> (hoặc <span class="mono">powershell -File scripts\\resource-manager.ps1 serve setpin</span>) rồi quay lại lưu.</div></div>' : '') +
      '<div class="field" style="margin-bottom:0"><span class="small mut">Điền nhanh:</span>' + Object.keys(PRESETS).map(function (k) { return '<button class="btn sm" data-preset="' + k + '">' + PRESETS[k].label + '</button>'; }).join('') + '<span class="small mut">chỉ điền bản nháp, bạn vẫn phải Lưu.</span></div></div>' +
      '<div class="card mt"><h2>Hiệu quả ra sao<span class="sp"></span>' + tabs + '</h2>' +
      '<div class="a-effect"><div><div class="small mut" style="margin-bottom:2px">Dung lượng trống ổ ' + esc(L || '') + ' 14 ngày qua. <b>Kéo đường đỏ</b> (hoặc dùng phím mũi tên) để đổi ngưỡng kích hoạt; đường xanh là mục tiêu.</div><svg id="aChart" class="chart tall" role="img" aria-label="Dung lượng trống 14 ngày với ngưỡng kích hoạt kéo được"></svg>' +
      '<div class="field"><label for="aTarget" style="min-width:auto">Dừng khi trống</label><input id="aTarget" type="range" min="' + Math.max(1, Math.round(trigGB(d.trigger === 'off' ? 'Critical' : d.trigger, L || 'C')) + 1) + '" max="200" step="1" value="' + Math.min(200, d.target) + '" style="flex:1;min-width:140px" aria-label="Mục tiêu dung lượng trống (GB)"><b class="num" id="aTargetV">' + d.target + ' GB</b></div></div>' +
      '<div id="aEffect"></div></div></div>' +
      '<div class="a-groups-h mt"><h2 class="sec">Từng nhóm</h2><span class="small mut">Tự động: dọn khi có áp lực · Hỏi tôi: chỉ hiện ở trang Dọn dẹp · Luôn giữ: không bao giờ đụng tới</span></div><div class="grid g3" id="aGroups"></div>' +
      '<div class="card mt"><h2>Lượt tự dọn gần nhất</h2><div id="autoLast"></div></div>' +
      '<details class="card mt" id="aAdv"' + (A.advOpen ? ' open' : '') + '><summary class="h-sum">Nâng cao <span class="mut small">nghỉ giữa hai lượt, giới hạn mỗi lượt, thứ tự ưu tiên, theo từng ổ, vùng bảo vệ</span></summary>' +
      '<div class="grid g2" style="margin-top:10px"><div class="card"><h2>Giới hạn</h2>' +
      '<div class="field"><label>RAM (kết thúc tiến trình) từ mức</label>' + seg('ramTrigger', p.ramTrigger, [['off', 'Không'], ['Restricted', 'Hạn chế'], ['Critical', 'Nguy cấp']]) + '</div>' +
      '<div class="field"><label for="fCool">Nghỉ giữa hai lượt (phút)</label><input id="fCool" data-num="cooldownMin" type="number" min="1" max="1440" value="' + p.cooldownMin + '"></div>' +
      '<div class="field"><label for="fMax">Tối đa mỗi lượt (GB)</label><input id="fMax" data-num="maxGBPerRun" type="number" min="0.1" max="500" step="0.5" value="' + p.maxGBPerRun + '"></div>' +
      '<div class="field"><label for="fTgt">Dừng khi ổ đĩa đạt trống (GB, chung)</label><input id="fTgt" data-num="targetFreeGB" type="number" min="1" max="1000" value="' + p.targetFreeGB + '"></div>' +
      '<div class="field"><label for="fKill">Tối đa tiến trình kết thúc / lượt</label><input id="fKill" data-num="maxKillsPerRun" type="number" min="0" max="50" value="' + p.maxKillsPerRun + '"></div></div>' +
      '<div class="card"><h2>Thứ tự ưu tiên khi dọn</h2>' + prio + '<p class="hint">Nhóm ở trên được dọn trước; trong cùng nhóm, mục lớn hơn dọn trước.</p></div></div>' +
      (dl.length ? '<div class="card mt"><h2>Theo từng ổ đĩa</h2><table><thead><tr><th>Ổ</th><th>Kích hoạt từ mức</th><th class="r">Dừng khi trống (GB)</th></tr></thead><tbody>' + drvRows + '</tbody></table><p class="hint">Mỗi ổ được đánh giá riêng; “Theo chung” dùng giá trị chung. Giới hạn “Tối đa mỗi lượt” tính riêng cho từng ổ.</p>' + ((S.roots || []).length ? '<p class="hint">Thư mục mã nguồn tool nhận diện: <span class="mono">' + (S.roots || []).map(esc).join(' · ') + '</span></p>' : '') + '</div>' : '') +
      '<div class="card mt"><h2>Vùng bảo vệ (tránh khi tự dọn)</h2><div class="field" style="margin-top:0"><label for="addPath" style="min-width:auto">Thư mục</label><input id="addPath" type="text" placeholder="C:\\Users\\bạn\\Work\\dự-án-quan-trọng" style="flex:1;min-width:200px"><button class="btn sm" id="addPathBtn">Thêm</button></div>' + tags(p.protectPaths, 'path') +
      '<div class="field"><label for="addProc" style="min-width:auto">Tiến trình</label><input id="addProc" type="text" placeholder="vd: sqlservr, devenv, node*" style="flex:1;min-width:200px"><button class="btn sm" id="addProcBtn">Thêm</button></div>' + tags(p.protectProcesses, 'proc') +
      '<p class="hint">Mục nằm trong (hoặc chứa) thư mục bảo vệ, và tiến trình khớp tên (hỗ trợ * ?), sẽ bị engine bỏ qua kể cả khi nhóm đặt “Tự động”. Thêm bảo vệ không cần PIN.</p></div></details>' +
      '<div class="sticky-bar" id="polBar" ' + (S.dirty ? '' : 'hidden') + '><b>Có thay đổi chưa lưu</b><span class="small mut" id="polPin"></span><span style="flex:1"></span><button class="btn" id="polReset">Hoàn tác</button><button class="btn primary" id="polSave">Lưu chính sách</button></div>';
    bind(p); drawGroups(); drawAutoLast(); drawEffect();
    if (!A.pv && !A.pvBusy) schedulePreview();
  }
  function bind(p) {
    $('#aAdv').ontoggle = function () { A.advOpen = $('#aAdv').open; };
    RG.$$('#polBody [data-ad]').forEach(function (b) { b.onclick = function () { A.drive = b.dataset.ad; draw(); }; });
    RG.$$('#polBody [data-preset]').forEach(function (b) {
      b.onclick = function () {
        var ps = PRESETS[b.dataset.preset];
        p.diskTrigger = ps.diskTrigger; p.maxGBPerRun = ps.maxGBPerRun; p.cooldownMin = ps.cooldownMin;
        (S.kinds || []).forEach(function (k) { p.categories[k] = ps.auto.indexOf(k) >= 0 ? 'auto' : (p.categories[k] === 'keep' ? 'keep' : 'ask'); });
        p.drives = {}; markDirty(); draw(); RG.toast('Đã điền mức “' + ps.label + '” vào bản nháp. Bấm Lưu để áp dụng.', 'ok');
      };
    });
    RG.$$('#polBody [data-set]').forEach(function (b) {
      if (b.closest('#aGroups')) return;
      b.onclick = function () {
        var n = b.dataset.set;
        if (n.indexOf('dtrig:') === 0) setDrive(p, n.slice(6), 'diskTrigger', b.dataset.val || null);
        else p[n] = b.dataset.val;
        markDirty(); draw();
      };
    });
    var tg = $('#aTarget');
    if (tg) { tg.oninput = function () { var v = +tg.value; setDrive(p, A.drive, 'targetFreeGB', v === p.targetFreeGB ? null : v); $('#aTargetV').textContent = v + ' GB'; markDirty(); drawSentence(); drawChart(); }; }
    RG.$$('#polBody [data-dnum]').forEach(function (inp) { inp.onchange = function () { var v = parseFloat(inp.value); setDrive(p, inp.dataset.dnum, 'targetFreeGB', isNaN(v) ? null : Math.max(1, Math.min(10000, v))); markDirty(); draw(); }; });
    RG.$$('#polBody [data-num]').forEach(function (inp) { inp.onchange = function () { var v = parseFloat(inp.value); if (!isNaN(v)) p[inp.dataset.num] = v; markDirty(); drawSentence(); }; });
    RG.$$('#polBody [data-mv]').forEach(function (b) { b.onclick = function () { var i = +b.dataset.mv, j = i + +b.dataset.d, a = p.priority; var t = a[i]; a[i] = a[j]; a[j] = t; markDirty(); draw(); }; });
    RG.$$('#polBody [data-rm]').forEach(function (b) { b.onclick = function () { var k = b.dataset.rm === 'path' ? 'protectPaths' : 'protectProcesses'; p[k] = p[k].filter(function (x) { return x !== b.dataset.v; }); markDirty(); draw(); }; });
    function addTag(inputId, key, valid) {
      var v = $(inputId).value.trim(); if (!v) return;
      if (valid && !valid(v)) { RG.toast('Giá trị không hợp lệ.', 'err'); return; }
      if (p[key].some(function (x) { return x.toLowerCase() === v.toLowerCase(); })) return;
      p[key].push(key === 'protectProcesses' ? v.toLowerCase() : v); A.advOpen = true; markDirty(); draw();
    }
    $('#addPathBtn').onclick = function () { addTag('#addPath', 'protectPaths', function (v) { return /^[A-Za-z]:\\.{2,}/.test(v) || /^%[A-Za-z_]+%\\/.test(v); }); };
    $('#addProcBtn').onclick = function () { addTag('#addProc', 'protectProcesses', function (v) { return /^[\w.*?\- ]{1,60}$/.test(v); }); };
    $('#addPath').onkeydown = function (e) { if (e.key === 'Enter') $('#addPathBtn').click(); };
    $('#addProc').onkeydown = function (e) { if (e.key === 'Enter') $('#addProcBtn').click(); };
    $('#polReset').onclick = function () { S.draft = RG.clone(S.policy); S.dirty = false; A.pv = null; draw(); };
    $('#polSave').onclick = function () {
      var btn = $('#polSave'); btn.disabled = true;
      RG.savePolicy(S.draft).then(function (j) { S.draft = RG.clone(j.policy); S.dirty = false; RG.toast('Đã lưu chính sách.', 'ok'); A.pv = null; draw(); })
        .catch(function (e) { RG.toast(e.message, 'err'); btn.disabled = false; });
    };
  }
  RG.pages.policy = {
    title: 'Tự động hoá',
    render: function (el) { el.innerHTML = '<div id="polBody"><div class="empty">Đang tải…</div></div>'; A.pv = null; draw(); this.refresh(); },
    refresh: function () { Promise.all([RG.loadPolicy(), RG.loadDrives().catch(function () { })]).then(function () { if (RG.cur === 'policy') draw(); }); RG.loadAuto().then(drawAutoLast).catch(function () { }); },
    jobs: function () { if (RG.cur === 'policy') drawAutoLast(); },
    live: function () { }
  };
})();
