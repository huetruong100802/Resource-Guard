/* p-clean.js - Dọn dẹp: các bước của kế hoạch (nhóm mở được), thanh ảnh hưởng trực tiếp, xác nhận có trước → sau. Chính sách tự động nằm ở p-auto.js. */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, GB = 1073741824;
  var OUT = { done: 'Đã xoá', skipped: 'Bỏ qua', failed: 'Thất bại', 'would-run': 'Sẽ chạy' };
  var CF = { drive: '', open: {}, all: {} };   // lọc ổ, nhóm đang mở, nhóm hiện đủ mục
  var MAXROWS = 40;
  var G = { groups: [], byKey: {} };           // nhóm dựng ở lần vẽ gần nhất (để cập nhật tick không vẽ lại cả trang)

  function seg(name, val, opts, dis) {
    return '<span class="seg sm" role="group" aria-label="' + esc(name) + '">' + opts.map(function (o) { return '<button data-set="' + esc(name) + '" data-val="' + esc(o[0]) + '" aria-pressed="' + (val === o[0]) + '"' + (dis ? ' disabled' : '') + '>' + o[1] + '</button>'; }).join('') + '</span>';
  }
  RG.seg = seg;

  function recFor(key) { var a = S.agent && S.agent.ok && S.agent.result; if (!a) return null; return (a.recommendations || []).filter(function (r) { return r.key === key; })[0] || null; }
  function allItems() { return (S.cands && S.cands.items) || []; }
  function itemByKey(k) { return allItems().filter(function (i) { return i.key === k; })[0]; }
  function scanState(c) {
    var has = !!(c && c.finishedUtc), max = (c && c.maxAgeHours) || 12, ageH = has ? (Date.now() - Date.parse(c.finishedUtc)) / 3600000 : null;
    return { has: has, max: max, stale: has && (isNaN(ageH) || ageH > max) };
  }
  function selectable(i) { return i.action !== 'report' && !i.protected && !scanState(S.cands).stale; }
  function selectedItems() { return allItems().filter(function (i) { return S.selected[i.key]; }); }
  function tgtOf(i) { return i.kind === 'process' ? (i.name + ' (pid ' + i.pid + ')') : i.path; }
  function pill(cls, t, title) { return '<span class="pill ' + cls + '"' + (title ? ' title="' + esc(title) + '"' : '') + '>' + t + '</span>'; }
  var RISKCLS = { low: 'auto', medium: 'ask', high: 'bad' };

  // Việc tool SẼ làm với mục. zip: undefined = bảng; true/false = hộp xác nhận.
  function actionOf(i, zip) {
    if (i.protected) return { k: 'prot', l: 'Được bảo vệ', d: 'Nằm trong vùng bảo vệ của bạn; bỏ bảo vệ trước nếu muốn dọn.', cls: 'keep' };
    if (i.action === 'report') return i.needsAdmin ? { k: 'admin', l: 'Cần quyền admin', d: 'Chỉ xoá được sau khi xác nhận UAC.', cls: 'ask' } : { k: 'report', l: 'Chỉ báo cáo', d: 'Tool không bao giờ xoá mục này.', cls: '' };
    if (i.action === 'kill') return { k: 'kill', l: 'Kết thúc tiến trình', d: 'Tiến trình bị dừng đột ngột; dữ liệu chưa lưu có thể mất.', cls: 'bad' };
    if (i.canArchive && zip === undefined) return { k: 'zipable', l: 'Xoá (có thể nén zip)', d: 'Có thể nén zip cạnh mục trước khi xoá; chọn ở hộp xác nhận.', cls: 'ask' };
    if (i.canArchive && zip) return { k: 'zip', l: 'Nén zip rồi xoá', d: 'Tạo .zip cạnh mục, kiểm tra xong mới xoá bản gốc.', cls: 'ask' };
    return { k: 'del', l: 'Xoá vĩnh viễn', d: 'Không qua Thùng rác, không hoàn tác được.', cls: 'bad' };
  }

  /* ----- Dựng nhóm từ kế hoạch ----- */
  function buildGroups() {
    var items = allItems().filter(function (i) { return i.protectedBy !== 'agent' && (!CF.drive || i.drive === CF.drive); }), used = {}, groups = [], a = S.advice;
    function claim(keys) { var m = {}; keys.forEach(function (k) { m[k] = 1; }); return items.filter(function (i) { if (m[i.key] && !used[i.key]) { used[i.key] = 1; return true; } return false; }); }
    ((a && a.steps) || []).filter(function (s) { return !CF.drive || s.drive === CF.drive; }).forEach(function (s, n) {
      var its = claim(s.keys); if (!its.length) return;
      groups.push({ id: 'step:' + s.id, kind: 'step', title: s.title, drive: s.drive, items: its, step: s, risk: s.riskLevel, regen: s.regen, impact: s.impact, why: s.why, agent: s.agent, reaches: s.reachesGoal });
    });
    var rv = {}; (((a && a.review) || {}).keys || []).forEach(function (k) { rv[k] = 1; });
    var review = items.filter(function (i) { return !used[i.key] && rv[i.key] && i.action !== 'report'; }); review.forEach(function (i) { used[i.key] = 1; });
    var rest = items.filter(function (i) { return !used[i.key] && i.action !== 'report' && !i.protected; }); rest.forEach(function (i) { used[i.key] = 1; });
    var rep = items.filter(function (i) { return !used[i.key]; });
    if (review.length) groups.push({ id: 'review', kind: 'review', title: 'Cần xem lại', items: review, risk: 'medium', impact: 'Mục chưa đủ tuổi hoặc cần bạn cân nhắc; máy không tự dọn các mục này.', why: 'Máy không tự quyết được.' });
    if (rest.length) groups.push({ id: 'rest', kind: 'rest', title: 'Các mục còn lại', items: rest, impact: 'Mỗi mục có ảnh hưởng riêng, bấm vào mục để xem biên lai.' });
    if (rep.length) groups.push({ id: 'report', kind: 'report', title: 'Chỉ báo cáo / được bảo vệ', items: rep, impact: 'Resource Guard không xoá loại này; chỉ cho bạn biết.' });
    groups.forEach(function (g) { g.bytes = g.items.reduce(function (x, i) { return x + (i.sizeBytes || 0); }, 0); g.items.sort(function (x, y) { return (y.sizeBytes || 0) - (x.sizeBytes || 0); }); });
    G.groups = groups; G.byKey = {}; groups.forEach(function (g) { g.items.forEach(function (i) { G.byKey[i.key] = g; }); });
    return groups;
  }

  function itemRow(i, g) {
    var dis = !selectable(i), rec = recFor(i.key), a = actionOf(i);
    var recPill = rec ? ' ' + pill(rec.verdict === 'clean' ? 'auto' : (rec.verdict === 'keep' ? 'keep' : 'ask'), 'Trợ lý AI: ' + ({ clean: 'nên dọn', keep: 'nên giữ', review: 'xem lại' }[rec.verdict] || esc(rec.verdict)), rec.reason + ' (độ tin cậy: ' + rec.confidence + ')') : '';
    return '<tr class="row clk" data-open="' + i.key + '"><td class="chk"><input type="checkbox" data-key="' + i.key + '"' + (S.selected[i.key] ? ' checked' : '') + (dis ? ' disabled' : '') + ' aria-label="Chọn ' + esc(tgtOf(i)) + '"></td>' +
      '<td><span class="mono ellipsis" style="max-width:100%" title="' + esc(tgtOf(i)) + '">' + esc(tgtOf(i)) + '</span>' + (i.young ? ' ' + pill('ask', 'chưa đủ tuổi', 'Chưa đủ tuổi theo policy; không bao giờ tự dọn.') : '') + recPill +
      (g.kind !== 'step' ? '<div class="small mut">' + esc(i.why || i.reason || '') + '</div>' : '') + '</td>' +
      '<td class="r num">' + (i.sizeBytes && i.action !== 'kill' ? RG.fmtBytes(i.sizeBytes) : '–') + '</td><td class="r num mut">' + (i.ageDays ? RG.fmtAge(i.ageDays) : '–') + '</td>' +
      '<td class="r">' + (g.kind === 'report' ? pill(a.cls, a.l, a.d) : '') + '<button class="icon-btn ' + (i.protected ? 'on' : '') + '" data-prot="' + i.key + '" aria-pressed="' + !!i.protected + '" aria-label="' + (i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ') + ' ' + esc(tgtOf(i)) + '" title="' + (i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ khỏi dọn') + '">' + RG.icon('shield') + '</button></td></tr>';
  }
  function groupHtml(g) {
    var big = g.items.filter(function (i) { return (i.sizeBytes || 0) > 0 || g.kind === 'report' || g.kind === 'review'; }), tiny = g.items.filter(function (i) { return big.indexOf(i) < 0; });
    var shown = CF.all[g.id] ? big : big.slice(0, MAXROWS), rows = shown.map(function (i) { return itemRow(i, g); }).join('');
    if (big.length > shown.length) rows += '<tr><td colspan="5" class="small"><button class="btn sm" data-more="' + esc(g.id) + '">Hiện đủ ' + big.length + ' mục</button> <span class="mut">(đang hiện ' + MAXROWS + ' mục lớn nhất)</span></td></tr>';
    if (tiny.length) rows += '<tr class="row"><td class="chk"><input type="checkbox" data-tiny="' + esc(g.id) + '" aria-label="Chọn ' + tiny.length + ' mục nhỏ"' + (tiny.every(function (i) { return !selectable(i); }) ? ' disabled' : '') + '></td><td>' + tiny.length + ' mục nhỏ (0 byte)</td><td class="r num">–</td><td></td><td></td></tr>';
    var risk = g.risk ? pill(RISKCLS[g.risk] || '', esc(RG.human.risk(g.risk))) : '', src = g.kind === 'step' ? pill(g.agent ? 'keep' : '', g.agent ? 'Trợ lý AI' : 'Quy tắc', 'Nguồn lời khuyên') : '';
    var regen = g.regen ? '<span class="mut small">· ' + esc(RG.human.regen(g.regen)) + '</span>' : '';
    return '<details class="acc cl-group" data-gid="' + esc(g.id) + '"' + (CF.open[g.id] ? ' open' : '') + '><summary>' + RG.icon('chev', 'chev') + '<input type="checkbox" data-grp="' + esc(g.id) + '" aria-label="Chọn cả nhóm ' + esc(g.title) + '">' +
      '<b>' + esc(g.title) + '</b>' + (g.drive ? '<span class="mut small">ổ ' + esc(g.drive) + ':</span>' : '') + '<span class="mut small">' + g.items.length + ' mục</span>' + regen + (g.reaches ? pill('auto', 'đủ mục tiêu ở bước này') : '') +
      '<span class="gs"><span class="num"><b>' + RG.fmtBytes(g.bytes) + '</b></span>' + risk + src + '</span></summary>' +
      '<div class="inner">' + (g.impact ? '<p class="hint" style="margin:0 0 6px">' + esc(g.impact) + '</p>' : '') + '<div class="tbl-wrap" style="max-height:none"><table class="cand"><tbody>' + rows + '</tbody></table></div></div></details>';
  }

  /* ----- Cột phải: thanh ảnh hưởng theo từng lần tick ----- */
  function gainByDrive(sel) {
    var m = {}; sel.forEach(function (i) { if (i.action === 'kill' || !i.drive) return; var d = m[i.drive] = m[i.drive] || { n: 0, b: 0, high: 0 }; d.n++; d.b += i.sizeBytes || 0; if (i.riskLevel === 'high') d.high++; });
    return m;
  }
  function barOpts(L, gain) {
    var d = RG.driveInfo(L); if (!d) return null;
    var thr = RG.diskThr(L);
    return { totalBytes: d.totalBytes || (d.totalGB ? d.totalGB * GB : 0), freeBytes: d.freeGB * GB, gainBytes: gain, cautionBytes: thr.cautionFrom * GB, normalBytes: thr.normalAbove * GB, label: 'Ổ ' + L + ':' };
  }
  function drawSide() {
    var el = $('#clSide'); if (!el) return;
    var sel = selectedItems(), cj = S.jobs.cleanup, crun = cj && cj.status === 'running', st = scanState(S.cands), gm = gainByDrive(sel), nKill = sel.filter(function (i) { return i.action === 'kill'; }).length;
    var total = sel.reduce(function (x, i) { return x + (i.action === 'kill' ? 0 : (i.sizeBytes || 0)); }, 0), nHigh = sel.filter(function (i) { return i.riskLevel === 'high'; }).length;
    var html = '<h2>Tác động nếu dọn</h2>';
    if (!sel.length) html += '<p class="small mut">Chưa chọn mục nào. Tick một nhóm hoặc từng mục để xem mỗi ổ sẽ thay đổi thế nào.</p>';
    else {
      html += '<div class="cl-sum"><b class="num">' + sel.length + ' mục</b> · <b class="num">' + RG.fmtBytes(total) + '</b>' + (nKill ? '<div class="small mut">' + nKill + ' tiến trình sẽ bị kết thúc</div>' : '') + '</div>';
      Object.keys(gm).sort().forEach(function (L) { html += '<div class="h-drive"><div id="clb_' + esc(L) + '"></div><div class="small mut">đã chọn ' + gm[L].n + ' mục · ' + RG.fmtBytes(gm[L].b) + '</div></div>'; });
      if (nHigh) html += '<div class="alert warn" style="margin-top:8px"><div class="small"><b>' + nHigh + ' mục rủi ro cao</b> (không tự tạo lại được). Kiểm tra kỹ từng mục trước khi dọn.</div></div>';
    }
    html += '<div style="margin-top:10px">' + (crun ? '<span class="spin"></span> <span class="small mut">đang dọn… ' + esc(cj.message || '') + '</span>' : '<button class="btn danger" id="doClean" style="width:100%;justify-content:center"' + (!sel.length || st.stale ? ' disabled' : '') + '>' + RG.icon('trash') + ' Dọn mục đã chọn</button>') + '</div>' +
      '<p class="hint">Chưa xoá gì cho tới khi bạn xác nhận ở bước sau.</p>';
    el.innerHTML = html;
    Object.keys(gm).forEach(function (L) { var o = barOpts(L, gm[L].b); if (o) V.impactBar($('#clb_' + L), o); });
    var dc = $('#doClean'); if (dc) dc.onclick = confirmClean;
  }
  // Cập nhật ô tick của nhóm/mục mà không vẽ lại trang.
  function syncChecks() {
    RG.$$('#cleanBody input[data-key]').forEach(function (cb) { cb.checked = !!S.selected[cb.dataset.key]; });
    G.groups.forEach(function (g) {
      var cb = RG.$('#cleanBody input[data-grp="' + g.id.replace(/"/g, '') + '"]'); if (!cb) return;
      var sel = g.items.filter(selectable), n = sel.filter(function (i) { return S.selected[i.key]; }).length;
      cb.disabled = !sel.length; cb.checked = sel.length > 0 && n === sel.length; cb.indeterminate = n > 0 && n < sel.length;
      var tn = RG.$('#cleanBody input[data-tiny="' + g.id.replace(/"/g, '') + '"]');
      if (tn) { var tiny = g.items.filter(function (i) { return !(i.sizeBytes > 0) && g.kind !== 'report' && g.kind !== 'review'; }).filter(selectable); tn.checked = tiny.length > 0 && tiny.every(function (i) { return S.selected[i.key]; }); }
    });
    var nc = $('#navCleanCnt'); if (nc) RG.updateNavBadges();
    drawSide();
  }

  /* ----- Trang ----- */
  function drawClean() {
    var el = $('#cleanBody'); if (!el) return;
    var c = S.cands, j = S.jobs.candidates, run = j && j.status === 'running', cj = S.jobs.cleanup, crun = cj && cj.status === 'running', st = scanState(c);
    var head = '<div class="field" style="margin-top:0"><button class="btn primary" id="scanC"' + (run ? ' disabled' : '') + '>' + RG.icon('refresh') + (c && c.finishedUtc ? 'Quét lại' : 'Quét mục có thể dọn') + '</button>' +
      '<button class="btn" id="selSafe"' + (st.stale ? ' disabled' : '') + '>Chọn mục rủi ro thấp</button><button class="btn" id="selNone">Bỏ chọn</button>';
    if (run) head += '<span class="spin"></span><span class="small mut">đang quét… ' + esc(j.message || '') + '</span>';
    else if (c && c.finishedUtc) head += '<span class="small mut">Quét ' + RG.timeAgo(c.finishedUtc) + ' (' + c.seconds + ' giây)</span>';
    head += '</div>';
    if (st.stale) head += '<div class="alert warn" role="status"><b>Dữ liệu quét đã cũ</b> (quá ' + st.max + ' giờ, quét ' + RG.timeAgo(c.finishedUtc) + '). Chưa chọn hay dọn được; bấm “Quét lại” ở trên trước.</div>';
    if (!c || !c.finishedUtc) { el.innerHTML = head + '<div class="card empty">' + RG.icon('inbox') + '<h3>Chưa có danh sách mục có thể dọn</h3><div>Quét sẽ tìm: file tạm cũ, bin/obj, node_modules lâu không mở, cache dev, tiến trình mồ côi của agent.</div></div>'; bindClean(); return; }
    var letters = {}; c.items.forEach(function (i) { if (i.drive) letters[i.drive] = (letters[i.drive] || 0) + 1; });
    var multi = Object.keys(letters).length > 1; if (!multi) CF.drive = '';
    if (multi) head += '<div class="field" style="margin-top:0"><span class="small mut">Lọc theo ổ:</span>' + seg('cdrive', CF.drive, [['', 'Tất cả (' + c.items.length + ')']].concat(Object.keys(letters).sort().map(function (L) { return [L, L + ': (' + letters[L] + ')']; }))) + '</div>';
    var groups = buildGroups(), main;
    if (!groups.length) main = '<div class="card empty">' + RG.icon('inbox') + '<h3>Không có mục nào để dọn</h3><div>Máy đang gọn theo các tiêu chí hiện tại.</div></div>';
    else main = '<div class="cl-intro small mut">Các bước được sắp theo mức an toàn và hiệu quả. Tick cả bước hoặc từng mục; bấm một mục để xem biên lai (vì sao, ảnh hưởng, cách lấy lại).</div>' + groups.map(groupHtml).join('') +
      '<p class="hint">Xoá là vĩnh viễn, không qua Thùng rác, trừ khi chọn nén zip. “Được bảo vệ” nằm trong vùng bảo vệ của bạn nên không chọn được; “Chỉ báo cáo” tool không bao giờ xoá.</p>';
    el.innerHTML = head + '<div class="cl-grid"><div class="cl-main">' + main + '</div><aside class="card cl-side" id="clSide" aria-live="polite"></aside></div>' +
      adminBox(crun) + drawAgentKept(c) + drawArchives() + drawCleanResult();
    bindClean(); syncChecks();
  }
  function drawAgentKept(c) {
    var ks = c.items.filter(function (i) { return i.protectedBy === 'agent'; });
    if (!ks.length) return '';
    var rows = ks.map(function (i) {
      var until = i.keepUntilUtc ? new Date(i.keepUntilUtc).toLocaleDateString('vi-VN') : '–';
      return '<tr class="row"><td><span class="ellipsis mono" title="' + esc(i.path) + '">' + esc(i.path) + '</span><div class="small mut">' + esc(i.keepReason || '') + '</div></td><td class="r num">' + (i.sizeBytes ? RG.fmtBytes(i.sizeBytes) : '–') + '</td><td class="r num mut">' + until + '</td><td class="r"><button class="btn sm" data-unkeep="' + i.key + '">Bỏ giữ</button></td></tr>';
    }).join('');
    return '<div class="card mt"><h2>Agent đang giữ <span class="ro">' + ks.length + ' mục</span></h2><div class="tbl-wrap" style="max-height:none"><table class="cand"><thead><tr><th>Mục</th><th class="r">Dung lượng</th><th class="r">Giữ đến</th><th></th></tr></thead><tbody>' + rows + '</tbody></table></div>' +
      '<p class="hint">Trợ lý AI đánh giá các mục này nên giữ (độ tin cậy cao) nên chúng không hiện trong danh sách dọn và không bao giờ bị tự dọn. Tự hết hạn sau 30 ngày rồi được đánh giá lại; bấm “Bỏ giữ” để đưa về danh sách dọn ngay.</p></div>';
  }
  function adminItems() { return allItems().filter(function (i) { return i.needsAdmin && !i.protected; }); }
  function adminBox(crun) {
    var adm = adminItems(); if (!adm.length) return '';
    var total = adm.reduce(function (a, i) { return a + (i.sizeBytes || 0); }, 0);
    return '<div class="card mt"><h2>Cần quyền admin<span class="ro">' + adm.length + ' thư mục tạm</span></h2>' +
      '<p class="small">Các thư mục tạm cũ này do <b>hệ thống (SYSTEM)</b> tạo nên tài khoản thường không xoá được' + (total ? ' (' + RG.fmtBytes(total) + ')' : '') + '. Bạn có thể xoá bằng quyền admin: Windows sẽ hỏi xác nhận (UAC), tool không tự nâng quyền.</p>' +
      '<div class="field" style="margin-top:8px">' + (crun ? '<span class="spin"></span><span class="small mut">đang chờ/đang dọn…</span>' : '<button class="btn" id="doElevate">' + RG.icon('shield') + ' Dọn bằng quyền admin…</button>') + '</div></div>';
  }
  function confirmElevate() {
    var adm = adminItems(); if (!adm.length) return;
    var list = adm.slice(0, 12).map(function (i) { return '<li><span class="mono">' + esc(i.path) + '</span> — ' + RG.fmtBytes(i.sizeBytes) + '</li>'; }).join('') + (adm.length > 12 ? '<li class="mut">… và ' + (adm.length - 12) + ' mục khác</li>' : '');
    RG.confirm('Dọn ' + adm.length + ' thư mục bằng quyền admin?', '<p>Tiếp theo Windows sẽ hiện hộp thoại <b>UAC</b>. Chỉ khi bạn chọn “Có”, một tiến trình admin riêng mới xoá các thư mục dưới đây rồi thoát. <b>Không thể hoàn tác</b>.</p><ul class="small" style="max-height:200px;overflow:auto;padding-left:18px">' + list + '</ul><p class="hint">Tiến trình admin tự kiểm lại từng mục: chỉ thư mục tên GUID nằm trực tiếp trong thư mục Temp, đủ 14 ngày không đổi, không phải junction, không nằm trong vùng bảo vệ. Chọn “Không” ở UAC thì không có gì bị xoá.</p>', 'Tiếp tục tới UAC', true).then(function (ok) {
      if (!ok) return;
      RG.startJob('/api/cleanup/elevate', { keys: adm.map(function (i) { return i.key; }) }, 'Chờ bạn xác nhận UAC…').then(drawClean).catch(function () { });
    });
  }
  function drawArchives() {
    var a = (S.archives || []); if (!a.length) return '';
    var rows = a.map(function (r) {
      var st = r.restoredUtc ? pill('auto', 'đã khôi phục') : (!r.zipExists ? pill('bad', 'zip đã mất') : (r.originalExists ? pill('', 'vị trí cũ đã có dữ liệu') : '')), can = r.zipExists && !r.originalExists && !r.restoredUtc;
      return '<tr><td><span class="ellipsis mono" title="' + esc(r.original) + '">' + esc(r.original) + '</span><div class="small mut">' + esc(r.zip) + '</div></td><td class="r num">' + RG.fmtBytes(r.bytes) + ' → ' + RG.fmtBytes(r.zipBytes) + '</td><td class="small mut">' + RG.timeAgo(r.createdUtc) + '</td><td>' + st + '</td><td class="r">' + (can ? '<button class="btn" data-restore="' + esc(r.id) + '">Giải nén về chỗ cũ</button>' : '') + '</td></tr>';
    }).join('');
    return '<div class="card mt"><h2>Bản nén đã tạo<span class="ro">' + a.length + '</span></h2><div class="tbl-wrap"><table><tbody>' + rows + '</tbody></table></div><p class="hint">Zip nằm cạnh vị trí gốc. Giải nén không ghi đè: chỉ chạy khi vị trí cũ trống. Xoá file zip thủ công khi chắc chắn không cần nữa.</p></div>';
  }
  function confirmRestore(id) {
    var r = (S.archives || []).filter(function (x) { return x.id === id; })[0]; if (!r) return;
    RG.confirm('Giải nén về chỗ cũ?', '<p>Khôi phục <span class="mono">' + esc(r.original) + '</span> (' + RG.fmtBytes(r.bytes) + ') từ <span class="mono">' + esc(r.zip) + '</span>. File zip được giữ lại.</p>', 'Giải nén', false).then(function (ok) {
      if (!ok) return; RG.startJob('/api/archive/restore', { id: id }, 'Đang giải nén…').then(drawClean).catch(function () { });
    });
  }
  function drawCleanResult() {
    var l = S.cleanupLast; if (!l) return '';
    var rows = (l.results || []).map(function (r) { return '<tr><td>' + esc(RG.human.kind(r.kind).l) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td>' + pill(r.outcome === 'done' ? 'auto' : (r.outcome === 'failed' ? 'bad' : 'ask'), OUT[r.outcome] || esc(r.outcome)) + '</td><td class="small mut">' + esc(r.detail || '') + '</td></tr>'; }).join('');
    (l.refused || []).forEach(function (r) { var it = itemByKey(r.key); rows += '<tr><td colspan="2"><span class="mono small" style="word-break:break-all">' + esc(it ? tgtOf(it) : r.key) + '</span></td><td>' + pill('bad', 'Từ chối') + '</td><td class="small mut">' + esc(r.reason) + '</td></tr>'; });
    var ex = S.cleanExpected, cmp = ex && ex.bytes != null ? '<div class="cl-cmp">Dự kiến <b>' + RG.fmtBytes(ex.bytes) + '</b> · thực tế <b>' + RG.fmtBytes(l.freedBytes) + '</b>' + (l.freedBytes < ex.bytes * 0.95 ? ' <span class="small mut">(phần chênh do mục bị bỏ qua, thất bại hoặc nén zip)</span>' : '') + '</div>' : '';
    var failed = (l.results || []).filter(function (r) { return r.outcome === 'failed'; }).length + (l.refused || []).length;
    return '<div class="card mt"><h2>Kết quả lượt dọn gần nhất<span class="ro">' + RG.timeAgo(l.finishedUtc) + ' · giải phóng ' + RG.fmtBytes(l.freedBytes) + (failed ? ' · ' + failed + ' mục không dọn được' : '') + '</span></h2>' + cmp + '<div class="tbl-wrap"><table><tbody>' + rows + '</tbody></table></div></div>';
  }

  /* ----- Ngăn kéo một mục ----- */
  function openItem(i) {
    var rec = recFor(i.key), g = G.byKey[i.key];
    var src = '<div class="small mut" style="margin-top:10px">Nguồn lời khuyên: <b>' + (rec ? 'Trợ lý AI' : 'Quy tắc') + '</b>' + (rec ? ' — ' + esc(rec.reason) + ' (độ tin cậy ' + esc(rec.confidence) + ')' : '') + '</div>' +
      (g && g.kind === 'step' ? '<div class="small mut">Thuộc bước: ' + esc(g.title) + '</div>' : '') + '<div class="small mut">' + esc(i.reason || '') + '</div>';
    var d = RG.drawer({ title: RG.human.kind(i.kind).l, html: RG.receipt(i) + src, actions: [] });
    function setActs() {
      var can = selectable(i), on = !!S.selected[i.key];
      d.setActions([
        { label: on ? 'Bỏ chọn' : 'Chọn để dọn', cls: on ? '' : 'primary', disabled: !can, onClick: function () { if (S.selected[i.key]) delete S.selected[i.key]; else S.selected[i.key] = true; syncChecks(); return false; } },
        { label: i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ khỏi dọn', onClick: function () { (i.kind === 'process' ? RG.toggleProtect('process', i.name, !i.protected) : RG.toggleProtect('path', i.path, !i.protected)).then(function () { return RG.loadCands(); }).then(drawClean); } },
        { label: 'Đóng' }]);
    }
    setActs();
    var origSync = syncChecks; // cập nhật nhãn nút sau mỗi lần chọn
    var obs = setInterval(function () { if (!document.body.contains(d.el)) { clearInterval(obs); return; } var b = d.el.querySelector('.dr-acts .btn'); if (b) { var on = !!S.selected[i.key]; if ((b.textContent === 'Bỏ chọn') !== on) setActs(); } }, 250);
  }

  /* ----- Xác nhận dọn ----- */
  function planHtml(sel, zip) {
    var gr = {}, order = [], bytes = 0;
    sel.forEach(function (i) {
      var g = G.byKey[i.key], id = g ? g.id : 'x:' + i.kind, o = gr[id];
      if (!o) { o = gr[id] = { title: g ? g.title : RG.human.kind(i.kind).l, impact: (g && g.impact) || i.impact || '', n: 0, b: 0, acts: {} }; order.push(id); }
      var a = actionOf(i, zip); o.n++; o.acts[a.l] = a.cls; if (i.action !== 'kill') { o.b += i.sizeBytes || 0; bytes += i.sizeBytes || 0; }
    });
    var rows = order.map(function (id) { var o = gr[id]; return '<tr><td><b>' + esc(o.title) + '</b><div class="small mut">' + esc(o.impact) + '</div></td><td>' + Object.keys(o.acts).map(function (l) { return pill(o.acts[l], l); }).join(' ') + '</td><td class="r num">' + o.n + '</td><td class="r num">' + (o.b ? RG.fmtBytes(o.b) : '–') + '</td></tr>'; }).join('');
    var list = sel.map(function (i) { var a = actionOf(i, zip); return '<tr><td>' + pill(a.cls, a.l) + '</td><td><span class="mono" style="word-break:break-all">' + esc(tgtOf(i)) + '</span></td><td class="r num">' + (i.sizeBytes && i.action !== 'kill' ? RG.fmtBytes(i.sizeBytes) : '–') + '</td></tr>'; }).join('');
    return '<p class="small">Tổng ước tính giải phóng <b>' + RG.fmtBytes(bytes) + '</b> (mục nén zip chỉ giải phóng phần chênh lệch).</p><table class="cand small" style="margin-bottom:8px"><thead><tr><th>Nhóm và ảnh hưởng</th><th>Hành động</th><th class="r">Số mục</th><th class="r">Dung lượng</th></tr></thead><tbody>' + rows + '</tbody></table>' +
      '<details><summary class="small" style="cursor:pointer">Danh sách đầy đủ ' + sel.length + ' mục</summary><div class="tbl-wrap" style="max-height:220px;margin-top:6px"><table class="cand small"><tbody>' + list + '</tbody></table></div></details>';
  }
  function confirmClean() {
    var sel = selectedItems(); if (!sel.length) return;
    if (scanState(S.cands).stale) { RG.toast('Dữ liệu quét đã cũ; hãy quét lại trước khi dọn.', 'err'); return; }
    var zipN = sel.filter(function (i) { return i.canArchive; }).length, zip = true, nKill = sel.filter(function (i) { return i.action === 'kill'; }).length;
    var bytes = sel.reduce(function (x, i) { return x + (i.action === 'kill' ? 0 : (i.sizeBytes || 0)); }, 0), gm = gainByDrive(sel);
    var bars = Object.keys(gm).sort().map(function (L) { return '<div class="h-drive"><div id="cfb_' + esc(L) + '"></div></div>'; }).join('');
    var zipBox = zipN ? '<label class="small" style="display:block;margin:8px 0"><input type="checkbox" id="optZip" checked> <b>Nén zip cạnh mục trước khi xoá</b> (' + zipN + ' mục). Tạo <span class="mono">&lt;tên&gt;.zip</span> trong cùng thư mục, kiểm tra xong mới xoá bản gốc; khôi phục bằng nút Giải nén ở bảng “Bản nén đã tạo”. Bỏ chọn thì các mục đó xoá vĩnh viễn.</label>' : '';
    var html = (bars ? '<div class="cf-bars">' + bars + '</div>' : '') + '<div id="cfPlan">' + planHtml(sel, true) + '</div>' + zipBox +
      (nKill ? '<p class="small"><b>Lưu ý:</b> ' + nKill + ' tiến trình sẽ bị kết thúc. Chỉ tiếp tục nếu các tiến trình đó không còn cần thiết.</p>' : '') +
      '<p class="hint">Mục “Xoá vĩnh viễn” không qua Thùng rác và không hoàn tác được. Trước khi làm, engine kiểm lại từng mục (allowlist, tuổi file, junction, trạng thái git…). Mục không đạt sẽ bị bỏ qua và báo lý do ở “Kết quả lượt dọn gần nhất”.</p>';
    var label = (nKill ? 'Dọn ' + sel.length + ' mục' : 'Xoá vĩnh viễn ' + sel.length + ' mục') + ' (' + RG.fmtBytes(bytes) + ')';
    var m = RG.modal({ title: 'Xác nhận dọn ' + sel.length + ' mục?', html: html, onClose: function (v) {
        if (v !== true) return;
        S.cleanExpected = { bytes: bytes, n: sel.length, at: Date.now() };
        RG.startJob('/api/cleanup/apply', { keys: sel.map(function (i) { return i.key; }), archive: zip }, zip && zipN ? 'Đang nén zip và dọn…' : 'Đang dọn…').then(drawClean).catch(function () { });
      }, actions: [{ label: 'Huỷ', value: false }, { label: label, cls: 'danger', value: true }] });
    m.el.classList.add('wide');
    Object.keys(gm).forEach(function (L) { var o = barOpts(L, gm[L].b); if (o) V.impactBar(RG.$('#cfb_' + L, m.el), o); });
    var c = RG.$('#optZip', m.el); if (c) c.onchange = function () { zip = c.checked; RG.$('#cfPlan', m.el).innerHTML = planHtml(sel, zip); };
  }

  function bindClean() {
    var sc = $('#scanC'); if (sc) sc.onclick = function () { RG.startJob('/api/candidates/scan', {}, 'Bắt đầu quét các mục có thể dọn…'); };
    var ss = $('#selSafe'); if (ss) ss.onclick = function () { allItems().forEach(function (i) { if (i.action === 'delete' && !i.protected && i.riskLevel === 'low' && !i.young) S.selected[i.key] = true; }); syncChecks(); };
    var sn = $('#selNone'); if (sn) sn.onclick = function () { S.selected = {}; syncChecks(); };
    RG.$$('#cleanBody [data-set="cdrive"]').forEach(function (b) { b.onclick = function () { CF.drive = b.dataset.val; drawClean(); }; });
    RG.$$('#cleanBody input[data-key]').forEach(function (cb) { cb.onclick = function (e) { e.stopPropagation(); }; cb.onchange = function () { if (cb.checked) S.selected[cb.dataset.key] = true; else delete S.selected[cb.dataset.key]; syncChecks(); }; });
    RG.$$('#cleanBody input[data-grp]').forEach(function (cb) {
      cb.onclick = function (e) { e.stopPropagation(); };
      cb.onchange = function () { var g = G.groups.filter(function (x) { return x.id === cb.dataset.grp; })[0]; if (!g) return; g.items.filter(selectable).forEach(function (i) { if (cb.checked) S.selected[i.key] = true; else delete S.selected[i.key]; }); syncChecks(); };
    });
    RG.$$('#cleanBody input[data-tiny]').forEach(function (cb) {
      cb.onchange = function () { var g = G.groups.filter(function (x) { return x.id === cb.dataset.tiny; })[0]; if (!g) return; g.items.filter(function (i) { return !(i.sizeBytes > 0) && g.kind !== 'report' && g.kind !== 'review'; }).filter(selectable).forEach(function (i) { if (cb.checked) S.selected[i.key] = true; else delete S.selected[i.key]; }); syncChecks(); };
    });
    RG.$$('#cleanBody details.cl-group').forEach(function (d) { d.ontoggle = function () { CF.open[d.dataset.gid] = d.open; }; });
    RG.$$('#cleanBody [data-more]').forEach(function (b) { b.onclick = function () { CF.all[b.dataset.more] = true; CF.open[b.dataset.more] = true; drawClean(); }; });
    RG.$$('#cleanBody tr[data-open]').forEach(function (tr) { tr.onclick = function () { var i = itemByKey(tr.dataset.open); if (i) openItem(i); }; });
    RG.$$('#cleanBody [data-prot]').forEach(function (b) {
      b.onclick = function (e) {
        e.stopPropagation(); var it = itemByKey(b.dataset.prot); if (!it) return; var on = b.getAttribute('aria-pressed') !== 'true';
        (it.kind === 'process' ? RG.toggleProtect('process', it.name, on) : RG.toggleProtect('path', it.path, on)).then(function () { return RG.loadCands(); }).then(function () { RG.loadAdvice().catch(function () { }).then(drawClean); });
      };
    });
    RG.$$('#cleanBody [data-unkeep]').forEach(function (b) {
      b.onclick = function () { b.disabled = true; RG.api('/api/agent/keep/release', { method: 'POST', body: { key: b.dataset.unkeep } }).then(function () { RG.toast('Đã bỏ giữ. Mục quay lại danh sách dọn.', 'ok'); return RG.loadCands(); }).then(drawClean).catch(function (e) { RG.toast(e.message, 'err'); b.disabled = false; }); };
    });
    var de = $('#doElevate'); if (de) de.onclick = confirmElevate;
    RG.$$('#cleanBody [data-restore]').forEach(function (b) { b.onclick = function () { confirmRestore(b.dataset.restore); }; });
  }
  RG.pages.clean = {
    title: 'Dọn dẹp',
    render: function (el) { el.innerHTML = '<div id="cleanBody"></div>'; drawClean(); this.refresh(); },
    refresh: function () { Promise.all([RG.loadCands(), RG.loadPolicy(), RG.loadAdvice().catch(function () { }), RG.api('/api/cleanup/last').then(function (j) { S.cleanupLast = j.last; }), RG.api('/api/archives').then(function (j) { S.archives = j.items || []; }), RG.loadAgent()]).then(function () { RG.updateNavBadges(); if (RG.cur === 'clean') drawClean(); }).catch(function () { }); },
    jobs: function () { if (RG.cur === 'clean') { drawClean(); } },
    live: function () { }
  };
})();
