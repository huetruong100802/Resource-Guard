/* p-overview.js - Cài đặt: ngưỡng trạng thái (sửa được), chu kỳ lấy mẫu, khởi động + PIN, tự động hoá nâng cao, an toàn, giao diện.
   Trang chủ ở p-home.js, Ổ đĩa ở p-disk.js, Bộ nhớ ở p-proc.js. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;
  var SET = { auto: 'Tự động', ask: 'Hỏi tôi', keep: 'Luôn giữ' };

  /* ---------- Ngưỡng trạng thái ---------- */
  var THR = [
    ['ramAvailGB', 'RAM trống (GB)', [['normalAbove', 'Bình thường khi trên'], ['cautionFrom', 'Cần chú ý từ'], ['restrictedFrom', 'Hạn chế từ']], 'Dưới mức “Hạn chế” là Nguy cấp.'],
    ['diskFreeGB', 'Ổ đĩa trống (GB)', [['normalAbove', 'Bình thường khi trên'], ['cautionFrom', 'Cần chú ý từ']], 'Dưới mức “Cần chú ý” là Nguy cấp.'],
    ['commitPct', 'Bộ nhớ cam kết (%)', [['restricted', 'Hạn chế từ'], ['critical', 'Nguy cấp từ']], 'Càng cao càng gần hết bộ nhớ ảo.']
  ];
  function thrCard() {
    var t = S.thr; if (!t) return '';
    var rows = THR.map(function (g) {
      return '<div class="thr-g"><b>' + esc(g[1]) + '</b>' + g[2].map(function (f) {
        var v = t[g[0]] && t[g[0]][f[0]];
        return '<div class="field"><label for="th_' + g[0] + '_' + f[0] + '">' + esc(f[1]) + '</label><input id="th_' + g[0] + '_' + f[0] + '" data-g="' + g[0] + '" data-f="' + f[0] + '" type="number" min="0" step="any" value="' + (v == null ? '' : v) + '"></div>';
      }).join('') + '<div class="small mut">' + esc(g[3]) + '</div></div>';
    }).join('');
    return '<div class="card"><h2>Ngưỡng trạng thái</h2>' + rows +
      '<div class="field"><button class="btn primary" id="thrSave">Lưu ngưỡng</button></div><div id="thrMsg" class="small" role="status"></div>' +
      '<p class="hint">Trạng thái lên mức xấu hơn ngay, về mức tốt hơn sau khoảng 45 giây ổn định để không nhấp nháy. Nới lỏng ngưỡng khi tự động hoá đang Bật cần PIN.</p></div>';
  }
  function saveThr(pin) {
    var body = { thresholds: {} }, bad = false;
    RG.$$('[data-g]').forEach(function (inp) {
      var v = parseFloat(inp.value); if (isNaN(v)) { bad = true; return; }
      var g = inp.dataset.g; body.thresholds[g] = body.thresholds[g] || {}; body.thresholds[g][inp.dataset.f] = v;
    });
    var msg = $('#thrMsg');
    if (bad) { msg.className = 'small warn'; msg.textContent = 'Mỗi ô cần một số.'; return; }
    if (pin) body.pin = pin;
    RG.api('/api/settings', { method: 'POST', body: body }).then(function (j) {
      S.thr = j.thresholds; if (S.settings) S.settings.thresholds = j.thresholds;
      msg.className = 'small ok'; msg.textContent = 'Đã lưu ngưỡng. Có hiệu lực ngay.';
    }).catch(function (e) {
      var c = e.data && e.data.code;
      if (c === 'pin-required' || c === 'pin-wrong') { RG.askPin(c === 'pin-wrong' ? 'PIN không đúng. Nhập lại:' : 'Nới lỏng ngưỡng khi tự động hoá đang Bật cần PIN.').then(function (p) { if (p) saveThr(p); else { msg.className = 'small warn'; msg.textContent = 'Đã huỷ.'; } }); return; }
      msg.className = 'small warn'; msg.textContent = 'Không lưu được: ' + e.message;
    });
  }

  /* ---------- Tự động hoá nâng cao (chuyển từ p-auto.js) ---------- */
  function tags(list, type) { return '<div class="tags">' + (list.length ? list.map(function (x) { return '<span class="tag"><span class="mono">' + esc(x) + '</span><button data-rm="' + type + '" data-v="' + esc(x) + '" aria-label="Gỡ ' + esc(x) + '">×</button></span>'; }).join('') : '<span class="small mut">Chưa có.</span>') + '</div>'; }
  function setDrive(p, L, key, val) { var o = p.drives[L] || {}; if (val == null) delete o[key]; else o[key] = val; if (Object.keys(o).length) p.drives[L] = o; else delete p.drives[L]; }
  function markDirty() { S.dirty = JSON.stringify(S.draft) !== JSON.stringify(S.policy); var b = $('#polBar'); if (b) b.classList.toggle('show', !!S.dirty); }

  function drawAdv() {
    var el = $('#polBody'); if (!el) return;
    var p = S.draft; if (!p) { RG.empty(el, { compact: true, title: 'Đang tải…' }); return; }
    if (!p.drives || Array.isArray(p.drives)) p.drives = {};
    var dl = RG.driveList();
    var prio = p.priority.map(function (k, i) {
      return '<div class="prio"><span class="n">' + (i + 1) + '</span><span style="flex:1">' + esc(RG.human.kind(k).l) + ' ' + (p.categories[k] ? '<span class="pill ' + p.categories[k] + '">' + SET[p.categories[k]] + '</span>' : '') + '</span>' +
        '<button class="icon-btn" data-mv="' + i + '" data-d="-1" aria-label="Chuyển lên"' + (i === 0 ? ' disabled' : '') + '>' + RG.icon('up') + '</button><button class="icon-btn" data-mv="' + i + '" data-d="1" aria-label="Chuyển xuống"' + (i === p.priority.length - 1 ? ' disabled' : '') + '>' + RG.icon('down') + '</button></div>';
    }).join('');
    var drvRows = dl.map(function (x) {
      var o = p.drives[x.drive] || {};
      return '<tr><td><b>' + esc(x.drive) + ':</b>' + (x.label ? ' <span class="small mut">' + esc(x.label) + '</span>' : '') + '<div class="small mut">' + RG.fmtGB(x.freeGB) + ' trống</div></td>' +
        '<td>' + RG.seg('dtrig:' + x.drive, o.diskTrigger || '', [['', 'Theo chung'], ['off', 'Không'], ['Caution', 'Cần chú ý'], ['Critical', 'Nguy cấp']]) + '</td>' +
        '<td class="r"><input type="number" min="1" max="10000" data-dnum="' + esc(x.drive) + '" value="' + (o.targetFreeGB != null ? o.targetFreeGB : '') + '" placeholder="' + p.targetFreeGB + '" aria-label="Dừng khi ổ ' + esc(x.drive) + ' đạt trống (GB)" style="width:90px"></td></tr>';
    }).join('');
    el.innerHTML =
      '<div class="grid g2"><div class="card"><h2>Giới hạn mỗi lượt</h2>' +
      '<div class="field"><label>RAM (kết thúc tiến trình) từ mức</label>' + RG.seg('ramTrigger', p.ramTrigger, [['off', 'Không'], ['Restricted', 'Hạn chế'], ['Critical', 'Nguy cấp']]) + '</div>' +
      '<div class="field"><label for="fCool">Nghỉ giữa hai lượt (phút)</label><input id="fCool" data-num="cooldownMin" type="number" min="1" max="1440" value="' + p.cooldownMin + '"></div>' +
      '<div class="field"><label for="fMax">Tối đa mỗi lượt (GB)</label><input id="fMax" data-num="maxGBPerRun" type="number" min="0.1" max="500" step="0.5" value="' + p.maxGBPerRun + '"></div>' +
      '<div class="field"><label for="fTgt">Dừng khi ổ đĩa đạt trống (GB, chung)</label><input id="fTgt" data-num="targetFreeGB" type="number" min="1" max="1000" value="' + p.targetFreeGB + '"></div>' +
      '<div class="field"><label for="fKill">Tối đa tiến trình kết thúc / lượt</label><input id="fKill" data-num="maxKillsPerRun" type="number" min="0" max="50" value="' + p.maxKillsPerRun + '"></div></div>' +
      '<div class="card"><h2>Thứ tự ưu tiên khi dọn' + RG.help('Nhóm ở trên được dọn trước; trong cùng nhóm, mục lớn hơn dọn trước.') + '</h2>' + prio + '</div></div>' +
      (dl.length ? '<div class="card mt"><h2>Theo từng ổ đĩa' + RG.help('Mỗi ổ được đánh giá riêng; “Theo chung” dùng giá trị chung. Giới hạn mỗi lượt tính riêng cho từng ổ.') + '</h2><table><thead><tr><th>Ổ</th><th>Kích hoạt từ mức</th><th class="r">Dừng khi trống (GB)</th></tr></thead><tbody>' + drvRows + '</tbody></table>' + ((S.roots || []).length ? '<p class="hint">Thư mục mã nguồn nhận diện: <span class="mono">' + (S.roots || []).map(esc).join(' · ') + '</span></p>' : '') + '</div>' : '') +
      '<div class="card mt"><h2>Vùng bảo vệ (tránh khi tự dọn)' + RG.help('Mục nằm trong (hoặc chứa) thư mục bảo vệ, và tiến trình khớp tên (hỗ trợ * ?), bị bỏ qua kể cả khi nhóm đặt “Tự động”. Thêm bảo vệ không cần PIN.') + '</h2><div class="field" style="margin-top:0"><label for="addPath" style="min-width:auto">Thư mục</label><input id="addPath" type="text" placeholder="C:\\Users\\bạn\\Work\\dự-án-quan-trọng" style="flex:1;min-width:200px"><button class="btn sm" id="addPathBtn">Thêm</button></div>' + tags(p.protectPaths, 'path') +
      '<div class="field"><label for="addProc" style="min-width:auto">Tiến trình</label><input id="addProc" type="text" placeholder="vd: sqlservr, devenv, node*" style="flex:1;min-width:200px"><button class="btn sm" id="addProcBtn">Thêm</button></div>' + tags(p.protectProcesses, 'proc') + '</div>' +
      '<div class="savebar' + (S.dirty ? ' show' : '') + '" id="polBar"><b>Chính sách đã đổi</b><span class="small mut">chưa áp dụng cho tới khi Lưu</span><span class="sp"></span><button class="btn" id="polReset">Huỷ</button><button class="btn primary" id="polSave">Lưu</button></div>';
    bindAdv(p);
  }
  function bindAdv(p) {
    RG.$$('#polBody [data-set]').forEach(function (b) {
      b.onclick = function () { var n = b.dataset.set; if (n.indexOf('dtrig:') === 0) setDrive(p, n.slice(6), 'diskTrigger', b.dataset.val || null); else p[n] = b.dataset.val; markDirty(); drawAdv(); };
    });
    RG.$$('#polBody [data-dnum]').forEach(function (inp) { inp.onchange = function () { var v = parseFloat(inp.value); setDrive(p, inp.dataset.dnum, 'targetFreeGB', isNaN(v) ? null : Math.max(1, Math.min(10000, v))); markDirty(); drawAdv(); }; });
    RG.$$('#polBody [data-num]').forEach(function (inp) { inp.onchange = function () { var v = parseFloat(inp.value); if (!isNaN(v)) p[inp.dataset.num] = v; markDirty(); }; });
    RG.$$('#polBody [data-mv]').forEach(function (b) { b.onclick = function () { var i = +b.dataset.mv, j = i + +b.dataset.d, a = p.priority; var t = a[i]; a[i] = a[j]; a[j] = t; markDirty(); drawAdv(); }; });
    RG.$$('#polBody [data-rm]').forEach(function (b) { b.onclick = function () { var k = b.dataset.rm === 'path' ? 'protectPaths' : 'protectProcesses'; p[k] = p[k].filter(function (x) { return x !== b.dataset.v; }); markDirty(); drawAdv(); }; });
    function addTag(inputId, key, valid) {
      var v = $(inputId).value.trim(); if (!v) return;
      if (valid && !valid(v)) { RG.toast('Giá trị không hợp lệ.', 'err'); return; }
      if (p[key].some(function (x) { return x.toLowerCase() === v.toLowerCase(); })) return;
      p[key].push(key === 'protectProcesses' ? v.toLowerCase() : v); markDirty(); drawAdv();
    }
    $('#addPathBtn').onclick = function () { addTag('#addPath', 'protectPaths', function (v) { return /^[A-Za-z]:\\.{2,}/.test(v) || /^%[A-Za-z_]+%\\/.test(v); }); };
    $('#addProcBtn').onclick = function () { addTag('#addProc', 'protectProcesses', function (v) { return /^[\w.*?\- ]{1,60}$/.test(v); }); };
    $('#addPath').onkeydown = function (e) { if (e.key === 'Enter') $('#addPathBtn').click(); };
    $('#addProc').onkeydown = function (e) { if (e.key === 'Enter') $('#addProcBtn').click(); };
    $('#polReset').onclick = function () { S.draft = RG.clone(S.policy); S.dirty = false; drawAdv(); };
    $('#polSave').onclick = function () {
      var btn = $('#polSave'); btn.disabled = true;
      RG.savePolicy(S.draft).then(function (j) { S.draft = RG.clone(j.policy); S.dirty = false; RG.toast('Đã lưu chính sách.', 'ok'); drawAdv(); })
        .catch(function (e) { RG.toast(e.message, 'err'); btn.disabled = false; });
    };
  }

  /* ---------- Mức tự chủ của trợ lý (E2/E4) ----------
     Mỗi nhóm việc có mức L0 Tắt · L1 Đề xuất · L2 Chờ duyệt · L3 Tự động. File cá nhân và tiến trình bị chặn trần L2. Hạ mức luôn được; nâng lên L3 cần PIN.
     Server là nơi quyết định (cap, PIN); UI chỉ hiện và gửi { group, level, pin }. */
  var LVN = { L0: 'Tắt', L1: 'Đề xuất', L2: 'Chờ duyệt', L3: 'Tự động' };
  var AU = { data: null };
  function loadAut() { return RG.api('/api/autonomy').then(function (j) { AU.data = j; }).catch(function () { }); }
  function syncDraftAut() { return RG.loadPolicy().then(function () { if (S.draft && S.policy) S.draft.autonomy = RG.clone(S.policy.autonomy || {}); }).catch(function () { }); }
  function drawAut() {
    var el = $('#autCard'); if (!el) return;
    var d = AU.data;
    if (!d) { el.innerHTML = '<div class="card"><h2>Mức tự chủ của trợ lý</h2><div class="small mut">Đang tải…</div></div>'; return; }
    var rows = (d.groups || []).map(function (g) {
      return '<div class="au-row"><div class="au-name"><b>' + esc(g.label) + '</b>' + (g.source === 'legacy' ? ' <span class="pill" title="Chưa chọn mức riêng: đang theo cài đặt nhóm cũ">theo cài đặt cũ</span>' : (g.source === 'default' ? ' <span class="pill" title="Mức mặc định">mặc định</span>' : '')) +
        '<div class="small mut">' + esc(g.text) + '</div></div><span class="seg sm" role="group" aria-label="Mức của ' + esc(g.label) + '">' +
        g.levels.map(function (l) { return '<button data-aug="' + esc(g.id) + '" data-alv="' + l.level + '" aria-pressed="' + (g.level === l.level) + '" title="' + esc(l.text) + '">' + LVN[l.level] + '</button>'; }).join('') + '</span></div>';
    }).join('');
    var adv = d.advice || { promote: [], demote: [] };
    var pro = (adv.promote || []).map(function (a) {
      return '<div class="au-adv"><span>' + RG.icon('spark') + ' Đề nghị nâng <b>' + esc(a.label) + '</b> lên ' + LVN[a.to] + ': ' + esc(a.reason) + '</span><button class="btn sm primary" data-aprom="' + esc(a.group) + '" data-ato="' + a.to + '">Cấp' + (a.needsPin ? ' (cần PIN)' : '') + '</button></div>';
    }).join('');
    var dem = (d.demotions || []).slice(-3).map(function (x) { return '<div class="small mut">Đã tự hạ ' + esc(x.group) + ' ' + esc(x.from) + ' → ' + esc(x.to) + ': ' + esc(x.reason) + '</div>'; }).join('');
    el.innerHTML = '<div class="card"><h2>Mức tự chủ của trợ lý' + RG.help('L0 Tắt: không đụng tới. L1 Đề xuất: chỉ báo cáo. L2 Chờ duyệt: chuẩn bị sẵn, bạn bấm một lần. L3 Tự động: tự làm khi máy có áp lực, trong ngân sách. File cá nhân và tiến trình tối đa L2. Nâng lên L3 cần PIN; hạ thì không.') +
      '<span class="sp"></span><button class="btn sm danger" id="autPanic" title="Tắt chính sách tự động và huỷ mọi job nền của Resource Guard">Dừng khẩn cấp</button></h2>' +
      '<p class="hint">Chính sách hiện ' + (d.mode === 'on' ? '<b>Bật</b>' : (d.mode === 'dry-run' ? '<b>Chạy thử</b> (chưa xoá gì)' : '<b>Tắt</b>')) + '. Mức L3 chỉ có hiệu lực khi chính sách đang Bật; ở Chạy thử trợ lý chỉ ghi lại việc SẼ làm.</p>' +
      pro + '<div class="au-list">' + rows + '</div>' + dem + '</div>';
    RG.$$('#autCard [data-aug]').forEach(function (b) { b.onclick = function () { if (b.getAttribute('aria-pressed') !== 'true') setLevel(b.dataset.aug, b.dataset.alv); }; });
    RG.$$('#autCard [data-aprom]').forEach(function (b) { b.onclick = function () { setLevel(b.dataset.aprom, b.dataset.ato); }; });
    var pb = $('#autPanic'); if (pb) pb.onclick = function () { RG.panic(); };
  }
  function setLevel(g, lv, pin) {
    return RG.api('/api/autonomy/level', { method: 'POST', body: { group: g, level: lv, pin: pin || '' } }).then(function () {
      RG.toast('Đã đặt mức ' + LVN[lv] + '.', 'ok'); return Promise.all([loadAut(), syncDraftAut()]);
    }).then(function () { drawAut(); }).catch(function (e) {
      var c = e.data && e.data.code;
      if (c === 'pin-required' || c === 'pin-wrong') return RG.askPin(c === 'pin-wrong' ? 'PIN không đúng. Nhập lại:' : 'Nâng lên mức Tự động cần PIN.').then(function (p) { if (p) return setLevel(g, lv, p); });
      RG.toast(e.message, 'err', 9000);
    });
  }
  /* Dừng khẩn cấp: dùng chung cho Cài đặt và Tổng quan. Tắt chính sách + huỷ job nền; không cần PIN. */
  RG.panic = function () {
    return RG.confirm('Dừng khẩn cấp?', '<p>Resource Guard sẽ <b>tắt chính sách tự động</b> và <b>huỷ mọi việc nền đang chạy</b> (quét, dọn, đánh giá). Việc đã dọn xong không bị hoàn tác. Bật lại chính sách cần PIN.</p>', 'Dừng ngay', true).then(function (ok) {
      if (!ok) return;
      return RG.api('/api/panic', { method: 'POST', body: {} }).then(function (j) {
        RG.toast('Đã dừng khẩn cấp: chính sách → Tắt; huỷ ' + ((j.stopped || []).length) + ' việc nền.', 'ok', 8000);
        return RG.loadPolicy().catch(function () { });
      }).then(function () { if (RG.pages[RG.cur] && RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh(); }).catch(function (e) { RG.toast(e.message, 'err', 9000); });
    });
  };

  RG.pages.settings = {
    title: 'Cài đặt',
    render: function (el) {
      var s = S.settings || { intervalSec: 15, minSec: 2, maxSec: 300, defaultSec: 15 };
      el.innerHTML = '<div class="grid g2">' + thrCard() + '<div class="card"><h2>Chu kỳ lấy mẫu</h2>' +
        '<div class="field"><label for="iv">Lấy mẫu mỗi (giây)</label><input id="iv" type="number" min="' + s.minSec + '" max="' + s.maxSec + '" step="1" value="' + s.intervalSec + '"><button class="btn primary" id="ivSave">Lưu</button></div>' +
        '<div class="field">' + [5, 15, 30, 60].map(function (v) { return '<button class="btn sm" data-v="' + v + '">' + v + 's' + (v === s.defaultSec ? ' (mặc định)' : '') + '</button>'; }).join('') + '</div>' +
        '<p class="hint">Từ ' + s.minSec + ' đến ' + s.maxSec + ' giây, có hiệu lực ngay. Chu kỳ ngắn phản ứng nhanh hơn nhưng tốn CPU hơn một chút.</p><div id="ivMsg" class="small" role="status"></div></div>' +
        '<div class="card"><h2>Khởi động và PIN</h2><div id="setupTog"></div><p class="hint">PIN (để bật tự dọn thật) chỉ đặt được ở terminal: <span class="mono">rg pin</span>. ' + (S.pinConfigured ? '<span class="pill auto">PIN đã đặt</span>' : '<span class="pill ask">chưa đặt PIN</span>') + '</p></div>' +
        '<div class="card"><h2>An toàn</h2><ul class="small" style="margin:0;padding-left:18px"><li>Chỉ nghe <b>localhost</b>; mọi thao tác ghi cần header riêng.</li><li>Giao diện chỉ gửi <b>key</b> của mục dọn; engine kiểm lại allowlist trước khi xoá.</li><li>Không kết thúc ứng dụng của bạn; chỉ hạ ưu tiên CPU (đảo ngược được). Trợ lý AI chỉ nhận metadata.</li></ul></div>' +
        '<div class="card"><h2>Giao diện</h2><div class="field"><label>Chủ đề</label><span class="seg" role="group" aria-label="Chủ đề"><button data-th="auto">Theo hệ thống</button><button data-th="light">Sáng</button><button data-th="dark">Tối</button></span></div></div></div>' +
        '<div id="autCard" class="mt"></div><h2 class="sec-h">Tự động hoá nâng cao</h2><div id="polBody"></div>';
      RG.setup.toggles($('#setupTog'));
      var ts = $('#thrSave'); if (ts) ts.onclick = function () { saveThr(); };
      RG.$$('[data-v]').forEach(function (b) { b.onclick = function () { $('#iv').value = b.dataset.v; }; });
      $('#ivSave').onclick = function () {
        var v = parseInt($('#iv').value, 10);
        RG.api('/api/settings', { method: 'POST', body: { intervalSec: v } }).then(function (j) { S.settings.intervalSec = j.intervalSec; $('#ivMsg').className = 'small ok'; $('#ivMsg').textContent = 'Đã lưu: lấy mẫu mỗi ' + j.intervalSec + ' giây.'; RG.nextAt = Date.now() + j.intervalSec * 1000; })
          .catch(function (e) { $('#ivMsg').className = 'small warn'; $('#ivMsg').textContent = 'Lỗi: ' + e.message; });
      };
      var cur = RG.theme();
      RG.$$('[data-th]').forEach(function (b) { b.setAttribute('aria-pressed', b.dataset.th === cur); b.onclick = function () { RG.theme(b.dataset.th); RG.$$('[data-th]').forEach(function (x) { x.setAttribute('aria-pressed', x.dataset.th === b.dataset.th); }); }; });
      drawAdv(); drawAut(); this.refresh();
    },
    refresh: function () { Promise.all([RG.loadPolicy(), RG.loadDrives().catch(function () { }), loadAut()]).then(function () { if (RG.cur === 'settings') { drawAdv(); drawAut(); } }).catch(function () { }); },
    live: function () { }
  };
})();
