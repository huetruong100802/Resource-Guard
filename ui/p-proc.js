/* p-proc.js - Bộ nhớ & tiến trình (#mem): ai đang dùng RAM theo việc đang làm, chi tiết bên phải, "nếu đóng", hạ ưu tiên (đảo ngược được)
   và Kết thúc tiến trình (B1): chỉ hiện nút cho lớp tiến trình được phép (server quyết định, canEnd/whyNotEnd), có hộp xác nhận trước → sau;
   tiến trình đang do trợ lý AI giữ thì cần PIN. Phần CPU theo thời gian, từng nhân, thông tin máy gập sẵn ở cuối. Giữ alias RG.pages.cpu. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, MB = 1048576;
  var P = { procs: [], wl: [], loaded: false, logical: 1, busy: false, mode: 'wl', filter: '', open: {}, sel: null, minutes: 60, cmdOpen: false, bar: null, offs: [] };

  function roleColor(role) { return 'var(--role-' + (role || 'unknown') + ')'; }
  function idOf(r) { return (r && r.identity) || {}; }
  function wlBase(w) { return (w.title || RG.human.role(w.role)) + (w.project ? ' · ' + w.project : ''); }
  // Nhiều nhóm cùng tên (vd. 3 dòng "Trình duyệt") thì thêm tên chương trình lớn nhất để phân biệt.
  function wlTitle(w) {
    var b = wlBase(w), d = 0, i;
    for (i = 0; i < P.wl.length; i++) if (wlBase(P.wl[i]) === b) d++;
    if (d > 1) { var m = procsOf(w.key)[0]; if (m && m.name) b += ' (' + String(m.name).replace(/\.exe$/i, '') + ')'; }
    return b;
  }
  function wlByKey(k) { for (var i = 0; i < P.wl.length; i++) if (P.wl[i].key === k) return P.wl[i]; return null; }
  function procsOf(k) { return P.procs.filter(function (r) { return idOf(r).workload === k; }).sort(function (a, b) { return b.ramMB - a.ramMB; }); }
  function procBy(pid, start) { for (var i = 0; i < P.procs.length; i++) if (String(P.procs[i].pid) === String(pid) && (!start || P.procs[i].start === start)) return P.procs[i]; return null; }
  function sumRam(ms) { return ms.reduce(function (a, m) { return a + m.ramMB; }, 0); }
  function sumCpu(ms) { return ms.reduce(function (a, m) { return a + m.cpu; }, 0); }
  function totalRamMB() { return (S.live && S.live.totalRamGB ? S.live.totalRamGB * 1024 : 0); }
  function ago(start) { var t = RG.tsMs(start), s = (Date.now() - t) / 1000; return (isNaN(t) || s < 0 || s > 31536000) ? '' : 'chạy ' + RG.fmtDur(s); }

  /* Mục đang chọn -> { ms, rep, title, id, key } */
  function selInfo() {
    var s = P.sel; if (!s) return null;
    if (s.t === 'w') {
      var w = wlByKey(s.k); if (!w) return null;
      var ms = procsOf(w.key); if (!ms.length) return null;
      var rid = idOf(ms[0]);
      return { ms: ms, rep: ms[0], title: wlTitle(w), key: w.key, role: w.role, id: { what: rid.what || w.what, owner: rid.owner || w.owner, chain: rid.chain, closeHint: rid.closeHint || w.closeHint, confidence: rid.confidence, project: w.project }, wl: w };
    }
    var r = procBy(s.k, s.s); if (!r) return null;
    var id = idOf(r);
    return { ms: [r], rep: r, title: r.name + ' (PID ' + r.pid + ')', key: id.workload, role: id.role, id: id };
  }

  /* ----- Thanh RAM trước → sau ----- */
  function drawBar() {
    var l = S.live, el = $('#mBar'); if (!l || !el) return;
    var tot = l.totalRamGB, free = Math.min(tot, l.availRamGB), used = Math.max(0, tot - free), segs = [], sum = 0;
    P.wl.slice().sort(function (a, b) { return b.ramMB - a.ramMB; }).slice(0, 6).forEach(function (w) {
      var v = w.ramMB / 1024; if (v <= 0) return;
      segs.push({ key: w.key, label: wlTitle(w), value: v, color: roleColor(w.role) }); sum += v;
    });
    if (sum > used && sum > 0) { var k = used / sum; segs.forEach(function (s) { s.value *= k; }); sum = used; }
    if (used - sum > 0.01) segs.push({ key: '_other', label: 'Khác', value: used - sum, color: 'var(--role-unknown)' });
    var si = selInfo(), gain = si ? Math.min(used, sumRam(si.ms) / 1024) : 0, t = S.thr && S.thr.ramAvailGB;
    var st0 = RG.human.state(RG.ramState(free)), cap;
    if (gain > 0.001) cap = 'Nếu đóng mục đang chọn: trống <b>' + RG.fmtGB(free) + ' → ' + RG.fmtGB(free + gain) + '</b> · ' + (st0 === RG.human.state(RG.ramState(free + gain)) ? st0 + ', chưa đổi mức' : st0 + ' → ' + RG.human.state(RG.ramState(free + gain)));
    else cap = 'Trống <b>' + RG.fmtGB(free) + '</b> · ' + st0 + ' · bấm một đoạn hoặc một dòng để xem trước kết quả nếu đóng';
    P.bar = V.resourceBar(el, { total: tot, segments: segs, free: free, gain: gain, caption: cap, leftLabel: 'Đã dùng ' + RG.fmtGB(used), rightLabel: 'Tổng ' + RG.fmtGB(tot), fmt: RG.fmtGB,
      aria: 'RAM: đã dùng ' + RG.fmtGB(used) + ' trên ' + RG.fmtGB(tot) + ', còn trống ' + RG.fmtGB(free),
      marks: [],
      band: t ? [   // dải trạng thái mỏng cùng thang với thanh (vị trí = tổng − RAM trống); rê chuột mới có giải thích
        { from: 0, to: Math.max(0, tot - t.normalAbove), color: RG.stateColor('Normal'), label: 'Ổn: trống từ ' + RG.fmtGB(t.normalAbove) + ' trở lên' },
        { from: Math.max(0, tot - t.normalAbove), to: Math.max(0, tot - t.cautionFrom), color: RG.stateColor('Caution'), label: 'Cần chú ý: trống dưới ' + RG.fmtGB(t.normalAbove) },
        { from: Math.max(0, tot - t.cautionFrom), to: Math.max(0, tot - t.restrictedFrom), color: RG.stateColor('Restricted'), label: 'Hạn chế: trống dưới ' + RG.fmtGB(t.cautionFrom) },
        { from: Math.max(0, tot - t.restrictedFrom), to: tot, color: RG.stateColor('Critical'), label: 'Nguy cấp: trống dưới ' + RG.fmtGB(t.restrictedFrom) }] : null,
      legendHtml: segs.map(function (g) { return '<span class="rb-lg"><i style="background:' + g.color + '"></i>' + RG.esc(g.label) + ' <b class="num">' + RG.fmtGB(g.value) + '</b></span>'; }).join(''),
      onPick: function (key) { if (key && key !== '_other') select({ t: 'w', k: key }, true); } });
    var dn = $('#mDn'); if (dn) {
      var rows = segs.concat([{ key: 'free', label: 'RAM trống', value: free, color: 'var(--free)' }]);
      V.donut(dn, rows, tot, { big: RG.fmtGB(free + gain), small: gain > 0.001 ? 'trống nếu đóng' : 'trống' }, 112, 20, { fmt: RG.fmtGB });
      V.legend($('#mLg'), rows.slice(0, 7), { fmt: RG.fmtGB });
    }
  }

  /* ----- Danh sách bên trái ----- */
  function procMatch(r, f) { var id = idOf(r); return r.name.toLowerCase().indexOf(f) >= 0 || String(r.pid) === f || (id.project || '').toLowerCase().indexOf(f) >= 0 || (id.title || '').toLowerCase().indexOf(f) >= 0; }
  function procRow(r, flat) {
    var id = idOf(r), sel = P.sel && P.sel.t === 'p' && String(P.sel.k) === String(r.pid) && P.sel.s === r.start;
    var sub = [];
    if (id.owner && id.owner.label) sub.push('do ' + id.owner.label + ' mở');
    if (id.what) sub.push(id.what);
    if (flat && id.project) sub.unshift(id.project);
    var a = ago(r.start); if (a) sub.push(a);
    return '<div class="mm-p' + (sel ? ' sel' : '') + '" tabindex="0" role="button" data-pid="' + r.pid + '" data-start="' + esc(r.start) + '" data-wk="' + esc(id.workload || '') + '">' +
      (flat ? '<i class="mm-sw" style="background:' + roleColor(id.role) + '"></i>' : '') +
      '<span class="mm-pt"><span class="mono">' + esc(r.name) + '</span>' + (flat ? ' <span class="mut small">PID ' + r.pid + '</span>' : '') + (r.lowered ? ' <span class="pill ask">đang hạ ưu tiên</span>' : '') + (r.protected ? ' <span class="pill keep">bảo vệ</span>' : '') +
      '<span class="mut small mm-sub">' + esc(sub.join(' · ')) + '</span></span><span class="num mm-ram">' + RG.fmtBytes(r.ramMB * MB) + '</span><span class="num mm-cpu mut">' + RG.fmtPct(r.cpu) + '</span></div>';
  }
  function drawList() {
    var el = $('#mList'); if (!el) return;
    var f = P.filter.trim().toLowerCase(), html = '', n = 0, shown = 0;
    if (!P.loaded) { RG.empty(el, { compact: true, title: 'Đang tải…' }); $('#mCount').textContent = '–'; return; }
    if (P.mode === 'wl') {
      var ws = P.wl.slice().sort(function (a, b) { return b.ramMB - a.ramMB; }); n = ws.length;
      ws.forEach(function (w) {
        if (shown >= 200) return;
        var ms = procsOf(w.key), hit = false;
        if (f) { hit = (wlTitle(w) + ' ' + w.key).toLowerCase().indexOf(f) >= 0; if (!hit) { var mh = ms.some(function (r) { return procMatch(r, f); }); if (!mh) return; } }
        shown++;
        var open = P.open[w.key] || (f && !hit), sel = P.sel && P.sel.t === 'w' && P.sel.k === w.key;
        html += '<div class="mm-g"><div class="mm-gh' + (sel ? ' sel' : '') + '" tabindex="0" role="button" aria-expanded="' + !!open + '" data-wk="' + esc(w.key) + '">' +
          '<button class="mm-car" data-car="' + esc(w.key) + '" aria-label="' + (open ? 'Gập' : 'Mở') + ' ' + esc(wlTitle(w)) + '">' + (open ? '▾' : '▸') + '</button>' +
          '<i class="mm-sw" style="background:' + roleColor(w.role) + '"></i><span class="mm-pt"><b>' + esc(wlTitle(w)) + '</b>' + (w.count > 1 ? ' <span class="mut small">(' + w.count + ' tiến trình)</span>' : '') +
          (w.protected ? ' <span class="pill keep">bảo vệ</span>' : '') + '<span class="mut small mm-sub">' + esc(w.what || RG.human.role(w.role)) + '</span></span>' +
          '<span class="num mm-ram">' + RG.fmtBytes(w.ramMB * MB) + '</span><span class="num mm-cpu mut">' + (w.cpuPct >= 0.5 ? RG.fmtPct(w.cpuPct) + ' CPU' : 'nghỉ') + '</span></div>' +
          (open ? '<div class="mm-ms">' + ms.slice(0, 15).map(function (r) { return procRow(r, false); }).join('') + (ms.length > 15 ? '<div class="small mut mm-more">… và ' + (ms.length - 15) + ' tiến trình nhỏ hơn cùng nhóm</div>' : '') + '</div>' : '') + '</div>';
      });
    } else {
      var rows = P.procs.slice().sort(function (a, b) { return b.ramMB - a.ramMB; }); n = rows.length;
      rows.forEach(function (r) { if (shown >= 200) return; if (f && !procMatch(r, f)) return; shown++; html += procRow(r, true); });
    }
    if (!html) { RG.empty(el, { compact: true, title: 'Không có kết quả.' }); }
    else el.innerHTML = html + (shown >= 200 ? '<div class="small mut mm-more">Chỉ hiện 200 dòng đầu; gõ vào ô lọc để thu hẹp.</div>' : '');
    $('#mCount').textContent = shown + ' / ' + n;
    bindList(el);
  }
  function bindList(el) {
    function pick(t) {
      var c = t.closest('[data-car]'); if (c) { var k = c.dataset.car; P.open[k] = !P.open[k]; drawList(); return; }
      var p = t.closest('.mm-p'); if (p) { select({ t: 'p', k: p.dataset.pid, s: p.dataset.start }); return; }
      var g = t.closest('.mm-gh'); if (g) select({ t: 'w', k: g.dataset.wk });
    }
    el.onclick = function (e) { pick(e.target); };
    el.onkeydown = function (e) { if ((e.key === 'Enter' || e.key === ' ') && e.target.matches && e.target.matches('.mm-gh,.mm-p')) { e.preventDefault(); pick(e.target); } };
    el.onmouseover = function (e) { var n = e.target.closest && e.target.closest('[data-wk]'); if (n && P.bar && n.dataset.wk) P.bar.highlight(n.dataset.wk); };
    el.onmouseleave = function () { if (P.bar) P.bar.highlight(null); };
  }

  /* ----- Chọn mục ----- */
  function select(sel, scroll) {
    P.sel = sel; P.cmdOpen = false;
    if (sel && sel.t === 'w') { P.open[sel.k] = P.open[sel.k] || false; }
    drawList(); drawDetail(); drawBar();
    if (scroll) { var n = $('#mList .mm-gh.sel'); if (n && n.scrollIntoView) n.scrollIntoView({ block: 'nearest' }); }
  }

  /* ----- Khung chi tiết bên phải ----- */
  function memberTable(si) {
    // Chỉ liệt kê tiến trình đang dùng CPU (hoặc đang bị hạ): hạ ưu tiên tiến trình đang nghỉ không đổi được gì.
    var busy = si.ms.filter(function (m) { return m.cpu >= 1 || m.lowered; }), ms = busy.slice(0, 8);
    if (!busy.length) return '<tr><td colspan="4" class="small mut">Cả ' + si.ms.length + ' tiến trình đang nghỉ nên không cần hạ ưu tiên. Mục này chỉ giúp khi có tiến trình ngốn CPU.</td></tr>';
    return ms.map(function (m) {
      var act = m.lowered ? '<button class="btn sm" data-lv="normal" data-pid="' + m.pid + '" data-start="' + esc(m.start) + '">Trả về bình thường</button>' :
        (m.canLower ? '<button class="btn sm" data-lv="below" data-pid="' + m.pid + '" data-start="' + esc(m.start) + '">Hạ ưu tiên</button>' : '<span class="small mut" title="' + esc(m.whyNot) + '">' + RG.icon('info') + ' ' + esc(m.whyNot || 'Không hạ được') + '</span>');
      return '<tr><td><span class="mono">' + esc(m.name) + '</span> <span class="mut small">PID ' + m.pid + '</span></td><td class="r num">' + RG.fmtPct(m.cpu) + '</td><td class="r num">' + RG.fmtBytes(m.ramMB * MB) + '</td><td>' + (m.lowered ? '<span class="pill ask">đang hạ</span> ' : '') + act + '</td></tr>';
    }).join('') + (busy.length > 8 ? '<tr><td colspan="4" class="small mut">… và ' + (busy.length - 8) + ' tiến trình khác (chọn riêng ở chế độ “Từng tiến trình”)</td></tr>' : '');
  }
  /* Kết thúc tiến trình: tối đa 8 tiến trình lớn nhất của mục đang chọn; nút chỉ hiện khi server nói canEnd, nếu không thì nêu lý do. */
  function endTable(si) {
    var ms = si.ms.slice().sort(function (a, b) { return b.ramMB - a.ramMB; }), shown = ms.slice(0, 8);
    var rows = shown.map(function (m) {
      var act = m.canEnd ? '<button class="btn sm danger" data-end="1" data-pid="' + m.pid + '" data-start="' + esc(m.start) + '">Kết thúc' + (m.endNeedsPin ? ' (cần PIN)' : '') + '</button>' :
        '<span class="small mut" title="' + esc(m.whyNotEnd) + '">' + RG.icon('info') + ' ' + esc(m.whyNotEnd || 'Không kết thúc được') + '</span>';
      return '<tr><td><span class="mono">' + esc(m.name) + '</span> <span class="mut small">PID ' + m.pid + '</span></td><td class="r num">' + RG.fmtBytes(m.ramMB * MB) + '</td><td>' + act + '</td></tr>';
    }).join('');
    return rows + (ms.length > 8 ? '<tr><td colspan="3" class="small mut">… và ' + (ms.length - 8) + ' tiến trình nhỏ hơn (chọn riêng ở chế độ “Từng tiến trình”)</td></tr>' : '');
  }
  /* Hộp xác nhận trước → sau, rồi (nếu cần) hỏi PIN, rồi gọi server. Server kiểm lại mọi điều kiện lúc thực thi. */
  function endProc(btn) {
    var pid = +btn.dataset.pid, start = btn.dataset.start, m = procBy(pid, start);
    if (!m) { RG.toast('Tiến trình không còn trong danh sách. Hãy tải lại.', 'err'); return; }
    var l = S.live, free = l ? l.availRamGB : null, gain = m.ramMB / 1024;
    var html = '<p>Kết thúc <b>' + esc(m.name) + '</b> (PID ' + pid + ')? Việc chưa lưu trong tiến trình này sẽ mất; cửa sổ (nếu có) được yêu cầu đóng êm trước, không đóng thì buộc dừng.</p>' +
      (free != null ? '<p>RAM trống: <b>' + RG.fmtGB(free) + ' → ' + RG.fmtGB(free + gain) + '</b> <span class="mut small">(ước tính theo bộ nhớ đang dùng)</span></p>' : '') +
      (m.endNeedsPin ? '<p class="hint">Tiến trình này đang do trợ lý AI giữ nên cần PIN.</p>' : '') +
      '<p class="mut small">Các tiến trình con thuộc nhóm build/test/dev của nó cũng được kết thúc; việc kết thúc được ghi vào nhật ký.</p>';
    RG.confirm('Kết thúc tiến trình?', html, 'Kết thúc', true).then(function (ok) {
      if (!ok) return;
      var send = function (pin) {
        btn.disabled = true;
        RG.api('/api/process/end', { method: 'POST', body: { pid: pid, start: start, pin: pin || '' } }).then(function (j) {
          var kids = Math.max(0, (j.tree || []).length - 1);
          RG.toast('Đã kết thúc ' + (j.name || m.name) + ' (PID ' + pid + ')' + (kids ? ' và ' + kids + ' tiến trình con' : '') + '. Đã xác minh tiến trình thoát.', 'ok', 7000);
          RG.loadEvents().catch(function () { }).then(function () { drawLow(); });
          fetchProcs();
        }).catch(function (e) {
          var c = e.data && e.data.code;
          if (c === 'pin-required' || c === 'pin-wrong') {
            btn.disabled = false;
            RG.askPin(c === 'pin-wrong' ? 'PIN không đúng. Nhập lại:' : 'Tiến trình này do trợ lý AI giữ nên cần PIN.').then(function (p) { if (p) send(p); });
          } else { RG.toast(e.message, 'err', 9000); btn.disabled = false; fetchProcs(); }
        });
      };
      if (m.endNeedsPin) RG.askPin('Tiến trình này do trợ lý AI giữ nên cần PIN.').then(function (p) { if (p) send(p); }); else send('');
    });
  }
  function protButtons(si) {
    var names = [], seen = {}; si.ms.forEach(function (m) { if (!seen[m.name]) { seen[m.name] = 1; names.push(m); } });
    return names.slice(0, 6).map(function (m) {
      return '<button class="btn sm' + (m.protected ? ' primary' : '') + '" data-prot="' + esc(m.name) + '" aria-pressed="' + !!m.protected + '">' + RG.icon('shield') + (m.protected ? ' Đang bảo vệ ' : ' Bảo vệ ') + esc(m.name) + '</button>';
    }).join(' ') + (names.length > 6 ? ' <span class="small mut">… và ' + (names.length - 6) + ' tên khác</span>' : '');
  }
  function summaryHtml(si) {
    var ram = sumRam(si.ms), tot = totalRamMB();
    return si.ms.length + ' tiến trình · CPU ' + RG.fmtPct(sumCpu(si.ms)) + ' · ' + RG.fmtBytes(ram * MB) + (tot ? ' (' + RG.fmtPct(ram / tot * 100) + ' RAM máy)' : '');
  }
  function whatHtml(si) {
    var ram = sumRam(si.ms), ledger = si.ms.some(function (m) { return m.agent; }), ch = si.id.closeHint;
    return '<p>Đóng ' + (si.ms.length > 1 ? 'cả nhóm' : 'tiến trình này') + ' có thể giải phóng khoảng <b>' + RG.fmtBytes(ram * MB) + '</b> RAM <span class="mut small">(ước tính theo bộ nhớ đang dùng; số thực tế có thể khác)</span>.</p>' +
      (ch ? '<blockquote class="mm-hint">' + esc(ch) + '</blockquote>' : '') +
      '<p class="hint">Resource Guard không tự đóng ứng dụng' + (ledger ? ' của bạn (tiến trình agent đã đăng ký và mất chủ có thể dọn ở màn Ổ đĩa)' : '') + '. Có thể kết thúc từ mục “Kết thúc tiến trình” bên dưới với các loại an toàn (build, test, máy chủ dev…); còn lại hãy tự đóng sau khi lưu việc đang làm.</p>';
  }
  function cmdHtml(si) {
    var c = si.rep.cmd || ''; if (!c) return '<span class="mut small">Không đọc được dòng lệnh.</span>';
    var long = c.length > 140;
    return '<code class="mono mm-cmd' + (P.cmdOpen ? ' open' : '') + '">' + esc(P.cmdOpen || !long ? c : c.slice(0, 140) + '…') + '</code>' + (long ? ' <button class="btn sm" id="mCmdBtn" aria-expanded="' + !!P.cmdOpen + '">' + (P.cmdOpen ? 'Thu gọn' : 'Xem đủ') + '</button>' : '');
  }
  /* Giải thích tiến trình (D4): server dựng từ luật + cây tiến trình + file cài đặt + chữ ký số + ledger/lease; không dùng AI, chỉ đọc. */
  P.expl = P.expl || {};
  function explKey(si) { return si.rep.pid + '|' + (si.rep.start || ''); }
  function explainHtml(si) {
    var e = P.expl[explKey(si)];
    if (!si.rep.start) return '<span class="mut small">Chưa đọc được thời điểm khởi động; thử lại sau vài giây.</span>';
    if (!e) return '<button class="btn sm" id="mExplBtn">' + RG.icon('info') + ' Giải thích đầy đủ</button> <span class="small mut">đọc từ máy, không gửi đi đâu</span>';
    if (e.err) return '<span class="small" style="color:var(--bad)">' + esc(e.err) + '</span> <button class="btn sm" id="mExplBtn">Thử lại</button>';
    if (e.loading) return '<span class="small mut">Đang đọc…</span>';
    var sv = e.serving || {}, ins = e.install || {};
    return '<p class="mm-expl">' + esc(e.text) + '</p>' +
      (sv.kind && sv.kind !== 'none' ? '<div class="small"><span class="pill ask">đang phục vụ trợ lý AI</span> ' + esc(sv.detail) + '</div>' : '') +
      (ins.dir ? '<div class="small mut">Vị trí: <code class="mono">' + esc(ins.dir) + '</code>' + (ins.company ? ' · ' + esc(ins.company) : '') + ' · ' + (ins.signed ? 'có chữ ký số hợp lệ' : 'không xác minh được chữ ký số') + '</div>' : '') +
      '<div class="small mut">Nguồn: ' + esc((e.sources || []).join(', ')) + '</div>';
  }
  function loadExplain(si) {
    var k = explKey(si); P.expl[k] = { loading: true };
    var el = $('#mExpl'); if (el) el.innerHTML = explainHtml(si);
    RG.api('/api/process/explain?pid=' + encodeURIComponent(si.rep.pid) + '&start=' + encodeURIComponent(si.rep.start || '')).then(function (j) {
      P.expl[k] = j;
    }).catch(function (err) { P.expl[k] = { err: err.message || 'Không giải thích được tiến trình này.' }; }).then(function () {
      var s2 = selInfo(), el2 = $('#mExpl'); if (el2 && s2 && explKey(s2) === k) { el2.innerHTML = explainHtml(s2); var b = $('#mExplBtn'); if (b) b.onclick = function () { loadExplain(s2); }; }
    });
  }
  function drawDetail() {
    var el = $('#mDetail'); if (!el) return;
    var si = selInfo();
    if (!si) { if (P.loaded) P.sel = null; RG.empty(el, { icon: 'info', title: 'Chọn một dòng ở bên trái để xem đó là gì, của ai và đóng thì được bao nhiêu RAM.' }); return; }
    var id = si.id, guess = id.confidence === 'guess', chain = (id.chain && id.chain.length) ? id.chain : null;
    if (chain) { chain = chain.filter(function (c, i) { return i === 0 || c !== chain[i - 1]; }); if (chain.length < 2) chain = null; }
    var own = chain ? chain.map(esc).join(' → ') : (id.owner && id.owner.label ? esc(id.owner.label) : '<span class="mut">Chạy độc lập, không rõ do ai mở</span>');
    el.innerHTML = '<h3 class="mm-dh"><i class="mm-sw" style="background:' + roleColor(si.role) + '"></i>' + esc(si.title) + ' <span class="pill">' + esc(RG.human.role(si.role)) + '</span></h3>' +
      '<div class="small mut" id="mSum">' + summaryHtml(si) + '</div>' +
      '<dl class="kv mm-kv"><dt>Là gì</dt><dd>' + esc(id.what || 'Chưa nhận diện được') + (guess ? ' <span class="pill ask" title="Suy đoán từ tên và vị trí, không chắc chắn">phỏng đoán</span>' : '') + '</dd>' +
      '<dt>Của ai</dt><dd>' + own + (id.project ? '<div class="small mut">Dự án: ' + esc(id.project) + '</div>' : '') + '</dd>' +
      '<dt>Giải thích</dt><dd id="mExpl">' + explainHtml(si) + '</dd>' +
      '<dt>Dòng lệnh</dt><dd id="mCmd">' + cmdHtml(si) + '</dd></dl>' +
      '<h4 class="dh">Theo thời gian <span class="seg sm" role="group" aria-label="Khoảng thời gian">' + [[60, '1 giờ'], [360, '6 giờ'], [1440, '24 giờ']].map(function (x) { return '<button data-min="' + x[0] + '" aria-pressed="' + (P.minutes === x[0]) + '">' + x[1] + '</button>'; }).join('') + '</span></h4>' +
      '<div class="small mut">CPU (%) · ' + esc(si.rep.name) + '</div><svg id="dCpu" class="chart" style="height:80px" role="img" aria-label="CPU của ' + esc(si.rep.name) + ' theo thời gian"></svg>' +
      '<div class="small mut">RAM (MB)</div><svg id="dRam" class="chart" style="height:80px" role="img" aria-label="RAM của ' + esc(si.rep.name) + ' theo thời gian"></svg><div class="small mut" id="dNote"></div>' +
      '<h4 class="dh">Nếu đóng</h4><div id="mWhat">' + whatHtml(si) + '</div>' +
      '<h4 class="dh">Ưu tiên CPU' + RG.help('Hạ ưu tiên nhường CPU cho việc khác, không giải phóng RAM. Hoàn tác bất cứ lúc nào bằng “Trả về bình thường”.') + '</h4><table class="small"><thead><tr><th>Tiến trình</th><th class="r">CPU</th><th class="r">RAM</th><th></th></tr></thead><tbody id="mMem">' + memberTable(si) + '</tbody></table>' +
      '<h4 class="dh">Kết thúc tiến trình' + RG.help('Chỉ hiện nút cho loại an toàn: build, test, máy chủ dev, trình quản lý gói… Hệ thống, bảo mật, dịch vụ, Docker/SQL, vùng bạn bảo vệ và chính Resource Guard thì không bao giờ. Có hộp xác nhận trước khi thực hiện.') + '</h4><table class="small"><thead><tr><th>Tiến trình</th><th class="r">RAM</th><th></th></tr></thead><tbody id="mEnd">' + endTable(si) + '</tbody></table>' +
      '<h4 class="dh">Bảo vệ khỏi tự dọn' + RG.help('Tiến trình được bảo vệ không bao giờ bị tự dọn, kể cả khi nhóm đặt “Tự động”.') + '</h4><div id="mProt">' + protButtons(si) + '</div>';
    bindDetail(si); loadHistory(si.rep.name);
  }
  function bindDetail(si) {
    RG.$$('#mDetail [data-min]').forEach(function (b) { b.onclick = function () { P.minutes = +b.dataset.min; RG.$$('#mDetail [data-min]').forEach(function (x) { x.setAttribute('aria-pressed', x === b); }); var s = selInfo(); if (s) loadHistory(s.rep.name); }; });
    var xb = $('#mExplBtn'); if (xb) xb.onclick = function () { loadExplain(si); };
    var cb = $('#mCmdBtn'); if (cb) cb.onclick = function () { P.cmdOpen = !P.cmdOpen; var s = selInfo(); if (s) { $('#mCmd').innerHTML = cmdHtml(s); bindDetail(s); } };
    bindDyn();
  }
  function bindDyn() {
    RG.$$('#mDetail [data-lv]').forEach(function (b) {
      b.onclick = function () {
        b.disabled = true;
        RG.api('/api/process/priority', { method: 'POST', body: { pid: +b.dataset.pid, start: b.dataset.start, level: b.dataset.lv } }).then(function (j) {
          RG.toast((b.dataset.lv === 'below' ? 'Đã hạ ưu tiên ' : 'Đã trả ưu tiên bình thường cho ') + (j.name || 'tiến trình') + ' (PID ' + b.dataset.pid + ').', 'ok');
          RG.loadEvents().catch(function () { }).then(function () { drawLow(); });
          fetchProcs();
        }).catch(function (e) { RG.toast(e.message, 'err', 8000); b.disabled = false; });
      };
    });
    RG.$$('#mDetail [data-end]').forEach(function (b) { b.onclick = function () { endProc(b); }; });
    RG.$$('#mDetail [data-prot]').forEach(function (b) { b.onclick = function () { RG.toggleProtect('process', b.dataset.prot, b.getAttribute('aria-pressed') !== 'true').then(function () { fetchProcs(); }).catch(function () { }); }; });
  }
  // Mỗi lần có dữ liệu mới chỉ làm mới phần số, không vẽ lại biểu đồ.
  function updateDyn() {
    var si = selInfo(); if (!si) { if (P.sel) { P.sel = null; drawDetail(); } return; }
    var a = $('#mSum'); if (!a) { drawDetail(); return; }
    a.textContent = summaryHtml(si); $('#mMem').innerHTML = memberTable(si); $('#mWhat').innerHTML = whatHtml(si); $('#mProt').innerHTML = protButtons(si);
    var me = $('#mEnd'); if (me) me.innerHTML = endTable(si);
    bindDyn();
  }
  function loadHistory(name) {
    RG.api('/api/process/history?name=' + encodeURIComponent(name) + '&min=' + P.minutes).then(function (j) {
      var si = selInfo(); if (!si || si.rep.name !== name) return;
      var pts = j.points || [], xf = function (t) { return String(t).slice(11, 16); };
      RG.lineChart($('#dCpu'), pts, { key: 'cpu', color: RG.css('--cpu'), min: 0, area: true, unit: '%', xfmt: xf });
      RG.lineChart($('#dRam'), pts, { key: 'ramMB', color: RG.css('--disk'), min: 0, area: true, unit: ' MB', xfmt: xf });
      var n = $('#dNote'); if (n) n.textContent = pts.length < 2 ? 'Chưa đủ dữ liệu: tiến trình này chưa nằm trong nhóm chiếm nhiều nhất đủ lâu.' : (pts.length < P.minutes / 20 ? 'Dữ liệu thưa: chỉ có ' + pts.length + ' điểm vì tiến trình không phải lúc nào cũng nằm trong nhóm chiếm nhiều nhất.' : '');
    }).catch(function () { });
  }

  function fetchProcs() {
    if (P.busy) return; P.busy = true;
    RG.api('/api/processes').then(function (j) {
      P.procs = j.procs || []; P.wl = j.workloads || []; P.logical = j.logical || 1; P.loaded = true;
      if (RG.cur !== 'mem' && RG.cur !== 'cpu') return;
      drawList(); drawBar(); updateDyn();
    }).catch(function () { }).then(function () { P.busy = false; });
  }

  /* ----- Gập sẵn ở cuối: CPU theo thời gian, từng nhân, thông tin máy ----- */
  function drawLow() {
    var det = $('#mLow'); if (!det || !det.open) return;
    var markers = (S.events || []).filter(function (e) { return e.event === 'proc-priority'; }).map(function (e) { return { ts: e.ts, type: e.event, label: RG.human.event(e), e: e }; });
    RG.lineChart($('#cpuBig'), S.hist, { key: 'cpuPct', color: RG.css('--cpu'), min: 0, max: 100, area: true, readout: 'roCpu2', unit: '%', n: 120, markers: markers, onMarker: function (m) { RG.eventDrawer(m.e); } });
    var r = S.live; if (!r) return;
    var ci = r.cpuInfo || {}, cores = r.cores || [];
    $('#cpuInfo').innerHTML = '<dt>Hiện tại</dt><dd><b>' + (r.cpuPct == null ? '–' : RG.fmtPct(r.cpuPct)) + '</b></dd><dt>Bộ xử lý</dt><dd title="' + esc(ci.name) + '">' + esc(ci.name || '–') + '</dd>' +
      '<dt>Tốc độ tối đa</dt><dd>' + (ci.mhz ? RG.fmtNum(ci.mhz / 1000, 2) + ' GHz' : '–') + '</dd><dt>Nhân vật lý</dt><dd>' + (ci.physical || '–') + '</dd><dt>Nhân logic</dt><dd>' + (ci.logical || cores.length || '–') + '</dd>' +
      '<dt>Tiến trình</dt><dd>' + (r.procCount || '–') + '</dd><dt>Thời gian chạy</dt><dd>' + RG.fmtDur(r.uptimeSec) + '</dd><dt>Tác vụ nặng</dt><dd>' + (r.heavy || 0) + '</dd>';
    var g = $('#coreGrid');
    if (cores.length) {
      if (g.children.length !== cores.length) g.innerHTML = cores.map(function (_, i) { return '<div class="core"><div class="t"><span>Nhân ' + i + '</span><b class="num" id="cv' + i + '">–</b></div><svg id="cs' + i + '" role="img" aria-label="Nhân ' + i + '"></svg></div>'; }).join('');
      cores.forEach(function (v, i) {
        $('#cv' + i).textContent = v + '%';
        RG.lineChart($('#cs' + i), S.hist, { fn: function (h) { return h.cores && h.cores[i] != null ? h.cores[i] : null; }, color: RG.css('--cpu'), min: 0, max: 100, area: true, axes: false, n: 60 });
      });
    } else g.innerHTML = '<span class="mut">Chưa có dữ liệu từng nhân (cần ít nhất hai lần lấy mẫu).</span>';
  }

  RG.pages.mem = {
    title: 'Bộ nhớ & tiến trình',
    render: function (el) {
      P.offs.forEach(function (f) { f(); }); P.offs = []; P.bar = null;
      el.innerHTML = '<div id="memBody"><div class="card ws-sticky" id="mBar"></div>' +
        '<div class="ws mm"><div class="card"><h2>Ai đang dùng RAM <span class="pill" id="mCount">–</span><span class="sp"></span>' +
        '<span class="seg sm" role="group" aria-label="Kiểu hiển thị"><button id="mgW" aria-pressed="' + (P.mode === 'wl') + '">Gộp theo việc</button><button id="mgP" aria-pressed="' + (P.mode === 'pid') + '">Từng tiến trình</button></span></h2>' +
        '<div class="dk-dn"><div id="mDn"></div><div id="mLg"></div></div>' +
        '<div class="field" style="margin-top:0"><label for="mFilter" style="min-width:auto">Lọc</label><input id="mFilter" type="text" placeholder="Tên, dự án hoặc PID" aria-label="Lọc tiến trình" style="flex:1"></div>' +
        '<div id="mList" class="mm-list" aria-live="polite"></div>' +
        '<p class="hint">Resource Guard chỉ liệt kê và có thể <b>hạ ưu tiên CPU</b> (đảo ngược được); màn này không có nút kết thúc tiến trình.</p></div>' +
        '<div class="card mm-detail" id="mDetail"></div></div>' +
        '<details class="card mt" id="mLow"><summary class="h-sum">CPU theo thời gian · Từng nhân logic · Thông tin máy</summary>' +
        '<div class="cpu-head" style="margin-top:8px"><div><h2>Mức sử dụng CPU<span class="ro" id="roCpu2"></span></h2><svg id="cpuBig" class="chart" role="img" aria-label="Biểu đồ CPU tổng"></svg>' +
        '<div class="small mut">% sử dụng theo thời gian · chấm tròn = lần Resource Guard hạ/trả ưu tiên một tiến trình</div></div><div><h2>Thông tin</h2><dl class="kv" id="cpuInfo"></dl></div></div>' +
        '<h2 class="mt">Từng nhân logic</h2><div class="cores" id="coreGrid"></div></details></div>';
      var flt = $('#mFilter'); flt.value = P.filter; flt.oninput = function () { P.filter = this.value; drawList(); };
      function mode(m) { P.mode = m; $('#mgW').setAttribute('aria-pressed', m === 'wl'); $('#mgP').setAttribute('aria-pressed', m === 'pid'); drawList(); }
      $('#mgW').onclick = function () { mode('wl'); }; $('#mgP').onclick = function () { mode('pid'); };
      $('#mLow').ontoggle = drawLow;
      P.offs.push(RG.link.on('hover', function (key, on) {
        RG.$$('#mList [data-wk]').forEach(function (n) { n.classList.toggle('hl', !!on && n.dataset.wk === key); });
      }));
      drawList(); drawDetail(); drawBar(); this.refresh();
    },
    refresh: function () { RG.loadEvents().catch(function () { }).then(function () { drawLow(); }); fetchProcs(); },
    jobs: function () { },
    live: function () { if (!$('#mBar')) return; drawBar(); drawLow(); fetchProcs(); }
  };
  // Trang chủ gọi trước khi RG.go('mem'): chọn sẵn một workload và mở nhóm của nó.
  RG.memSelect = function (key) { P.sel = { t: 'w', k: key }; P.open[key] = true; P.cmdOpen = false; };
  RG.pages.cpu = RG.pages.mem;
})();
