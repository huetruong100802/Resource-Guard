/* p-overview.js - Cài đặt (chu kỳ lấy mẫu, ngưỡng, khởi động, an toàn, giao diện). Trang chủ ở p-home.js, Tiến trình ở p-proc.js. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;

  RG.pages.settings = {
    title: 'Cài đặt',
    render: function (el) {
      var s = S.settings || { intervalSec: 15, minSec: 2, maxSec: 300, defaultSec: 15 }, t = S.thr, H = RG.human;
      el.innerHTML = '<div class="grid g2"><div class="card"><h2>Chu kỳ lấy mẫu</h2>' +
        '<div class="field"><label for="iv">Lấy mẫu mỗi (giây)</label><input id="iv" type="number" min="' + s.minSec + '" max="' + s.maxSec + '" step="1" value="' + s.intervalSec + '"><button class="btn primary" id="ivSave">Lưu</button></div>' +
        '<div class="field">' + [5, 15, 30, 60].map(function (v) { return '<button class="btn sm" data-v="' + v + '">' + v + 's' + (v === s.defaultSec ? ' (mặc định)' : '') + '</button>'; }).join('') + '</div>' +
        '<p class="hint">Từ ' + s.minSec + ' đến ' + s.maxSec + ' giây, có hiệu lực ngay. Chu kỳ ngắn phản ứng nhanh hơn nhưng tốn CPU hơn một chút; bảng tiến trình luôn làm mới tối đa mỗi 30 giây.</p><div id="ivMsg" class="small"></div></div>' +
        '<div class="card"><h2>Khởi động</h2><div id="setupTog"></div><p class="hint">Giống lệnh <span class="mono">rg autostart on|off</span> và <span class="mono">rg shortcut</span>. Đặt PIN (để bật tự dọn thật) chỉ làm được ở terminal: <span class="mono">rg pin</span>. ' + (S.pinConfigured ? '<span class="pill auto">PIN đã đặt</span>' : '<span class="pill ask">chưa đặt PIN</span>') + '</p></div>' +
        '<div class="card"><h2>Ngưỡng trạng thái <span class="ro">chỉnh trong config.json</span></h2>' + (t ? '<table><tbody>' +
          '<tr><td>RAM trống (GB)</td><td class="r small">' + H.state('Normal') + ' &gt; ' + t.ramAvailGB.normalAbove + ' · ' + H.state('Caution') + ' ≥ ' + t.ramAvailGB.cautionFrom + ' · ' + H.state('Restricted') + ' ≥ ' + t.ramAvailGB.restrictedFrom + ' · dưới nữa ' + H.state('Critical') + '</td></tr>' +
          '<tr><td>Ổ đĩa trống (GB)</td><td class="r small">' + H.state('Normal') + ' &gt; ' + t.diskFreeGB.normalAbove + ' · ' + H.state('Caution') + ' ≥ ' + t.diskFreeGB.cautionFrom + ' · dưới nữa ' + H.state('Critical') + '</td></tr>' +
          '<tr><td>Bộ nhớ cam kết (%)</td><td class="r small">' + H.state('Restricted') + ' ≥ ' + t.commitPct.restricted + ' · ' + H.state('Critical') + ' ≥ ' + t.commitPct.critical + '</td></tr></tbody></table>' : '') +
        '<p class="hint">Trạng thái được giữ có trễ (hysteresis): lên mức xấu hơn ngay lập tức, về mức tốt hơn sau khoảng 45 giây ổn định để không nhấp nháy.</p></div>' +
        '<div class="card"><h2>An toàn</h2><ul class="small" style="margin:0;padding-left:18px"><li>Chỉ nghe <b>localhost</b>; mọi thao tác ghi cần header riêng chống CSRF/DNS-rebinding.</li><li>Giao diện chỉ gửi <b>key</b> của mục dọn, không gửi đường dẫn; engine kiểm lại allowlist trước khi xoá.</li><li>Resource Guard <b>không kết thúc tiến trình</b> ngoài tiến trình agent đã đăng ký và mất chủ; với ứng dụng khác chỉ có thể hạ ưu tiên CPU (đảo ngược được).</li><li>Trợ lý AI chỉ nhận metadata (tên, kích thước, tuổi), không nhận nội dung file.</li></ul></div>' +
        '<div class="card"><h2>Giao diện</h2><div class="field"><label>Chủ đề</label><span class="seg" role="group" aria-label="Chủ đề"><button data-th="auto">Theo hệ thống</button><button data-th="light">Sáng</button><button data-th="dark">Tối</button></span></div></div></div>';
      RG.setup.toggles($('#setupTog'));
      RG.$$('[data-v]').forEach(function (b) { b.onclick = function () { $('#iv').value = b.dataset.v; }; });
      $('#ivSave').onclick = function () {
        var v = parseInt($('#iv').value, 10);
        RG.api('/api/settings', { method: 'POST', body: { intervalSec: v } }).then(function (j) { S.settings.intervalSec = j.intervalSec; $('#ivMsg').className = 'small ok'; $('#ivMsg').textContent = 'Đã lưu: lấy mẫu mỗi ' + j.intervalSec + ' giây.'; RG.nextAt = Date.now() + j.intervalSec * 1000; })
          .catch(function (e) { $('#ivMsg').className = 'small warn'; $('#ivMsg').textContent = 'Lỗi: ' + e.message; });
      };
      var cur = RG.theme();
      RG.$$('[data-th]').forEach(function (b) { b.setAttribute('aria-pressed', b.dataset.th === cur); b.onclick = function () { RG.theme(b.dataset.th); RG.$$('[data-th]').forEach(function (x) { x.setAttribute('aria-pressed', x.dataset.th === b.dataset.th); }); }; });
    },
    live: function () { }
  };
})();
