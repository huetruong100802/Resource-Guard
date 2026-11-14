/* p-connect.js - Cài đặt: thẻ "Kết nối agent" (danh mục agent, cách kết nối, nhà cung cấp AI đánh giá) và thẻ "Giới thiệu".
   Chỉ đọc + hiển thị đoạn cấu hình để người dùng tự dán: Resource Guard không tự sửa file cấu hình của agent. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;
  var C = RG.connect = { view: null };
  var VIA = { mcp: 'MCP', hooks: 'Hook', wrapper: 'Bọc lệnh' };

  function fmtAgo(iso) {
    if (!iso) return '';
    var s = (Date.now() - Date.parse(iso)) / 1000; if (!(s >= 0)) return '';
    return s < 90 ? 'vừa xong' : s < 3600 ? Math.round(s / 60) + ' phút trước' : s < 86400 ? Math.round(s / 3600) + ' giờ trước' : Math.round(s / 86400) + ' ngày trước';
  }
  function agentState(a) {
    if (a.sessions) return '<span class="pill auto" title="Đã kết nối qua ' + esc((a.via || []).join(', ')) + '">đã kết nối · ' + a.sessions + ' phiên</span>';
    if (a.running) return '<span class="pill ask" title="Đang chạy nhưng chưa báo cho Resource Guard">đang chạy, chưa kết nối</span>';
    if (a.installed) return '<span class="pill">đã cài</span>';
    if (a.installed === false) return '<span class="pill" style="opacity:.6">chưa thấy trên máy</span>';
    return '';
  }
  function rows(v) {
    return (v.agents || []).filter(function (a) { return (a.connect || []).length; }).map(function (a) {
      return '<tr><td><b>' + esc(a.label) + '</b>' + (a.lastSeenUtc ? '<div class="small mut">thấy lần cuối ' + esc(fmtAgo(a.lastSeenUtc)) + '</div>' : '') + '</td>' +
        '<td>' + agentState(a) + '</td><td class="small mut">' + (a.connect || []).map(function (c) { return VIA[c] || c; }).join(' · ') + '</td>' +
        '<td style="text-align:right"><button class="btn sm" data-guide="' + esc(a.id) + '">Cách kết nối</button></td></tr>';
    }).join('');
  }
  function provOptions(v) {
    var cur = v.choice ? v.choice.provider : 'auto';
    return '<option value="auto"' + (cur === 'auto' ? ' selected' : '') + '>Tự chọn (cái đầu tiên dùng được)</option>' + (v.providers || []).map(function (p) {
      return '<option value="' + esc(p.id) + '"' + (cur === p.id ? ' selected' : '') + (p.ready ? '' : ' disabled') + '>' + esc(p.label) + (p.local ? ' · trên máy' : '') + (p.ready ? '' : ' (chưa sẵn sàng)') + '</option>';
    }).join('');
  }
  function provList(v) {
    return '<ul class="small prov-list">' + (v.providers || []).map(function (p) {
      return '<li><span class="dot' + (p.ready ? ' on' : '') + '"></span><b>' + esc(p.label) + '</b> ' +
        (p.ready ? '<span class="mut">sẵn sàng' + (p.model ? ' · model ' + esc(p.model) : '') + (p.verified ? '' : ' · chưa kiểm với dịch vụ thật') + '</span>' : '<span class="mut">' + esc(p.reason || 'chưa sẵn sàng') + '</span>') + '</li>';
    }).join('') + '</ul>';
  }
  function draw(el) {
    var v = C.view;
    if (!v) { el.innerHTML = '<div class="card"><h2>Kết nối agent</h2><p class="mut small">Đang dò agent trên máy…</p></div>'; return; }
    var ev = v.evaluator;
    el.innerHTML = '<div class="card"><h2>Kết nối agent</h2>' +
      '<p class="hint" style="margin-bottom:8px">Agent đã kết nối sẽ hỏi Resource Guard trước khi chạy build/test nặng hoặc tạo subagent, và được báo khi máy sắp cạn RAM/ổ đĩa. Agent chỉ được <b>xem và đề xuất</b>; mọi lần dọn vẫn do bạn duyệt.</p>' +
      '<div class="tbl-wrap" style="max-height:none"><table class="ag-tbl"><thead><tr><th>Agent</th><th>Trạng thái</th><th>Cách kết nối</th><th></th></tr></thead><tbody>' + rows(v) + '</tbody></table></div>' +
      '<p class="hint">Agent khác có hỗ trợ MCP: dùng đoạn của “VS Code”. Script hoặc CI: <span class="mono">POST /api/connect/v1/preflight</span> với header <span class="mono">X-RG-Client: agent</span>.</p></div>' +
      '<div class="card mt"><h2>Trợ lý AI đánh giá</h2>' +
      '<p class="hint" style="margin-bottom:8px">Dùng cho nút “Hỏi trợ lý AI”. Chỉ gửi <b>metadata</b> (tên, kích thước, tuổi của mục dọn; tên tiến trình), không gửi nội dung file. ' +
      (ev ? 'Đang dùng: <b>' + esc(ev.label) + '</b>' + (ev.local ? ' (dữ liệu không rời máy)' : '') + '.' : '<b>Chưa có nhà cung cấp nào dùng được.</b>') + '</p>' +
      '<div class="field"><label for="evProv">Nhà cung cấp</label><select id="evProv">' + provOptions(v) + '</select></div>' +
      '<div class="field"><label for="evModel">Model (để trống = mặc định)</label><input id="evModel" type="text" style="width:200px" value="' + esc(v.choice && v.choice.model || '') + '"></div>' +
      '<div class="field"><button class="btn primary" id="evSave">Lưu</button><button class="btn" id="evTest">Thử kết nối</button></div><div id="evMsg" class="small" role="status"></div>' +
      provList(v) +
      '<p class="hint">Ollama, LM Studio, OpenRouter… khai địa chỉ trong <span class="mono">config.json</span> (mục <span class="mono">agents.providers</span>). Khoá API chỉ đọc từ biến môi trường, không lưu vào file.</p></div>';
    RG.$$('[data-guide]', el).forEach(function (b) { b.onclick = function () { guide(b.dataset.guide); }; });
    $('#evSave').onclick = function () {
      var msg = $('#evMsg'); msg.className = 'small'; msg.textContent = 'Đang lưu…';
      RG.api('/api/agents/evaluator', { method: 'POST', body: { provider: $('#evProv').value, model: $('#evModel').value.trim() } })
        .then(function (j) { C.view = j.view; draw(el); var m = $('#evMsg'); m.className = 'small ok'; m.textContent = 'Đã lưu.'; })
        .catch(function (e) { msg.className = 'small warn'; msg.textContent = 'Lỗi: ' + e.message; });
    };
    $('#evTest').onclick = function () {
      var b = $('#evTest'), msg = $('#evMsg'), pv = $('#evProv').value;
      b.disabled = true; msg.className = 'small'; msg.textContent = 'Đang gửi một câu hỏi thử (không kèm dữ liệu máy), có thể mất tới một phút…';
      RG.api('/api/agents/test', { method: 'POST', body: { provider: pv } }).then(function (j) {
        msg.className = 'small ' + (j.ok ? 'ok' : 'warn');
        msg.textContent = j.ok ? 'Kết nối được ' + (j.provider || pv) + (j.durationMs ? ' (' + (j.durationMs / 1000).toFixed(1) + ' giây)' : '') + '.' : 'Không dùng được: ' + (j.error || 'lỗi không rõ');
      }).catch(function (e) { msg.className = 'small warn'; msg.textContent = 'Lỗi: ' + e.message; }).then(function () { b.disabled = false; });
    };
  }
  function copyText(t) {
    if (navigator.clipboard && navigator.clipboard.writeText) return navigator.clipboard.writeText(t);
    return new Promise(function (res, rej) {
      var ta = document.createElement('textarea'); ta.value = t; ta.style.position = 'fixed'; ta.style.opacity = '0'; document.body.appendChild(ta); ta.select();
      try { document.execCommand('copy') ? res() : rej(new Error('không sao chép được')); } catch (e) { rej(e); } document.body.removeChild(ta);
    });
  }
  function guide(id, heavy) {
    var d = RG.drawer({ title: 'Kết nối agent', html: '<p class="mut small">Đang tạo hướng dẫn…</p>', actions: [{ label: 'Đóng' }] });
    d.el.classList.add('wide');
    RG.api('/api/agents/connect?id=' + encodeURIComponent(id) + (heavy ? '&heavy=1' : '')).then(function (g) {
      d.setTitle('Kết nối ' + g.label);
      var steps = g.steps || [];
      d.setHtml('<p class="small"><span class="pill ' + (g.verified ? 'auto' : 'ask') + '">' + (g.verified ? 'đã kiểm trên máy thật' : 'chưa kiểm với bản thật') + '</span> ' + esc(g.status) + '</p>' +
        '<p class="hint">Resource Guard <b>không tự sửa</b> file cấu hình của bạn. Sao chép từng đoạn và dán vào đúng file, rồi khởi động lại agent.</p>' +
        (g.note ? '<p class="small">' + esc(g.note) + '</p>' : '') +
        steps.map(function (s, i) {
          return '<div class="cn-step"><div class="cn-h"><b>' + (i + 1) + '. ' + esc(s.title) + '</b><button class="btn sm" data-copy="' + i + '">Sao chép</button></div>' +
            (s.file ? '<div class="small mut">Dán vào: <span class="mono">' + esc(s.file) + '</span></div>' : '') +
            '<pre class="json">' + esc(s.text) + '</pre>' + (s.note ? '<div class="small mut">' + esc(s.note) + '</div>' : '') + '</div>';
        }).join('') +
        (id === 'claude' ? '<label class="small"><input type="checkbox" id="cnHeavy"' + (heavy ? ' checked' : '') + '> Hook cũng kiểm build/test chạy qua Bash (chặt hơn)</label>' : '') +
        '<p class="hint">Từ terminal: <span class="mono">rguard connect ' + esc(g.id) + '</span> in cùng nội dung.</p>');
      RG.$$('[data-copy]', d.el).forEach(function (b) {
        b.onclick = function () { copyText(steps[+b.dataset.copy].text).then(function () { b.textContent = 'Đã chép'; setTimeout(function () { b.textContent = 'Sao chép'; }, 1600); }, function (e) { RG.toast(e.message, 'err'); }); };
      });
      var hv = $('#cnHeavy', d.el); if (hv) hv.onchange = function () { guide(id, hv.checked); };
    }).catch(function (e) { d.setHtml('<p class="warn">Không tạo được hướng dẫn: ' + esc(e.message) + '</p>'); });
  }
  C.render = function (el) {
    draw(el);
    RG.api('/api/agents').then(function (v) { C.view = v; if (el.isConnected) draw(el); }).catch(function (e) { if (el.isConnected) el.innerHTML = '<div class="card"><h2>Kết nối agent</h2><p class="warn small">Không đọc được danh sách agent: ' + esc(e.message) + '</p></div>'; });
  };

  /* ---------- Giới thiệu ---------- */
  RG.aboutCard = function (el) {
    function fill(a) {
      var o = a.overhead || {};
      el.innerHTML = '<div class="card"><h2>Giới thiệu</h2><table class="about-tbl small"><tbody>' +
        '<tr><th>Phiên bản</th><td><b>' + esc(a.version) + '</b></td></tr>' +
        '<tr><th>Chi phí của Resource Guard</th><td>' + (o.samples ? 'mỗi lượt lấy mẫu ~' + Math.round(o.avgTickMs) + ' ms, ước tính ' + (o.estCpuPctAtInterval != null ? o.estCpuPctAtInterval : '?') + '% của một nhân CPU ở chu kỳ ' + a.intervalSec + ' giây; ' + Math.round(o.workingSetMB || 0) + ' MB RAM' : 'đang đo…') + '</td></tr>' +
        '<tr><th>Dữ liệu</th><td class="mono">' + esc(a.home) + '</td></tr>' +
        '<tr><th>Nhật ký</th><td class="mono">' + esc(a.logs) + '</td></tr>' +
        '<tr><th>Cài ở</th><td class="mono">' + esc(a.install) + '</td></tr>' +
        '<tr><th>PowerShell</th><td>' + esc(a.powershell) + ' · cổng ' + esc(a.port) + ' · pid ' + esc(a.pid) + '</td></tr>' +
        '</tbody></table><p class="hint">Mọi dữ liệu nằm trên máy này. Gỡ cài đặt giữ lại thư mục dữ liệu trừ khi bạn chọn xoá.</p></div>';
    }
    if (S.about) fill(S.about); else el.innerHTML = '<div class="card"><h2>Giới thiệu</h2><p class="mut small">Đang tải…</p></div>';
    RG.api('/api/about').then(function (a) { S.about = a; if (el.isConnected) fill(a); }).catch(function () { });
  };
})();
