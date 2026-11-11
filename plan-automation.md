# Resource Guard — Plan lấp GAP và hướng tới trợ lý AI tự động hoá

> Lập ngày 2026-11-11. Nguồn quyết định: `docs/ui-yeu-cau-va-quyet-dinh.md` §3, §7–§11 (đi trước README/code khi mâu thuẫn). Khi được duyệt, bước đầu tiên là chép file này về gốc repo thành `plan-automation.md` (cùng quy ước với `plan-ux-impact.md`), commit: none.

## Context

22 phase của `plan-ux-impact` đã xong và đã commit (5d9a297; git đang sạch — ghi chú memory "chưa commit" đã cũ). Chủ sản phẩm chốt 2026-11-11: làm **trợ lý tự động hoá** song song với lấp GAP, không chờ UI xong. Người dùng phải *cảm nhận có một trợ lý AI quản lý máy mình*: báo cáo file nên xoá/nén/chuyển nhóm tự động, giải thích tiến trình (là gì, từ đâu, phục vụ việc gì).

Khảo sát code cho thấy nền đã khá chắc (plan→approve→apply, plan hash, revalidate, zip có xác minh, PIN, ledger, hạ ưu tiên đảo ngược được, `Get-RgProcIdentity`, `rg-agent.ps1` chỉ nhận metadata) nhưng còn các lỗ sau, chia làm hai nhóm:

**GAP độ tin cậy (phải đóng trước khi trao thêm quyền tự động)**
- Kill = `Stop-Process -Force` một PID, không đóng êm, không chờ/xác minh thoát, không xét cây tiến trình (`rg-common.ps1`:1167-1169). Ledger do agent tự đăng ký, không TTL/heartbeat, ghi không khoá (`Write-RgLedger` :275).
- Không có journal ghi trước; `Remove-RgTree` xoá dở thì chỉ báo `failed`; kind không nén (cache/temp) xoá vĩnh viễn.
- `Write-RgFileAtomic` (:40-52) nuốt lỗi lần cuối, `Write-RgLog` có `catch {}` rỗng → ổ C đầy thì state/log mất mà không báo. `plans\*.json` và `logs\rg-*.jsonl` không có retention.
- Không có benchmark/đo overhead watcher, không có CI; số test lệch (README 132 / 374 / plan-clarity 405).
- Config người dùng thay hẳn default (`rg-common.ps1`:24-28) → khoá mới thiếu ở máy cũ; `workspaceRoots` mặc định không khớp máy này; `Get-RgScanMaxAgeHours` luôn 12; tài liệu lỗi thời (TECHNOTE nhắc `p-clean.js`/`p-auto.js` không còn; README còn "không có nút kết thúc tiến trình").
- U7 (nhóm "Tệp tạm & cache" cần biết tiến trình nào đang giữ file) và "trang đầu trống tới 25 giây" chưa làm.

**GAP cho trợ lý (§7)**
- `large-item` chỉ quét con trực tiếp của Downloads/Videos, ngưỡng 500 MB (100 MB cho mục `young`) → mục nhẹ/góc khuất không bao giờ tới agent.
- Chưa có clustering, hồ sơ cụm, cache verdict `(path, size, mtime)`, giải thích tiến trình có nguồn gốc, hook Claude/Codex, đếm subagent, lease/giữ chỗ preflight, action registry có schema, mức tự chủ L0–L3 theo nhóm, vòng lặp đo lại, nút dừng khẩn cấp.

**Kết quả mong muốn**: sau plan này, trợ lý ở mức L1 (đề xuất, báo cáo theo cụm) cho mọi loại, L2 (chờ duyệt rồi dọn/nén) cho nhóm được cấp, L3 (tự động có ngân sách) cho nhóm đầu tiên "cache dev đủ tuổi" — và mọi mức đều **đáng tin khi tắt AI**.

## Giả định cần chủ sản phẩm xác nhận (các điểm còn mở ở §9)

1. Kết thúc tiến trình: một cú bấm + hộp xác nhận có trước → sau; **cần PIN** nếu tiến trình đang giữ lease/ledger của agent. Lớp tiến trình không bao giờ đủ điều kiện: hệ thống, bảo mật, dịch vụ, chính Resource Guard, vùng bảo vệ.
2. Preflight không có trả lời từ server: build/test **chạy tiếp** (ghi cảnh báo); subagent **bị chặn** khi Nguy cấp, **hoãn** khi Hạn chế.
3. Nhóm tự động đầu tiên: cache dev đủ tuổi (sau chế độ Chạy thử). File cá nhân mức cao nhất là **"chờ duyệt rồi nén"**, không bao giờ tự xoá. `node_modules`, `bin/obj` luôn xác nhận.
4. Job Object / giới hạn process group: ngoài phạm vi.
5. LLM giữ nguyên đường `claude -p --model haiku` trong `rg-agent.ps1`; không thêm nhà cung cấp; agent không đọc nội dung file, chỉ nhận metadata cụm; phần kết quả bị ép qua bộ lọc bảo vệ.

## Giai đoạn

Track A — Lấp GAP nền (tin cậy khi không có AI)
- [x] A1 Ghi bền vững: journal ghi trước, hết nuốt lỗi ghi file/log, retention plans/logs — touches: scripts/rg-common.ps1, scripts/rg-watcher.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] A2 Kill có xác minh + ledger có khoá/TTL/heartbeat + cây tiến trình — deps: A1 — touches: scripts/rg-common.ps1, scripts/Register-AgentProcess.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] A3 Xoá có thể khôi phục/tiếp tục: resume từ journal, rà kind nào xoá vĩnh viễn và đánh dấu "tái tạo được" — deps: A1 — touches: scripts/rg-common.ps1, scripts/rg-extra.ps1, scripts/rg-restore.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] A4 Config deep-merge với default, bỏ hardcode (scan max age, workspaceRoots, quét nền 10 phút), đồng bộ docs và số test — deps: A1 — touches: scripts/rg-common.ps1, config.default.json, scripts/rg-server.ps1, README.md, docs/TECHNOTE.md, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: medium — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`
- [x] A5 Số liệu: metrics hiệu quả (GB giải phóng, số lần khôi phục), đo overhead watcher, CI GitHub Actions windows-latest — deps: A2 — touches: scripts/rg-watcher.ps1, scripts/rg-insight.ps1, .github/workflows/ci.yml, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] A6 Trang đầu hiện dữ liệu từ API trước SSE (hết "đang kết nối…" 25s) — deps: A4 — touches: ui/boot.js, ui/core.js, ui/p-home.js — kind: code — model: sonnet — effort: medium — risk: low — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`

Track B — Quyền kết thúc tiến trình (§8)
- [x] B1 Eligibility theo allowlist lớp + route `POST /api/process/end` + nút trong trang Tiến trình + hộp xác nhận trước → sau; sửa test `Acceptance.ps1`:566 (đường kill dùng chung hàm của A2, `rg-proc.ps1` vẫn không tự gọi `Stop-Process`) — deps: A2 — touches: scripts/rg-proc.ps1, scripts/rg-server.ps1, scripts/rg-policy.ps1, ui/p-proc.js, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`

Track C — Lifecycle và probe
- [x] C1 Spike (không sửa code sản phẩm): xác minh giao thức hook Claude Code/Codex, `Zone.Identifier`, last-access time, Restart Manager (`RmGetList`) trên máy thật; ghi kết quả vào `docs/` — touches: scripts/spikes/hook-probe.ps1, scripts/spikes/rm-probe.ps1, docs/ui-yeu-cau-va-quyet-dinh.md — kind: code — model: sonnet — effort: high — risk: low — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File scripts/spikes/rm-probe.ps1 -Json`
- [x] C2 Probe tiến trình đang giữ file (C# 5 qua `Add-Type`) + nhóm "Tệp tạm & cache" (U7): mục bị giữ thì bỏ qua và ghi lý do — deps: C1, A3 — touches: scripts/rg-common.ps1, scripts/rg-scan.ps1, ui/p-disk.js, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] C3 Hook lifecycle + ledger hai tầng (khai báo qua hook + quan sát từ cây tiến trình), lease có fencing, giữ chỗ cho preflight, đếm subagent, chính sách khi server không trả lời; lệnh `rg.ps1 hooks print` in snippet, **không tự sửa settings của người dùng** — deps: C1, A2 — touches: scripts/rg-common.ps1, scripts/resource-manager.ps1, scripts/Register-AgentProcess.ps1, scripts/rg-server.ps1, rg.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`

Track D — Trợ lý hiểu máy (L0/L1, chỉ đọc, chạy thử)
- [x] D1 Kiểm kê metadata nhẹ `state\inventory.json`: Downloads/Documents/Desktop/góc khuất (`*.db`, `*.sqlite`, `*.bak`, `*.mdf` dưới AppData…) không còn ngưỡng 500 MB; chỉ path/size/mtime/ext/(atime, nguồn tải nếu C1 xác nhận) — deps: A4, C1 — touches: scripts/rg-scan.ps1, scripts/rg-extra.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] D2 Clustering tất định (không AI): gom theo thư mục cha, loại, tuổi, tổng dung lượng → cụm có `clusterId`, đặc trưng, "hơn 20 file xlsx trong Downloads, X MB, chưa đụng 90 ngày" — deps: D1 — touches: scripts/rg-insight.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] D3 Agent đánh giá theo cụm: payload có ngân sách token, schema verdict `keep|compress|clean|promote-auto`, cache verdict theo `(path, bậc dung lượng, mtime)`, hậu xử lý ép bảo vệ/bỏ key bịa; chạy được khi vắng `claude` (rơi về kết quả tất định) — deps: D2 — touches: scripts/rg-agent.ps1, scripts/rg-insight.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] D4 Giải thích tiến trình: mở rộng `Get-RgProcIdentity` với chuỗi cha, service, đường cài, chữ ký, "đang phục vụ job nào" (ledger/lease); agent chỉ diễn giải từ dữ liệu có cấu trúc — deps: C3, D3 — touches: scripts/rg-proc.ps1, scripts/rg-agent.ps1, ui/p-proc.js, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] D5 "Báo cáo của trợ lý" trên Trang chủ: cụm nên xoá / nén / chuyển nhóm auto; hành động đi qua pipeline hiện có, UI chỉ gửi `clusterId`/key, server tự giải ra đường dẫn; nén cụm = zip có xác minh — deps: D3, A3 — touches: scripts/rg-server.ps1, scripts/rg-cleanup.ps1, scripts/rg-extra.ps1, ui/p-home.js, ui/app.css, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`

Track E — Tự động có ngân sách (L2/L3)
- [x] E1 Action registry: mỗi action (`clean-cache`, `archive-cluster`, `lower-priority`, `end-process`) có schema, precondition, permission; Policy Engine là điểm thi hành duy nhất, agent chỉ chọn id — deps: B1, D5 — touches: scripts/rg-policy.ps1, scripts/rg-common.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] E2 Mức tự chủ L0–L3 theo nhóm trong `policy.json` (mặc định L1, sau thiết lập là Chạy thử); nhóm đầu "cache dev đủ tuổi"; UI chọn mức bằng câu mô tả + xem trước — deps: E1 — touches: scripts/rg-policy.ps1, ui/p-overview.js, ui/p-setup.js, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] E3 Vòng lặp phát hiện → tự dọn trong phạm vi → đo lại → dừng hoặc hỏi; chống lặp (báo một lần, kích hoạt lại khi xuống dưới mốc rồi vượt lại hoặc hết hoãn); banner Tổng quan khi vẫn vượt mốc — deps: E2 — touches: scripts/rg-auto.ps1, scripts/rg-policy.ps1, scripts/rg-server.ps1, ui/p-home.js, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [x] E4 Nâng/hạ mức theo số liệu: đề nghị nâng khi N lượt chạy thử không bị khôi phục (người dùng cấp bằng PIN); tự hạ khi bị khôi phục nhiều; nút dừng khẩn cấp (policy off + huỷ job) qua API/UI/`rg.ps1 panic` — deps: E3, A5 — touches: scripts/rg-policy.ps1, scripts/rg-insight.ps1, rg.ps1, ui/p-home.js, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`

Chốt
- [ ] F1 Kiểm toàn bộ trên PS 5.1 + kiểm tay UI (Edge, sandbox `AGENT_RESOURCE_HOME` riêng, không đụng dữ liệu thật) — deps: E4, D4, C2, A6 — kind: verify — model: sonnet — effort: low — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1 && powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [ ] F2 Tài liệu: README, TECHNOTE (kill từ app, action registry, mức L0–L3, cụm), ghi lại quyết định đã chốt; chụp lại `docs/img` — deps: F1 — touches: README.md, docs/TECHNOTE.md, docs/ui-yeu-cau-va-quyet-dinh.md — kind: code — model: sonnet — effort: low — risk: low — exit: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1`

hot-files: scripts/rg-common.ps1, scripts/rg-server.ps1, scripts/rg-policy.ps1, tests/Acceptance.ps1, ui/p-home.js
commit: none

Thứ tự gợi ý: A1 → (A2, A3, A4 song song được nếu không đụng cùng hàm; hot-files nên chạy tuần tự) → B1; C1 độc lập, chạy sớm; D1–D3 làm song song với track A/B sau khi C1 xong (phần báo cáo chỉ đọc, đúng §11 bước 4); E chỉ bắt đầu khi A2, A3, B1 xong — **không trao thêm quyền tự động trước khi nền kill/xoá có journal và xác minh**.

## Quy ước chung (mọi executor đọc)

Kế thừa nguyên văn từ `plan-ux-impact.md` mục "Quy ước chung", cộng thêm:

- Backend chạy trên **Windows PowerShell 5.1** (không cần `pwsh`); C# qua `Add-Type` là C# 5. Không thêm phụ thuộc. UI vanilla ES5.
- Mọi `*.ps1` là UTF-8 **BOM + CRLF**; ui js/css/html LF không BOM; README/TECHNOTE/plan CRLF. Sửa bằng công cụ Edit/Write, không `sed -i`, không viết chữ Việt vào `.ps1` từ bash heredoc.
- Bẫy PS 5.1: `ConvertFrom-Json '[]'` trả `$null`; `[math]::Max(0, <long>)` dùng `0L`; `Get-Content -Encoding UTF8`.
- Test chạy trong sandbox `%TEMP%`/`AGENT_RESOURCE_HOME` riêng; dừng mọi server Resource Guard trước khi chạy Acceptance (mutex toàn máy), chỉ dừng đúng PID mình tạo. **Không bao giờ dọn dữ liệu thật của người dùng** khi kiểm tay. Ổ C máy dev có thể gần đầy: kiểm dung lượng trống trước khi chạy.

**Bất biến an toàn không được đổi** (giữ nguyên các test hiện có; test nào buộc phải sửa — như `Acceptance.ps1`:566 ở B1 — thì ghi rõ lý do trong NOTES):
- `plan → approve → apply`, kiểm lại từng mục ngay trước khi thực thi, vùng bảo vệ thắng mọi thứ.
- Mục `young`, `report`, agent-keep không bao giờ tự dọn; file cá nhân không bao giờ tự xoá.
- **Agent đề xuất, Policy Engine thi hành.** Agent không phát shell command; chỉ chọn id action trong registry. Agent chỉ thêm được bảo vệ, không gỡ được, không tự cấp quyền xoá cho nhóm mới. Học tách khỏi đổi chính sách.
- UI chỉ gửi key/pid/clusterId, không bao giờ gửi đường dẫn để xoá. Kill chỉ sau khi `Test-RgProcessIdentity` khớp PID + start time + tên ngay trước khi thực thi.
- Phase 1 đáng tin khi **không có AI**: mọi tính năng mới phải có đường tất định khi vắng `claude`, và test chạy không cần AI.
- Không đổi các chuỗi `reason` hiện có ở backend.

**Khi xong phase**: ghi 1–5 dòng NOTES (`CONTRACT:` cho chữ ký phase sau cần). Không commit, không sửa plan.

## Hợp đồng dùng chung (chốt trước)

- **Journal** (A1): `state\journal.jsonl`, mỗi hành động ghi 2 dòng `intent` → `done|failed` có `actionId`, `planId`, `ts`, danh sách mục; khởi động server quét `intent` không có `done` để báo/resume. Dùng chung cho cleanup, kill, nén, đổi ưu tiên.
- **Kill có xác minh** (A2): `Stop-RgProcessVerified -Pid -Start -Name` → thử đóng êm → chờ N giây → buộc dừng → xác minh thoát; trả `{ok, method, exited, tree[]}`; B1/E1 chỉ gọi hàm này.
- **Cụm** (D2): `{clusterId, label, root, kind, count, totalBytes, oldestMtime, newestMtime, ageDays, sample[≤5 tên], protected:false, verdictKey}`; `clusterId` ổn định theo (root, kind, bậc tuổi).
- **Verdict** (D3): `{clusterId, verdict: keep|compress|clean|promote-auto, reason(vi), confidence, source: rule|agent}`; cache theo `(path, bậc dung lượng, mtime)` ở `state\verdicts.json`.
- **Action registry** (E1): `{id, schema, precondition(), permission: L1|L2|L3, reversible, needsPin}`; `Invoke-RgAction` là cửa duy nhất vào Policy Engine.
- **Mức tự chủ** (E2): `policy.json` → `autonomy.<group> = L0..L3`; thiếu khoá thì L1.

## Xác minh end-to-end

1. Mỗi phase: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Check-Syntax.ps1` (parse mọi `.ps1`, `node --check ui/*.js`); phase backend thêm `tests/Acceptance.ps1` (hiện ~374–405 test, phải giữ xanh và thêm test mới cho mỗi phase).
2. Test mới bắt buộc theo track: A (giả lập ngắt giữa chừng → journal resume; kill tiến trình giả lờ SIGTERM → buộc dừng + xác minh; ổ đầy → báo lỗi chứ không nuốt), B (tiến trình hệ thống/bảo mật/chính app → bị từ chối; PID bị tái sử dụng → từ chối), C (mục bị giữ bị bỏ qua kèm lý do; server không trả lời → đúng chính sách), D (fixture 25 file xlsx nhẹ → ra đúng 1 cụm; vắng `claude` → vẫn có báo cáo tất định; verdict bịa key bị loại), E (nhóm L1 không tự chạy; mục `young`/cá nhân không bao giờ tự xoá; bị khôi phục nhiều → tự hạ; nút dừng khẩn cấp → mọi job dừng).
3. F1: dựng server sandbox (`AGENT_RESOURCE_HOME` riêng, config trỏ tempRoot/cache giả), chạy playwright-core + Edge qua các route `#home #clean #disk #cpu #policy #settings`: báo cáo trợ lý → nén cụm → khôi phục; kết thúc một tiến trình giả; nâng mức nhóm bằng PIN; dừng khẩn cấp. Chụp ảnh 1440px/980px, sáng/tối, đối chiếu mockup.
4. Chế độ Chạy thử ở máy thật ≥ 1 tuần trước khi bật L3 cho nhóm đầu tiên (kiểm số liệu E4: số lượt, GB, số lần khôi phục).
