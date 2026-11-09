/* boot.js - khung ứng dụng: điều hướng, theme, SSE realtime, khởi tạo. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, $ = RG.$, MAX = 480;
  var NAV = [['overview', 'home', 'Tổng quan'], ['cpu', 'cpu', 'CPU & Tiến trình'], ['disk', 'disk', 'Ổ đĩa'], ['clean', 'trash', 'Dọn dẹp'], ['policy', 'policy', 'Chính sách tự động'], ['agent', 'spark', 'Agent đánh giá'], ['settings', 'gear', 'Cài đặt']];
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
    if (!RG.pages[name]) name = 'overview';
    RG.cur = name;
    RG.$$('#nav button').forEach(function (b) { if (b.dataset.p === name) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
    $('#pageTitle').textContent = RG.pages[name].title;
    if (!noHash) history.replaceState(null, '', '#' + name);
    var el = $('#page'); el.innerHTML = ''; window.scrollTo(0, 0);
    RG.pages[name].render(el);
    document.title = (S.live ? '[' + S.live.state + '] ' : '') + 'Resource Guard · ' + RG.pages[name].title;
  };

  function onLive(r) {
    S.live = r; S.hist.push(r); if (S.hist.length > MAX) S.hist.shift();
    var b = $('#badge'); b.textContent = r.state; b.className = 'badge ' + r.state;
    RG.nextAt = Date.now() + (r.intervalSec || 15) * 1000;
    if (S.settings) S.settings.intervalSec = r.intervalSec || S.settings.intervalSec;
    document.title = '[' + r.state + '] Resource Guard · ' + RG.pages[RG.cur].title;
    var p = RG.pages[RG.cur]; if (p && p.live) p.live();
    onLive.n = (onLive.n || 0) + 1; if (RG.cur === 'overview' && onLive.n % 4 === 0) p.refresh();
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
      return '<button data-p="' + n[0] + '">' + RG.icon(n[1]) + '<span class="lbl">' + n[2] + '</span>' + (n[0] === 'clean' ? '<span class="cnt" id="navCleanCnt" hidden>0</span>' : '') + '</button>';
    }).join('');
    RG.$$('#nav button').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.p); }; });
    $('#themeBtn').onclick = function () { RG.theme(dark() ? 'light' : 'dark'); };
    $('#askBtn').onclick = function () { RG.askAgent(); };
    $('#quitBtn').onclick = function () { RG.quit(); };
    $('#askBtn').insertAdjacentHTML('afterbegin', RG.icon('spark'));
    $('#themeBtn').innerHTML = RG.icon(dark() ? 'sun' : 'moon');
    var t = RG.theme(); if (t !== 'auto') document.documentElement.setAttribute('data-theme', t);
    window.addEventListener('resize', function () { var p = RG.pages[RG.cur]; if (p && p.live) p.live(); });
    if (window.matchMedia) window.matchMedia('(prefers-color-scheme: dark)').addEventListener('change', function () { var p = RG.pages[RG.cur]; if (p && p.live) p.live(); });
    window.addEventListener('hashchange', function () { RG.go(location.hash.slice(1), true); });
    setInterval(function () { var s = Math.max(0, Math.round((RG.nextAt - Date.now()) / 1000)); $('#cd').textContent = RG.nextAt ? s : '–'; }, 500);

    Promise.all([
      RG.api('/api/settings').then(function (s) { S.settings = s; S.thr = s.thresholds; }),
      RG.api('/api/history').then(function (h) { S.hist = (h || []).slice(-MAX); }),
      RG.loadPolicy().catch(function () { }),
      RG.loadCands().catch(function () { }),
      RG.loadDisk().catch(function () { })
    ]).catch(function () { }).then(function () {
      if (S.hist.length) S.live = S.hist[S.hist.length - 1];
      RG.updateNavBadges();
      RG.go(location.hash.slice(1) || 'overview', true);
      connect(); RG.watchJobs();
    });
  }
  init();
})();
