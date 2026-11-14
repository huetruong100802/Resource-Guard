/* boot.js - khung ứng dụng: điều hướng, theme, SSE realtime, khởi tạo. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, $ = RG.$, MAX = 480;
  var NAV = [['home', 'home', 'Tổng quan'], ['disk', 'disk', 'Ổ đĩa'], ['mem', 'cpu', 'Bộ nhớ & tiến trình'], ['settings', 'gear', 'Cài đặt']];
  // Hash cũ -> màn mới. Chỉ áp dụng khi trang cũ không còn đăng ký (clean/policy bị gỡ ở P7, cpu đổi thành mem ở P8); trong lúc chuyển tiếp trang cũ vẫn mở được.
  var LEGACY = { clean: 'disk', policy: 'disk', cpu: 'mem', overview: 'home', agent: 'home', '': 'home' };
  function resolve(name) {
    if (name === 'mem' && !RG.pages.mem && RG.pages.cpu) return 'cpu';
    if (!RG.pages[name] && LEGACY[name]) name = LEGACY[name];
    return RG.pages[name] ? name : 'home';
  }
  RG.nextAt = 0;

  RG.theme = function (t) {
    if (t === undefined) { try { return localStorage.getItem('rg-theme') || 'auto'; } catch (e) { return 'auto'; } }
    try { localStorage.setItem('rg-theme', t); } catch (e) { }
    if (t === 'auto') document.documentElement.removeAttribute('data-theme'); else document.documentElement.setAttribute('data-theme', t);
    var b = $('#themeBtn'); if (b) b.innerHTML = RG.icon(dark() ? 'sun' : 'moon');
    var p = RG.pages[RG.cur]; if (p && p.live) p.live();
  };
  function dark() { var t = RG.theme(); return t === 'dark' || (t === 'auto' && window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches); }

  RG.go = function (name, noHash) {
    var wantAgent = name === 'agent';
    if (wantAgent) name = 'home';
    name = resolve(name);
    RG.cur = name;
    if (wantAgent) { noHash = false; setTimeout(function () { RG.askAgent(); }, 60); }
    // Mục nav sáng theo màn đang mở; trang cũ (clean/policy/cpu) thuộc về mục của màn thay thế.
    var navOf = { clean: 'disk', policy: 'disk', cpu: 'mem' }[name] || name;
    RG.$$('#nav button').forEach(function (b) { if (b.dataset.p === navOf) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
    $('#pageTitle').textContent = RG.pages[name].title;
    if (!noHash) history.replaceState(null, '', '#' + name);
    var el = $('#page'); el.innerHTML = ''; window.scrollTo(0, 0);
    RG.pages[name].render(el);
    document.title = (S.live ? '[' + RG.human.state(S.live.state) + '] ' : '') + 'Resource Guard · ' + RG.pages[name].title;
  };
  /* Badge trạng thái bấm được: popover liệt kê lý do + nút sang màn liên quan. */
  function setBadge(r) {
    var b = $('#badge'), why = RG.human.reasons(r);
    b.textContent = RG.human.state(r.state); b.className = 'badge ' + r.state;
    b.title = why.length ? why.join('; ') : 'Mọi chỉ số trong ngưỡng';
    b.setAttribute('aria-haspopup', 'true');
    if (RG.$('#badgePop')) RG.statusBadge(true);
  }
  RG.statusBadge = function (refresh) {
    var old = RG.$('#badgePop'), b = $('#badge');
    if (old && !refresh) { old.parentNode.removeChild(old); b.setAttribute('aria-expanded', 'false'); return; }
    if (old) old.parentNode.removeChild(old);
    var items = RG.human.reasonItems(S.live), h = '<div class="pop-h">Trạng thái: <b>' + RG.esc(RG.human.state(S.live && S.live.state)) + '</b></div>';
    h += items.length ? items.map(function (x, i) { return '<div class="pop-row"><span>' + RG.esc(x.text) + '</span><button class="btn sm" data-go="' + RG.esc(x.go) + '">Xem</button></div>'; }).join('') : '<div class="pop-row mut">Mọi chỉ số đang trong ngưỡng.</div>';
    var p = document.createElement('div'); p.id = 'badgePop'; p.className = 'pop'; p.setAttribute('role', 'dialog'); p.setAttribute('aria-label', 'Lý do trạng thái'); p.innerHTML = h;
    b.parentNode.appendChild(p); b.setAttribute('aria-expanded', 'true');
    RG.$$('[data-go]', p).forEach(function (x) { x.onclick = function () { p.parentNode.removeChild(p); b.setAttribute('aria-expanded', 'false'); RG.go(x.dataset.go); }; });
  };
  document.addEventListener('click', function (e) { var p = RG.$('#badgePop'); if (p && !p.contains(e.target) && e.target.id !== 'badge') { p.parentNode.removeChild(p); var bb = $('#badge'); if (bb) bb.setAttribute('aria-expanded', 'false'); } });
  document.addEventListener('keydown', function (e) { if (e.key === 'Escape') { var p = RG.$('#badgePop'); if (p) { p.parentNode.removeChild(p); var bb = $('#badge'); if (bb) { bb.setAttribute('aria-expanded', 'false'); bb.focus(); } } } });

  function driveSig(a) { return (a || []).map(function (d) { return d.drive; }).join(','); }
  function onLive(r) {
    // Tập ổ thay đổi (cắm/rút ổ): nạp lại meta (ngưỡng, chính sách) và vẽ lại trang.
    var changed = S.live && driveSig(S.live.drives) !== driveSig(r.drives);
    S.live = r;
    /* Có số liệu là đang kết nối: đừng để chấm đỏ "đang kết nối…" khi onopen tới muộn (SSE xếp hàng sau request chậm). */
    if (!r.stale) { lostAt = 0; $('#lost').classList.remove('on'); $('#dot').className = 'dot on'; }
    if (changed) {
      if (S.driveSel && !(r.drives || []).some(function (d) { return d.drive === S.driveSel; })) S.driveSel = null;
      RG.loadDrives().catch(function () { }).then(function () { var q = RG.pages[RG.cur]; if (q && q.render && (RG.cur === 'home' || RG.cur === 'disk')) RG.go(RG.cur, true); });
    }
    S.hist.push(r); if (S.hist.length > MAX) S.hist.shift();
    setBadge(r);
    /* r.stale = bản số liệu lần chạy trước server nạp sẵn để có gì hiển thị ngay; tick thật sẽ thay trong vài giây. */
    var ct = $('#connTxt'); if (ct) { if (r.stale) ct.textContent = 'đang cập nhật…'; else if (ct.textContent !== 'trực tiếp') ct.textContent = 'trực tiếp'; }
    RG.nextAt = Date.now() + (r.intervalSec || 15) * 1000;
    if (S.settings) S.settings.intervalSec = r.intervalSec || S.settings.intervalSec;
    document.title = '[' + RG.human.state(r.state) + '] Resource Guard · ' + RG.pages[RG.cur].title;
    var p = RG.pages[RG.cur]; if (p && p.live) p.live();
  }
  var es = null, lostAt = 0;
  function connect() {
    es = new EventSource('/events');
    es.onopen = function () { lostAt = 0; $('#lost').classList.remove('on'); $('#dot').className = 'dot on'; $('#connTxt').textContent = 'trực tiếp'; };
    es.onmessage = function (m) { try { onLive(JSON.parse(m.data)); } catch (e) { } };
    es.onerror = function () { if (!lostAt) lostAt = Date.now(); $('#dot').className = 'dot'; $('#connTxt').textContent = 'mất kết nối, đang thử lại…'; };
  }
  setInterval(function () { if (lostAt && Date.now() - lostAt > 12000) $('#lost').classList.add('on'); }, 2000);

  /* Thoát: xác nhận -> /api/shutdown (server dừng êm) -> màn hình "đã dừng" kèm cách mở lại. */
  function showStopped() {
    if (es) es.close();
    lostAt = 0; document.title = 'Resource Guard đã dừng';
    var d = document.createElement('div'); d.className = 'stopped'; d.setAttribute('role', 'alertdialog'); d.setAttribute('aria-label', 'Resource Guard đã dừng');
    d.innerHTML = '<div class="card">' + RG.icon('shield') + '<h2>Resource Guard đã dừng</h2>' +
      '<p class="mut">Giám sát realtime và tự dọn nền đã tắt. Không có file nào bị thay đổi.</p>' +
      '<p>Mở lại bằng lối tắt <b>Resource Guard</b> trong Start Menu, hoặc chạy <code>rg start</code>. Có thể đóng tab này.</p></div>';
    document.body.appendChild(d);
  }
  RG.quit = function () {
    RG.confirm('Thoát Resource Guard?',
      '<p>Giám sát realtime sẽ dừng. <b>Tự dọn nền chỉ hoạt động khi Resource Guard đang chạy</b>, nên sẽ không dọn khi đã tắt.</p>' +
      '<p class="mut">Lượt quét ổ đĩa hoặc agent đang chạy sẽ bị huỷ. Mở lại bất cứ lúc nào bằng lối tắt Resource Guard hoặc <code>rg start</code>.</p>', 'Thoát', true)
      .then(function (ok) {
        if (!ok) return;
        RG.api('/api/shutdown', { method: 'POST' }).then(showStopped)
          .catch(function (e) { RG.toast(e.data && e.data.busy ? e.message + ' Hãy chờ lượt đó xong rồi thử lại.' : 'Không thoát được: ' + e.message, 'err', 9000); });
      });
  };

  function init() {
    $('#nav').innerHTML = NAV.map(function (n) {
      return '<button data-p="' + n[0] + '">' + RG.icon(n[1]) + '<span class="lbl">' + n[2] + '</span>' + (n[0] === 'disk' ? '<span class="cnt" id="navDiskCnt" hidden>0</span>' : '') + '</button>';
    }).join('');
    RG.$$('#nav button').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.p); }; });
    $('#badge').onclick = function () { RG.statusBadge(); };
    $('#themeBtn').onclick = function () { RG.theme(dark() ? 'light' : 'dark'); };
    $('#quitBtn').onclick = function () { RG.quit(); };
    RG.api('/api/about').then(function (a) { S.about = a; var v = $('#verTxt'); if (v && a && a.version) { v.textContent = 'Phiên bản ' + a.version; v.title = 'Cài đặt → Giới thiệu'; } }).catch(function () { });
    $('#themeBtn').innerHTML = RG.icon(dark() ? 'sun' : 'moon');
    var t = RG.theme(); if (t !== 'auto') document.documentElement.setAttribute('data-theme', t);
    window.addEventListener('resize', function () { var p = RG.pages[RG.cur]; if (p && p.live) p.live(); });
    if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () { var p = RG.pages[RG.cur]; if (p && p.live) p.live(); });
    window.addEventListener('hashchange', function () { RG.go(location.hash.slice(1), true); });
    setInterval(function () { var s = Math.max(0, Math.round((RG.nextAt - Date.now()) / 1000)); $('#cd').textContent = RG.nextAt ? s : '–'; }, 500);

    /* Vẽ trang ngay khi có số liệu cần thiết (cài đặt + lịch sử, đều nhẹ); phần nặng (chính sách, ứng viên dọn, ổ đĩa) nạp song song,
       chờ tối đa 1,2 giây rồi vẽ luôn, xong thì làm tươi lại. Trước đây phải chờ hết mọi API nên trang trống tới hàng chục giây khi server đang lấy mẫu đầu tiên. */
    var painted = false;
    function firstPaint() {
      if (painted) return; painted = true;
      if (S.hist.length && !S.live) S.live = S.hist[S.hist.length - 1];
      RG.updateNavBadges();
      if (S.live) setBadge(S.live);
      RG.go(location.hash.slice(1) || 'home', true);
      connect(); RG.watchJobs(); RG.setup.check();
      /* Chưa có lịch sử (máy mới cài): lấy bản tức thời của server thay vì chờ tin SSE đầu tiên. */
      if (!S.live) RG.api('/api/state').then(function (j) { if (j && j.state && !S.live) onLive(j); }).catch(function () { });
    }
    var fast = Promise.all([
      RG.api('/api/settings').then(function (s) { S.settings = s; S.thr = s.thresholds; }).catch(function () { }),
      RG.api('/api/history').then(function (h) { S.hist = (h || []).slice(-MAX); }).catch(function () { })
    ]);
    var rest = Promise.all([
      RG.loadPolicy().catch(function () { }),
      RG.loadCands().catch(function () { }),
      RG.loadDrives().catch(function () { }).then(function () { return RG.loadDisk(); }).catch(function () { })
    ]);
    fast.then(function () {
      var t = setTimeout(firstPaint, 1200);
      rest.then(function () {
        clearTimeout(t);
        if (!painted) { firstPaint(); return; }
        RG.updateNavBadges();
        if (RG.cur === 'home' || RG.cur === 'disk') RG.go(RG.cur, true);
      });
    });
  }
  init();
})();
