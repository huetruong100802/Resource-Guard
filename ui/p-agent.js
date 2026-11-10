/* p-agent.js - "Hỏi trợ lý": ngăn kéo (mở từ Trang chủ và trang Dọn dẹp). Xem trước dữ liệu gửi đi, chạy claude (haiku, high), hiện tóm tắt + phát hiện.
   Đánh giá từng mục hiện ngay ở trang Dọn dẹp dưới nhãn "Trợ lý AI". Không có trang riêng. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;
  var SEV = { ok: ['ok', 'Ổn'], watch: ['watch', 'Cần theo dõi'], act: ['act', 'Nên xử lý'] };
  var AREA = { disk: 'Ổ đĩa', ram: 'RAM', cpu: 'CPU', process: 'Tiến trình', policy: 'Chính sách' };
  var VERD = { clean: ['auto', 'Nên dọn'], keep: ['keep', 'Nên giữ'], review: ['ask', 'Xem lại'] };
  var A = { preview: null, showPreview: false, dr: null, timer: null, sig: '' };

  function candByKey(k) { return ((S.cands && S.cands.items) || []).filter(function (i) { return i.key === k; })[0]; }
  function open() { return A.dr && document.body.contains(A.dr.el); }
  function html() {
    var j = S.jobs.agent, run = j && j.status === 'running', l = S.agent;
    var h = '<p style="margin:0 0 10px">Máy đã đo toàn bộ sự thật (dung lượng, tuổi file, tiến trình) và lập kế hoạch. Trợ lý AI chỉ <b>đọc bản tóm tắt</b>, đánh giá các mục máy không tự quyết được và nói <b>nên làm gì trước, vì sao</b>. <b>Bạn quyết định</b>: không có gì bị xoá ở đây.</p>' +
      '<div class="field" style="margin:0"><button class="btn primary" id="agRun"' + (run ? ' disabled' : '') + '>' + RG.icon('spark') + ' Hỏi trợ lý</button>' +
      '<button class="btn" id="agPrev">' + RG.icon('eye') + ' ' + (A.showPreview ? 'Ẩn' : 'Xem trước') + ' dữ liệu sẽ gửi</button>' + (run ? '<span class="spin"></span><span class="small mut">đang chờ claude… (thường 10–40 giây)</span>' : '') + '</div>' +
      '<p class="hint">Chỉ gửi metadata: tên mục, kích thước, số ngày không dùng, số liệu RAM/CPU/ổ đĩa, tên tiến trình, tóm tắt chính sách và kế hoạch. Không gửi nội dung file; đường dẫn đã thay tên tài khoản bằng “~”.</p>' +
      (A.showPreview ? '<pre class="json" id="agJson">' + (A.preview ? esc(A.preview) : 'Đang tạo bản xem trước…') + '</pre>' : '');
    if (j && j.status === 'error' && !run) h += '<div class="alert warn" style="margin-top:10px"><div><b>Trợ lý lỗi:</b> ' + esc(j.message) + '</div></div>';
    if (l && l.ok === false && !run) h += '<div class="alert warn" style="margin-top:10px"><div><b>Lần gần nhất thất bại</b> (' + RG.timeAgo(l.finishedUtc) + '): ' + esc(l.error) + '</div></div>';
    if (l && l.ok && l.result) {
      var r = l.result, sev = SEV[r.severity] || SEV.watch;
      h += '<h4 class="dh">Kết luận <span class="sev ' + sev[0] + '">' + sev[1] + '</span></h4><p style="margin:0;font-size:15px">' + esc(r.summary) + '</p><div class="small mut">' + RG.timeAgo(l.finishedUtc) + ' · ' + Math.round((l.durationMs || 0) / 1000) + ' giây · gửi ' + RG.fmtBytes(l.payloadBytes) + '</div>';
      if (r.keptApplied) h += '<div class="alert ok" style="margin-top:8px"><div class="small"><b>Đã bảo vệ ' + r.keptApplied + ' mục</b> trợ lý đánh giá “nên giữ” (độ tin cậy cao) trong 30 ngày: các mục này không hiện trong danh sách dọn và không bị tự dọn. Bỏ giữ ở trang Dọn dẹp, mục “Agent đang giữ”.</div></div>';
      if ((r.findings || []).length) h += '<h4 class="dh">Phát hiện</h4>' + r.findings.map(function (f) { return '<div style="padding:6px 0;border-bottom:1px solid var(--line)"><span class="pill">' + esc(AREA[f.area] || f.area) + '</span> <b>' + esc(f.title) + '</b><div class="small mut">' + esc(f.detail) + '</div></div>'; }).join('');
      var recs = (r.recommendations || []).slice().sort(function (a, b) { return a.priority - b.priority; });
      if (recs.length) {
        h += '<h4 class="dh">Đánh giá từng mục <span class="small mut">(hiện cả ở trang Dọn dẹp)</span></h4>' + recs.map(function (x) {
          var c = candByKey(x.key), v = VERD[x.verdict] || VERD.review, tgt = c ? (c.kind === 'process' ? c.name + ' (pid ' + c.pid + ')' : c.path) : x.key;
          return '<div style="padding:6px 0;border-bottom:1px solid var(--line)"><span class="pill">P' + x.priority + '</span> <span class="pill ' + v[0] + '">' + v[1] + '</span> <span class="small mut">' + esc(x.confidence) + '</span>' + (x.autoKept || (c && c.protectedBy === 'agent') ? ' <span class="pill keep">đã bảo vệ</span>' : '') +
            '<div class="mono small ellipsis" style="max-width:100%" title="' + esc(tgt) + '">' + esc(tgt) + '</div><div class="small mut">' + esc(x.reason) + (c ? ' · ' + RG.fmtBytes(c.sizeBytes) : '') + '</div></div>';
        }).join('') + (r.droppedUnknownKeys ? '<p class="hint">Đã loại ' + r.droppedUnknownKeys + ' gợi ý có key không tồn tại trong danh sách (tool không tin nội dung agent bịa ra).</p>' : '');
      }
      if ((r.policySuggestions || []).length) {
        h += '<h4 class="dh">Gợi ý chính sách</h4>' + r.policySuggestions.map(function (p, i) {
          var cur = S.policy && S.policy.categories[p.kind];
          return '<div style="display:flex;gap:10px;align-items:center;padding:6px 0;border-bottom:1px solid var(--line)"><div style="flex:1"><b>' + esc(RG.human.kind(p.kind).l) + '</b> → <span class="pill ' + p.setting + '">' + ({ auto: 'Tự động', ask: 'Hỏi tôi', keep: 'Luôn giữ' }[p.setting]) + '</span> <span class="small mut">(hiện: ' + esc(({ auto: 'Tự động', ask: 'Hỏi tôi', keep: 'Luôn giữ' }[cur]) || '–') + ')</span><div class="small mut">' + esc(p.reason) + '</div></div>' +
            '<button class="btn sm" data-ps="' + i + '"' + (cur === p.setting ? ' disabled' : '') + '>Áp vào bản nháp</button></div>';
        }).join('') + '<p class="hint">Chỉ thay đổi bản nháp ở trang Tự động hoá; bạn phải bấm Lưu (và nhập PIN nếu nới lỏng chế độ “Bật”).</p>';
      }
    } else if (!run && !(l && l.ok === false)) h += '<div class="empty" style="padding:20px 0">' + RG.icon('spark') + '<h3>Chưa có đánh giá nào</h3><div>Bấm “Hỏi trợ lý” để gửi bản tóm tắt cho Claude.</div></div>';
    return h;
  }
  function draw() {
    if (!open()) { if (A.timer) { clearInterval(A.timer); A.timer = null; } return; }
    A.dr.setHtml(html()); bind();
  }
  function bind() {
    var b = $('#agRun'); if (b) b.onclick = run_;
    var pv = $('#agPrev'); if (pv) pv.onclick = function () {
      A.showPreview = !A.showPreview; draw();
      if (A.showPreview) RG.api('/api/agent/payload').then(function (j) { A.preview = JSON.stringify(j.payload, null, 2) + '\n\n// ' + RG.fmtBytes(j.bytes) + ' sẽ được gửi'; draw(); }).catch(function (e) { A.preview = 'Lỗi: ' + e.message; draw(); });
    };
    RG.$$('.drawer [data-ps]').forEach(function (x) { x.onclick = function () {
      var p = S.agent.result.policySuggestions[+x.dataset.ps]; if (!S.draft) return; S.draft.categories[p.kind] = p.setting; S.dirty = JSON.stringify(S.draft) !== JSON.stringify(S.policy);
      RG.toast('Đã áp vào bản nháp. Sang trang Tự động hoá để lưu.', 'ok'); x.disabled = true;
    }; });
  }
  function run_() {
    var cj = S.cands && S.cands.finishedUtc, bj = S.disk;
    var go = function () { RG.startJob('/api/agent/run', {}, 'Đã gửi cho trợ lý…').then(draw).catch(function () { }); };
    if (!cj || !bj) RG.confirm('Dữ liệu chưa đầy đủ', '<p>' + (!bj ? 'Chưa quét phân bố ổ đĩa. ' : '') + (!cj ? 'Chưa quét các mục có thể dọn. ' : '') + 'Trợ lý vẫn chạy được nhưng đánh giá sẽ thiếu. Tiếp tục?</p>', 'Vẫn gửi', false).then(function (ok) { if (ok) go(); });
    else go();
  }
  /* Mở ngăn kéo. Không có `claude` trong PATH thì không mở: kế hoạch tất định vẫn đầy đủ. */
  RG.askAgent = function () {
    if (S.settings && S.settings.agentAvailable === false) { RG.toast('Không tìm thấy lệnh claude trong PATH nên không dùng được Trợ lý AI. Kế hoạch dọn của máy vẫn đầy đủ.', 'err', 8000); return; }
    A.dr = RG.drawer({ title: 'Hỏi trợ lý', html: '', actions: [{ label: 'Đóng' }], onClose: function () { if (A.timer) { clearInterval(A.timer); A.timer = null; } } });
    A.dr.el.classList.add('wide');
    draw();
    Promise.all([RG.loadAgent(), RG.loadCands().catch(function () { }), RG.loadPolicy().catch(function () { }), RG.loadDisk().catch(function () { })]).then(draw).catch(function () { });
    A.sig = ''; A.timer = setInterval(function () { var j = S.jobs.agent, sig = (j ? j.status + (j.message || '') : '') + (S.agent ? S.agent.finishedUtc : ''); if (sig !== A.sig) { A.sig = sig; draw(); } }, 1200);
  };
  RG.agentRecFor = function (key) { var a = S.agent && S.agent.ok && S.agent.result; if (!a) return null; return (a.recommendations || []).filter(function (r) { return r.key === key; })[0] || null; };
})();
