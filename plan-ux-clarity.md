# Resource Guard — Plan thiết kế lại "một màn hình, thấy ngay ảnh hưởng"

> Lập ngày 2026-11-11, nối tiếp `plan-ux-impact.md` (đã xong 22/22 phase). Định dạng skill `plan-phases`.
> Phiên chính điều phối; mỗi executor làm MỘT phase, đọc "Quy ước chung" + "Hợp đồng dùng chung" + đặc tả phase của mình.

## Vì sao phải làm lại

Plan trước đạt về chức năng nhưng chủ sản phẩm chưa hài lòng. Ý kiến gốc (2026-11-11):

1. Đau nhất là **trực quan và rõ ràng**. Thông tin (ổ, tiến trình), hành động (dọn) và lịch tự động đang nằm ở các trang khác nhau; muốn thấy ảnh hưởng của một hành động phải chuyển qua lại. Yêu cầu: **gom lại để thấy ảnh hưởng ngay trên một màn hình**.
2. Tiến trình chỉ hiện tên + PID ("dotnet", "node"). Người dùng **không biết nó là gì, của ai, để làm gì**.
3. Với RAM/CPU: giữ mức quyền hiện tại (chỉ gợi ý, không đóng ứng dụng ngoài ledger), nhưng phải rõ ràng hơn.
4. Giữ hình thức trang web localhost. Không làm khay hệ thống, không làm cửa sổ riêng.
5. Thiết kế lại toàn bộ; có bản mẫu để duyệt trước khi code.

Lỗi cụ thể đã thấy trên bản hiện tại (ảnh `docs/img`, dữ liệu giả):

| # | Hiện tượng | Nguyên nhân | Phase sửa |
|---|---|---|---|
| L1 | Trang chủ báo thiếu RAM nhưng kế hoạch đề xuất dọn 104 MB ổ đĩa | `Get-RgAdvice` chỉ có mục tiêu theo ổ, bỏ qua `kind=process` | P3 |
| L2 | Bước "Các mục nhỏ" gộp zip/cache/tmp/bin, gắn "Rủi ro cao" dưới câu "rủi ro thấp trước" | `New-RgAdviceStep` kind `small` lấy rủi ro cao nhất | P3 |
| L3 | "Agent Thiếu 0 GB RAM" | làm tròn `fmtGB` | P5 |
| L4 | Thanh dung lượng có 3 vạch không nhãn | `impactBar` không vẽ nhãn ngưỡng | P6 |
| L5 | Biểu đồ 14 ngày to nửa màn hình, chỉ là đường phẳng | không có trạng thái "ít dữ liệu" | P6 |
| L6 | Treemap: 51% là khối đen "chưa quét chi tiết", 33% là một khối "Users" | vẽ một cấp, vùng cố định chiếm diện tích | P6 |
| L7 | Mỗi khối có 1–3 dòng chữ xám giải thích | không có quy tắc chữ | P5 + mọi phase UI |
| L8 | "1.82 GB" lẫn "2,4 GB"; nhóm "other" tiếng Anh | 24 chỗ `toFixed` rời rạc | P5 |
| L9 | Ngưỡng trạng thái chỉ sửa được trong `config.json` | chưa có API ghi | P4 + P10 |
| L10 | Badge "Nguy cấp" ở mọi trang, không bấm được | — | P5 |

## Giai đoạn

- [x] P1 Bản mẫu tĩnh 3 màn hình để chủ sản phẩm duyệt — touches: docs/mockup/index.html — kind: code — mode: direct — risk: low — exit: `powershell.exe -NoProfile -Command "if (Test-Path docs/mockup/index.html) { exit 0 } else { exit 1 }"`
- [x] P2 Danh tính tiến trình (là gì, của ai, để làm gì) — deps: P1 — touches: scripts/rg-proc.ps1, scripts/rg-server.ps1, scripts/rg-watcher.ps1, config.default.json, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P3 Advice: mục tiêu RAM, bỏ nhóm "Các mục nhỏ" — deps: P2 — touches: scripts/rg-insight.ps1, scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P4 API ghi ngưỡng trạng thái + tóm tắt 7 ngày — deps: P3 — touches: scripts/rg-server.ps1, scripts/rg-insight.ps1, scripts/rg-common.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: medium — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P5 Nền giao diện: token, khung 4 mục, định dạng số, quy tắc chữ — deps: P1 — touches: ui/app.css, ui/core.js, ui/boot.js, ui/index.html — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P6 Thành phần hình: resourceBar, treemap 2 cấp, liên kết rê chuột, biểu đồ ít dữ liệu — deps: P5 — touches: ui/viz.js, ui/core.js, ui/app.css — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P7 Màn Ổ đĩa hợp nhất (bản đồ + dọn + tự động) — deps: P6, P4 — touches: ui/p-disk.js, ui/p-clean.js, ui/p-auto.js, ui/index.html, ui/boot.js, ui/app.css — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P8 Màn Bộ nhớ & tiến trình hợp nhất — deps: P7 — touches: ui/p-proc.js, ui/app.css — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P9 Màn Tổng quan — deps: P8 — touches: ui/p-home.js, ui/app.css, ui/p-proc.js — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] P10 Cài đặt, hộp lần đầu, trợ lý AI, dọn file cũ — deps: P9 — touches: ui/p-overview.js, ui/p-setup.js, ui/p-agent.js, ui/boot.js, ui/index.html, ui/app.css, ui/p-disk.js, ui/p-auto.js, ui/viz.js, ui/core.js, ui/p-home.js, scripts/rg-server.ps1 — kind: code — model: sonnet — effort: medium — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [ ] P11 Kiểm toàn bộ + kiểm tay — deps: P10 — kind: verify — model: sonnet — effort: low — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1 && powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [ ] P12 Tài liệu + ảnh chụp — deps: P11 — touches: README.md, docs/TECHNOTE.md, docs/img — kind: code — model: sonnet — effort: low — risk: low — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
hot-files: ui/app.css, ui/core.js, ui/index.html, ui/boot.js, scripts/rg-server.ps1, tests/Acceptance.ps1
commit: none
workdir: C:/Users/HueTruong/Work/Repositories/Researchs/DEVELOPER WORKSPACE JANITOR/resource-guard

## Điều chỉnh

- 2026-11-11: chủ sản phẩm duyệt P1 và yêu cầu KHÔNG dùng subagent: phiên chính tự làm P2–P12 tuần tự (executor chỉ còn là tên phase; `model/effort` trong dòng plan không áp dụng). P3 đóng bằng -AcceptUnchanged vì baseline lấy sau khi sửa (đã tự chạy khối test advice, 0 FAIL). Từ P4: `ready` trước, sửa sau, `check` cuối.
- CỔNG DUYỆT: sau P1, phiên chính dừng và đưa bản mẫu cho chủ sản phẩm. Chỉ mở P2/P5 khi đã có câu "duyệt". Ý kiến sửa → cập nhật bản mẫu và mục "Thiết kế" dưới đây trước, rồi mới dispatch.
- Chạy tuần tự (`-MaxParallel 1`): gần như mọi phase chạm `app.css`, `rg-server.ps1` hoặc `Acceptance.ps1`.
- P2 và P7 dùng opus: P2 phải suy luận từ dòng lệnh/chuỗi cha (nhiều trường hợp biên); P7 gộp ba trang có luồng xoá file, PIN, quyền admin.
- P2: CONTRACT: Get-RgProcIdentity($Row,$ByPid,$Cfg,$Services,$Roots) + Get-RgWorkloads($Rows) + Get-RgWorkloadMap($Table) + Hide-RgCmdSecret + Get-RgServiceMap (cache 60s) nằm ở scripts/rg-proc.ps1; luật ở config.default.json identity.rules/launchers (config.json cũ thiếu khoá -> rơi về default).
- P2: /api/processes trả thêm mỗi dòng `cmd` (đã che bí mật, ≤600 ký tự) + `identity`, và `workloads[]`. Resource Guard tự nó có role 'system', title 'Resource Guard' (P3 dùng để loại khỏi close-app).
- P2: Hiệu năng (435 tiến trình, PS 5.1): lần đầu ~2 s (nguội), sau đó cache identity theo pid|start 10 phút ~110 ms; watcher dựng workload map khi làm mới bảng (30 s). procTop có thêm `workload` (tiến trình nặng nhất trong nhóm). rg-watcher.ps1 giờ dot-source rg-proc.ps1.
- P2: Đã chạy thử khối test identity bằng script rời (13/13 PASS); Acceptance.ps1 chạy một lần ở P11.
- P3: CONTRACT: GET /api/advice: steps[] có resource('disk'|'ram'), actionType('delete'|'close-app'), manual, minor(<50MB, giữ kind thật). Không còn kind 'small', không còn giới hạn 5 bước/ổ. Bước RAM: drive='RAM', id='RAM:close-app:<workloadKey>', workload, keys=[]; goals[]/afterPlan[] có phần tử resource='ram' (drive='RAM'; afterPlan thêm beforeBytes/afterBytes/stateBefore/stateAfter). Phần tử ổ có thêm resource='disk', goal có state.
- P3: Get-RgAdvice thêm tham số cuối -Ram {availGB,totalGB} -Workloads (Get-RgLiveWorkloads trong rg-proc.ps1). Workload thêm `what`, `closeHint`.
- P3: Câu "N nhóm, rủi ro thấp trước" nằm ở ui/p-home.js:103 (P9 phải chỉ sinh khi steps[0].riskLevel==='low'); UI cũ p-home.js dùng s.drive/g.drive nên bước RAM (drive 'RAM') tạm hiện như một "ổ" tới khi P9 viết lại; p-clean.js lọc theo ổ thật nên không thấy bước RAM. UI gộp minor=true dưới "N nhóm nhỏ khác (X MB)".
- P3: Đã chạy khối test advice (cũ + RAM mới) bằng script rời: 0 FAIL.
- P3: ACCEPT_UNCHANGED: operator explicitly accepted; no reason supplied
- P5: CONTRACT: RG.fmtNum(v,d)/RG.n1(x)/RG.fmtBytes/RG.fmtGB(<0,05 GB -> MB; 0 -> "0 GB")/RG.fmtPct; RG.human.role/group/reasonItems; RG.help(text); RG.empty(el,{icon,title,action,compact}); RG.statusBadge() (badge là <button>, popover #badgePop). Lớp CSS: .ws .ws-sticky .savebar(.show) .empty-state(.compact) .pop; token --space-1..6, --font-size-1..5, --role-<role>.
- P5: NAV 4 mục (home, disk, mem, settings). Hash cũ chỉ chuyển hướng khi trang cũ không còn đăng ký (LEGACY trong boot.js); 'mem' tạm trỏ tới RG.pages.cpu tới P8. Badge đếm mục dọn nay là #navDiskCnt (p-clean.js:117 vẫn gọi RG.updateNavBadges, vô hại).
- P5: Không còn toFixed trong core.js/boot.js. viz.js và các file trang còn toFixed: sửa ở P6–P10, P11 grep.
- P5: Class `.empty` cũ (p-home/p-auto/p-agent) vẫn dùng đến khi các trang đó được viết lại; RG.empty dùng `.empty-state`.
- P5: ACCEPT_UNCHANGED: operator explicitly accepted; no reason supplied
- P4: CONTRACT: POST /api/settings nhận { thresholds:{ ramAvailGB:{normalAbove,cautionFrom,restrictedFrom}, diskFreeGB:{normalAbove,cautionFrom}, commitPct:{restricted,critical} }, pin? } (cho phép gửi một phần) và/hoặc { intervalSec }. Lỗi thứ tự/khoảng -> 400 {ok:false,error}. Nới lỏng (hạ ngưỡng trống / nâng % commit) khi policy.mode='on' -> 403 code pin-required|pin-not-set|pin-wrong|pin-locked (giống /api/policy). Thành công trả { ok, thresholds, intervalSec? }.
- P4: Ghi vào config.json của người dùng (toàn bộ cấu hình; Save-RgThresholds trong rg-common.ps1). GET /api/insight thêm week:{autoRuns,autoBytes,dryRuns,dryBytes,alerts,manualRuns,manualBytes}. Sự kiện 'thresholds-change' được ghi log nhưng CHƯA có câu trong RG.human.event (core.js) và chưa nằm trong regex Get-RgRecentEvents: để P10 quyết định.
- P4: LƯU Ý: lần chạy thử đầu của tôi đã tạo ~/.agent-resource/config.json (bản sao cấu hình mặc định) vì biến môi trường sandbox là AGENT_RESOURCE_HOME chứ không phải RG_HOME; hệ thống chặn việc xoá nên giữ nguyên, báo chủ sản phẩm.
- P6: CONTRACT: RG.viz.resourceBar(el,{total,segments:[{key,label,value,color,pattern}],free,gain,marks:[{value,label,drag:{min,max,step,onChange(v,final)}}],caption,leftLabel,rightLabel,fmt,onHover,onPick}) -> {update,highlight,destroy}. Gọi lại trên cùng el = cập nhật tại chỗ (đang kéo tay nắm thì không dựng lại vạch). marks[].value là VỊ TRÍ dọc thanh (0..total), vạch "còn trống X" đặt ở total - X; drag.min/max cùng đơn vị vị trí.
- P6: RG.viz.donut(el,segs,total,{big,small},size,thick,{fmt,onHover,onPick}) và RG.viz.legend(el,rows,{fmt,onPick}); RG.link.on/emit/clear('hover'|'select', key, state) — resourceBar/donut/legend/treemap đều phát và nhận 'hover'. impactBar giờ là vỏ gọi resourceBar (xoá ở P10 khi hết lời gọi).
- P6: RG.viz.treemap thêm opts.depth(2)/exclude(node)/onPick(node,parent); trả {up,redraw,current,highlight(keys),select(keys)}; key ô = node.key||node.path; ô "(khác)"/"file ngay trong thư mục" có key = path+'#rest'/'#own'. Vùng zone 'fixed' truyền exclude để không vẽ (trang tự vẽ dải mỏng).
- P6: RG.lineChart: o.minPoints (mặc định 12 khi có trục, 2 khi không trục), < minPoints -> RG.empty compact "Đang thu thập dữ liệu (N/12 mẫu)" (svg phải nằm trong một thẻ cha riêng; ẩn svg), o.fit=true co trục Y.
- P6: Đã kiểm bằng Edge headless (harness trong scratchpad): 13/13 PASS trên #viz-demo, 0 lỗi JS. Không còn toFixed trong viz.js/core.js/boot.js.
- P7: CONTRACT: ui/p-disk.js = RG.pages.disk hợp nhất (578 dòng, không cần tách file). p-clean.js đã xoá và gỡ khỏi index.html; RG.seg(name,val,opts,dis) nay định nghĩa trong p-disk.js. p-auto.js chỉ còn 'Nâng cao' + vùng bảo vệ, đăng ký RG.pages.policy (hash #policy vẫn mở được, không ở NAV; P10 chuyển sang Cài đặt rồi xoá file). Không sửa boot.js.
- P7: Bố cục: #dkHead (chip ổ + Quét lại ▾ nhanh/đầy đủ) · #dkSticky (câu mô tả + công tắc Tắt/Chạy thử/Bật + resourceBar có tay nắm 'Tự dọn khi còn dưới X GB' + nút Dọn N mục) · .ws gồm #dkMap (donut+legend, treemap 2 cấp, #tmInfo bảo vệ/chọn thư mục, dải vùng cố định) và #dkList (nhóm theo advice steps, minor gộp 'N nhóm nhỏ khác', Cần xem lại, Được bảo vệ) · #dkExtra (admin, kết quả dọn, bản nén, agent đang giữ, chạy thử + mức sẵn, lịch sử 14 ngày, gập sẵn) · .savebar #dkSave.
- P7: Phạm vi theo ổ: mục dọn được lọc theo S.driveSel; mục không thuộc ổ nào (tiến trình mồ côi) hiện ở ổ đầu tiên. Nút Dọn và hộp xác nhận chỉ xử lý mục đã chọn của ổ đang xem (selFor). Bấm ô có mục dọn được → mở và cuộn tới nhóm lớn nhất; rê dòng/nhóm → treemap.highlight(ô sâu nhất đang vẽ). Phím mũi tên trên tay nắm nhảy sang mức kế tiếp (Ổn/Nguy cấp/Tắt).
- P7: Đã kiểm bằng Edge headless + API giả (harness h7.html trong scratchpad): 21/21 PASS (tick nhóm→gain+viền ô, rê→ô sáng, bấm ô→mở nhóm, phím kéo ngưỡng→savebar, công tắc nhóm, mục bảo vệ disabled, hộp xác nhận có resourceBar + nút 'Xoá vĩnh viễn N mục (X GB)', menu quét, Huỷ bản nháp), 0 lỗi JS, không còn toFixed. Chưa kiểm với backend thật (P11): PIN khi nới lỏng lúc Lưu, admin/UAC, zip/giải nén, lượt dọn thật trên fixture, biểu đồ lịch sử có điểm đánh dấu lượt dọn (chưa làm).
- P7: Cho P8–P10: P9 dùng RG.go('disk') (hash #clean tự chuyển vì không còn đăng ký); chọn sẵn key từ trang chủ bằng S.selected[key]=true rồi RG.go('disk'). p-home.js còn gọi tới trang Dọn dẹp cũ (tìm 'clean'/'Dọn dẹp') → sửa ở P9. Câu 'Hỏi trợ lý AI' ở nhóm 'Cần bạn xem lại' chưa có nút (P10). Sự kiện 'thresholds-change' vẫn chưa có câu UI (P10).

- NOTES P8: `RG.pages.mem` (p-proc.js, alias `cpu`): thanh RAM `resourceBar` dính (6 workload lớn nhất + Khác, vạch "Ổn từ"), gain = RAM mục đang chọn; bấm đoạn thanh = chọn workload; rê dòng → `bar.highlight`.
- NOTES P8: chi tiết bên phải dùng đại diện = tiến trình RAM lớn nhất của nhóm (chain, dòng lệnh, biểu đồ theo tên đó); chỉ làm mới số mỗi nhịp, không vẽ lại biểu đồ. Bảo vệ theo từng tên tiến trình. Không có nút đóng tiến trình. CPU/từng nhân/thông tin máy trong `<details id=mLow>` gập sẵn.
- NOTES P8: kiểm bằng harness Edge headless (API giả) 31/31 PASS, 0 lỗi JS. Chưa kiểm với backend thật (hạ ưu tiên thật, identity thật) → P11.

- NOTES P9: `RG.pages.home` viết lại: câu trạng thái + chip sẵn sàng (lý do trong RG.help), mỗi tài nguyên một dòng donut 68px + resourceBar (bấm → #mem/#disk, set S.driveSel), "Nên làm gì" ≤3 bước theo goals (dừng sau bước reachesGoal), dòng "Sau N bước", 4 ô tuần từ insight.week + 8 sự kiện gần nhất. Rê bước → thanh tài nguyên đó hiện gain (cumBytes).
- NOTES P9: [Xem] ổ đĩa = S.selected[key]=true + RG.go('disk'); [Xem] RAM = RG.memSelect(workload) (mới, thêm vào p-proc.js nên P9 touches thêm ui/p-proc.js) + RG.go('mem'). Đã bỏ biểu đồ 14 ngày, chỉ số chi tiết, ngăn kéo bước, nút Tự động hoá. P8 có thêm donut theo workload cạnh danh sách (nguyên tắc 6). Kiểm harness h9 23/23, h8 31/31.

## Quy ước chung (mọi executor đọc)

- Mục tiêu hỗ trợ: **Windows PowerShell 5.1** (`powershell.exe`). Không dùng cú pháp chỉ có ở PowerShell 7 (`??`, `?.`, toán tử ba ngôi, `&&`).
- UI là JavaScript thuần ES5 trong `ui/` (không framework, không bước build, không thư viện ngoài). Giữ kiểu `var` + `function` như file hiện có. Mọi chuỗi đưa vào HTML qua `RG.esc`.
- Mọi chữ người dùng thấy là tiếng Việt có dấu. Tên nhóm/loại/trạng thái lấy từ `RG.human`, không in giá trị thô (`other`, `Critical`).
- Số: chỉ dùng `RG.fmtBytes`, `RG.fmtGB`, `RG.fmtPct` (P5). Cấm `toFixed` trực tiếp trong file trang.
- **Quy tắc chữ (L7):** mỗi thẻ tối đa MỘT dòng phụ ≤ 90 ký tự. Giải thích dài hơn đặt vào `title` của biểu tượng "?" (`RG.help(text)`, P5). Không viết đoạn hướng dẫn cách dùng trên màn hình.
- **Bất biến an toàn, không được đổi:** thân `POST /api/cleanup/apply`; luồng PIN (`RG.askPin`, `needsPin`); "Dọn bằng quyền admin" (`/api/cleanup/elevate`); ô nén zip + "Bản nén đã tạo" + giải nén; mục được bảo vệ không chọn được; không có nút kết thúc tiến trình ngoài ledger; trang chủ không xoá gì; mọi lượt xoá qua hộp xác nhận.
- Xoá/đổi tên file: tìm tên file đó trong `tests/`, `README.md`, `docs/TECHNOTE.md`, `ui/index.html`, `scripts/rg-server.ps1` và sửa trong cùng phase.
- Kiểm tay luôn dùng home sandbox (như P21 plan trước: `%TEMP%\rg-*`, fixture giả). Không chạy lượt dọn thật trên dữ liệu người dùng.
- Test mới viết cùng phase vào `tests/Acceptance.ps1`, chạy một lần ở P11.

---

## Thiết kế

### Nguyên tắc

1. **Một màn hình cho một tài nguyên.** Mỗi màn có ba vùng luôn cùng hiện: *Bản đồ* (cái gì đang chiếm, nằm ở đâu) · *Việc có thể làm* (danh sách hành động) · *Thanh trước → sau* (dính trên cùng). Không còn trang Dọn dẹp và Tự động hoá riêng.
2. **Liên kết hai chiều.** Rê/chọn một dòng hành động → phần tương ứng trên bản đồ sáng lên và thanh trước → sau đổi ngay. Bấm một ô trên bản đồ → dòng hành động tương ứng được cuộn tới và tô.
3. **Tự động hoá nằm ngay trên dòng hành động.** Mỗi nhóm có công tắc 3 nấc *Tự động / Hỏi tôi / Luôn giữ* ở chính dòng đó. Ngưỡng kích hoạt là một tay nắm kéo được trên thanh trước → sau. Người dùng đặt lịch ở đúng nơi họ thấy ảnh hưởng.
4. **Hình trước, chữ sau.** Mọi thanh có nhãn số ở hai đầu và nhãn tại từng vạch ngưỡng. Mọi màu/hoạ tiết có chú giải một dòng.
6. **Biểu đồ tròn (donut) cho phần "cái gì chiếm bao nhiêu".** Thêm theo yêu cầu 2026-11-11, đã có trong bản mẫu: Ổ đĩa = donut + chú giải cạnh treemap; Bộ nhớ = donut theo workload cạnh danh sách; Tổng quan = donut nhỏ (68px) ở đầu mỗi dòng tài nguyên. Donut dùng chung kênh liên kết với thanh/treemap/danh sách; đoạn "sẽ dọn / nếu đóng" gạch chéo, tâm donut hiện số trống. Thành phần mới `RG.viz.donut(el, segs, total, center, size, thick)` thuộc P6 (xem `donut()` trong `docs/mockup/index.html`).
5. **Biểu đồ chỉ hiện khi có dữ liệu.** Dưới 12 điểm → thay bằng một dòng "Đang thu thập dữ liệu (N/12 mẫu)".

### Điều hướng (4 mục, thay 6 mục cũ)

| Mục | Hash | Gộp từ | File |
|---|---|---|---|
| Tổng quan | `#home` | Trang chủ | `ui/p-home.js` |
| Ổ đĩa | `#disk` | Ổ đĩa + Dọn dẹp + Tự động hoá (phần ổ) | `ui/p-disk.js` |
| Bộ nhớ & tiến trình | `#mem` | Tiến trình + Tự động hoá (phần tiến trình) | `ui/p-proc.js` |
| Cài đặt | `#settings` | Cài đặt + "Nâng cao" của Tự động hoá | `ui/p-overview.js` |

Hash cũ: `#clean`, `#policy` → `#disk`; `#cpu` → `#mem`; `#overview`, `#agent` → `#home`. Badge số mục dọn được chuyển sang mục "Ổ đĩa".

### Màn Ổ đĩa (`#disk`)

```
[ C: còn 8,6 GB ● Nguy cấp ] [ D: còn 216 GB ● Ổn ]            [Quét lại ▾]  quét 3 phút trước
┌ Thanh trước → sau (dính) ───────────────────────────────────────────────────────────────┐
│ ███████████████████████████████▨▨▨▨▨▨░░░░░░░░░░                                          │
│ Đã dùng 173 GB          Sẽ giải phóng 11,4 GB   Trống 8,6 → 20,0 GB                      │
│                                  ▲ Tự dọn khi còn dưới 10 GB (kéo)   ┆ Ổn từ 20 GB       │
│ Nguy cấp → Ổn · đã chọn 14 mục                         [ Dọn 14 mục đã chọn (11,4 GB) ]  │
├ Bản đồ ổ C (trái, 55%) ───────────────┬ Việc có thể làm (phải, 45%) ────────────────────┤
│ treemap 2 cấp, chỉ vùng quét được;    │ ☑ Gói NuGet không dùng 14 ngày   7,3 GB  ● thấp │
│ ô có mục dọn được = gạch chéo xanh;   │   [Tự động | Hỏi tôi | Luôn giữ]   3 mục  ▸     │
│ ô đang chọn = viền đậm.               │ ☑ bin/obj cũ                     4,1 GB  ● thấp │
│ Dưới bản đồ: một dải mỏng             │   [Tự động | Hỏi tôi | Luôn giữ]  11 mục  ▸     │
│ "Hệ thống & chương trình 52 GB        │ ☐ node_modules cũ                2,0 GB  ● vừa  │
│  (không dọn được)"                    │ ── Cần bạn xem lại (3) ──        [Hỏi trợ lý AI]│
│ [Bản đồ | Danh sách lớn nhất]         │ ── Được bảo vệ / chỉ báo cáo (1) ──             │
└───────────────────────────────────────┴─────────────────────────────────────────────────┘
▸ Lịch sử ổ C: biểu đồ dung lượng trống + điểm đánh dấu lượt dọn (gập sẵn)
```

- Dòng nhóm mở ra (▸) → từng mục: tên ngắn (thư mục cuối + dự án), dung lượng, tuổi, nút khiên bảo vệ. Bấm mục → `RG.drawer` + `RG.receipt` như cũ.
- Nhóm ở "Tự động" có dòng phụ lấy từ `evidence`: "9 lượt chạy thử: 41 mục, 5,2 GB".
- Chế độ tự động (Tắt / Chạy thử / Bật) là một công tắc nhỏ cạnh tay nắm ngưỡng, kèm một câu sinh từ bản nháp (giữ hàm sinh câu của `p-auto.js`).
- Đổi công tắc nhóm hoặc kéo ngưỡng = sửa bản nháp chính sách → hiện thanh "Chính sách đã đổi · [Lưu] [Huỷ]" ở đáy màn. Lưu dùng `RG.savePolicy` + PIN như cũ.
- Màn hẹp < 980px: bản đồ trên, danh sách dưới; thanh trước → sau vẫn dính.

### Màn Bộ nhớ & tiến trình (`#mem`)

```
┌ Thanh RAM trước → sau (dính) ───────────────────────────────────────────────────────────┐
│ [Trình duyệt 2,1][Build .NET 1,4][VS Code 1,1][Windows 1,6][Khác 0,9]░░ trống 2,4 GB     │
│ Nếu đóng mục đang chọn: trống 2,4 → 3,8 GB · Hạn chế → Cần chú ý       ┆ Ổn từ 5 GB      │
├ Ai đang dùng (trái, 60%) ───────────────────────────┬ Chi tiết mục đang chọn (phải) ────┤
│ ▾ Build .NET · dự án dxwms            1,4 GB  38%CPU│ dotnet build                      │
│     dotnet build  ·  do VS Code mở  ·  chạy 4 phút  │ Là gì: đang build dự án dxwms     │
│     VBCSCompiler  ·  trình biên dịch C# chạy nền    │ Của ai: VS Code → pwsh → dotnet   │
│ ▾ Trình duyệt Edge (23 tiến trình)    2,1 GB   2%CPU│ Dòng lệnh: dotnet build src\…     │
│ ▸ VS Code (12 tiến trình)             1,1 GB        │ Biểu đồ CPU/RAM 1 giờ             │
│ ▸ Windows (dịch vụ hệ thống)          1,6 GB        │ Nếu đóng: +1,4 GB RAM             │
│ ▸ Trợ lý AI: claude (được bảo vệ)     0,4 GB        │ [Hạ ưu tiên] [Bảo vệ]             │
│ [Gộp theo việc | Từng tiến trình]   lọc: [______]   │ "Muốn đóng: tự tắt trong VS Code" │
└─────────────────────────────────────────────────────┴───────────────────────────────────┘
▸ CPU theo thời gian · Từng nhân logic · Thông tin máy (gập sẵn)
```

- Thanh RAM chia đoạn theo `workload` (hợp đồng P2), màu cố định theo `role`. Rê vào đoạn → dòng tương ứng sáng; chọn dòng → đoạn đó chuyển gạch chéo và hiện "nếu đóng".
- Không có nút đóng tiến trình. Câu hướng dẫn tự đóng lấy từ `identity.closeHint`.

### Màn Tổng quan (`#home`)

```
┌ Máy đang thiếu RAM: còn 2,4 GB trống                                   [vì sao?] ─────────┐
│ Sẵn sàng cho:  Build ✗ thiếu 0,8 GB RAM · Test ✗ thiếu 1,8 GB RAM · Trợ lý AI ✓           │
├ Tài nguyên (mỗi dòng một resourceBar có nhãn; bấm → sang màn tương ứng) ──────────────────┤
│ RAM   ████████████████░░░  trống 2,4 / 7,8 GB   ● Nguy cấp                               │
│ Ổ C   ████████░░░░░░░░░░░  trống 80 / 182 GB    ● Ổn · đủ dùng ~40 ngày                  │
│ Ổ D   ███░░░░░░░░░░░░░░░░  trống 216 / 300 GB   ● Ổn                                     │
├ Nên làm gì bây giờ (tối đa 3 bước, đúng tài nguyên đang thiếu) ───────────────────────────┤
│ 1. Đóng Build .NET của dxwms nếu đã xong    +1,4 GB RAM   bạn tự đóng   [Xem]            │
│ 2. Đóng bớt tab Edge                        +2,1 GB RAM   bạn tự đóng   [Xem]            │
│ → Sau 2 bước: RAM trống 2,4 → 5,9 GB · Nguy cấp → Ổn                                     │
├ 7 ngày qua Resource Guard đã ────────────────────────────────────────────────────────────┤
│ tự dọn 3 lượt · 6,2 GB   │  chạy thử 9 lượt · sẽ dọn 5,2 GB  │  cảnh báo 2 lần           │
│ dòng thời gian sự kiện (gộp sự kiện trùng)                                               │
└──────────────────────────────────────────────────────────────────────────────────────────┘
```

- Khi mọi thứ Ổn: tiêu đề "Máy đang ổn. Không cần làm gì." và khối "Nên làm gì" thu thành một dòng.
- Bấm [Xem] ở bước ổ đĩa → `#disk` với các key đã chọn sẵn; ở bước RAM → `#mem` với workload đó được chọn.

---

## Hợp đồng dùng chung (chốt trước, không đổi giữa chừng)

### P2 — danh tính tiến trình

`Get-RgProcIdentity($Row, $ByPid, $Cfg, $Services)` trong `scripts/rg-proc.ps1`, trả về:

```
identity = {
  role:        'build' | 'test' | 'devserver' | 'compiler' | 'langserver' | 'packagemgr' | 'runtime-app'
             | 'browser' | 'editor' | 'agent' | 'infra' | 'system' | 'security' | 'app' | 'unknown'
  title:       string   # tiếng Việt, ≤ 40 ký tự: "Build .NET", "Angular dev server", "Trình biên dịch C# chạy nền"
  what:        string   # một câu: "Đang build dự án dxwms"
  project:     string|null   # tên thư mục dự án suy ra từ dòng lệnh, nằm dưới workspaceRoots
  projectPath: string|null
  owner:       { name, pid, label } | null   # tổ tiên gần nhất thuộc danh sách launcher
  chain:       [ 'Code', 'pwsh', 'dotnet' ]  # tối đa 5 mắt, từ launcher xuống
  workload:    string   # khoá gộp: role + '|' + (project hoặc owner.name hoặc name)
  closeHint:   string   # "Tự tắt trong cửa sổ terminal của VS Code"
  confidence:  'rule' | 'guess'
}
```

- Nguồn dữ liệu chỉ gồm thứ đã có trong `Get-RgProcessTable` (`Name`, `Cmd`, `ParentPid`, `Start`) cộng `Win32_Service` (lấy MỘT lần mỗi lượt, map PID → tên hiển thị dịch vụ cho `svchost`). Không đọc bộ nhớ tiến trình khác, không cần admin.
- Bảng luật nằm trong `config.default.json` khoá `identity.rules` (mảng `{ name, cmdRegex, role, title, what }`, `what` có thể chứa `{project}` và `{arg}`) và `identity.launchers` (`Code`, `devenv`, `rider64`, `WindowsTerminal`, `explorer`, `claude`…). Luật tối thiểu phải có: `dotnet build|test|run|watch|restore|publish`, `dotnet … MSBuild.dll /nodeReuse` (nút build chờ sẵn), `VBCSCompiler`, `testhost`, `node …ng serve|ng build`, `node …vite`, `node …tsserver` (dịch vụ ngôn ngữ TypeScript), `npm|npx|pnpm run <script>`, `node …webpack`, `msedge|chrome|firefox` (browser, đếm tiến trình con), `Code` (editor), `MsMpEng` (Windows Defender), `Memory Compression`, `svchost` (tên dịch vụ), `sqlservr`, `vmmem*` (WSL/Docker).
- `project`: lấy đường dẫn tuyệt đối đầu tiên trong `Cmd` nằm dưới một `workspaceRoots`; tên dự án = thư mục con cấp 1 dưới root đó. Không có → thử `Cmd` của từng mắt trong chuỗi cha. Vẫn không có → `null`, `confidence='guess'`.
- Không khớp luật nào: `role='app'` nếu có cửa sổ/không phải session 0, ngược lại `unknown`; `title` = tên file; `what` = "Chưa nhận diện được".
- `GET /api/processes`: mỗi dòng thêm `identity`. Thêm mảng `workloads: [{ key, role, title, project, owner, count, ramMB, cpuPct, pids, protected }]` sắp theo `ramMB` giảm dần.
- `procTop` trong metrics (watcher) thêm trường `workload` để `stackArea` và thanh RAM dùng lại; bản ghi cũ thiếu trường này phải đọc được (rơi về `name`).
- Dòng lệnh có thể chứa bí mật: trước khi trả ra API, che giá trị sau `--password`, `--token`, `-p`, `apikey=`, `pwd=` bằng `***` (hàm `Hide-RgCmdSecret`, có test).

### P3 — advice

`GET /api/advice` thêm (không bỏ trường cũ):

```
goals[]      thêm { resource: 'disk'|'ram', ... }; goal RAM: { resource:'ram', needBytes, state }
steps[]      thêm { resource, actionType: 'delete'|'close-app', workload?, manual: bool }
afterPlan[]  thêm phần tử { resource:'ram', beforeBytes, afterBytes, stateBefore, stateAfter }
```

- Khi RAM ở mức Cần chú ý trở xuống: sinh bước `close-app` từ `workloads`, loại `agent`, `system`, `security`, `infra`, mục được bảo vệ và chính Resource Guard; sắp theo `ramMB`; dừng khi đủ đưa RAM về Ổn, tối đa 3 bước. `manual=true` luôn luôn. `why` nêu `identity.what`; `impact` = "Việc chưa lưu trong ứng dụng này sẽ mất nếu bạn đóng mà chưa lưu".
- Thứ tự bước: tài nguyên có trạng thái xấu nhất đứng trước.
- Bỏ kind `small`. Bước < 50 MB giữ nguyên kind thật, đánh dấu `minor=true`; UI gộp chúng dưới một dòng "N nhóm nhỏ khác (X MB)" mở ra được. `riskLevel` luôn là của chính kind đó.
- Câu tóm tắt "rủi ro thấp trước" chỉ sinh khi bước đầu có `riskLevel='low'`.

### P4 — cài đặt và tóm tắt

- `POST /api/settings` nhận thêm `thresholds` (RAM GB, ổ GB, commit %) với kiểm tra: số dương, thứ tự Ổn > Cần chú ý > Hạn chế, trong khoảng hợp lý; ghi vào config người dùng bằng `Write-RgFileAtomic`. Executor đọc handler `/api/settings` hiện có trước; nếu nới lỏng ngưỡng khi chế độ tự động đang Bật thì yêu cầu PIN giống `needsPin` của chính sách.
- `GET /api/insight` thêm `week: { autoRuns, autoBytes, dryRuns, dryBytes, alerts, manualRuns, manualBytes }` tính từ events 7 ngày.

### P5 — nền giao diện (`ui/core.js`, `ui/app.css`)

| Hàm / lớp | Việc |
|---|---|
| `RG.fmtGB(n)`, `RG.fmtBytes(n)`, `RG.fmtPct(n)` | Dấu phẩy thập phân; < 0,05 GB hiện bằng MB, không bao giờ in "0 GB" cho số khác 0 (L3) |
| `RG.human.role(r)`, `RG.human.group(g)` | Tên tiếng Việt cho `role` và nhóm cũ (`other` → "Khác") |
| `RG.help(text)` | Trả HTML biểu tượng "?" có `title` + `aria-label` |
| `RG.empty(el, { icon, title, action })` | Trạng thái trống thống nhất |
| `RG.statusBadge` | Badge trên topbar bấm được → popover liệt kê lý do từ `RG.human.reasons(live)` + nút sang màn liên quan (L10) |
| Token CSS | `--space-1..6`, `--radius`, `--font-size-1..5`, màu trạng thái `--ok/--caution/--limited/--critical`, màu `--role-*` (14 role); cả theme sáng và tối |
| Bố cục | `.ws` (lưới 2 cột màn hợp nhất), `.ws-sticky`, `.savebar` (thanh Lưu/Huỷ ở đáy) |

`NAV` 4 mục và ánh xạ hash cũ theo bảng Điều hướng. Trong P5 các trang cũ (`clean`, `policy`) vẫn chạy được qua hash cũ cho tới P7.

### P6 — thành phần hình (`ui/viz.js`)

| Hàm | Chữ ký | Việc |
|---|---|---|
| `RG.viz.resourceBar` | `(el, { total, segments:[{ key, label, value, color, pattern }], free, gain, marks:[{ value, label, drag?:{min,max,onChange} }], caption, onHover(key), onPick(key) })` → `{ update(o), highlight(key) }` | Thanh có nhãn số hai đầu, nhãn chữ tại từng vạch, đoạn gạch chéo cho `gain`, tay nắm kéo được (chuột + phím mũi tên). Thay `impactBar`; `impactBar` giữ lại làm vỏ gọi sang để không vỡ lời gọi cũ cho tới P10. |
| `RG.viz.treemap` (mở rộng) | thêm `opts.depth` (mặc định 2: ô cha có tiêu đề, ô con bên trong), `opts.exclude(node)`, trả `{ highlight(pathsOrKeys), select(...) }` | Vùng `fixed` không vẽ thành ô; trang gọi tự vẽ dải mỏng bên dưới (L6). |
| `RG.lineChart` (mở rộng) | `o.minPoints` (mặc định 12) | Ít điểm hơn → vẽ `RG.empty` "Đang thu thập dữ liệu (N/12 mẫu)" cao 56px thay cho biểu đồ (L5). Trục Y tự co quanh dữ liệu khi `o.fit=true`. |
| `RG.link` | `RG.link.on(channel, fn)`, `RG.link.emit(channel, key, state)` | Kênh sự kiện nhỏ để bản đồ, danh sách và thanh sáng cùng nhau (`hover`/`select`). |

Cập nhật trang thử `#viz-demo` cho mọi thành phần mới ở cả hai theme.

---

## Đặc tả từng phase

### P1 Bản mẫu tĩnh — phiên chính làm
- Một file HTML tự chứa (`docs/mockup/index.html`, không gọi API, dữ liệu mẫu viết cứng), có 3 màn Tổng quan / Ổ đĩa / Bộ nhớ & tiến trình theo đúng wireframe trên, cả hai theme, có tương tác tối thiểu: rê dòng → bản đồ + thanh đổi; kéo ngưỡng; đổi công tắc nhóm → hiện thanh Lưu.
- Dữ liệu mẫu phải có trường hợp xấu: thiếu RAM, ổ C Nguy cấp, tên thư mục dài, 40 mục trong một nhóm.
- Đưa chủ sản phẩm duyệt (CỔNG DUYỆT). Sau khi duyệt, bản mẫu là chuẩn hình ảnh cho P5–P10: executor mở file này để lấy bố cục, khoảng cách, màu.

### P2 Danh tính tiến trình
- Cài theo hợp đồng P2. Đọc trước: `Get-RgProcessTable`, `Get-RgGroup` (`rg-common.ps1`), `Get-RgProcTop` (`rg-watcher.ps1`), handler `/api/processes` (`rg-server.ps1`).
- Hiệu năng: không gọi CIM thêm cho từng tiến trình; `Win32_Service` một lần mỗi lượt và giữ cache 60 giây. Đo thời gian `/api/processes` trước/sau, ghi vào NOTES; chậm hơn quá 150 ms thì giảm tần suất tính identity.
- Test (fixture bảng tiến trình giả, không phụ thuộc máy): `dotnet build` dưới `Code → pwsh` → role build, project đúng, owner Code; `node …\@angular\cli\bin\ng.js serve` → devserver; `svchost` có 2 dịch vụ; tiến trình mồ côi; dòng lệnh rỗng (không có quyền đọc); vòng lặp cha–con (PID tái sử dụng) không treo; che bí mật.

### P3 Advice
- Cài theo hợp đồng P3 trong `Get-RgAdvice` và `New-RgAdviceStep`. Tìm mọi nơi đọc `kind -eq 'small'` hoặc tiêu đề "Các mục nhỏ" (`ui/p-home.js`, `ui/p-clean.js`, tests) và ghi vào NOTES cho P7/P9; test backend sửa trong phase này.
- Test: máy thiếu RAM + ổ Ổn → bước đầu là `close-app`, không có bước xoá nào đứng trước; cả hai cùng thiếu → tài nguyên xấu hơn trước; workload agent/được bảo vệ không bao giờ xuất hiện; bước < 50 MB giữ kind và `riskLevel` thật.

### P4 Cài đặt + tóm tắt
- Theo hợp đồng P4. Test: thứ tự ngưỡng sai bị từ chối 400; ghi xong `/api/settings` đọc lại đúng; `week` đếm đúng trên events giả.

### P5 Nền giao diện
- Theo hợp đồng P5. Thay `toFixed` trong `core.js` và `boot.js` bằng hàm định dạng. KHÔNG chạm file trang ở phase này: `toFixed` trong `viz.js` thay ở P6, trong từng file trang thay khi trang đó được viết lại (P7–P10); P11 grep xác nhận không còn sót.
- Nghiệm thu: 4 mục nav; hash cũ chuyển hướng đúng; badge bấm ra lý do; hai theme; 980px và 400px không tràn ngang.

### P6 Thành phần hình
- Theo hợp đồng P6. Nghiệm thu trên `#viz-demo`: thanh có 2 vạch nhãn không đè nhau khi hai vạch sát nhau (nhãn tự lệch dòng); kéo tay nắm bằng chuột và phím; treemap 2 cấp với 1 nút, 0 byte, 500 nút không lỗi; `highlight` sáng đúng ô; biểu đồ 3 điểm hiện trạng thái thu thập.

### P7 Màn Ổ đĩa hợp nhất — risk: high
- Viết lại `RG.pages.disk` theo wireframe. Chuyển vào `p-disk.js` toàn bộ logic còn dùng của `p-clean.js` (chọn mục, hộp xác nhận, kết quả dự kiến/thực tế, "Agent đang giữ", admin, zip/giải nén) và phần ổ của `p-auto.js` (bản nháp, sinh câu mô tả, `/api/auto/preview` debounce 300 ms, 3 mức sẵn, "Chạy thử ngay"). Xoá `p-clean.js`; `p-auto.js` chỉ còn phần "Nâng cao" + vùng bảo vệ để P10 đưa sang Cài đặt (giữ đăng ký `RG.pages.policy` nội bộ, không có trong NAV).
- Nếu `p-disk.js` vượt ~900 dòng: tách `ui/p-disk-actions.js` (danh sách + xác nhận) — báo BLOCKED để phiên chính thêm touches, không tự thêm file.
- Hành vi bắt buộc:
  1. Tick/bỏ tick nhóm hoặc mục → `resourceBar` cập nhật tức thì (gain, trạng thái trước → sau), ô trên treemap đổi viền.
  2. Rê dòng → ô sáng; bấm ô có mục dọn được → danh sách cuộn tới và mở nhóm đó.
  3. Kéo tay nắm ngưỡng → câu mô tả và "14 ngày qua chạm N lần" đổi; hiện thanh Lưu.
  4. Công tắc nhóm 3 nấc sửa bản nháp; nới lỏng khi đang Bật → hỏi PIN lúc Lưu.
  5. Mục được bảo vệ không tick được; bảo vệ một thư mục từ bản đồ → ô chuyển nét đứt, mục rời danh sách.
  6. Hộp xác nhận giữ `resourceBar` + danh sách gộp theo nhóm + nút "Xoá vĩnh viễn N mục (X GB)".
  7. Quét: hiện dần; nút "Quét lại ▾" có hai lựa chọn nhanh/đầy đủ.
- Toàn bộ "Bất biến an toàn" ở Quy ước chung là tiêu chí nghiệm thu của phase này; kiểm tay ở P11.

### P8 Màn Bộ nhớ & tiến trình
- Viết lại `RG.pages.cpu` thành `RG.pages.mem` (giữ alias `cpu`) theo wireframe, dùng `workloads` + `identity`.
- Chế độ "Gộp theo việc" (mặc định) và "Từng tiến trình"; lọc theo tên/dự án/PID.
- Khung chi tiết bên phải (không dùng ngăn kéo): Là gì / Của ai (chuỗi `chain`) / Dòng lệnh (rút gọn, bấm để xem đủ) / biểu đồ 1–6–24 giờ / "Nếu đóng" / Hạ ưu tiên – Trả về bình thường / Bảo vệ / `closeHint`. `confidence='guess'` → gắn nhãn "phỏng đoán".
- Phần CPU theo thời gian, từng nhân, thông tin máy: gập sẵn ở cuối.

### P9 Màn Tổng quan
- Viết lại `RG.pages.home` theo wireframe: tiêu đề trạng thái, chip sẵn sàng, một `resourceBar` cho RAM và mỗi ổ, "Nên làm gì bây giờ" từ `/api/advice` (đủ loại `delete` và `close-app`), khối `week`, dòng thời gian sự kiện.
- Biểu đồ 14 ngày chuyển sang màn Ổ đĩa (đã có ở P7); bỏ "Chỉ số chi tiết" khỏi trang chủ.
- Không có hành động xoá nào ở trang này.

### P10 Cài đặt, lần đầu, trợ lý AI, dọn dẹp code
- Cài đặt: ngưỡng trạng thái sửa được (ô số + Lưu, gọi `POST /api/settings`); mục "Tự động hoá nâng cao" (nghỉ giữa hai lượt, GB tối đa mỗi lượt, thứ tự ưu tiên, ghi đè theo ổ, vùng bảo vệ) chuyển từ `p-auto.js` sang; trạng thái PIN + hướng dẫn `rg pin`. Khối "An toàn" rút còn 3 dòng.
- Hộp lần đầu: cập nhật câu chữ và ảnh minh hoạ theo 3 màn mới.
- Ngăn kéo "Hỏi trợ lý AI": mở từ màn Ổ đĩa (nhóm Cần xem lại) và Tổng quan; hành vi giữ nguyên.
- Xoá `p-auto.js` và vỏ `impactBar` nếu không còn lời gọi (kiểm bằng grep); sửa `index.html`.

### P11 Kiểm toàn bộ
Ngoài lệnh `exit`, phiên chính chạy app trong sandbox và kiểm tay, ghi vào NOTES:
1. Ổ đĩa: 7 hành vi của P7 + một lượt dọn thật trên fixture + luồng PIN, admin, zip.
2. Bộ nhớ: chạy thật `dotnet build` và `npm run` của một dự án thử → màn hiện đúng "là gì, của ai, dự án nào"; hạ ưu tiên rồi hoàn tác.
3. Tổng quan: giả lập thiếu RAM → bước đầu là đóng ứng dụng; giả lập ổ đầy → bước đầu là dọn.
4. Đếm chữ: không thẻ nào quá một dòng phụ; không còn chuỗi tiếng Anh hay số dùng dấu chấm thập phân.
5. Hai theme, 980px và 400px, chỉ bàn phím.
6. So ảnh chụp từng màn với bản mẫu P1; nêu chỗ lệch.

### P12 Tài liệu
- README (bảng màn hình mới, mục tiến trình), `docs/TECHNOTE.md` (hợp đồng identity, advice RAM, API settings). Chụp lại ảnh `docs/img` từ sandbox.

## NOTES (phiên chính)
- P10: Cài đặt = p-overview.js (7 ô ngưỡng POST /api/settings {thresholds,pin?}, hỏi PIN khi nới lỏng lúc tự động hoá Bật; chu kỳ; khởi động + PIN `rg pin`; An toàn 3 dòng; Giao diện; mục "Tự động hoá nâng cao" chuyển từ p-auto.js, dùng S.draft/savePolicy). p-auto.js đã xoá, RG.pages.policy bỏ, impactBar bỏ (giữ V.stateOf vì p-disk dùng; demo #viz-demo bỏ thẻ impactBar). Nút "Hỏi trợ lý AI" ở nhóm Cần bạn xem lại (p-disk, data-ask-agent → RG.askAgent). thresholds-change có câu UI (core.js) và nằm trong regex Get-RgRecentEvents. Hộp lần đầu (p-setup.js) viết lại bước 1 theo 3 màn mới. CHƯA làm: nút Hỏi trợ lý AI trên Tổng quan (p-home) — chỉ mở được từ Ổ đĩa. Harness: scratchpad h10.html 13/13.

- P11 (đang làm, CHƯA đóng): Check-Syntax OK, không còn toFixed. Acceptance 405 pass / 0 fail (đã sửa tests/Acceptance.ps1 dòng khởi động server: quote đường dẫn có dấu cách; trước đó 26 FAIL do mutex Local\ResourceGuardWatcher bị terminal cũ giữ). Kiểm tay bằng Edge CDP (scratchpad cdp.mjs) trên server sandbox cổng 47811. Đã sửa: donut thiếu fill="none" (tâm đen); "0% CPU" → "nghỉ" khi <0,5%; chip "thiếu 0 GB RAM" (nay nêu đúng blocker); nhóm trùng tên thêm tên chương trình; nhãn ngưỡng resourceBar tràn/đè nút kéo; số xuống dòng (nowrap); thanh RAM "Cần chú ý → Cần chú ý"; trục biểu đồ dùng dấu chấm (nay RG.fmtNum); "Của ai: firefox → firefox"; bảng Ưu tiên CPU chỉ liệt kê tiến trình có CPU ≥1% hoặc đang hạ. CÒN LẠI: theme tối, 980px/400px, chỉ bàn phím, lượt dọn thật trên fixture + PIN/admin/zip, giả lập thiếu RAM/ổ đầy (bước đầu đúng không), đếm chữ + grep tiếng Anh, so ảnh với bản mẫu docs/mockup (chủ sản phẩm nói UI chưa giống bản hứa: màn Ổ đĩa treemap 75% một khối "Users" ít thông tin, cột phải ngắn hơn cột trái; cần đối chiếu). Bộ slide: docs/Resource-Guard-gioi-thieu.pptx (build từ scratchpad/deck/build.js, ảnh chụp trước các sửa cuối).

## Ngoài phạm vi plan này

- Biểu tượng khay, cửa sổ app riêng (chủ sản phẩm chọn giữ trang web).
- Kết thúc tiến trình ngoài ledger, tự đóng ứng dụng, trim working set (chủ sản phẩm chọn giữ mức gợi ý).
- Thùng rác/giữ tạm trước khi xoá; quét tăng dần bằng USN.
