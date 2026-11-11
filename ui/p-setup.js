/* p-setup.js - Thiết lập lần đầu (hộp 3 bước, bỏ qua được) và hai công tắc "chạy cùng Windows" / "lối tắt" dùng chung với trang Cài đặt. PIN chỉ đặt được ở console. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc;
  var Z = RG.setup = { info: null };

  function load() { return RG.api('/api/setup').then(function (j) { Z.info = j; return j; }); }
  function post(body) { return RG.api('/api/setup', { method: 'POST', body: body }); }

  /* Hai công tắc: dựng vào phần tử `el`. Mỗi lần bật/tắt gọi POST /api/setup (cùng logic với `rg autostart|shortcut`). */
  Z.toggles = function (el, onChange) {
    if (!el) return;
    function draw() {
      var i = Z.info || {};
      el.innerHTML = '<label class="sw-row"><input type="checkbox" id="swAuto"' + (i.autostart ? ' checked' : '') + '><span><b>Chạy cùng Windows</b><span class="small mut" style="display:block">Resource Guard tự mở ngầm khi bạn đăng nhập (không cần quyền admin). Tắt thì chỉ chạy khi bạn mở.</span></span></label>' +
        '<label class="sw-row"><input type="checkbox" id="swLnk"' + (i.shortcut ? ' checked' : '') + '><span><b>Lối tắt trong Start Menu</b><span class="small mut" style="display:block">Mở Resource Guard bằng một cú bấm; chạy ngầm nếu chưa chạy.</span></span></label>';
      [['swAuto', 'autostart'], ['swLnk', 'shortcut']].forEach(function (p) {
        var cb = document.getElementById(p[0]); if (!cb) return;
        cb.onchange = function () {
          var body = {}; body[p[1]] = cb.checked; cb.disabled = true;
          post(body).then(function () { return load(); }).then(function () { RG.toast((cb.checked ? 'Đã bật: ' : 'Đã tắt: ') + (p[1] === 'autostart' ? 'chạy cùng Windows' : 'lối tắt Start Menu'), 'ok'); if (onChange) onChange(); draw(); })
            .catch(function (e) { RG.toast('Không đổi được: ' + e.message, 'err', 8000); cb.checked = !cb.checked; cb.disabled = false; });
        };
      });
    }
    draw(); load().then(draw).catch(function () { });
  };

  /* Hộp thiết lập lần đầu. */
  Z.firstRun = function () {
    var step = 0, mode = 'dry-run', done = false, m;
    function finish(save) {
      if (done) return; done = true;
      var p = save && S.policy && S.policy.mode === 'off' && mode !== 'off' ? RG.savePolicy(Object.assign(RG.clone(S.policy), { mode: 'dry-run' })).catch(function () { }) : Promise.resolve();
      p.then(function () { return post({ firstRunDone: true }); }).then(function () { return RG.loadPolicy().catch(function () { }); }).then(function () { if (m) m.close(true); if (save && mode === 'dry-run') RG.toast('Đang ở chế độ Chạy thử: một tuần nữa bạn sẽ thấy tôi dọn được gì.', 'ok', 8000); if (RG.pages[RG.cur] && RG.pages[RG.cur].refresh) RG.pages[RG.cur].refresh(); })
        .catch(function (e) { done = false; RG.toast('Không lưu được thiết lập: ' + e.message, 'err'); });
    }
    function body() {
      var dots = '<div class="su-dots" aria-label="Bước ' + (step + 1) + '/3">' + [0, 1, 2].map(function (i) { return '<i class="' + (i === step ? 'on' : '') + '"></i>'; }).join('') + '</div>';
      if (step === 0) return dots + '<h4 class="dh">Resource Guard làm gì cho bạn</h4><p><b>Tổng quan:</b> cho biết máy đang ổn hay thiếu gì (RAM, ổ đĩa), và việc nên làm trước.</p><p><b>Ổ đĩa:</b> dọn gì, được bao nhiêu, hậu quả gì, bằng hình thay vì danh sách dài.</p><p><b>Bộ nhớ &amp; tiến trình:</b> ứng dụng nào đang ăn RAM, của ai, thuộc dự án nào.</p><p><b>Tự động, an toàn:</b> chỉ dọn loại tự tạo lại được, tránh vùng bạn bảo vệ, không bao giờ kết thúc ứng dụng của bạn. Mọi thứ bạn duyệt trước.</p>';
      if (step === 1) return dots + '<h4 class="dh">Khởi động</h4><div id="suTog"></div>';
      return dots + '<h4 class="dh">Chế độ tự động</h4><p class="small mut">Chọn cách Resource Guard tự dọn khi máy thiếu chỗ. Đổi bất cứ lúc nào ở trang Ổ đĩa.</p>' +
        [['dry-run', 'Chạy thử (khuyên dùng)', 'Một tuần nữa tôi sẽ cho bạn xem tôi sẽ dọn được gì. Chưa xoá gì cả.'], ['off', 'Tắt', 'Không làm gì tự động. Bạn dọn tay ở trang Ổ đĩa.'], ['on', 'Bật', 'Tự dọn thật khi cần. Cần đặt PIN trước.']].map(function (o) {
          return '<label class="su-opt"><input type="radio" name="suMode" value="' + o[0] + '"' + (mode === o[0] ? ' checked' : '') + '><span><b>' + o[1] + '</b><span class="small mut" style="display:block">' + o[2] + '</span></span></label>';
        }).join('') + (mode === 'on' ? '<div class="alert info" style="margin-top:8px"><div class="small">PIN chỉ đặt được ở terminal, không qua trình duyệt: chạy <span class="mono">rg pin</span>, rồi vào trang Ổ đĩa và chọn Bật. Tạm thời tôi để ở chế độ Chạy thử.</div></div>' : '');
    }
    function render() {
      var b = RG.$('.body', m.el); b.innerHTML = body();
      var acts = RG.$('.acts', m.el); acts.innerHTML = '';
      function btn(label, cls, fn) { var x = document.createElement('button'); x.className = 'btn ' + cls; x.textContent = label; x.onclick = fn; acts.appendChild(x); return x; }
      btn('Bỏ qua', '', function () { finish(false); });
      var sp = document.createElement('span'); sp.style.flex = '1'; acts.appendChild(sp);
      if (step > 0) btn('Quay lại', '', function () { step--; render(); });
      if (step < 2) btn('Tiếp', 'primary', function () { step++; render(); }); else btn('Hoàn tất', 'primary', function () { finish(true); });
      if (step === 1) Z.toggles(RG.$('#suTog', m.el));
      RG.$$('input[name=suMode]', m.el).forEach(function (r) { r.onchange = function () { mode = r.value; render(); }; });
      var f = RG.$('.btn.primary', acts); if (f) f.focus();
    }
    m = RG.modal({ title: 'Chào mừng đến Resource Guard', html: '', actions: [] });
    m.el.classList.add('wide');
    render();
  };

  /* Gọi sau khi vào app: mở hộp nếu chưa thiết lập. Chỉ hỏi một lần mỗi phiên trang. */
  Z.check = function () {
    load().then(function (j) { if (j && j.firstRun && !Z.shown) { Z.shown = true; Z.firstRun(); } }).catch(function () { });
  };
})();
