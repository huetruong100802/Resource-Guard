/* p-agent.js - "Nhờ agent đánh giá": xem trước dữ liệu gửi đi, gọi claude (haiku, high), hiển thị gợi ý có cấu trúc. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;
  var SEV = { ok: ['ok', 'Ổn'], watch: ['watch', 'Cần theo dõi'], act: ['act', 'Nên xử lý'] };
  var AREA = { disk: 'Ổ đĩa', ram: 'RAM', cpu: 'CPU', process: 'Tiến trình', policy: 'Chính sách' };
  var VERD = { clean: ['auto', 'Nên dọn'], keep: ['keep', 'Nên giữ'], review: ['ask', 'Xem lại'] };
  var A = { preview: null, showPreview: false };

  function candByKey(k) { return ((S.cands && S.cands.items) || []).filter(function (i) { return i.key === k; })[0]; }
  function draw() {
    var el = $('#agentBody'); if (!el) return;
    var j = S.jobs.agent, run = j && j.status === 'running', l = S.agent;
    var h = '<div class="card"><h2>Nhờ agent đánh giá <span class="ro">claude · haiku · effort high</span></h2>' +
      '<p style="margin:0 0 10px">Tool đã đo toàn bộ sự thật (dung lượng, tuổi file, tiến trình). Agent chỉ <b>đọc bản tóm tắt</b> và gợi ý nên dọn gì, giữ gì, theo thứ tự nào. <b>Bạn quyết định</b>: gợi ý chỉ chọn sẵn các ô ở tab Dọn dẹp, không tự xoá gì.</p>' +
      '<div class="field" style="margin:0"><button class="btn primary" id="agRun"' + (run ? ' disabled' : '') + '>' + RG.icon('spark') + ' Nhờ agent đánh giá</button>' +
      '<button class="btn" id="agPrev">' + RG.icon('eye') + ' ' + (A.showPreview ? 'Ẩn' : 'Xem trước') + ' dữ liệu sẽ gửi</button>' +
      (run ? '<span class="spin"></span><span class="small mut">đang chờ claude… (thường 10–40 giây)</span>' : '') + '</div>' +
      '<p class="hint">Chỉ gửi metadata: tên thư mục/mục, kích thước, số ngày không dùng, số liệu RAM/CPU/ổ đĩa, tên tiến trình, tóm tắt chính sách. Không gửi nội dung file; đường dẫn đã thay tên tài khoản bằng “~”. Nên quét ổ đĩa và ứng viên trước để agent có đủ dữ liệu.</p>' +
      (A.showPreview ? '<pre class="json" id="agJson">' + (A.preview ? esc(A.preview) : 'Đang tạo bản xem trước…') + '</pre>' : '') + '</div>';
    if (j && j.status === 'error' && !run) h += '<div class="alert warn mt"><div><b>Agent lỗi:</b> ' + esc(j.message) + '</div></div>';
    if (l && l.ok === false && !run) h += '<div class="alert warn mt"><div><b>Lần gần nhất thất bại</b> (' + RG.timeAgo(l.finishedUtc) + '): ' + esc(l.error) + '</div></div>';
    if (l && l.ok && l.result) {
      var r = l.result, sev = SEV[r.severity] || SEV.watch;
      h += '<div class="card mt"><h2>Kết quả <span class="sev ' + sev[0] + '">' + sev[1] + '</span><span class="ro">' + RG.timeAgo(l.finishedUtc) + ' · ' + Math.round((l.durationMs || 0) / 1000) + 's · $' + (+l.costUsd || 0).toFixed(4) + ' · gửi ' + RG.fmtBytes(l.payloadBytes) + '</span></h2>' +
        '<p style="margin:0;font-size:15px">' + esc(r.summary) + '</p></div>';
      if (r.keptApplied) h += '<div class="alert ok mt"><div><b>Đã bảo vệ ' + r.keptApplied + ' mục</b> agent đánh giá “nên giữ” (độ tin cậy cao) trong 30 ngày: các mục này không hiện trong danh sách dọn và không bị tự dọn. Xem hoặc bỏ giữ ở tab Dọn dẹp, mục “Agent đang giữ”.</div></div>';
      if ((r.findings || []).length) h += '<div class="card mt"><h2>Phát hiện</h2>' + r.findings.map(function (f) { return '<div style="padding:6px 0;border-bottom:1px solid var(--line)"><span class="pill">' + esc(AREA[f.area] || f.area) + '</span> <b>' + esc(f.title) + '</b><div class="small mut">' + esc(f.detail) + '</div></div>'; }).join('') + '</div>';
      var recs = (r.recommendations || []).slice().sort(function (a, b) { return a.priority - b.priority; });
      if (recs.length) {
        var rows = recs.map(function (x) {
          var c = candByKey(x.key), v = VERD[x.verdict] || VERD.review, tgt = c ? (c.kind === 'process' ? c.name + ' (pid ' + c.pid + ')' : c.path) : x.key;
          var can = c && c.action !== 'report' && !c.protected && x.verdict === 'clean';
          return '<tr class="row"><td class="chk"><input type="checkbox" data-rk="' + esc(x.key) + '"' + (can ? '' : ' disabled') + ' aria-label="Chọn ' + esc(tgt) + '"' + (S.selected[x.key] ? ' checked' : '') + '></td><td><span class="pill">P' + x.priority + '</span></td>' +
            '<td><span class="ellipsis mono" title="' + esc(tgt) + '">' + esc(tgt) + '</span><div class="small mut">' + esc(x.reason) + '</div></td><td class="r num">' + (c ? RG.fmtBytes(c.sizeBytes) : '–') + '</td>' +
            '<td><span class="pill ' + v[0] + '">' + v[1] + '</span> <span class="small mut">' + esc(x.confidence) + '</span>' + (x.autoKept || (c && c.protectedBy === 'agent') ? ' <span class="pill keep" title="Đã được bảo vệ có thời hạn: ẩn khỏi danh sách dọn, không tự dọn">đã bảo vệ</span>' : '') + '</td></tr>';
        }).join('');
        h += '<div class="card mt"><h2>Gợi ý theo thứ tự ưu tiên <span class="sp"></span><button class="btn sm" id="agSel">Chọn các mục “nên dọn” và mở tab Dọn dẹp</button></h2><div class="tbl-wrap" style="max-height:none"><table><thead><tr><th></th><th>Ưu tiên</th><th>Mục & lý do</th><th class="r">Dung lượng</th><th>Đánh giá</th></tr></thead><tbody>' + rows + '</tbody></table></div>' +
          (r.droppedUnknownKeys ? '<p class="hint">Đã loại ' + r.droppedUnknownKeys + ' gợi ý có key không tồn tại trong danh sách ứng viên (tool không tin nội dung agent bịa ra).</p>' : '') + '<p class="hint">Ô chỉ chọn được với mục tool cho phép xoá và không nằm trong vùng bảo vệ.</p></div>';
      }
      if ((r.policySuggestions || []).length) {
        h += '<div class="card mt"><h2>Gợi ý chính sách</h2>' + r.policySuggestions.map(function (p, i) {
          var cur = S.policy && S.policy.categories[p.kind];
          return '<div style="display:flex;gap:10px;align-items:center;padding:6px 0;border-bottom:1px solid var(--line)"><div style="flex:1"><b>' + esc(p.kind) + '</b> → <span class="pill ' + p.setting + '">' + ({ auto: 'Tự động', ask: 'Hỏi tay', keep: 'Luôn giữ' }[p.setting]) + '</span> <span class="small mut">(hiện: ' + esc(cur || '–') + ')</span><div class="small mut">' + esc(p.reason) + '</div></div>' +
            '<button class="btn sm" data-ps="' + i + '"' + (cur === p.setting ? ' disabled' : '') + '>Áp vào bản nháp</button></div>';
        }).join('') + '<p class="hint">Chỉ thay đổi bản nháp ở tab Chính sách; bạn phải bấm Lưu (và nhập PIN nếu nới lỏng chế độ “Bật”).</p></div>';
      }
    } else if (!run && !(l && l.ok === false)) {
      h += '<div class="card mt empty">' + RG.icon('spark') + '<h3>Chưa có đánh giá nào</h3><div>Bấm “Nhờ agent đánh giá” để gửi bản tóm tắt cho Claude (haiku, effort high).</div></div>';
    }
    el.innerHTML = h;
    $('#agRun').onclick = run_;
    $('#agPrev').onclick = function () {
      A.showPreview = !A.showPreview; draw();
      if (A.showPreview) RG.api('/api/agent/payload').then(function (j) { A.preview = JSON.stringify(j.payload, null, 2) + '\n\n// ' + RG.fmtBytes(j.bytes) + ' sẽ được gửi'; draw(); }).catch(function (e) { A.preview = 'Lỗi: ' + e.message; draw(); });
    };
    RG.$$('#agentBody input[data-rk]').forEach(function (cb) { cb.onchange = function () { if (cb.checked) S.selected[cb.dataset.rk] = true; else delete S.selected[cb.dataset.rk]; }; });
    var sb = $('#agSel'); if (sb) sb.onclick = function () {
      var n = 0; ((S.agent.result.recommendations) || []).forEach(function (x) { var c = candByKey(x.key); if (x.verdict === 'clean' && c && c.action !== 'report' && !c.protected) { S.selected[x.key] = true; n++; } });
      RG.toast(n ? 'Đã chọn ' + n + ' mục. Xem lại rồi xác nhận ở tab Dọn dẹp.' : 'Không có mục nào đủ điều kiện để chọn.'); if (n) RG.go('clean');
    };
    RG.$$('#agentBody [data-ps]').forEach(function (b) { b.onclick = function () {
      var p = S.agent.result.policySuggestions[+b.dataset.ps]; if (!S.draft) return; S.draft.categories[p.kind] = p.setting; S.dirty = JSON.stringify(S.draft) !== JSON.stringify(S.policy);
      RG.toast('Đã áp vào bản nháp. Sang tab Chính sách để lưu.', 'ok'); b.disabled = true;
    }; });
  }
  function run_() {
    var cj = S.cands && S.cands.finishedUtc, bj = S.disk;
    var go = function () { RG.startJob('/api/agent/run', {}, 'Đã gửi cho agent…').then(draw).catch(function () { }); };
    if (!cj || !bj) {
      RG.confirm('Dữ liệu chưa đầy đủ', '<p>' + (!bj ? 'Chưa quét phân bố ổ đĩa. ' : '') + (!cj ? 'Chưa quét ứng viên dọn dẹp. ' : '') + 'Agent vẫn chạy được nhưng đánh giá sẽ thiếu. Tiếp tục?</p>', 'Vẫn gửi', false).then(function (ok) { if (ok) go(); });
    } else go();
  }
  RG.pages.agent = {
    title: 'Agent đánh giá',
    render: function (el) { el.innerHTML = '<div id="agentBody"></div>'; draw(); this.refresh(); },
    refresh: function () { Promise.all([RG.loadAgent(), RG.loadCands(), RG.loadPolicy(), RG.loadDisk()]).then(draw).catch(function () { }); },
    jobs: function () { if (RG.cur === 'agent') draw(); },
    live: function () { }
  };
  RG.askAgent = function () { RG.go('agent'); setTimeout(run_, 50); };
})();
