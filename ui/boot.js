/* boot.js - khung ứng dụng: điều hướng, theme, SSE realtime, khởi tạo. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, $ = RG.$, MAX = 480;
  var NAV = [['home', 'home', 'Trang chủ'], ['clean', 'trash', 'Dọn dẹp'], ['disk', 'disk', 'Ổ đĩa'], ['cpu', 'cpu', 'Tiến trình'], ['policy', 'policy', 'Tự động hoá'], ['settings', 'gear', 'Cài đặt']];
  var ALIAS = { overview: 'home', '': 'home' };   // hash cũ; #agent mở ngăn kéo trợ lý ở Trang chủ
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
    if (ALIAS[name]) name = ALIAS[name];
    if (!RG.pages[name]) name = 'home';
    RG.cur = name;
    if (wantAgent) { noHash = false; setTimeout(function () { RG.askAgent(); }, 60); }
    RG.$$('#nav button').forEach(function (b) { if (b.dataset.p === name) b.setAttribute('aria-current', 'page'); else b.removeAttribute('aria-current'); });
    $('#pageTitle').textContent = RG.pages[name].title;
    if (!noHash) history.replaceState(null, '', '#' + name);
    var el = $('#page'); el.innerHTML = ''; window.scrollTo(0, 0);
    RG.pages[name].render(el);
    document.title = (S.live ? '[' + RG.human.state(S.live.state) + '] ' : '') + 'Resource Guard · ' + RG.pages[name].title;
  };
  function setBadge(r) {
    var b = $('#badge'), why = RG.human.reasons(r);
    b.textContent = RG.human.state(r.state); b.className = 'badge ' + r.state;
    b.title = why.length ? why.join('; ') : 'Mọi chỉ số trong ngưỡng';
  }

  function driveSig(a) { return (a || []).map(function (d) { return d.drive; }).join(','); }
  function onLive(r) {
    // Tập ổ thay đổi (cắm/rút ổ): nạp lại meta (ngưỡng, chính sách) và vẽ lại trang.
    var changed = S.live && driveSig(S.live.drives) !== driveSig(r.drives);
    S.live = r;
    if (changed) {
      if (S.driveSel && !(r.drives || []).some(function (d) { return d.drive === S.driveSel; })) S.driveSel = null;
      RG.loadDrives().catch(function () { }).then(function () { var q = RG.pages[RG.cur]; if (q && q.render && (RG.cur === 'home' || RG.cur === 'disk' || RG.cur === 'policy')) RG.go(RG.cur, true); });
    }
    S.hist.push(r); if (S.hist.length > MAX) S.hist.shift();
    setBadge(r);
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
      return '<button data-p="' + n[0] + '">' + RG.icon(n[1]) + '<span class="lbl">' + n[2] + '</span>' + (n[0] === 'clean' ? '<span class="cnt" id="navCleanCnt" hidden>0</span>' : '') + '</button>';
    }).join('');
    RG.$$('#nav button').forEach(function (b) { b.onclick = function () { RG.go(b.dataset.p); }; });
    $('#themeBtn').onclick = function () { RG.theme(dark() ? 'light' : 'dark'); };
    $('#quitBtn').onclick = function () { RG.quit(); };
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
      RG.loadDrives().catch(function () { }).then(function () { return RG.loadDisk(); }).catch(function () { })
    ]).catch(function () { }).then(function () {
      if (S.hist.length) S.live = S.hist[S.hist.length - 1];
      RG.updateNavBadges();
      if (S.live) setBadge(S.live);
      RG.go(location.hash.slice(1) || 'home', true);
      connect(); RG.watchJobs(); RG.setup.check();
    });
  }
  init();
})();
