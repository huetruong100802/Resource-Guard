/* p-disk.js - Màn Ổ đĩa hợp nhất: thanh trước → sau (dính) · bản đồ + việc có thể làm (công tắc tự động ngay trên dòng) · thanh Lưu chính sách.
   Gộp p-clean.js (chọn mục, xác nhận, kết quả, admin, zip) và phần ổ của p-auto.js (bản nháp, câu mô tả, xem trước, chạy thử). */
(function () {
  'use strict';
  var RG = window.RG, S = RG.S, esc = RG.esc, $ = RG.$, V = RG.viz, GB = 1073741824, LABEL = V.CAT_LABEL;
  var OUT = { done: 'Đã xoá', skipped: 'Bỏ qua', failed: 'Thất bại', 'would-run': 'Sẽ chạy' };
  var RISKCLS = { low: 'auto', medium: 'ask', high: 'bad' };
  var SET = [['auto', 'Tự động'], ['ask', 'Hỏi tôi'], ['keep', 'Luôn giữ']];
  var MODEHELP = {
    off: 'Không làm gì tự động; bạn dọn tay ở màn này.',
    'dry-run': 'Khi có áp lực, tiến trình nền chỉ ghi nhận việc SẼ làm, không xoá gì. Nên chạy vài ngày trước khi bật thật.',
    on: 'Khi có áp lực và hết thời gian nghỉ, tiến trình nền tự dọn đúng các nhóm đặt “Tự động”, tránh vùng bảo vệ. Cần PIN để bật hoặc nới lỏng.'
  };
  // Ba mức sẵn: chỉ điền bản nháp (vẫn phải Lưu). Nhóm rủi ro cao không bao giờ đặt “Tự động” ở mức sẵn.
  var PRESETS = {
    careful: { label: 'Thận trọng', diskTrigger: 'Critical', maxGBPerRun: 5, cooldownMin: 120, auto: ['temp-entry'] },
    balanced: { label: 'Cân bằng', diskTrigger: 'Critical', maxGBPerRun: 10, cooldownMin: 60, auto: ['temp-entry', 'dotnet-artifact'] },
    active: { label: 'Chủ động', diskTrigger: 'Caution', maxGBPerRun: 20, cooldownMin: 30, auto: ['temp-entry', 'dotnet-artifact', 'cache-aged'] }
  };
  var NOTE = {
    'system-files': 'pagefile.sys, hiberfil.sys, swapfile.sys: chỉ giảm được bằng cấu hình Windows.',
    repos: 'Mã nguồn của bạn; node_modules/bin/obj bên trong được tách ra thành mục dọn.',
    downloads: 'File cá nhân: chỉ liệt kê, không bao giờ tự xoá.', documents: 'File cá nhân: chỉ liệt kê, không bao giờ tự xoá.',
    'vm-disks': 'Ổ ảo chỉ nén thủ công (docker builder prune, wsl --manage … --set-sparse true).'
  };
  var MAXROWS = 40;
  var D = { view: 'map', tree: {}, stale: {}, treeBusy: {}, open: {}, all: {}, pv: null, pvBusy: false, timer: null, seq: 0, hist: {}, histAt: 0, tm: null, bar: null, pick: null, menu: false, wasRun: false, sig: '', hov: null, adv: false };
  var G = { groups: [], byKey: {} };

  function seg(name, val, opts, dis) { return '<span class="seg sm" role="group" aria-label="' + esc(name) + '">' + opts.map(function (o) { return '<button data-set="' + esc(name) + '" data-val="' + esc(o[0]) + '" aria-pressed="' + (val === o[0]) + '"' + (dis ? ' disabled' : '') + '>' + o[1] + '</button>'; }).join('') + '</span>'; }
  RG.seg = seg;
  function pill(cls, t, title) { return '<span class="pill ' + cls + '"' + (title ? ' title="' + esc(title) + '"' : '') + '>' + t + '</span>'; }
  function noop() { }
  function lc(p) { return String(p || '').replace(/\\+$/, '').toLowerCase(); }

  /* ---------- Dữ liệu ---------- */
  function recFor(key) { var a = S.agent && S.agent.ok && S.agent.result; if (!a) return null; return (a.recommendations || []).filter(function (r) { return r.key === key; })[0] || null; }
  function allItems() { return (S.cands && S.cands.items) || []; }
  function itemByKey(k) { return allItems().filter(function (i) { return i.key === k; })[0]; }
  function scanState(c) {
    var has = !!(c && c.finishedUtc), max = (c && c.maxAgeHours) || 12, ageH = has ? (Date.now() - Date.parse(c.finishedUtc)) / 3600000 : null;
    return { has: has, max: max, stale: has && (isNaN(ageH) || ageH > max) };
  }
  function selectable(i) { return i.action !== 'report' && !i.protected && !scanState(S.cands).stale; }
  function tgtOf(i) { return i.kind === 'process' ? (i.name + ' (pid ' + i.pid + ')') : i.path; }
  function shortOf(i) { if (i.kind === 'process') return tgtOf(i); var p = String(i.path || '').split('\\').filter(Boolean); return p.length > 2 ? '…\\' + p.slice(-2).join('\\') : p.join('\\'); }
  function firstDrive() { var dl = RG.driveList(); return dl[0] ? dl[0].drive : ''; }
  function inScope(i, L) { return i.drive ? i.drive === L : L === firstDrive(); }   // mục không thuộc ổ nào (tiến trình mồ côi) hiện ở ổ đầu tiên
  function scopeItems(L) { return allItems().filter(function (i) { return i.protectedBy !== 'agent' && inScope(i, L); }); }
  function selFor(L) { return scopeItems(L).filter(function (i) { return S.selected[i.key]; }); }
  function bytesOf(sel) { return sel.reduce(function (x, i) { return x + (i.action === 'kill' ? 0 : (i.sizeBytes || 0)); }, 0); }
  function candsIn(path) {
    var p = lc(path); if (!p) return [];
    return allItems().filter(function (i) { if (!i.path || i.action === 'report' || i.kind === 'process') return false; var q = lc(i.path); return q === p || q.indexOf(p + '\\') === 0; });
  }
  function cleanBytes(n) { return !n || !n.path ? 0 : candsIn(n.path).reduce(function (a, i) { return a + (i.sizeBytes || 0); }, 0); }
  function overlay(n) {
    if (!n || n.ownTile || n.rest || !n.path) return n && n.zone === 'fixed' ? 'fixed' : null;
    var c = candsIn(n.path).filter(function (i) { return i.sizeBytes > 0; });
    if (c.some(function (i) { return S.selected[i.key]; })) return 'sel';
    if (RG.isPathProtected(n.path) && n.path.length > 3) return 'prot';
    if (c.length) return 'cand';
    return n.zone === 'fixed' ? 'fixed' : null;
  }
  // Việc tool SẼ làm với mục. zip: undefined = danh sách; true/false = hộp xác nhận.
  function actionOf(i, zip) {
    if (i.protected) return { k: 'prot', l: 'Được bảo vệ', d: 'Nằm trong vùng bảo vệ của bạn; bỏ bảo vệ trước nếu muốn dọn.', cls: 'keep' };
    if (i.action === 'report') return i.needsAdmin ? { k: 'admin', l: 'Cần quyền admin', d: 'Chỉ xoá được sau khi xác nhận UAC.', cls: 'ask' } : { k: 'report', l: 'Chỉ báo cáo', d: 'Tool không bao giờ xoá mục này.', cls: '' };
    if (i.action === 'kill') return { k: 'kill', l: 'Kết thúc tiến trình', d: 'Tiến trình bị dừng đột ngột; dữ liệu chưa lưu có thể mất.', cls: 'bad' };
    if (i.canArchive && zip === undefined) return { k: 'zipable', l: 'Xoá (có thể nén zip)', d: 'Có thể nén zip cạnh mục trước khi xoá; chọn ở hộp xác nhận.', cls: 'ask' };
    if (i.canArchive && zip) return { k: 'zip', l: 'Nén zip rồi xoá', d: 'Tạo .zip cạnh mục, kiểm tra xong mới xoá bản gốc.', cls: 'ask' };
    return { k: 'del', l: 'Xoá vĩnh viễn', d: 'Không qua Thùng rác, không hoàn tác được.', cls: 'bad' };
  }

  /* ---------- Chính sách (bản nháp) ---------- */
  function drvOf(p, L) { var o = (p.drives && p.drives[L]) || {}; return { trigger: o.diskTrigger || p.diskTrigger, target: o.targetFreeGB != null ? o.targetFreeGB : p.targetFreeGB }; }
  function setDrive(p, L, key, val) { var o = p.drives[L] || {}; if (val == null) delete o[key]; else o[key] = val; if (Object.keys(o).length) p.drives[L] = o; else delete p.drives[L]; }
  function trigGB(level, L) { var t = RG.diskThr(L); return level === 'Caution' ? t.normalAbove : (level === 'Critical' ? t.cautionFrom : 0); }
  function levelFor(v, L) {
    var t = RG.diskThr(L), c = [['off', 0], ['Critical', t.cautionFrom], ['Caution', t.normalAbove]], best = c[0];
    c.forEach(function (x) { if (Math.abs(x[1] - v) < Math.abs(best[1] - v)) best = x; });
    return best[0];
  }
  function lcf(s) { return s.charAt(0).toLowerCase() + s.slice(1); }
  function listVi(a) { return a.length <= 1 ? a.join('') : a.slice(0, -1).join(', ') + ' và ' + a[a.length - 1]; }
  function sentence(p, L) {
    var kinds = (S.kinds || []).filter(function (k) { return k !== 'process'; }), by = function (v) { return kinds.filter(function (k) { return p.categories[k] === v; }).map(function (k) { return lcf(RG.human.kind(k).l); }); };
    var auto = by('auto'), d = drvOf(p, L), t = trigGB(d.trigger, L);
    if (!L) return 'Chưa có ổ nào để áp dụng.';
    if (d.trigger === 'off') return 'Tôi không tự dọn file theo dung lượng ổ ' + esc(L) + ':.';
    return 'Khi ổ ' + esc(L) + ': còn dưới <b>' + RG.fmtGB(t) + '</b>, ' + (auto.length ? 'tôi dọn <b>' + esc(listVi(auto)) + '</b> tới khi trống <b>' + RG.fmtGB(d.target) + '</b>, tối đa <b>' + RG.fmtGB(p.maxGBPerRun) + '</b> mỗi lượt.' : 'tôi không tự dọn nhóm nào.');
  }
  function markDirty() {
    S.dirty = RG.policyDirty();
    var b = $('#dkSave'); if (b) b.classList.toggle('show', !!S.dirty);
    drawSentence(); schedulePreview();
  }
  function schedulePreview() {
    if (D.timer) clearTimeout(D.timer);
    D.pvBusy = true; drawNote();
    D.timer = setTimeout(function () {
      var seq = ++D.seq;
      RG.api('/api/auto/preview', { method: 'POST', body: { policy: S.draft } }).then(function (j) { if (seq !== D.seq) return; D.pv = j; D.pvBusy = false; drawNote(); drawList(); })
        .catch(function (e) { if (seq !== D.seq) return; D.pvBusy = false; D.pv = { error: e.message }; drawNote(); });
    }, 300);
  }
  function polCat(g) { var p = S.draft; return g.ck && p && p.categories && p.categories[g.ck] ? p.categories[g.ck] : null; }

  /* ---------- Dựng nhóm từ kế hoạch ---------- */
  function buildGroups(L) {
    var items = scopeItems(L), used = {}, groups = [], minor = [], a = S.advice;
    function claim(keys) { var m = {}; keys.forEach(function (k) { m[k] = 1; }); return items.filter(function (i) { if (m[i.key] && !used[i.key]) { used[i.key] = 1; return true; } return false; }); }
    ((a && a.steps) || []).filter(function (s) { return s.resource !== 'ram' && s.drive === L; }).forEach(function (s) {
      var its = claim(s.keys || []); if (!its.length) return;
      var g = { id: 'step:' + s.id, kind: 'step', ck: s.kind, title: s.title, items: its, risk: s.riskLevel, regen: s.regen, impact: s.impact, agent: s.agent, reaches: s.reachesGoal };
      if (s.minor) minor.push(g); else groups.push(g);
    });
    var minorItems = minor.reduce(function (x, g) { return x.concat(g.items); }, []);
    /* Nhóm gộp chỉ đáng hiện khi thật sự giải phóng được gì: "1 nhóm nhỏ khác · 0 B" chỉ làm rối danh sách. */
    if (minorItems.some(function (i) { return (i.sizeBytes || 0) > 0; })) groups.push({ id: 'minor', kind: 'minor', title: minor.length === 1 ? minor[0].title : minor.length + ' nhóm nhỏ khác', items: minorItems, impact: 'Các nhóm dưới 50 MB, gộp lại cho gọn.' });
    var rv = {}; (((a && a.review) || {}).keys || []).forEach(function (k) { rv[k] = 1; });
    var review = items.filter(function (i) { return !used[i.key] && rv[i.key] && i.action !== 'report'; }); review.forEach(function (i) { used[i.key] = 1; });
    var rest = items.filter(function (i) { return !used[i.key] && i.action !== 'report' && !i.protected; }); rest.forEach(function (i) { used[i.key] = 1; });
    var rep = items.filter(function (i) { return !used[i.key]; });
    if (review.length) groups.push({ id: 'review', kind: 'review', title: 'Cần bạn xem lại', items: review, risk: 'medium', impact: 'Mục chưa đủ tuổi hoặc cần cân nhắc; máy không tự dọn các mục này.' });
    if (rest.length) groups.push({ id: 'rest', kind: 'rest', title: 'Các mục còn lại', items: rest, impact: 'Mỗi mục có ảnh hưởng riêng; bấm vào mục để xem biên lai.' });
    if (rep.length) groups.push({ id: 'report', kind: 'report', title: 'Được bảo vệ / chỉ báo cáo', items: rep, impact: 'Resource Guard không xoá loại này; chỉ cho bạn biết.' });
    groups.forEach(function (g) { g.bytes = g.items.reduce(function (x, i) { return x + (i.sizeBytes || 0); }, 0); g.items.sort(function (x, y) { return (y.sizeBytes || 0) - (x.sizeBytes || 0); }); });
    G.groups = groups; G.byKey = {}; groups.forEach(function (g) { g.items.forEach(function (i) { G.byKey[i.key] = g; }); });
    return groups;
  }
  function evFor(g) {
    var e = null; ((D.pv && D.pv.evidence) || []).forEach(function (x) { if (x.kind === g.ck) e = x; });
    return e ? e.dryRuns + ' lượt chạy thử: ' + e.items + ' mục, ' + RG.fmtBytes(e.bytes) : '';
  }

  /* ---------- Danh sách "Việc có thể làm" ---------- */
  function itemRow(i, g) {
    var dis = !selectable(i), rec = recFor(i.key), a = actionOf(i);
    var recPill = rec ? ' ' + pill(rec.verdict === 'clean' ? 'auto' : (rec.verdict === 'keep' ? 'keep' : 'ask'), 'Trợ lý AI: ' + ({ clean: 'nên dọn', keep: 'nên giữ', review: 'xem lại' }[rec.verdict] || esc(rec.verdict)), rec.reason + ' (độ tin cậy: ' + rec.confidence + ')') : '';
    return '<div class="dg-r" data-open="' + esc(i.key) + '"><input type="checkbox" data-key="' + esc(i.key) + '"' + (S.selected[i.key] ? ' checked' : '') + (dis ? ' disabled' : '') + ' aria-label="Chọn ' + esc(tgtOf(i)) + '">' +
      '<span class="dg-n mono" title="' + esc((i.why || i.reason || '') ? tgtOf(i) + ' — ' + (i.why || i.reason) : tgtOf(i)) + '">' + esc(shortOf(i)) + '</span>' + (i.young ? ' ' + pill('ask', 'chưa đủ tuổi', 'Chưa đủ tuổi theo chính sách; không bao giờ tự dọn.') : '') + (i.heldBy && i.heldBy.length ? ' ' + pill('ask', 'đang được dùng', 'Đang được mở bởi: ' + i.heldBy.join(', ') + '. Khi dọn, mục này sẽ bị bỏ qua nếu chương trình đó vẫn còn mở file.') : '') + recPill +
      (g.kind === 'report' ? ' ' + pill(a.cls, a.l, a.d) : '') + '<span class="sp"></span><span class="num">' + (i.sizeBytes && i.action !== 'kill' ? RG.fmtBytes(i.sizeBytes) : '–') + '</span><span class="num mut dg-a">' + (i.ageDays ? RG.fmtAge(i.ageDays) : '–') + '</span>' +
      '<button class="icon-btn ' + (i.protected ? 'on' : '') + '" data-prot="' + esc(i.key) + '" aria-pressed="' + !!i.protected + '" aria-label="' + (i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ') + ' ' + esc(tgtOf(i)) + '" title="' + (i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ khỏi dọn') + '">' + RG.icon('shield') + '</button></div>';
  }
  function groupHtml(g) {
    var open = !!D.open[g.id], big = g.items.filter(function (i) { return (i.sizeBytes || 0) > 0 || g.kind === 'report' || g.kind === 'review'; }), tiny = g.items.filter(function (i) { return big.indexOf(i) < 0; });
    var cur = polCat(g), ev = cur === 'auto' ? evFor(g) : '', rows = '';
    if (open) {
      var shown = D.all[g.id] ? big : big.slice(0, MAXROWS); rows = shown.map(function (i) { return itemRow(i, g); }).join('');
      if (big.length > shown.length) rows += '<div class="dg-r"><button class="btn sm" data-more="' + esc(g.id) + '">Hiện đủ ' + big.length + ' mục</button></div>';
      if (tiny.length) rows += '<div class="dg-r"><input type="checkbox" data-tiny="' + esc(g.id) + '" aria-label="Chọn ' + tiny.length + ' mục nhỏ"' + (tiny.every(function (i) { return !selectable(i); }) ? ' disabled' : '') + '><span>' + tiny.length + ' mục nhỏ (0 byte)</span></div>';
    }
    var help = g.impact ? RG.help(g.impact + (g.regen ? ' Cách lấy lại: ' + RG.human.regen(g.regen) + '.' : '')) : '';
    return '<div class="dg" data-gid="' + esc(g.id) + '"><div class="dg-h"><input type="checkbox" data-grp="' + esc(g.id) + '" aria-label="Chọn cả nhóm ' + esc(g.title) + '">' +
      '<button class="dg-t" data-tog="' + esc(g.id) + '" aria-expanded="' + open + '">' + RG.icon('chev', 'chev') + '<b>' + esc(g.title) + '</b></button>' + help + '<span class="sp"></span>' +
      '<b class="num">' + RG.fmtBytes(g.bytes) + '</b>' + (g.risk ? pill(RISKCLS[g.risk] || '', esc(RG.human.risk(g.risk))) : '') + '</div>' +
      '<div class="dg-s small mut"><span>' + g.items.length + ' mục</span>' + (cur ? seg('cat:' + g.ck, cur, SET) : '') + (ev ? '<span>' + esc(ev) + '</span>' : '') + (g.kind === 'review' ? '<button class="btn sm" data-ask-agent="1">' + RG.icon('spark') + ' Hỏi trợ lý AI</button>' : '') + '<button class="dg-more" data-tog="' + esc(g.id) + '" aria-expanded="' + open + '">' + (open ? '▾ Ẩn bớt' : '▸ Xem từng mục') + '</button></div>' +
      (open ? '<div class="dg-b">' + rows + '</div>' : '') + '</div>';
  }
  /* Công tắc tự động hoá nằm ngay đầu "Việc có thể làm" (đúng bản mẫu), kèm câu mô tả chính sách của ổ đang xem. */
  function autoRow() {
    var p = S.draft; if (!p || !p.categories) return '';
    return '<div class="dk-auto"><b>Tự động hoá</b>' + seg('mode', p.mode, [['off', 'Tắt'], ['dry-run', 'Chạy thử'], ['on', 'Bật']]) + RG.help(MODEHELP[p.mode] || '') + '<span id="dkSent" class="dk-sent small mut">' + sentence(p, S.driveSel) + '</span></div>';
  }
  function drawList() {
    var el = $('#dkList'); if (!el) return;
    var L = S.driveSel, c = S.cands, st = scanState(c), h = '<h2>Việc có thể làm<span class="sp"></span><button class="btn sm" id="selSafe"' + (st.stale || !c ? ' disabled' : '') + '>Chọn mục rủi ro thấp</button><button class="btn sm" id="selNone">Bỏ chọn</button></h2>' + autoRow();
    if (st.stale) h += '<div class="alert warn" role="status"><b>Dữ liệu quét đã cũ</b> (quá ' + st.max + ' giờ). Bấm “Quét lại” trước khi chọn hay dọn.</div>';
    if (!c || !c.finishedUtc) { h += '<div id="dkListEmpty"></div>'; el.innerHTML = h; RG.empty($('#dkListEmpty'), { icon: 'inbox', title: 'Chưa có danh sách mục có thể dọn', action: { label: 'Quét ngay', onClick: function () { startScan('focus'); } } }); bindTop(); return; }
    var groups = buildGroups(L);
    if (!groups.length) { h += '<div id="dkListEmpty"></div>'; el.innerHTML = h; RG.empty($('#dkListEmpty'), { icon: 'inbox', title: 'Không có mục nào để dọn ở ổ ' + L + ':' }); bindTop(); return; }
    el.innerHTML = h + groups.map(groupHtml).join(''); bindTop(); syncChecks(true);
  }
  function syncChecks(skipBar) {
    RG.$$('#dkList input[data-key]').forEach(function (cb) { cb.checked = !!S.selected[cb.dataset.key]; });
    G.groups.forEach(function (g) {
      var cb = $('#dkList input[data-grp="' + g.id.replace(/"/g, '') + '"]'); if (!cb) return;
      var sel = g.items.filter(selectable), n = sel.filter(function (i) { return S.selected[i.key]; }).length;
      cb.disabled = !sel.length; cb.checked = sel.length > 0 && n === sel.length; cb.indeterminate = n > 0 && n < sel.length;
      var tn = $('#dkList input[data-tiny="' + g.id.replace(/"/g, '') + '"]');
      if (tn) { var tiny = g.items.filter(function (i) { return !(i.sizeBytes > 0) && g.kind !== 'report' && g.kind !== 'review'; }).filter(selectable); tn.checked = tiny.length > 0 && tiny.every(function (i) { return S.selected[i.key]; }); }
    });
    RG.updateNavBadges();
    if (!skipBar) { drawBar(); drawDn(); if (D.tm) D.tm.redraw(); }
  }
  /* Donut theo "việc có thể làm" (không theo loại nội dung): sẽ dọn / dọn được / cần xem lại / của bạn / hệ thống / trống. */
  function semRows(d, t, free) {
    var L = d.drive, total = d.totalBytes || 0, used = Math.max(0, total - free), pick = 0, clean = 0, review = 0;
    buildGroups(L).forEach(function (g) {
      if (g.kind === 'report') return;
      g.items.forEach(function (i) {
        if (i.kind === 'process' || i.action === 'kill') return;
        var b = i.sizeBytes || 0;
        if (S.selected[i.key]) pick += b; else if (g.kind === 'review') review += b; else clean += b;
      });
    });
    var sys = fixedBytes(t, d), mine = Math.max(0, used - sys - pick - clean - review);
    return [
      { key: 'sel', label: 'Sẽ dọn (đã chọn)', value: pick, color: 'var(--normal)', pattern: 'hatch' },
      { key: 'clean', label: 'Dọn được, chưa chọn', value: clean, color: 'var(--normal)' },
      { key: 'review', label: 'Cần bạn xem lại', value: review, color: 'var(--d-review)' },
      { key: 'mine', label: 'Dự án & tệp của bạn', value: mine, color: 'var(--d-mine)' },
      { key: 'sys', label: 'Hệ thống & chương trình', value: sys, color: 'var(--d-system)' },
      { key: 'free', label: 'Trống', value: free, color: 'var(--free)' }
    ].filter(function (r) { return r.value > 0; });
  }
  function drawDn() {
    var L = S.driveSel, d = S.disk && S.disk.drive === L ? S.disk : null; if (!d || !$('#dkDn')) return;
    var di = RG.driveInfo(L), free = di ? di.freeGB * GB : (d.freeBytes || 0), rows = semRows(d, D.tree[d.drive], free);
    V.donut($('#dkDn'), rows, d.totalBytes || (di && di.totalBytes) || 1, { big: RG.fmtGB(free / GB), small: 'trống' }, 112, 20, { fmt: RG.fmtBytes });
    V.legend($('#dkLg'), rows);
  }
  function setSel(items, on) { items.filter(selectable).forEach(function (i) { if (on) S.selected[i.key] = true; else delete S.selected[i.key]; }); syncChecks(); }

  /* ---------- Liên kết danh sách ↔ bản đồ ---------- */
  function tilesFor(items) {
    var tiles = Array.prototype.map.call(document.querySelectorAll('#tmBox svg.tm .tile'), function (g) { return g.dataset.k; }), out = {};
    items.forEach(function (i) {
      if (!i.path || i.kind === 'process') return; var ip = lc(i.path), best = null;
      tiles.forEach(function (k) { if (/#(rest|own)$/.test(k)) return; var q = lc(k); if ((ip === q || ip.indexOf(q + '\\') === 0) && (!best || q.length > lc(best).length)) best = k; });
      if (best) out[best] = 1;
    });
    return Object.keys(out);
  }
  function hoverItems(items) { if (D.tm) D.tm.highlight(items && items.length ? tilesFor(items) : null); }
  function goGroup(g) {
    D.open[g.id] = true; drawList();
    var n = $('#dkList [data-gid="' + g.id.replace(/"/g, '') + '"]'); if (!n) return;
    n.scrollIntoView({ block: 'nearest', behavior: 'smooth' }); n.classList.add('flash'); setTimeout(function () { n.classList.remove('flash'); }, 1600);
  }

  /* Các đoạn của thanh = đúng các phần của donut (cùng khoá, cùng màu), xếp từ trái: Hệ thống, Của bạn, Cần xem lại, Dọn được, Sẽ dọn. Phần trống là nền thanh. */
  function usedSegs(L, total, free) {
    var d = S.disk && S.disk.drive === L ? S.disk : null;
    if (!d) return [{ key: 'used', label: 'Đã dùng', value: total - free, color: 'var(--disk)' }];
    var by = {}; semRows(d, D.tree[d.drive], free).forEach(function (r) { by[r.key] = r; });
    var segs = ['sys', 'mine', 'review', 'clean', 'sel'].map(function (k) { return by[k]; }).filter(Boolean);
    var sum = segs.reduce(function (a, r) { return a + r.value; }, 0), used = Math.max(0, total - free);
    if (sum < used * 0.98 || !segs.length) return [{ key: 'used', label: 'Đã dùng', value: used, color: 'var(--disk)' }];
    return segs;
  }
  /* ---------- Thanh trước → sau ---------- */
  function barBase(L, gain) {
    var di = RG.driveInfo(L); if (!di) return null;
    var total = di.totalBytes || (di.totalGB ? di.totalGB * GB : 0); if (!total) return null;
    var thr = RG.diskThr(L), free = di.freeGB * GB; gain = Math.max(0, Math.min(gain || 0, total - free));
    var so = { cautionBytes: thr.cautionFrom * GB, normalBytes: thr.normalAbove * GB }, s0 = V.stateOf(so, free), s1 = V.stateOf(so, free + gain);
    var cap = 'Trống <b class="num">' + RG.fmtBytes(free) + '</b>' + (gain > 0 ? ' → <b class="num">' + RG.fmtBytes(free + gain) + '</b>' : '') + ' · <span style="color:' + RG.stateColor(s0) + '">' + RG.human.state(s0) + '</span>' + (gain > 0 && s1 !== s0 ? ' → <span style="color:' + RG.stateColor(s1) + '">' + RG.human.state(s1) + '</span>' : '');
    return { total: total, free: free, gain: gain, thr: thr, so: so, cap: cap, o: {
      total: total, segments: usedSegs(L, total, free), free: free, gain: 0, marksTop: true,
      marks: [],
      band: [
        { from: 0, to: Math.max(0, total - thr.normalAbove * GB), color: RG.stateColor('Normal'), label: 'Ổn: trống từ ' + RG.fmtGB(thr.normalAbove) + ' trở lên' },
        { from: Math.max(0, total - thr.normalAbove * GB), to: Math.max(0, total - thr.cautionFrom * GB), color: RG.stateColor('Caution'), label: 'Cần chú ý: trống dưới ' + RG.fmtGB(thr.normalAbove) },
        { from: Math.max(0, total - thr.cautionFrom * GB), to: total, color: RG.stateColor('Critical'), label: 'Nguy cấp: trống dưới ' + RG.fmtGB(thr.cautionFrom) }],
      leftLabel: 'Đã dùng ' + RG.fmtBytes(total - free), midLabel: gain > 0 ? 'Sẽ giải phóng ' + RG.fmtBytes(gain) : '', rightLabel: 'Trống ' + RG.fmtBytes(free) + (gain > 0 ? ' → ' + RG.fmtBytes(free + gain) : '') + ' / ' + RG.fmtBytes(total),
      aria: 'Ổ ' + L + ' trống ' + RG.fmtBytes(free) + (gain > 0 ? ', sau khi dọn ' + RG.fmtBytes(free + gain) : '') + ', ' + RG.human.state(s0) + (gain > 0 && s1 !== s0 ? ' rồi ' + RG.human.state(s1) : '') } };
  }
  function drawBar() {
    var el = $('#dkBar'), L = S.driveSel; if (!el) return;
    var sel = selFor(L), gain = bytesOf(sel), b = barBase(L, gain);
    if (!b) { if (D.bar) D.bar.destroy(); D.bar = null; el.innerHTML = '<div class="small mut">Chưa có số liệu dung lượng ổ ' + esc(L || '') + '.</div>'; drawAct(sel, gain); return; }
    var p = S.draft;
    if (p && p.categories) {
      var d = drvOf(p, L), tg = trigGB(d.trigger, L);
      var T = b.total, lo = T - b.thr.normalAbove * GB, hiPos = T, curPos = T - tg * GB;
      function lvName(lv) { return lv === 'Caution' ? RG.human.state('Caution') : (lv === 'Critical' ? RG.human.state('Critical') : 'tắt'); }
      function detail(pos) {
        var lv = levelFor((T - pos) / GB, L), g = trigGB(lv, L), auto = ((S.draft && S.draft.categories) ? (S.kinds || []).filter(function (k) { return k !== 'process' && S.draft.categories[k] === 'auto'; }).length : 0);
        if (lv === 'off') return 'Tự dọn: tắt (kéo sang trái để đặt mốc)';
        return 'Tự dọn khi đã dùng quá <b>' + RG.fmtBytes(T - g * GB) + '</b> (trống dưới ' + RG.fmtGB(g) + ' · ' + esc(lvName(lv)) + ') · ' + auto + ' nhóm tự động' + (D.hits != null ? ' · 14 ngày qua chạm ' + D.hits + ' lần' : '');
      }
      b.o.marks = [{ value: curPos, label: d.trigger === 'off' ? 'Tự dọn: tắt (kéo để đặt)' : 'Tự dọn tại mốc này', detail: detail(curPos), detailFn: detail,
        drag: { min: lo, max: hiPos, step: GB, onChange: function (pos, final) {
          var v = (T - pos) / GB, lv = levelFor(v, L), curLv = drvOf(S.draft, L).trigger, startPos = T - tg * GB;
          if (final && lv === curLv && Math.abs(pos - startPos) >= 0.9 * GB) { var order = ['Caution', 'Critical', 'off'], ix = order.indexOf(curLv) + (pos > startPos ? 1 : -1); if (ix >= 0 && ix < order.length) lv = order[ix]; }   // phím/nhích nhẹ: nhảy sang mức kế tiếp
          if (lv !== curLv) { setDrive(S.draft, L, 'diskTrigger', lv === S.draft.diskTrigger ? null : lv); markDirty(); }
          if (final) drawBar();
        } } }];
    }
    b.o.caption = sel.length ? b.cap + ' · đã chọn <b>' + sel.length + ' mục</b>' : '';   // chưa chọn gì: thước đã nói đủ, bỏ dòng lặp để thanh dính thấp hơn
    var hadFocus = document.activeElement && document.activeElement.classList && document.activeElement.classList.contains('rb-knob');
    D.bar = V.resourceBar(el, b.o);
    if (hadFocus) { var kn = $('#dkBar .rb-knob'); if (kn) kn.focus(); }
    drawAct(sel, gain);
  }
  function drawAct(sel, gain) {
    var el = $('#dkAct'); if (!el) return;
    var cj = S.jobs.cleanup, crun = cj && cj.status === 'running', st = scanState(S.cands), hi = sel.filter(function (i) { return i.riskLevel === 'high'; }).length;
    el.innerHTML = '<span class="small" id="dkNote"></span><span class="sp"></span>' + (hi ? '<span class="small" style="color:var(--caution)">' + hi + ' mục rủi ro cao</span>' : '') +
      (crun ? '<span class="spin"></span><span class="small mut">đang dọn… ' + esc(cj.message || '') + '</span>' : '<button class="btn danger" id="doClean"' + (!sel.length || st.stale ? ' disabled' : '') + '>' + RG.icon('trash') + ' Dọn ' + sel.length + ' mục đã chọn (' + RG.fmtBytes(gain) + ')</button>');
    var dc = $('#doClean'); if (dc) dc.onclick = confirmClean;
    drawNote();
  }
  function drawSentence() { var s = $('#dkSent'); if (s && S.draft) s.innerHTML = sentence(S.draft, S.driveSel); }
  function drawNote() {
    var el = $('#dkNote'); if (!el) return; var L = S.driveSel, p = S.draft, pv = D.pv;
    if (!p || !L) { el.textContent = ''; return; }
    if (D.pvBusy && !pv) { el.innerHTML = '<span class="spin"></span> đang tính…'; return; }
    if (pv && pv.error) { el.textContent = 'Không xem trước được: ' + pv.error; return; }
    if (!pv) { el.textContent = ''; return; }
    var tr = ((pv.triggers14d || []).filter(function (x) { return x.drive === L; })[0]) || { count: 0 };
    el.innerHTML = drvOf(p, L).trigger === 'off' ? 'Ổ này đang tắt tự dọn.' : '14 ngày qua ngưỡng này chạm <b>' + tr.count + ' lần</b>' + (tr.lastUtc ? ' (gần nhất ' + esc(RG.timeAgo(tr.lastUtc)) + ')' : '');
  }
  function drawSticky() {
    var el = $('#dkSticky'); if (!el) return; var p = S.draft, L = S.driveSel;
    var top = '';
    if (D.bar) D.bar.destroy(); D.bar = null;
    el.innerHTML = top + '<div id="dkBar"></div><div class="dk-act" id="dkAct"></div>';
    drawSentence(); drawBar();
  }

  /* ---------- Đầu trang: chọn ổ, quét ---------- */
  function startScan(scope) {
    var L = S.driveSel; D.menu = false;
    RG.startJob('/api/candidates/scan', {}).catch(noop);
    RG.startJob('/api/disk/scan', L ? { drive: L, scope: scope } : { scope: scope }, 'Bắt đầu quét ' + (scope === 'full' ? 'đầy đủ' : 'nhanh') + ' ổ ' + (L ? L + ':' : 'đĩa') + '…').then(function () { if (S.jobs.breakdown) S.jobs.breakdown.drive = L; }).catch(noop);
  }
  function drawHead() {
    var el = $('#dkHead'); if (!el) return;
    var L = S.driveSel, dl = RG.driveList(), j = S.jobs.breakdown, run = j && j.status === 'running', cj = S.jobs.candidates, crun = cj && cj.status === 'running', busy = run || crun, c = S.cands, d = S.disk && S.disk.drive === L ? S.disk : null;
    var tabs = dl.map(function (x) {
      var st = x.state || 'Normal', n = selFor(x.drive).length;
      return '<button role="tab" data-drive="' + esc(x.drive) + '" aria-pressed="' + (x.drive === L) + '" title="' + esc(x.label || '') + '">' + esc(x.drive) + ': còn <span class="num">' + RG.fmtGB(x.freeGB) + '</span> <span class="pill ' + (st === 'Critical' ? 'bad' : (st === 'Normal' ? 'auto' : 'ask')) + '">' + esc(RG.human.state(st)) + '</span>' + (n ? ' <span class="pill keep">' + n + ' chọn</span>' : '') + '</button>';
    }).join('');
    var info = '';
    if (run) info = '<span class="spin"></span><div class="progress" style="width:160px"><i style="width:' + (j.pct || 0) + '%"></i></div><span class="small mut num">' + (j.pct || 0) + '% · ' + RG.fmtBytes(j.bytes || 0) + '</span>';
    else if (crun) info = '<span class="spin"></span><span class="small mut">đang quét mục dọn được…</span>';
    else if (c && c.finishedUtc) info = '<span class="small mut">quét ' + esc(RG.timeAgo(c.finishedUtc)) + '</span>';
    if (j && j.status === 'error' && (!j.drive || j.drive === L)) info += '<span class="small" style="color:var(--critical)">Lỗi: ' + esc(j.message) + '</span>';
    el.innerHTML = '<div class="seg dk-tabs" role="tablist" aria-label="Chọn ổ đĩa">' + tabs + '</div><span class="sp"></span>' + info +
      '<span class="dk-mw"><button class="btn primary" id="scanGo"' + (busy ? ' disabled' : '') + '>' + RG.icon('refresh') + ' Quét lại</button><button class="btn primary dk-caret" id="scanMenu" aria-haspopup="true" aria-expanded="' + D.menu + '" aria-label="Chọn kiểu quét"' + (busy ? ' disabled' : '') + '>▾</button>' +
      (D.menu ? '<div class="dk-menu" role="menu"><button role="menuitem" data-scan="focus"><b>Quét nhanh</b><span class="small mut">bỏ qua vùng hệ thống</span></button><button role="menuitem" data-scan="full"><b>Quét đầy đủ</b><span class="small mut">cả vùng hệ thống</span></button></div>' : '') + '</span>';
    RG.$$('#dkHead [data-drive]').forEach(function (b) {
      b.onclick = function () { if (b.dataset.drive === S.driveSel) return; S.driveSel = b.dataset.drive; S.disk = null; D.pick = null; D.pv = null; drawAll(); RG.loadDisk(b.dataset.drive).then(drawAll).catch(noop); schedulePreview(); };
    });
    $('#scanGo').onclick = function () { startScan('focus'); };
    $('#scanMenu').onclick = function (e) { e.stopPropagation(); D.menu = !D.menu; drawHead(); };
    RG.$$('#dkHead [data-scan]').forEach(function (b) { b.onclick = function () { startScan(b.dataset.scan); }; });
  }

  /* ---------- Bản đồ ---------- */
  function loadTree(L) {
    if (!L || D.treeBusy[L] || (D.tree[L] && !D.stale[L])) return;
    D.treeBusy[L] = true;
    RG.api('/api/disk/tree?drive=' + encodeURIComponent(L)).then(function (j) { D.tree[L] = j; delete D.stale[L]; }).catch(function () { D.tree[L] = D.tree[L] || { none: true }; delete D.stale[L]; }).then(function () { D.treeBusy[L] = false; if (RG.cur === 'disk') drawMap(); });
  }
  function catRows(d, extra) {
    var rows = d.categories.map(function (c) { return { key: 'cat:' + c.cat, label: LABEL[c.cat] || c.cat, value: c.bytes, color: V.catColor(c.cat) }; }).filter(function (r) { return r.value > 0; }).sort(function (a, b) { return b.value - a.value; });
    if (extra && extra.unscanned > 0) rows.push({ key: 'unscanned', label: 'Hệ thống & chương trình (chưa quét chi tiết)', value: extra.unscanned, color: 'var(--mut)', pattern: 'hatch' });
    return rows;
  }
  function flatRow(it, catBytes, col) {
    var key = String(it.key), age = RG.daysSince(it.newestUtc), isPath = /^[A-Za-z]:\\/.test(key), prot = isPath && RG.isPathProtected(key), pc = it.bytes / Math.max(1, catBytes) * 100;
    return '<tr class="row"><td><span class="ellipsis mono" title="' + esc(key) + '">' + esc(key) + '</span> ' + pill('', esc(LABEL[it.cat] || it.cat)) + '<div class="minibar"><i style="width:' + RG.n1(Math.min(100, pc)) + '%;background:' + col + '"></i></div></td>' +
      '<td class="r num">' + RG.fmtBytes(it.bytes) + '</td><td class="r num mut">' + RG.fmtPct(pc) + '</td><td class="r num mut" title="Lần ghi gần nhất trong thư mục này">' + (age == null ? '–' : RG.fmtAge(age)) + '</td>' +
      '<td class="r">' + (isPath ? '<button class="icon-btn ' + (prot ? 'on' : '') + '" data-path="' + esc(key) + '" aria-pressed="' + prot + '" aria-label="' + (prot ? 'Bỏ bảo vệ' : 'Bảo vệ') + ' ' + esc(key) + '" title="' + (prot ? 'Đang được bảo vệ' : 'Bảo vệ khỏi tự dọn') + '">' + RG.icon('shield') + '</button>' : '') + '</td></tr>';
  }
  function fixedBytes(t, d) {
    var s = 0; if (t && t.root) (t.root.children || []).forEach(function (c) { if (c.zone === 'fixed') s += c.bytes || 0; });
    return s || (d && d.unscannedBytes) || 0;
  }
  function infoHtml(n) {
    if (!n) return '<span class="small mut">Bấm một ô để xem chi tiết và bảo vệ thư mục.</span>';
    var cs = (n.rest || n.ownTile) ? [] : candsIn(n.path), cb = cs.reduce(function (a, i) { return a + (i.sizeBytes || 0); }, 0), prot = !n.rest && n.path && n.path.length > 3 && RG.isPathProtected(n.path), nsel = cs.filter(function (i) { return S.selected[i.key]; }).length;
    var d = S.disk, used = (d && d.usedBytes) || 1;
    return '<span class="mono ellipsis" style="max-width:46%" title="' + esc(n.path || '') + '">' + esc(n.name || n.path) + '</span><span class="small mut num">' + RG.fmtBytes(n.bytes) + ' · ' + RG.fmtPct(n.bytes / used * 100) + (n.newestUtc ? ' · ghi ' + esc(RG.timeAgo(n.newestUtc)) : '') + '</span><span class="sp"></span>' +
      (cs.length ? '<button class="btn sm" data-pickall>' + (nsel === cs.length ? 'Bỏ chọn' : 'Chọn') + ' ' + cs.length + ' mục (' + RG.fmtBytes(cb) + ')</button>' : '') +
      (!n.rest && !n.ownTile && n.path && n.path.length > 3 && n.zone !== 'fixed' ? '<button class="btn sm" data-pickprot>' + (prot ? 'Bỏ bảo vệ' : 'Bảo vệ thư mục') + '</button>' : '');
  }
  function pickNode(n) {
    D.pick = n; drawInfo();
    var cs = (n.rest || n.ownTile) ? [] : candsIn(n.path).filter(function (i) { return G.byKey[i.key]; });
    if (cs.length) { cs.sort(function (a, b) { return (b.sizeBytes || 0) - (a.sizeBytes || 0); }); goGroup(G.byKey[cs[0].key]); }
  }
  function drawInfo() {
    var el = $('#tmInfo'); if (!el) return; var n = D.pick; el.innerHTML = infoHtml(n);
    var pa = $('[data-pickall]', el), pp = $('[data-pickprot]', el);
    if (pa) pa.onclick = function () { var cs = candsIn(n.path), off = cs.filter(selectable).every(function (i) { return S.selected[i.key]; }); setSel(cs, !off); drawInfo(); };
    if (pp) pp.onclick = function () { var on = !RG.isPathProtected(n.path); RG.toggleProtect('path', n.path, on).then(function () { return RG.loadCands(); }).then(function () { return RG.loadAdvice().catch(noop); }).then(drawAll); };
  }
  /* Gốc treemap phản chiếu donut: mọi vùng cố định gộp một ô "Hệ thống & chương trình", thêm ô "Trống" (diện tích đúng bằng dung lượng trống). */
  function mapRoot(t, d, free) {
    var root = t.root, kids = [], fixed = 0, orig = 0;
    (root.children || []).forEach(function (c) { orig += c.bytes || 0; if (c.zone === 'fixed') fixed += c.bytes || 0; else kids.push(c); });
    if (!fixed) fixed = (d && d.unscannedBytes) || 0;
    var own = Math.max(0, (root.bytes || 0) - orig), out = {}, k;
    for (k in root) out[k] = root[k];
    if (fixed > 0) kids.push({ name: 'Hệ thống & chương trình', path: '', key: '#sys', bytes: fixed, zone: 'fixed', sys: true, children: [] });
    if (free > 0) kids.push({ name: 'Trống', path: '', key: '#free', bytes: free, freeTile: true, children: [] });
    out.children = kids; out.bytes = kids.reduce(function (a, c) { return a + (c.bytes || 0); }, 0) + own;
    return out;
  }
  /* Các dải màu bên trong một ô, cùng bảng màu và cùng cách tính với semRows (donut): Sẽ dọn / Dọn được / Cần xem lại; phần còn lại là "của bạn". */
  function partsOf(n) {
    if (!n || n.ownTile || n.rest || !n.path) return null;
    var sel = 0, clean = 0, review = 0;
    candsIn(n.path).forEach(function (i) {
      if (i.kind === 'process' || i.action === 'kill' || !(i.sizeBytes > 0)) return;
      var g = G.byKey[i.key]; if (g && g.kind === 'report') return;
      if (S.selected[i.key]) sel += i.sizeBytes; else if (g && g.kind === 'review') review += i.sizeBytes; else clean += i.sizeBytes;
    });
    return [{ color: 'var(--d-review)', bytes: review }, { color: 'var(--normal)', bytes: clean }, { color: 'var(--normal)', bytes: sel, pattern: 'hatch' }];
  }
  function drawMap() {
    var el = $('#dkMap'); if (!el) return;
    var L = S.driveSel, d = S.disk && S.disk.drive === L ? S.disk : null, j = S.jobs.breakdown, mine = j && j.status === 'running' && (!j.drive || j.drive === L), di = RG.driveInfo(L);
    var head = '<h2>Bản đồ ổ ' + esc(L || '') + ':<span class="sp"></span>' + seg('view', D.view, [['map', 'Bản đồ'], ['flat', 'Danh sách lớn nhất']]) + '</h2>';
    D.tm = null;
    if (mine && d) head += '<div class="small mut" role="status">Đang quét lại ổ ' + esc(L) + ':. Hình dưới là kết quả lần quét trước, sẽ tự cập nhật khi quét xong.</div>';
    if (mine && j.cats && j.cats.length && !d) {   // chưa có kết quả cũ mới dựng theo số liệu quét dần; có rồi thì giữ nguyên bản đồ cũ
      var total = di ? (di.totalBytes || (di.totalGB ? di.totalGB * GB : 0)) : Math.max(1, j.bytes), rows = catRows({ categories: j.cats });
      el.innerHTML = head + '<div class="dk-dn"><div id="dkDn"></div><div id="dkLg"></div></div><div class="small mut">Đang quét… số liệu hiện dần.</div>';
      V.donut($('#dkDn'), rows, total, { big: RG.fmtBytes(j.bytes || 0), small: 'đã quét' }, 112, 20); V.legend($('#dkLg'), rows.slice(0, 7)); bindMap(); return;
    }
    if (!d) { el.innerHTML = head + '<div id="dkMapIn"></div>'; RG.empty($('#dkMapIn'), { icon: 'disk', title: 'Chưa có dữ liệu phân tích ổ ' + (L || 'đĩa') + ':', action: { label: 'Quét nhanh', onClick: function () { startScan('focus'); } } }); bindMap(); return; }
    var t = D.tree[d.drive]; if (t && D.stale[d.drive]) loadTree(d.drive);
    if (D.view === 'flat') {
      var all = [], col = {}; d.categories.forEach(function (c) { col[c.cat] = V.catColor(c.cat); c.items.forEach(function (it) { all.push({ key: it.key, bytes: it.bytes, newestUtc: it.newestUtc, cat: c.cat }); }); });
      all.sort(function (a, b) { return b.bytes - a.bytes; });
      el.innerHTML = head + '<div class="dk-dn"><div id="dkDn"></div><div id="dkLg"></div></div><div class="tbl-wrap" style="max-height:420px"><table><thead><tr><th>Thư mục</th><th class="r">Dung lượng</th><th class="r">Tỷ lệ</th><th class="r">Không ghi</th><th class="r">Bảo vệ</th></tr></thead><tbody>' + all.slice(0, 80).map(function (it) { return flatRow(it, d.usedBytes, col[it.cat]); }).join('') + '</tbody></table></div>';
      RG.$$('#dkMap [data-path]').forEach(function (b) { b.onclick = function () { RG.toggleProtect('path', b.dataset.path, b.getAttribute('aria-pressed') !== 'true'); }; });
      drawDn(); bindMap(); return;
    }
    el.innerHTML = head + '<div class="dk-dn"><div id="dkDn"></div><div id="dkLg"></div></div><div id="tmBox"></div><div class="dk-info" id="tmInfo"></div><div id="fixStrip"></div>';
    drawDn();
    var box = $('#tmBox');
    if (!t) { RG.empty(box, { compact: true, title: 'Đang tải cây thư mục…' }); loadTree(d.drive); }
    else if (t.none || !t.root) RG.empty(box, { compact: true, title: 'Chưa có cây thư mục cho ổ này; bấm “Quét lại”.' });
    else {
      var dfree = di ? di.freeGB * GB : (d.freeBytes || 0); buildGroups(L);
      D.tm = V.treemap(box, mapRoot(t, d, dfree), { overlay: overlay, parts: partsOf, baseFill: 'var(--d-mine)', depth: 2, onPick: pickNode, maxTiles: 60, height: 340 });
    }
    drawInfo(); bindMap();
  }
  function bindMap() { RG.$$('#dkMap [data-set="view"]').forEach(function (b) { b.onclick = function () { D.view = b.dataset.val; drawMap(); }; }); }

  /* ---------- Phần phụ: admin, kết quả, bản nén, agent đang giữ, chạy thử ---------- */
  function adminItems() { return allItems().filter(function (i) { return i.needsAdmin && !i.protected; }); }
  function adminBox() {
    var adm = adminItems(); if (!adm.length) return '';
    var total = adm.reduce(function (a, i) { return a + (i.sizeBytes || 0); }, 0), crun = S.jobs.cleanup && S.jobs.cleanup.status === 'running';
    return '<div class="card mt"><h2>Cần quyền admin<span class="ro">' + adm.length + ' thư mục tạm' + (total ? ' · ' + RG.fmtBytes(total) : '') + '</span>' + RG.help('Các thư mục tạm cũ do hệ thống (SYSTEM) tạo nên tài khoản thường không xoá được. Windows sẽ hỏi UAC; tool không tự nâng quyền.') + '<span class="sp"></span>' +
      (crun ? '<span class="spin"></span>' : '<button class="btn" id="doElevate">' + RG.icon('shield') + ' Dọn bằng quyền admin…</button>') + '</h2></div>';
  }
  function confirmElevate() {
    var adm = adminItems(); if (!adm.length) return;
    var list = adm.slice(0, 12).map(function (i) { return '<li><span class="mono">' + esc(i.path) + '</span> — ' + RG.fmtBytes(i.sizeBytes) + '</li>'; }).join('') + (adm.length > 12 ? '<li class="mut">… và ' + (adm.length - 12) + ' mục khác</li>' : '');
    RG.confirm('Dọn ' + adm.length + ' thư mục bằng quyền admin?', '<p>Tiếp theo Windows sẽ hiện hộp thoại <b>UAC</b>. Chỉ khi bạn chọn “Có”, một tiến trình admin riêng mới xoá các thư mục dưới đây rồi thoát. <b>Không thể hoàn tác</b>.</p><ul class="small" style="max-height:200px;overflow:auto;padding-left:18px">' + list + '</ul><p class="hint">Tiến trình admin tự kiểm lại từng mục: chỉ thư mục tên GUID nằm trực tiếp trong thư mục Temp, đủ 14 ngày không đổi, không phải junction, không nằm trong vùng bảo vệ. Chọn “Không” ở UAC thì không có gì bị xoá.</p>', 'Tiếp tục tới UAC', true).then(function (ok) {
      if (!ok) return;
      RG.startJob('/api/cleanup/elevate', { keys: adm.map(function (i) { return i.key; }) }, 'Chờ bạn xác nhận UAC…').then(drawExtra).catch(noop);
    });
  }
  function drawArchives() {
    var a = (S.archives || []); if (!a.length) return '';
    var rows = a.map(function (r) {
      var st = r.restoredUtc ? pill('auto', 'đã khôi phục') : (!r.zipExists ? pill('bad', 'zip đã mất') : (r.originalExists ? pill('', 'vị trí cũ đã có dữ liệu') : '')), can = r.zipExists && !r.originalExists && !r.restoredUtc;
      return '<tr><td><span class="ellipsis mono" title="' + esc(r.original) + '">' + esc(r.original) + '</span><div class="small mut">' + esc(r.zip) + '</div></td><td class="r num">' + RG.fmtBytes(r.bytes) + ' → ' + RG.fmtBytes(r.zipBytes) + '</td><td class="small mut">' + esc(RG.timeAgo(r.createdUtc)) + '</td><td>' + st + '</td><td class="r">' + (can ? '<button class="btn" data-restore="' + esc(r.id) + '">Giải nén về chỗ cũ</button>' : '') + '</td></tr>';
    }).join('');
    return '<details class="card mt"><summary class="h-sum">Bản nén đã tạo <span class="ro">' + a.length + '</span>' + RG.help('Zip nằm cạnh vị trí gốc. Giải nén không ghi đè: chỉ chạy khi vị trí cũ trống.') + '</summary><div class="tbl-wrap"><table><tbody>' + rows + '</tbody></table></div></details>';
  }
  function confirmRestore(id) {
    var r = (S.archives || []).filter(function (x) { return x.id === id; })[0]; if (!r) return;
    RG.confirm('Giải nén về chỗ cũ?', '<p>Khôi phục <span class="mono">' + esc(r.original) + '</span> (' + RG.fmtBytes(r.bytes) + ') từ <span class="mono">' + esc(r.zip) + '</span>. File zip được giữ lại.</p>', 'Giải nén', false).then(function (ok) {
      if (!ok) return; RG.startJob('/api/archive/restore', { id: id }, 'Đang giải nén…').then(drawExtra).catch(noop);
    });
  }
  function drawAgentKept() {
    var ks = allItems().filter(function (i) { return i.protectedBy === 'agent' && inScope(i, S.driveSel); }); if (!ks.length) return '';
    var rows = ks.map(function (i) {
      var until = i.keepUntilUtc ? new Date(i.keepUntilUtc).toLocaleDateString('vi-VN') : '–';
      return '<tr class="row"><td><span class="ellipsis mono" title="' + esc(i.path) + '">' + esc(i.path) + '</span><div class="small mut">' + esc(i.keepReason || '') + '</div></td><td class="r num">' + (i.sizeBytes ? RG.fmtBytes(i.sizeBytes) : '–') + '</td><td class="r num mut">' + until + '</td><td class="r"><button class="btn sm" data-unkeep="' + esc(i.key) + '">Bỏ giữ</button></td></tr>';
    }).join('');
    return '<details class="card mt"><summary class="h-sum">Agent đang giữ <span class="ro">' + ks.length + ' mục</span>' + RG.help('Trợ lý AI đánh giá các mục này nên giữ nên chúng không hiện trong danh sách dọn và không bao giờ bị tự dọn; tự hết hạn sau 30 ngày. “Bỏ giữ” đưa về danh sách dọn ngay.') + '</summary><div class="tbl-wrap"><table class="cand"><tbody>' + rows + '</tbody></table></div></details>';
  }
  /* Câu kết quả do engine ghi bằng tiếng Anh -> tiếng Việt để màn hình không lẫn ngôn ngữ. */
  function detailVi(d) {
    d = String(d || ''); var m, mb = function (x) { return String(x).replace('.', ','); };
    if ((m = /^deleted (\d+) files? \(([\d.,]+) MB\) with admin rights$/.exec(d))) return 'Đã xoá ' + m[1] + ' tệp (' + mb(m[2]) + ' MB) bằng quyền admin';
    if ((m = /^deleted (\d+) files? \(([\d.,]+) MB\), (\d+) failed\/locked$/.exec(d))) return 'Đã xoá ' + m[1] + ' tệp (' + mb(m[2]) + ' MB), ' + m[3] + ' tệp đang bị khoá hoặc lỗi';
    if ((m = /^deleted (\d+) files? \(([\d.,]+) MB\), (\d+) entries could not be deleted$/.exec(d))) return 'Đã xoá ' + m[1] + ' tệp (' + mb(m[2]) + ' MB), ' + m[3] + ' mục không xoá được';
    if ((m = /^deleted (\d+) files?, (\d+) entries could not be deleted:? ?(.*)$/.exec(d))) return 'Đã xoá ' + m[1] + ' tệp, ' + m[2] + ' mục không xoá được' + (m[3] ? ': ' + m[3] : '');
    return d;
  }
  function drawCleanResult() {
    var l = S.cleanupLast; if (!l) return '';
    var rows = (l.results || []).map(function (r) { return '<tr><td>' + esc(RG.human.kind(r.kind).l) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td>' + pill(r.outcome === 'done' ? 'auto' : (r.outcome === 'failed' ? 'bad' : 'ask'), OUT[r.outcome] || esc(r.outcome)) + '</td><td class="small mut">' + esc(detailVi(r.detail)) + '</td></tr>'; }).join('');
    (l.refused || []).forEach(function (r) { var it = itemByKey(r.key); rows += '<tr><td colspan="2"><span class="mono small" style="word-break:break-all">' + esc(it ? tgtOf(it) : r.key) + '</span></td><td>' + pill('bad', 'Từ chối') + '</td><td class="small mut">' + esc(r.reason) + '</td></tr>'; });
    var ex = S.cleanExpected, cmp = ex && ex.bytes != null ? '<div class="cl-cmp">Dự kiến <b>' + RG.fmtBytes(ex.bytes) + '</b> · thực tế <b>' + RG.fmtBytes(l.freedBytes) + '</b>' + (l.freedBytes < ex.bytes * 0.95 ? RG.help('Phần chênh do mục bị bỏ qua, thất bại hoặc nén zip.') : '') + '</div>' : '';
    var failed = (l.results || []).filter(function (r) { return r.outcome === 'failed'; }).length + (l.refused || []).length;
    return '<details class="card mt" open><summary class="h-sum">Kết quả lượt dọn gần nhất<span class="ro">' + esc(RG.timeAgo(l.finishedUtc)) + ' · giải phóng ' + RG.fmtBytes(l.freedBytes) + (failed ? ' · ' + failed + ' mục không dọn được' : '') + '</span></summary>' + cmp + '<div class="tbl-wrap"><table><tbody>' + rows + '</tbody></table></div></details>';
  }
  function drawAutoLast() {
    var l = S.autoLast, j = S.jobs.auto, run = j && j.status === 'running';
    var h = '<div class="field" style="margin-top:0"><button class="btn" id="dryRun"' + (run ? ' disabled' : '') + '>' + RG.icon('play') + ' Chạy thử ngay</button>' + (run ? '<span class="spin"></span><span class="small mut">đang mô phỏng…</span>' : '<span class="small mut">Không xoá gì.</span>') +
      '<span class="sp"></span><span class="small mut">Điền nhanh:</span>' + Object.keys(PRESETS).map(function (k) { return '<button class="btn sm" data-preset="' + k + '">' + PRESETS[k].label + '</button>'; }).join('') + RG.help('Mức sẵn chỉ điền bản nháp; bạn vẫn phải Lưu.') + '</div>';
    if (!l) return h + '<div class="small mut">Chưa có lượt tự dọn hay chạy thử nào.</div>';
    var rows = (l.items || []).map(function (r) { return '<tr><td>' + esc(RG.human.kind(r.kind).l) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td class="r num">' + (r.sizeBytes ? RG.fmtBytes(r.sizeBytes) : '') + '</td><td>' + pill(r.outcome === 'done' ? 'auto' : (r.outcome === 'failed' ? 'bad' : 'ask'), OUT[r.outcome] || esc(r.outcome)) + '</td><td class="small mut">' + esc(r.detail || '') + '</td></tr>'; }).join('');
    var sk = (l.skipped || []).map(function (r) { return '<tr><td>' + esc(RG.human.kind(r.kind).l) + '</td><td><span class="ellipsis mono" title="' + esc(r.target) + '">' + esc(r.target) + '</span></td><td class="small mut">' + esc(r.reason) + '</td></tr>'; }).join('');
    return h + '<div class="small mut">Lượt ' + esc(RG.timeAgo(l.finishedUtc)) + ' · chế độ <b>' + esc(RG.human.modes[l.mode] || l.mode) + '</b> · ' + l.candidateCount + ' mục có thể dọn · giải phóng ' + RG.fmtBytes(l.freedBytes) + '</div>' +
      (rows ? '<div class="tbl-wrap" style="margin-top:8px"><table><tbody>' + rows + '</tbody></table></div>' : '<p class="small mut">Không có mục nào được chọn.</p>') +
      (sk ? '<details style="margin-top:8px"><summary class="small" style="cursor:pointer">Mục bị bỏ qua (' + (l.skipped || []).length + ')</summary><div class="tbl-wrap" style="margin-top:6px"><table><tbody>' + sk + '</tbody></table></div></details>' : '');
  }
  function drawHist() {
    var svg = $('#dkChart'); if (!svg) return;
    var L = S.driveSel, p = S.draft, t = RG.diskThr(L);
    if (!D.hist[L] || Date.now() - D.histAt > 600000) {
      D.histAt = Date.now();
      RG.api('/api/drive/history?drive=' + encodeURIComponent(L) + '&days=14').then(function (j) { D.hist[L] = j.points || []; drawHist(); }).catch(function () { D.hist[L] = D.hist[L] || []; });
    }
    var data = D.hist[L] || [], fn;
    if (data.length < 2) { fn = function (h) { var x = (h.drives || []).filter(function (y) { return y.drive === L; })[0]; return x ? x.freeGB : null; }; data = S.hist || []; }
    var tg = p && p.categories ? trigGB(drvOf(p, L).trigger, L) : 0, lines = [{ v: t.normalAbove, c: RG.css('--normal') }]; if (tg) lines.push({ v: tg, c: RG.css('--critical') });
    RG.lineChart(svg, data, { key: 'freeGB', fn: fn, color: RG.css('--disk'), min: 0, area: true, unit: ' GB', xfmt: RG.fmtLocal, lines: lines, fit: true });
  }
  function drawExtra() {
    var el = $('#dkExtra'); if (!el) return;
    el.innerHTML = adminBox() + drawCleanResult() + drawArchives() + drawAgentKept() +
      '<details class="card mt" id="dkAuto"' + (D.adv ? ' open' : '') + '><summary class="h-sum">Chạy thử, mức sẵn và lượt tự dọn gần nhất</summary><div id="dkAutoIn">' + drawAutoLast() + '</div></details>' +
      '<details class="card mt" id="dkHistD"><summary class="h-sum">Lịch sử dung lượng trống ổ ' + esc(S.driveSel || '') + ' (14 ngày)</summary><div><svg id="dkChart" class="chart tall" role="img" aria-label="Dung lượng trống 14 ngày"></svg></div></details>';
    $('#dkAuto').ontoggle = function () { D.adv = $('#dkAuto').open; };
    $('#dkHistD').ontoggle = function () { if ($('#dkHistD').open) drawHist(); };
    var de = $('#doElevate'); if (de) de.onclick = confirmElevate;
    var dr = $('#dryRun'); if (dr) dr.onclick = function () { RG.startJob('/api/auto/run', {}, 'Đang chạy thử…').then(drawExtra).catch(noop); };
    RG.$$('#dkExtra [data-restore]').forEach(function (b) { b.onclick = function () { confirmRestore(b.dataset.restore); }; });
    RG.$$('#dkExtra [data-unkeep]').forEach(function (b) {
      b.onclick = function () { b.disabled = true; RG.api('/api/agent/keep/release', { method: 'POST', body: { key: b.dataset.unkeep } }).then(function () { RG.toast('Đã bỏ giữ. Mục quay lại danh sách dọn.', 'ok'); return RG.loadCands(); }).then(drawAll).catch(function (e) { RG.toast(e.message, 'err'); b.disabled = false; }); };
    });
    RG.$$('#dkExtra [data-preset]').forEach(function (b) {
      b.onclick = function () {
        var p = S.draft, ps = PRESETS[b.dataset.preset]; if (!p) return;
        p.diskTrigger = ps.diskTrigger; p.maxGBPerRun = ps.maxGBPerRun; p.cooldownMin = ps.cooldownMin;
        (S.kinds || []).forEach(function (k) { p.categories[k] = ps.auto.indexOf(k) >= 0 ? 'auto' : (p.categories[k] === 'keep' ? 'keep' : 'ask'); });
        p.drives = {}; markDirty(); drawSticky(); drawList(); RG.toast('Đã điền mức “' + ps.label + '” vào bản nháp. Bấm Lưu để áp dụng.', 'ok');
      };
    });
    if ($('#dkHistD').open) drawHist();
  }

  /* ---------- Ngăn kéo một mục ---------- */
  function openItem(i) {
    var rec = recFor(i.key), g = G.byKey[i.key];
    var src = '<div class="small mut" style="margin-top:10px">Nguồn lời khuyên: <b>' + (rec ? 'Trợ lý AI' : 'Quy tắc') + '</b>' + (rec ? ' — ' + esc(rec.reason) + ' (độ tin cậy ' + esc(rec.confidence) + ')' : '') + '</div>' +
      (g && g.kind === 'step' ? '<div class="small mut">Thuộc nhóm: ' + esc(g.title) + '</div>' : '') + '<div class="small mut">' + esc(i.reason || '') + '</div>';
    var d = RG.drawer({ title: RG.human.kind(i.kind).l, html: RG.receipt(i) + src, actions: [] });
    function setActs() {
      var can = selectable(i), on = !!S.selected[i.key];
      d.setActions([
        { label: on ? 'Bỏ chọn' : 'Chọn để dọn', cls: on ? '' : 'primary', disabled: !can, onClick: function () { if (S.selected[i.key]) delete S.selected[i.key]; else S.selected[i.key] = true; syncChecks(); return false; } },
        { label: i.protected ? 'Bỏ bảo vệ' : 'Bảo vệ khỏi dọn', onClick: function () { (i.kind === 'process' ? RG.toggleProtect('process', i.name, !i.protected) : RG.toggleProtect('path', i.path, !i.protected)).then(function () { return RG.loadCands(); }).then(drawAll); } },
        { label: 'Đóng' }]);
    }
    setActs();
    var obs = setInterval(function () { if (!document.body.contains(d.el)) { clearInterval(obs); return; } var b = d.el.querySelector('.dr-acts .btn'); if (b) { var on = !!S.selected[i.key]; if ((b.textContent === 'Bỏ chọn') !== on) setActs(); } }, 250);
  }

  /* ---------- Hộp xác nhận ---------- */
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
    var L = S.driveSel, sel = selFor(L); if (!sel.length) return;
    if (scanState(S.cands).stale) { RG.toast('Dữ liệu quét đã cũ; hãy quét lại trước khi dọn.', 'err'); return; }
    var zipN = sel.filter(function (i) { return i.canArchive; }).length, zip = true, nKill = sel.filter(function (i) { return i.action === 'kill'; }).length, bytes = bytesOf(sel);
    var zipBox = zipN ? '<label class="small" style="display:block;margin:8px 0"><input type="checkbox" id="optZip" checked> <b>Nén zip cạnh mục trước khi xoá</b> (' + zipN + ' mục). Tạo <span class="mono">&lt;tên&gt;.zip</span> trong cùng thư mục, kiểm tra xong mới xoá bản gốc; khôi phục bằng nút Giải nén ở “Bản nén đã tạo”. Bỏ chọn thì các mục đó xoá vĩnh viễn.</label>' : '';
    var html = '<div class="cf-bars"><div class="h-drive"><div id="cfBar"></div></div></div><div id="cfPlan">' + planHtml(sel, true) + '</div>' + zipBox +
      (nKill ? '<p class="small"><b>Lưu ý:</b> ' + nKill + ' tiến trình sẽ bị kết thúc. Chỉ tiếp tục nếu các tiến trình đó không còn cần thiết.</p>' : '') +
      '<p class="hint">Mục “Xoá vĩnh viễn” không qua Thùng rác và không hoàn tác được. Trước khi làm, engine kiểm lại từng mục (allowlist, tuổi file, junction, trạng thái git…). Mục không đạt sẽ bị bỏ qua và báo lý do ở “Kết quả lượt dọn gần nhất”.</p>';
    var label = (nKill ? 'Dọn ' + sel.length + ' mục' : 'Xoá vĩnh viễn ' + sel.length + ' mục') + ' (' + RG.fmtBytes(bytes) + ')';
    var m = RG.modal({ title: 'Xác nhận dọn ' + sel.length + ' mục?', html: html, onClose: function (v) {
        if (v !== true) return;
        S.cleanExpected = { bytes: bytes, n: sel.length, at: Date.now() };
        RG.startJob('/api/cleanup/apply', { keys: sel.map(function (i) { return i.key; }), archive: zip }, zip && zipN ? 'Đang nén zip và dọn…' : 'Đang dọn…').then(function () { drawBar(); }).catch(noop);
      }, actions: [{ label: 'Huỷ', value: false }, { label: label, cls: 'danger', value: true }] });
    m.el.classList.add('wide');
    var b = barBase(L, bytes); if (b) { b.o.caption = b.cap + ' · ' + sel.length + ' mục'; V.resourceBar(RG.$('#cfBar', m.el), b.o); }
    var c = RG.$('#optZip', m.el); if (c) c.onchange = function () { zip = c.checked; RG.$('#cfPlan', m.el).innerHTML = planHtml(sel, zip); };
  }

  /* ---------- Gắn sự kiện danh sách ---------- */
  function bindTop() {
    var ss = $('#selSafe'); if (ss) ss.onclick = function () { scopeItems(S.driveSel).forEach(function (i) { if (i.action === 'delete' && !i.protected && i.riskLevel === 'low' && !i.young && selectable(i)) S.selected[i.key] = true; }); syncChecks(); };
    var sn = $('#selNone'); if (sn) sn.onclick = function () { scopeItems(S.driveSel).forEach(function (i) { delete S.selected[i.key]; }); syncChecks(); };
  }
  function bindList(el) {
    function groupOf(id) { return G.groups.filter(function (x) { return x.id === id; })[0]; }
    el.addEventListener('click', function (e) {
      var t = e.target, b;
      if (t.closest('[data-ask-agent]')) { RG.askAgent(); return; }
      if ((b = t.closest('[data-tog]'))) { var id = b.dataset.tog; D.open[id] = !D.open[id]; drawList(); return; }
      if ((b = t.closest('[data-more]'))) { D.all[b.dataset.more] = true; D.open[b.dataset.more] = true; drawList(); return; }
      if ((b = t.closest('[data-set="mode"]')) && S.draft) { S.draft.mode = b.dataset.val; markDirty(); drawList(); return; }
      if ((b = t.closest('[data-set]'))) { var n = b.dataset.set; if (n.indexOf('cat:') === 0 && S.draft) { S.draft.categories[n.slice(4)] = b.dataset.val; markDirty(); drawList(); } return; }
      if ((b = t.closest('[data-prot]'))) {
        e.stopPropagation(); var it = itemByKey(b.dataset.prot); if (!it) return; var on = b.getAttribute('aria-pressed') !== 'true';
        (it.kind === 'process' ? RG.toggleProtect('process', it.name, on) : RG.toggleProtect('path', it.path, on)).then(function () { return RG.loadCands(); }).then(function () { return RG.loadAdvice().catch(noop); }).then(drawAll); return;
      }
      if (t.closest('input')) return;
      if ((b = t.closest('[data-open]'))) { var i2 = itemByKey(b.dataset.open); if (i2) openItem(i2); }
    });
    el.addEventListener('change', function (e) {
      var cb = e.target; if (!cb || cb.type !== 'checkbox') return;
      if (cb.dataset.key) { if (cb.checked) S.selected[cb.dataset.key] = true; else delete S.selected[cb.dataset.key]; syncChecks(); return; }
      var g = groupOf(cb.dataset.grp || cb.dataset.tiny); if (!g) return;
      if (cb.dataset.tiny) setSel(g.items.filter(function (i) { return !(i.sizeBytes > 0) && g.kind !== 'report' && g.kind !== 'review'; }), cb.checked); else setSel(g.items, cb.checked);
    });
    el.addEventListener('mouseover', function (e) {
      var n = e.target.closest ? e.target.closest('[data-open],[data-gid]') : null, key = n ? (n.dataset.open || ('g:' + n.dataset.gid)) : null;
      if (key === D.hov) return; D.hov = key;
      if (!n) return hoverItems(null);
      if (n.dataset.open) { var it = itemByKey(n.dataset.open); hoverItems(it ? [it] : null); } else { var g = groupOf(n.dataset.gid); hoverItems(g ? g.items : null); }
    });
    el.addEventListener('mouseleave', function () { D.hov = null; hoverItems(null); });
  }
  function bindSticky(el) {
    el.addEventListener('click', function (e) {
      var b = e.target.closest('[data-set="mode"]'); if (!b || !S.draft) return;
      S.draft.mode = b.dataset.val; markDirty(); drawSticky();
    });
  }

  /* ---------- Trang ---------- */
  function drawAll() {
    if (!$('#dkBody')) return;
    var dl = RG.driveList(); if (!S.driveSel || !dl.some(function (x) { return x.drive === S.driveSel; })) S.driveSel = dl[0] ? dl[0].drive : S.driveSel;
    if (S.draft && (!S.draft.drives || Array.isArray(S.draft.drives))) S.draft.drives = {};
    drawHead(); drawSticky(); drawMap(); drawList(); drawExtra();
  }
  function savePolicy() {
    var btn = $('#dkSaveBtn'); btn.disabled = true;
    RG.savePolicy(S.draft).then(function (j) { S.draft = RG.clone(j.policy); S.dirty = false; RG.toast('Đã lưu chính sách.', 'ok'); D.pv = null; $('#dkSave').classList.remove('show'); btn.disabled = false; drawAll(); schedulePreview(); })
      .catch(function (e) { RG.toast(e.message, 'err'); btn.disabled = false; });
  }
  RG.pages.disk = {
    title: 'Ổ đĩa',
    render: function (el) {
      el.innerHTML = '<div id="dkBody"><div class="dk-head" id="dkHead"></div><div class="card ws-sticky" id="dkSticky"></div><div class="ws"><div class="card" id="dkMap"></div><div class="card" id="dkList" aria-live="polite"></div></div><div id="dkExtra"></div>' +
        '<div class="savebar' + (S.dirty ? ' show' : '') + '" id="dkSave" role="region" aria-label="Chính sách đã đổi"><b>Chính sách đã đổi</b><span class="small mut">chưa áp dụng cho tới khi Lưu</span><span class="sp"></span><button class="btn" id="dkReset">Huỷ</button><button class="btn primary" id="dkSaveBtn">Lưu</button></div></div>';
      if (!D.docBound) { D.docBound = true; document.addEventListener('click', function () { if (RG.cur === 'disk' && D.menu) { D.menu = false; drawHead(); } }); }
      bindList($('#dkList')); bindSticky($('#dkSticky'));
      $('#dkReset').onclick = function () { S.draft = RG.clone(S.policy); S.dirty = false; D.pv = null; $('#dkSave').classList.remove('show'); drawAll(); schedulePreview(); };
      $('#dkSaveBtn').onclick = savePolicy;
      drawAll(); this.refresh();
    },
    refresh: function () {
      Promise.all([RG.loadDrives().catch(noop), RG.loadDisk(S.driveSel).catch(noop), RG.loadCands().catch(noop), RG.loadPolicy().catch(noop), RG.loadAdvice().catch(noop),
        RG.api('/api/cleanup/last').then(function (j) { S.cleanupLast = j.last; }).catch(noop), RG.api('/api/archives').then(function (j) { S.archives = j.items || []; }).catch(noop), RG.loadAuto().catch(noop), RG.loadAgent().catch(noop)])
        .then(function () { RG.updateNavBadges(); if (RG.cur === 'disk') { drawAll(); if (!D.pv) schedulePreview(); } }).catch(noop);
    },
    jobs: function () {
      if (RG.cur !== 'disk') return;
      var jb = S.jobs.breakdown, run = jb && jb.status === 'running';
      var sig = ['breakdown', jb && jb.status, jb && jb.pct, 'cand', S.jobs.candidates && S.jobs.candidates.status, 'clean', S.jobs.cleanup && S.jobs.cleanup.status, 'auto', S.jobs.auto && S.jobs.auto.status].join('|');
      if (sig === D.sig) return; D.sig = sig;
      if (D.wasRun && !run) Object.keys(D.tree).forEach(function (k) { D.stale[k] = true; });   // giữ cây cũ trên màn hình cho tới khi cây mới về, tránh nhảy số
      D.wasRun = !!run;
      drawHead(); drawBar(); drawMap(); drawExtra();
    },
    live: function () { if (RG.cur === 'disk') { drawHead(); drawBar(); } }
  };
})();
