/* p-clean.js - Dọn dẹp (chọn tay) và Chính sách tự động (giữ/dọn/ưu tiên/vùng bảo vệ). */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$;
  var KIND = {
    'temp-entry': { l: 'File tạm', d: 'Thư mục/tệp trong %TEMP% lâu không đụng tới; chương trình tự tạo lại khi cần.' },
    'dotnet-artifact': { l: 'bin/obj (.NET)', d: 'Kết quả build, sinh lại ở lần build kế tiếp.' },
    'cache-aged': { l: 'Cache dev', d: 'NuGet/npm/pnpm: chỉ file không dùng ≥ N ngày; tải lại khi cần (cần mạng).' },
    'node_modules': { l: 'node_modules', d: 'Gỡ gói npm của dự án lâu không mở; cài lại bằng package manager.' },
    'process': { l: 'Tiến trình', d: 'Chỉ tiến trình agent đã đăng ký và đã mất chủ; mọi tiến trình khác chỉ báo cáo.' },
    'stale-repo': { l: 'Repo cũ', d: 'Repo git không sửa file nguồn ≥ 90 ngày và mọi thứ đã có trên remote. Nên nén zip trước khi xoá.' },
    'large-item': { l: 'Mục lớn', d: 'File/thư mục ≥ 500 MB trong Downloads, Videos không đụng ≥ 60 ngày. Có thể nén zip trước khi xoá.' },
    'app': { l: 'Ứng dụng', d: 'Ứng dụng cài đặt lâu không ghi file. Chỉ báo cáo: gỡ bằng Cài đặt > Ứng dụng của Windows.' }
  };
  var MODEHELP = {
    'off': 'Không làm gì tự động. Bạn dọn tay ở tab Dọn dẹp.',
    'dry-run': 'Khi có áp lực, tiến trình nền chỉ ghi nhận việc SẼ làm (xem ở “Lượt tự dọn gần nhất”). Không xoá gì. Nên chạy chế độ này vài ngày trước khi bật thật.',
    'on': 'Khi có áp lực và hết cooldown, tiến trình nền tự dọn đúng các nhóm đặt “Tự động”, tránh mọi thứ trong vùng bảo vệ. Cần PIN để bật/nới lỏng.'
  };
  var OUT = { done: 'Đã xoá', skipped: 'Bỏ qua', failed: 'Thất bại', 'would-run': 'Sẽ chạy' };

  /* ====================== Dọn dẹp ====================== */
  function recFor(key) {
    var a = S.agent && S.agent.ok && S.agent.result; if (!a) return null;
    return (a.recommendations || []).filter(function (r) { return r.key === key; })[0] || null;
  }
  var CF = { drive: '' };   // lọc danh sách ứng viên theo ổ ('' = tất cả)
  function selectedItems() { return ((S.cands && S.cands.items) || []).filter(function (i) { return S.selected[i.key]; }); }
  // Dữ liệu quét có quá ngưỡng dọn tay không (server gửi maxAgeHours, mặc định 12). Tính lại mỗi lần vẽ.
  function scanState(c) {
    var has = !!(c && c.finishedUtc), max = (c && c.maxAgeHours) || 12;
    var ageH = has ? (Date.now() - Date.parse(c.finishedUtc)) / 3600000 : null;
    return { has: has, max: max, stale: has && (isNaN(ageH) || ageH > max) };
  }
  // Việc tool SẼ làm với mục (khác với "chính sách" trong cài đặt). zip: undefined = bảng; true/false = hộp xác nhận.
  function actionOf(i, zip) {
    if (i.protected) return { k: 'prot', l: 'Được bảo vệ', d: 'Nằm trong vùng bảo vệ của bạn; bỏ bảo vệ trước nếu muốn dọn.', cls: 'keep' };
    if (i.action === 'report') return i.needsAdmin ? { k: 'admin', l: 'Cần quyền admin', d: 'Chỉ xoá được sau khi xác nhận UAC.', cls: 'ask' } : { k: 'report', l: 'Chỉ báo cáo', d: 'Tool không bao giờ xoá mục này.', cls: '' };
    if (i.action === 'kill') return { k: 'kill', l: 'Kết thúc tiến trình', d: 'Tiến trình bị dừng đột ngột; dữ liệu chưa lưu có thể mất.', cls: 'bad' };
    if (i.canArchive && zip === undefined) return { k: 'zipable', l: 'Xoá (có thể nén zip)', d: 'Có thể nén zip cạnh mục trước khi xoá; chọn ở hộp xác nhận.', cls: 'ask' };
    if (i.canArchive && zip) return { k: 'zip', l: 'Nén zip rồi xoá', d: 'Tạo .zip cạnh mục, kiểm tra xong mới xoá bản gốc.', cls: 'ask' };
    return { k: 'del', l: 'Xoá vĩnh viễn', d: 'Không qua Thùng rác, không hoàn tác được.', cls: 'bad' };
  }
  // Tóm tắt theo hành động + danh sách đầy đủ mục sẽ bị tác động. Gọi lại khi đổi tuỳ chọn zip.
  function planHtml(sel, zip) {
    var order = ['del', 'zip', 'kill'], g = {}, bytes = 0;
    sel.forEach(function (i) {
      var a = actionOf(i, zip); g[a.k] = g[a.k] || { a: a, n: 0, b: 0 }; g[a.k].n++;
      if (i.action !== 'kill') { g[a.k].b += i.sizeBytes || 0; bytes += i.sizeBytes || 0; }
    });
    var sum = order.filter(function (k) { return g[k]; }).map(function (k) {
      return '<tr><td><span class="pill ' + g[k].a.cls + '" title="' + esc(g[k].a.d) + '">' + g[k].a.l + '</span></td><td class="r num">' + g[k].n + '</td><td class="r num">' + (g[k].b ? RG.fmtBytes(g[k].b) : '–') + '</td></tr>';
    }).join('');
    var rows = sel.map(function (i) {
      var a = actionOf(i, zip), tgt = i.kind === 'process' ? (i.name + ' (pid ' + i.pid + ')') : i.path;
      return '<tr><td><span class="pill ' + a.cls + '">' + a.l + '</span></td><td><span class="mono" style="word-break:break-all">' + esc(tgt) + '</span></td><td class="r num">' + (i.sizeBytes && i.action !== 'kill' ? RG.fmtBytes(i.sizeBytes) : '–') + '</td></tr>';
    }).join('');
    return '<p class="small">Tổng ước tính giải phóng <b>' + RG.fmtBytes(bytes) + '</b> (mục nén zip chỉ giải phóng phần chênh lệch).</p>' +
      '<table class="cand small" style="margin-bottom:8px"><thead><tr><th>Hành động</th><th class="r">Số mục</th><th class="r">Dung lượng</th></tr></thead><tbody>' + sum + '</tbody></table>' +
      '<div class="tbl-wrap" style="max-height:240px"><table class="cand small"><thead><tr><th>Hành động</th><th>Mục</th><th class="r">Dung lượng</th></tr></thead><tbody>' + rows + '</tbody></table></div>';
  }
  function drawClean() {
    var el = $('#cleanBody'); if (!el) return;
    var c = S.cands, j = S.jobs.candidates, run = j && j.status === 'running', cj = S.jobs.cleanup, crun = cj && cj.status === 'running', st = scanState(c);
    var head = '<div class="field" style="margin-top:0"><button class="btn primary" id="scanC"' + (run ? ' disabled' : '') + '>' + RG.icon('refresh') + (c && c.finishedUtc ? 'Quét lại ứng viên' : 'Quét ứng viên') + '</button>' +
      '<button class="btn" id="selSafe"' + (st.stale ? ' disabled' : '') + '>Chọn mục rủi ro thấp</button><button class="btn" id="selNone">Bỏ chọn</button>';
    if (run) head += '<span class="spin"></span><span class="small mut">đang quét… ' + esc(j.message || '') + '</span>';
    else if (c && c.finishedUtc) head += '<span class="small mut">Quét ' + RG.timeAgo(c.finishedUtc) + ' (' + c.seconds + ' giây)</span>';
    head += '</div>';
    if (st.stale) head += '<div class="alert warn" role="status"><b>Dữ liệu quét đã cũ</b> (quá ' + st.max + ' giờ, quét ' + RG.timeAgo(c.finishedUtc) + '). Chưa chọn hay dọn được; bấm “Quét lại ứng viên” ở trên trước.</div>';
    if (!c || !c.finishedUtc) { el.innerHTML = head + '<div class="card empty">' + RG.icon('inbox') + '<h3>Chưa có danh sách ứng viên</h3><div>Quét sẽ tìm: file tạm cũ, bin/obj, node_modules lâu không mở, cache dev, tiến trình mồ côi của agent.</div></div>'; bindClean(); return; }
    var letters = {}; c.items.forEach(function (i) { if (i.drive) letters[i.drive] = (letters[i.drive] || 0) + 1; });
    var multi = Object.keys(letters).length > 1;
    if (!multi) CF.drive = '';
    if (multi) {
      var fo = [['', 'Tất cả (' + c.items.length + ')']].concat(Object.keys(letters).sort().map(function (L) { return [L, L + ': (' + letters[L] + ')']; }));
      head += '<div class="field" style="margin-top:0"><span class="small mut">Lọc theo ổ:</span>' + seg('cdrive', CF.drive, fo) + '</div>';
    }
    var items = c.items.filter(function (i) { return i.protectedBy !== 'agent' && (!CF.drive || i.drive === CF.drive); }).sort(function (a, b) { return (a.action === 'report') - (b.action === 'report') || a.level - b.level || b.sizeBytes - a.sizeBytes; });
    var rows = items.map(function (i) {
      var dis = i.action === 'report' || i.protected || st.stale, tgt = i.kind === 'process' ? (i.name + ' (pid ' + i.pid + ')') : i.path, rec = recFor(i.key), a = actionOf(i);
      var recPill = rec ? ' <span class="pill ' + (rec.verdict === 'clean' ? 'auto' : (rec.verdict === 'keep' ? 'keep' : 'ask')) + '" title="' + esc(rec.reason) + ' (độ tin cậy: ' + esc(rec.confidence) + ')">Agent: ' + ({ clean: 'nên dọn', keep: 'nên giữ', review: 'xem lại' }[rec.verdict] || esc(rec.verdict)) + ' · P' + rec.priority + '</span>' : '';
      return '<tr class="row"><td class="chk"><input type="checkbox" data-key="' + i.key + '"' + (S.selected[i.key] ? ' checked' : '') + (dis ? ' disabled' : '') + ' aria-label="Chọn ' + esc(tgt) + '"></td>' +
        '<td><span class="pill">' + esc((KIND[i.kind] || {}).l || i.kind) + '</span></td>' +
        (multi ? '<td class="mut">' + (i.drive ? esc(i.drive) + ':' : '–') + '</td>' : '') +
        '<td><span class="mono" style="word-break:break-all" title="' + esc(tgt) + '">' + esc(tgt) + '</span>' + (i.young ? ' <span class="pill ask" title="Chưa đủ tuổi theo policy; agent/người dùng cân nhắc. Không bao giờ tự dọn.">chưa đủ tuổi</span>' : '') + recPill + '<div class="small mut">' + esc(i.reason) + ' — <i>' + esc(i.risk) + '</i></div></td>' +
        '<td class="r num">' + (i.sizeBytes && i.action !== 'kill' ? RG.fmtBytes(i.sizeBytes) : '–') + '</td><td class="r num mut">' + (i.ageDays ? RG.fmtAge(i.ageDays) : '–') + '</td>' +
        '<td><span class="pill ' + a.cls + '" title="' + esc(a.d) + '">' + a.l + '</span></td>' +
        '<td class="r"><button class="icon-btn ' + (i.protected ? 'on' : '') + '" data-prot="' + i.key + '" aria-pressed="' + !!i.protected + '" aria-label="' + (i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ') + ' ' + esc(tgt) + '" title="' + (i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ khỏi dọn') + '">' + RG.icon('shield') + '</button></td></tr>';
    }).join('');
    var sel = selectedItems(), nKill = sel.filter(function (i) { return i.action === 'kill'; }).length, nDel = sel.length - nKill;
    var selBytes = sel.reduce(function (a, i) { return a + (i.action === 'kill' ? 0 : (i.sizeBytes || 0)); }, 0);
    el.innerHTML = head + (items.length ? '<div class="card"><div class="tbl-wrap" style="max-height:none"><table class="cand"><thead><tr><th></th><th>Loại</th>' + (multi ? '<th>Ổ</th>' : '') + '<th>Mục</th><th class="r">Dung lượng</th><th class="r">Không dùng</th><th>Hành động</th><th class="r">Bảo vệ</th></tr></thead><tbody>' + rows + '</tbody></table></div>' +
      '<p class="hint">Cột “Hành động” là việc tool sẽ làm với mục đó khi bạn dọn. “Được bảo vệ” nằm trong vùng bảo vệ của bạn nên không chọn được. “Chỉ báo cáo” (VHDX, tiến trình lạ) tool không bao giờ xoá. Xoá là vĩnh viễn, không qua Thùng rác, trừ khi chọn nén zip.</p></div>' :
      '<div class="card empty">' + RG.icon('inbox') + '<h3>Không có ứng viên nào</h3><div>Máy đang gọn theo các tiêu chí hiện tại.</div></div>') + adminBox(items, crun) +
      '<div class="sticky-bar" ' + (sel.length || crun ? '' : 'hidden') + '><b class="num">' + sel.length + ' mục đã chọn</b><span class="mut small">' + (nDel ? nDel + ' xoá' : '') + (nDel && nKill ? ' · ' : '') + (nKill ? nKill + ' kết thúc tiến trình' : '') + '</span><span class="mut">ước tính giải phóng ' + RG.fmtBytes(selBytes) + '</span><span style="flex:1"></span>' +
      (crun ? '<span class="spin"></span><span class="small mut">đang dọn… ' + esc(cj.message || '') + '</span>' : '<button class="btn danger" id="doClean"' + (st.stale ? ' disabled title="Dữ liệu quét đã cũ; quét lại trước khi dọn"' : '') + '>' + RG.icon('trash') + ' Dọn mục đã chọn</button>') + '</div>' + drawAgentKept(c) + drawArchives() + drawCleanResult();
    bindClean();
  }
  /* Mục agent đánh giá "nên giữ" (độ tin cậy cao): ẩn khỏi danh sách dọn, không bao giờ tự dọn, tự hết hạn. Bỏ giữ từng mục. */
  function drawAgentKept(c) {
    var ks = c.items.filter(function (i) { return i.protectedBy === 'agent'; });
    if (!ks.length) return '';
    var rows = ks.map(function (i) {
      var until = i.keepUntilUtc ? new Date(i.keepUntilUtc).toLocaleDateString('vi-VN') : '–';
      return '<tr class="row"><td><span class="ellipsis mono" title="' + esc(i.path) + '">' + esc(i.path) + '</span><div class="small mut">' + esc(i.keepReason || '') + '</div></td>' +
        '<td class="r num">' + (i.sizeBytes ? RG.fmtBytes(i.sizeBytes) : '–') + '</td><td class="r num mut">' + until + '</td>' +
        '<td class="r"><button class="btn sm" data-unkeep="' + i.key + '">Bỏ giữ</button></td></tr>';
    }).join('');
    return '<div class="card mt"><h2>Agent đang giữ <span class="ro">' + ks.length + ' mục</span></h2><div class="tbl-wrap" style="max-height:none"><table class="cand"><thead><tr><th>Mục</th><th class="r">Dung lượng</th><th class="r">Giữ đến</th><th></th></tr></thead><tbody>' + rows + '</tbody></table></div>' +
      '<p class="hint">Agent đánh giá các mục này nên giữ (độ tin cậy cao) nên chúng không hiện trong danh sách dọn và không bao giờ bị tự dọn. Tự hết hạn sau 30 ngày rồi được đánh giá lại; bấm “Bỏ giữ” để đưa về danh sách dọn ngay.</p></div>';
  }
  /* Mục do tài khoản khác (SYSTEM) sở hữu: chỉ xoá được bằng quyền admin. Không tự nâng quyền: phải bấm nút + xác nhận + UAC của Windows. */
  function adminItems() { return ((S.cands && S.cands.items) || []).filter(function (i) { return i.needsAdmin && !i.protected; }); }
  function adminBox(items, crun) {
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
  /* Bản nén do tool tạo (zip cạnh mục gốc): giải nén lại đúng chỗ cũ. */
  function drawArchives() {
    var a = (S.archives || []);
    if (!a.length) return '';
    var rows = a.map(function (r) {
      var st = r.restoredUtc ? '<span class="pill auto">đã khôi phục</span>' : (!r.zipExists ? '<span class="pill bad">zip đã mất</span>' : (r.originalExists ? '<span class="pill">vị trí cũ đã có dữ liệu</span>' : ''));
      var can = r.zipExists && !r.originalExists && !r.restoredUtc;
      return '<tr><td><span class="ellipsis mono" title="' + esc(r.original) + '">' + esc(r.original) + '</span><div class="small mut">' + esc(r.zip) + '</div></td>' +
        '<td class="r num">' + RG.fmtBytes(r.bytes) + ' → ' + RG.fmtBytes(r.zipBytes) + '</td><td class="small mut">' + RG.timeAgo(r.createdUtc) + '</td><td>' + st + '</td>' +
        '<td class="r">' + (can ? '<button class="btn" data-restore="' + esc(r.id) + '">Giải nén về chỗ cũ</button>' : '') + '</td></tr>';
    }).join('');
    return '<div class="card mt"><h2>Bản nén đã tạo<span class="ro">' + a.length + '</span></h2><div class="tbl-wrap"><table><tbody>' + rows + '</tbody></table></div>' +
      '<p class="hint">Zip nằm cạnh vị trí gốc. Giải nén không ghi đè: chỉ chạy khi vị trí cũ trống. Xoá file zip thủ công khi chắc chắn không cần nữa.</p></div>';
  }
  function confirmRestore(id) {
    var r = (S.archives || []).filter(function (x) { return x.id === id; })[0]; if (!r) return;
    RG.confirm('Giải nén về chỗ cũ?', '<p>Khôi phục <span class="mono">' + esc(r.original) + '</span> (' + RG.fmtBytes(r.bytes) + ') từ <span class="mono">' + esc(r.zip) + '</span>. File zip được giữ lại.</p>', 'Giải nén', false).then(function (ok) {
      if (!ok) return;
      RG.startJob('/api/archive/restore', { id: id }, 'Đang giải nén…').then(drawClean).catch(function () { });
    });
  }
  function drawCleanResult() {
    var l = S.cleanupLast; if (!l) return '';
    var rows = (l.results || []).map(function (r) { return '<tr><td>' + esc((KIND[r.kind] || {}).l || r.kind) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td><span class="pill ' + (r.outcome === 'done' ? 'auto' : (r.outcome === 'failed' ? 'bad' : 'ask')) + '">' + (OUT[r.outcome] || esc(r.outcome)) + '</span></td><td class="small mut">' + esc(r.detail || '') + '</td></tr>'; }).join('');
    (l.refused || []).forEach(function (r) { var it = ((S.cands && S.cands.items) || []).filter(function (x) { return x.key === r.key; })[0]; var tg = it ? (it.kind === 'process' ? it.name + ' (pid ' + it.pid + ')' : it.path) : r.key; rows += '<tr><td colspan="2"><span class="mono small" style="word-break:break-all">' + esc(tg) + '</span></td><td><span class="pill bad">Từ chối</span></td><td class="small mut">' + esc(r.reason) + '</td></tr>'; });
    return '<div class="card mt"><h2>Kết quả lượt dọn gần nhất<span class="ro">' + RG.timeAgo(l.finishedUtc) + ' · giải phóng ' + RG.fmtBytes(l.freedBytes) + '</span></h2><div class="tbl-wrap"><table><tbody>' + rows + '</tbody></table></div></div>';
  }
  function bindClean() {
    var sc = $('#scanC'); if (sc) sc.onclick = function () { RG.startJob('/api/candidates/scan', {}, 'Bắt đầu quét ứng viên…'); };
    var ss = $('#selSafe'); if (ss) ss.onclick = function () { ((S.cands && S.cands.items) || []).forEach(function (i) { if (i.action === 'delete' && !i.protected && i.level <= 1) S.selected[i.key] = true; }); drawClean(); };
    var sn = $('#selNone'); if (sn) sn.onclick = function () { S.selected = {}; drawClean(); };
    RG.$$('#cleanBody [data-set="cdrive"]').forEach(function (b) { b.onclick = function () { CF.drive = b.dataset.val; drawClean(); }; });
    RG.$$('#cleanBody input[data-key]').forEach(function (cb) { cb.onchange = function () { if (cb.checked) S.selected[cb.dataset.key] = true; else delete S.selected[cb.dataset.key]; drawClean(); }; });
    RG.$$('#cleanBody [data-prot]').forEach(function (b) {
      b.onclick = function () {
        var it = S.cands.items.filter(function (i) { return i.key === b.dataset.prot; })[0]; if (!it) return;
        var on = b.getAttribute('aria-pressed') !== 'true';
        (it.kind === 'process' ? RG.toggleProtect('process', it.name, on) : RG.toggleProtect('path', it.path, on)).then(function () { return RG.loadCands(); }).then(drawClean);
      };
    });
    RG.$$('#cleanBody [data-unkeep]').forEach(function (b) {
      b.onclick = function () {
        b.disabled = true;
        RG.api('/api/agent/keep/release', { method: 'POST', body: { key: b.dataset.unkeep } }).then(function () { RG.toast('Đã bỏ giữ. Mục quay lại danh sách dọn.', 'ok'); return RG.loadCands(); }).then(drawClean).catch(function (e) { RG.toast(e.message, 'err'); b.disabled = false; });
      };
    });
    var dc = $('#doClean'); if (dc) dc.onclick = confirmClean;
    var de = $('#doElevate'); if (de) de.onclick = confirmElevate;
    RG.$$('#cleanBody [data-restore]').forEach(function (b) { b.onclick = function () { confirmRestore(b.dataset.restore); }; });
  }
  function confirmClean() {
    var sel = selectedItems(); if (!sel.length) return;
    if (scanState(S.cands).stale) { RG.toast('Dữ liệu quét đã cũ; hãy quét lại trước khi dọn.', 'err'); return; }
    var zipN = sel.filter(function (i) { return i.canArchive; }).length, zip = true;
    var zipBox = zipN ? '<label class="small" style="display:block;margin:8px 0"><input type="checkbox" id="optZip" checked> <b>Nén zip cạnh mục trước khi xoá</b> (' + zipN + ' mục). Tạo <span class="mono">&lt;tên&gt;.zip</span> trong cùng thư mục, kiểm tra xong mới xoá bản gốc; khôi phục bằng nút Giải nén ở bảng “Bản nén đã tạo”. Bỏ chọn thì các mục đó xoá vĩnh viễn.</label>' : '';
    var nKill = sel.filter(function (i) { return i.action === 'kill'; }).length;
    var html = '<p class="small">Bảng dưới cho biết <b>chính xác</b> việc gì sẽ xảy ra với từng mục.</p>' +
      '<div id="cfPlan">' + planHtml(sel, true) + '</div>' + zipBox +
      (nKill ? '<p class="small"><b>Lưu ý:</b> ' + nKill + ' tiến trình sẽ bị kết thúc. Chỉ tiếp tục nếu các tiến trình đó không còn cần thiết.</p>' : '') +
      '<p class="hint">Mục “Xoá vĩnh viễn” không qua Thùng rác và không hoàn tác được. Trước khi làm, engine kiểm lại từng mục (allowlist, tuổi file, junction, trạng thái git…). Mục không đạt sẽ bị bỏ qua và báo lý do ở “Kết quả lượt dọn gần nhất”.</p>';
    RG.confirm('Xác nhận dọn ' + sel.length + ' mục?', html, 'Dọn ' + sel.length + ' mục', true).then(function (ok) {
      if (!ok) return;
      RG.startJob('/api/cleanup/apply', { keys: sel.map(function (i) { return i.key; }), archive: zip }, zip && zipN ? 'Đang nén zip và dọn…' : 'Đang dọn…').then(drawClean).catch(function () { });
    });
    setTimeout(function () { var c = RG.$('#optZip'); if (c) c.onchange = function () { zip = c.checked; var p = RG.$('#cfPlan'); if (p) p.innerHTML = planHtml(sel, zip); }; }, 0);
  }
  RG.pages.clean = {
    title: 'Dọn dẹp',
    render: function (el) { el.innerHTML = '<div id="cleanBody"></div>'; drawClean(); this.refresh(); },
    refresh: function () { Promise.all([RG.loadCands(), RG.loadPolicy(), RG.api('/api/cleanup/last').then(function (j) { S.cleanupLast = j.last; }), RG.api('/api/archives').then(function (j) { S.archives = j.items || []; }), RG.loadAgent()]).then(function () { RG.updateNavBadges(); drawClean(); }).catch(function () { }); },
    jobs: function () { if (RG.cur === 'clean') drawClean(); },
    live: function () { }
  };

  /* ====================== Chính sách tự động ====================== */
  function seg(name, val, opts, dis) {
    return '<span class="seg sm" role="group" aria-label="' + esc(name) + '">' + opts.map(function (o) { return '<button data-set="' + esc(name) + '" data-val="' + esc(o[0]) + '" aria-pressed="' + (val === o[0]) + '"' + (dis ? ' disabled' : '') + '>' + o[1] + '</button>'; }).join('') + '</span>';
  }
  function tags(list, type) {
    return '<div class="tags">' + (list.length ? list.map(function (x) { return '<span class="tag"><span class="mono">' + esc(x) + '</span><button data-rm="' + type + '" data-v="' + esc(x) + '" aria-label="Gỡ ' + esc(x) + '">×</button></span>'; }).join('') : '<span class="small mut">Chưa có.</span>') + '</div>';
  }
  /* Ghi đè theo ổ: val rỗng/null = bỏ ghi đè (quay về giá trị chung); không còn khoá nào thì xoá cả mục của ổ. */
  function setDrive(p, L, key, val) {
    var o = p.drives[L] || {};
    if (val == null) delete o[key]; else o[key] = val;
    if (Object.keys(o).length) p.drives[L] = o; else delete p.drives[L];
  }
  function markDirty() {
    S.dirty = JSON.stringify(S.draft) !== JSON.stringify(S.policy);
    var b = $('#polBar'); if (b) b.hidden = !S.dirty;
  }
  function drawAutoLast() {
    var el = $('#autoLast'); if (!el) return;
    var l = S.autoLast, j = S.jobs.auto, run = j && j.status === 'running';
    var h = '<div class="field" style="margin-top:0"><button class="btn" id="dryRun"' + (run ? ' disabled' : '') + '>' + RG.icon('play') + ' Chạy thử ngay (không xoá)</button>' + (run ? '<span class="spin"></span><span class="small mut">đang quét và mô phỏng…</span>' : '') + '</div>';
    if (!l) { el.innerHTML = h + '<p class="small mut">Chưa có lượt nào. “Chạy thử” cho bạn thấy engine SẼ chọn gì với chính sách hiện tại (giả định có áp lực), không xoá gì.</p>'; bindAuto(); return; }
    var rows = (l.items || []).map(function (r) { return '<tr><td>' + esc((KIND[r.kind] || {}).l || r.kind) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td class="r num">' + (r.sizeBytes ? RG.fmtBytes(r.sizeBytes) : '') + '</td><td><span class="pill ' + (r.outcome === 'done' ? 'auto' : (r.outcome === 'failed' ? 'bad' : 'ask')) + '">' + (OUT[r.outcome] || esc(r.outcome)) + '</span></td><td class="small mut">' + esc(r.detail || '') + '</td></tr>'; }).join('');
    var sk = (l.skipped || []).map(function (r) { return '<tr><td>' + esc((KIND[r.kind] || {}).l || r.kind) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td class="small mut">' + esc(r.reason) + '</td></tr>'; }).join('');
    var sd = (l.stress.drives || []).filter(function (d) { return d && d.drive; });
    var diskTxt = sd.length ? 'Ổ ' + sd.map(function (d) { return esc(d.drive) + ': ' + esc(d.state) + ' (' + d.freeGB + ' GB trống' + (d.stress ? ', có áp lực' : '') + ')'; }).join('; ') : 'Ổ đĩa ' + esc(l.stress.diskState) + ' (' + l.stress.diskFreeGB + ' GB trống)';
    el.innerHTML = h + '<div class="small mut">Lượt ' + RG.timeAgo(l.finishedUtc) + ' · chế độ <b>' + esc(l.mode) + '</b> · kích hoạt: ' + esc(l.trigger) + ' · ' + diskTxt + ', RAM ' + esc(l.stress.ramState) + ' · ' + l.candidateCount + ' ứng viên · giải phóng ' + RG.fmtBytes(l.freedBytes) + '</div>' +
      (rows ? '<div class="tbl-wrap" style="margin-top:8px"><table><tbody>' + rows + '</tbody></table></div>' : '<p class="small mut">Không có mục nào được chọn.</p>') +
      (sk ? '<details style="margin-top:8px"><summary class="small" style="cursor:pointer">Mục bị bỏ qua (' + (l.skipped || []).length + ')</summary><div class="tbl-wrap" style="margin-top:6px"><table><tbody>' + sk + '</tbody></table></div></details>' : '');
    bindAuto();
  }
  function bindAuto() { var b = $('#dryRun'); if (b) b.onclick = function () { RG.startJob('/api/auto/run', {}, 'Đang chạy thử…').then(drawAutoLast).catch(function () { }); }; }
  function drawPolicy() {
    var el = $('#polBody'); if (!el) return;
    var p = S.draft; if (!p) { el.innerHTML = '<div class="empty">Đang tải…</div>'; return; }
    if (!p.drives || Array.isArray(p.drives)) p.drives = {};
    var noPin = p.mode === 'on' && !S.pinConfigured;
    var cats = (S.kinds || []).map(function (k) {
      var kd = KIND[k] || { l: k, d: '' };
      return '<tr><td><b>' + esc(kd.l) + '</b><div class="small mut">' + esc(kd.d) + '</div></td><td class="r">' + seg('cat:' + k, p.categories[k], [['auto', 'Tự động'], ['ask', 'Hỏi tay'], ['keep', 'Luôn giữ']]) + '</td></tr>';
    }).join('');
    var prio = p.priority.map(function (k, i) {
      return '<div class="prio"><span class="n">' + (i + 1) + '</span><span style="flex:1">' + esc((KIND[k] || {}).l || k) + ' ' + (p.categories[k] ? '<span class="pill ' + p.categories[k] + '">' + ({ auto: 'tự động', ask: 'hỏi tay', keep: 'giữ' }[p.categories[k]]) + '</span>' : '') + '</span>' +
        '<button class="icon-btn" data-mv="' + i + '" data-d="-1" aria-label="Chuyển lên"' + (i === 0 ? ' disabled' : '') + '>' + RG.icon('up') + '</button><button class="icon-btn" data-mv="' + i + '" data-d="1" aria-label="Chuyển xuống"' + (i === p.priority.length - 1 ? ' disabled' : '') + '>' + RG.icon('down') + '</button></div>';
    }).join('');
    var dl = RG.driveList();
    var drvRows = dl.map(function (d) {
      var o = p.drives[d.drive] || {}, st = d.state || 'Normal';
      return '<tr><td><b>' + esc(d.drive) + ':</b>' + (d.label ? ' <span class="small mut">' + esc(d.label) + '</span>' : '') + '<div class="small mut">' + d.freeGB + ' GB trống' + (st !== 'Normal' ? ' · <span class="pill ' + (st === 'Critical' ? 'ask' : '') + '">' + esc(st) + '</span>' : '') + '</div></td>' +
        '<td>' + seg('dtrig:' + d.drive, o.diskTrigger || '', [['', 'Theo chung (' + p.diskTrigger + ')'], ['off', 'Không'], ['Caution', 'Caution'], ['Critical', 'Critical']]) + '</td>' +
        '<td class="r"><input type="number" min="1" max="10000" data-dnum="' + esc(d.drive) + '" value="' + (o.targetFreeGB != null ? o.targetFreeGB : '') + '" placeholder="' + p.targetFreeGB + '" aria-label="Dừng khi ổ ' + esc(d.drive) + ' đạt trống (GB)" style="width:90px"></td></tr>';
    }).join('');
    var roots = (S.roots || []).length ? '<p class="hint">Thư mục mã nguồn tool nhận diện (quét repo, bảo vệ khi xoá): <span class="mono">' + (S.roots || []).map(esc).join(' · ') + '</span>. Thư mục tên Work, Repositories, Source, Projects… trên các ổ khác tự được thêm.</p>' : '';
    var drvCard = dl.length ? '<div class="card mt"><h2>Theo từng ổ đĩa</h2><table><thead><tr><th>Ổ</th><th>Kích hoạt từ mức</th><th class="r">Dừng khi trống (GB)</th></tr></thead><tbody>' + drvRows + '</tbody></table>' +
      '<p class="hint">Mỗi ổ được đánh giá riêng: ổ nào chạm ngưỡng thì chỉ dọn mục nằm trên ổ đó, và dừng khi ổ đó đủ dung lượng trống. “Theo chung” dùng giá trị ở khung bên trên. Giới hạn “Tối đa mỗi lượt” tính riêng cho từng ổ.</p>' + roots + '</div>' : '';
    el.innerHTML =
      '<div class="grid g2"><div class="card"><h2>Chế độ tự động</h2>' + seg('mode', p.mode, [['off', 'Tắt'], ['dry-run', 'Chạy thử'], ['on', 'Bật']]) +
      '<p class="hint" style="margin-top:8px">' + esc(MODEHELP[p.mode]) + '</p>' +
      (noPin ? '<div class="alert warn" style="margin-top:8px"><div>Chưa đặt PIN. Chạy ở terminal: <span class="mono">powershell -File scripts\\resource-manager.ps1 serve setpin</span> rồi quay lại lưu.</div></div>' : '') +
      '<h2 style="margin-top:14px">Khi nào kích hoạt</h2>' +
      '<div class="field"><label>Ổ đĩa (dọn file) từ mức</label>' + seg('diskTrigger', p.diskTrigger, [['off', 'Không'], ['Caution', 'Caution'], ['Critical', 'Critical']]) + '</div>' +
      '<div class="field"><label>RAM (kết thúc tiến trình) từ mức</label>' + seg('ramTrigger', p.ramTrigger, [['off', 'Không'], ['Restricted', 'Restricted'], ['Critical', 'Critical']]) + '</div>' +
      '<div class="field"><label for="fCool">Nghỉ giữa hai lượt (phút)</label><input id="fCool" data-num="cooldownMin" type="number" min="1" max="1440" value="' + p.cooldownMin + '"></div>' +
      '<div class="field"><label for="fMax">Tối đa mỗi lượt (GB)</label><input id="fMax" data-num="maxGBPerRun" type="number" min="0.1" max="500" step="0.5" value="' + p.maxGBPerRun + '"></div>' +
      '<div class="field"><label for="fTgt">Dừng khi ổ đĩa đạt trống (GB)</label><input id="fTgt" data-num="targetFreeGB" type="number" min="1" max="1000" value="' + p.targetFreeGB + '"></div>' +
      '<div class="field"><label for="fKill">Tối đa tiến trình kết thúc / lượt</label><input id="fKill" data-num="maxKillsPerRun" type="number" min="0" max="50" value="' + p.maxKillsPerRun + '"></div></div>' +
      '<div class="card"><h2>Từng nhóm: giữ hay dọn</h2><table><tbody>' + cats + '</tbody></table>' +
      '<p class="hint">“Tự động”: engine dọn khi có áp lực. “Hỏi tay”: chỉ xuất hiện ở tab Dọn dẹp để bạn chọn. “Luôn giữ”: không bao giờ đụng tới. File cá nhân (Downloads, Documents…) không nằm trong danh sách vì tool không bao giờ tự xoá chúng.</p></div></div>' +
      drvCard +
      '<div class="grid g2 mt"><div class="card"><h2>Thứ tự ưu tiên khi dọn</h2>' + prio + '<p class="hint">Nhóm ở trên được dọn trước; trong cùng nhóm, mục lớn hơn dọn trước.</p></div>' +
      '<div class="card"><h2>Vùng bảo vệ (tránh khi tự dọn)</h2><div class="field" style="margin-top:0"><label for="addPath" style="min-width:auto">Thư mục</label><input id="addPath" type="text" placeholder="C:\\Users\\bạn\\Work\\dự-án-quan-trọng" style="flex:1;min-width:200px"><button class="btn sm" id="addPathBtn">Thêm</button></div>' + tags(p.protectPaths, 'path') +
      '<div class="field"><label for="addProc" style="min-width:auto">Tiến trình</label><input id="addProc" type="text" placeholder="vd: sqlservr, devenv, node*" style="flex:1;min-width:200px"><button class="btn sm" id="addProcBtn">Thêm</button></div>' + tags(p.protectProcesses, 'proc') +
      '<p class="hint">Mục nằm trong (hoặc chứa) thư mục bảo vệ, và tiến trình khớp tên (hỗ trợ * ?), sẽ bị engine bỏ qua kể cả khi nhóm đặt “Tự động”. Thêm bảo vệ không cần PIN. Có thể bảo vệ nhanh bằng biểu tượng khiên ở các tab khác.</p></div></div>' +
      '<div class="card mt"><h2>Lượt tự dọn gần nhất</h2><div id="autoLast"></div></div>' +
      '<div class="sticky-bar" id="polBar" ' + (S.dirty ? '' : 'hidden') + '><b>Có thay đổi chưa lưu</b><span style="flex:1"></span><button class="btn" id="polReset">Hoàn tác</button><button class="btn primary" id="polSave">Lưu chính sách</button></div>';
    RG.$$('#polBody [data-set]').forEach(function (b) {
      b.onclick = function () {
        var n = b.dataset.set;
        if (n.indexOf('cat:') === 0) p.categories[n.slice(4)] = b.dataset.val;
        else if (n.indexOf('dtrig:') === 0) setDrive(p, n.slice(6), 'diskTrigger', b.dataset.val || null);
        else p[n] = b.dataset.val;
        markDirty(); drawPolicy();
      };
    });
    RG.$$('#polBody [data-dnum]').forEach(function (inp) {
      inp.onchange = function () { var v = parseFloat(inp.value); setDrive(p, inp.dataset.dnum, 'targetFreeGB', isNaN(v) ? null : Math.max(1, Math.min(10000, v))); markDirty(); drawPolicy(); };
    });
    RG.$$('#polBody [data-num]').forEach(function (inp) { inp.onchange = function () { var v = parseFloat(inp.value); if (!isNaN(v)) p[inp.dataset.num] = v; markDirty(); }; });
    RG.$$('#polBody [data-mv]').forEach(function (b) { b.onclick = function () { var i = +b.dataset.mv, j = i + +b.dataset.d, a = p.priority; var t = a[i]; a[i] = a[j]; a[j] = t; markDirty(); drawPolicy(); }; });
    RG.$$('#polBody [data-rm]').forEach(function (b) { b.onclick = function () { var k = b.dataset.rm === 'path' ? 'protectPaths' : 'protectProcesses'; p[k] = p[k].filter(function (x) { return x !== b.dataset.v; }); markDirty(); drawPolicy(); }; });
    function addTag(inputId, key, valid) {
      var v = $(inputId).value.trim(); if (!v) return;
      if (valid && !valid(v)) { RG.toast('Giá trị không hợp lệ.', 'err'); return; }
      if (p[key].some(function (x) { return x.toLowerCase() === v.toLowerCase(); })) return;
      p[key].push(key === 'protectProcesses' ? v.toLowerCase() : v); markDirty(); drawPolicy();
    }
    $('#addPathBtn').onclick = function () { addTag('#addPath', 'protectPaths', function (v) { return /^[A-Za-z]:\\.{2,}/.test(v) || /^%[A-Za-z_]+%\\/.test(v); }); };
    $('#addProcBtn').onclick = function () { addTag('#addProc', 'protectProcesses', function (v) { return /^[\w.*?\- ]{1,60}$/.test(v); }); };
    $('#addPath').onkeydown = function (e) { if (e.key === 'Enter') $('#addPathBtn').click(); };
    $('#addProc').onkeydown = function (e) { if (e.key === 'Enter') $('#addProcBtn').click(); };
    $('#polReset').onclick = function () { S.draft = RG.clone(S.policy); S.dirty = false; drawPolicy(); };
    $('#polSave').onclick = function () {
      var btn = $('#polSave'); btn.disabled = true;
      RG.savePolicy(S.draft).then(function (j) { S.draft = RG.clone(j.policy); S.dirty = false; RG.toast('Đã lưu chính sách.', 'ok'); drawPolicy(); })
        .catch(function (e) { RG.toast(e.message, 'err'); btn.disabled = false; });
    };
    drawAutoLast();
  }
  RG.pages.policy = {
    title: 'Chính sách tự động',
    render: function (el) { el.innerHTML = '<div id="polBody"><div class="empty">Đang tải…</div></div>'; drawPolicy(); this.refresh(); },
    refresh: function () { Promise.all([RG.loadPolicy(), RG.loadDrives().catch(function () { })]).then(function () { drawPolicy(); }); RG.loadAuto().then(drawAutoLast).catch(function () { }); },
    jobs: function () { if (RG.cur === 'policy') drawAutoLast(); },
    live: function () { }
  };
})();
