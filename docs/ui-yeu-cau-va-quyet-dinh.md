# Resource Guard — Yêu cầu UI và quyết định (ghi nhận 2026-11-11)

File này ghi lại điều chủ sản phẩm đã nói, tách khỏi plan phase. Khi mâu thuẫn với README hoặc code, **file này và mockup (`docs/mockup/index.html`) đi trước**.

## 1. Việc ưu tiên hiện tại

1. **UI phải rõ ràng trước.** Giao diện thực tế đang lệch mockup, xấu và lộn xộn.
2. **Luồng thủ công (manual) phải chạy đầy đủ**: xem ổ đĩa, hiểu cái gì chiếm chỗ, chọn nhóm, xem trước ảnh hưởng, dọn, khôi phục.
3. Agent AI và tự động hoá: từ 2026-11-11 chủ sản phẩm chọn hướng tự động hoá song song với việc lấp GAP (xem §7–§11). Ưu tiên 1 và 2 vẫn giữ.

## 2. Yêu cầu UI đã nêu

| # | Yêu cầu | Trạng thái |
|---|---|---|
| U1 | Treemap chỉ là **phản chiếu trực quan của donut**. Mỗi ô phải ứng với một phần của donut và rê chuột thấy đúng chi tiết phần đó. Không để một ô "Hệ thống" 29% diện tích mà không có thông tin | đã làm: treemap có ô "Hệ thống & chương trình" (gộp, tô màu như donut) và ô "Trống"; dải màu trong mỗi ô theo nhóm donut. Ô nhỏ hơn ~8px vẫn được vẽ tối thiểu 8px nên hơi phóng đại |
| U2 | Donut **luôn hiện**, kể cả khi chuyển sang "Danh sách lớn nhất" | đã làm: donut hiện cả ở "Danh sách lớn nhất" (chưa chụp ảnh riêng) |
| U3 | Một thanh dung lượng duy nhất, **mốc tự dọn kéo ngay trên thanh đó**. Không có thanh "tự dọn" riêng bên dưới | đã làm: một thanh 5 đoạn cùng màu donut, mốc kéo ngay trên thanh, dải trạng thái mỏng cùng thang |
| U4 | Khi không thao tác, mốc chỉ hiện nhãn ngắn "Tự dọn tại mốc này". Rê hoặc kéo mới hiện chi tiết | đã làm: nghỉ chỉ hiện "Tự dọn tại mốc này"; rê/kéo/focus hiện chi tiết, cập nhật theo lúc kéo |
| U5 | Mốc tự dọn diễn đạt theo **dung lượng đã dùng vượt mốc**, dễ hiểu hơn "trống bao nhiêu thì dọn" | đã làm: chi tiết ghi "Tự dọn khi đã dùng quá X GB (trống dưới Y GB · mức)" |
| U6 | Trang Bộ nhớ và tiến trình **không cần thanh riêng** cho Nguy cấp / Hạn chế / Cần chú ý. Dải trạng thái dán sát thanh, rê chuột mới có giải thích | đã làm cho trang Bộ nhớ: dải mỏng không chữ, giải thích khi rê chuột |
| U7 | Nhóm **"Tệp tạm & cache"**: giống PC Manager, mục cache/tạm **không có tiến trình nào đang dùng** thì vào nhóm dọn được. Mục đang bị tiến trình dùng thì bỏ qua và ghi chú rõ lý do | chưa làm: nhóm "Tệp tạm & cache" (xem mục 6) |

## 3. Vai trò của AI agent (định hướng, chưa làm vội)

Hai chức năng:
1. **Đánh giá và gợi ý** nên gỡ hay giữ một mục hoặc task.
2. **Hướng tới tự vận hành**: agent quản lý bộ nhớ theo rule do người dùng đặt.

Quyết định:
- AI chỉ là **một mức** của cơ chế, không phải điều kiện để app chạy.
- Tập trung trước vào việc agent **nhận thông tin từ tool để gợi ý và diễn giải**, tốn ít token.
- Phải đánh giá được càng nhiều càng tốt, kể cả app hoặc file (ví dụ DB) lâu ngày không dùng.
- Lưu kết quả theo `(đường dẫn, mức dung lượng, ngày sửa)` để không hỏi lại khi chưa đổi.

### Nguyên tắc kiến trúc (thảo luận 2026-11-11, chưa chốt thành spec)
- Agent **đề xuất**; Policy Engine và Orchestrator **thi hành**. Agent không phát shell command tuỳ ý, chỉ chọn từ danh sách action có schema, precondition, permission.
- Học (learning) tách khỏi đổi chính sách (policy change). Agent không tự cấp quyền xoá cho nhóm mới.
- Cấp tự chủ: L0 Quan sát, L1 Đề xuất, L2 Chờ duyệt rồi dọn, L3 Tự động trong phạm vi được cấp.
- Phase 1 phải đáng tin **khi không có AI**.

## 4. Luồng tự dọn: vấn đề chưa chốt

Mốc tự dọn chỉ là **điều kiện kích hoạt**, không phải đích phải đạt. Luồng chủ sản phẩm đề xuất:

1. Phát hiện áp lực dung lượng (trạng thái cảnh báo hoặc nguy cấp).
2. Tự dọn, chỉ trong các nhóm đã được cho phép tự động.
3. Đo lại và đánh giá trạng thái mới. Đã phục hồi thì **dừng**. Chưa phục hồi thì **hỏi người dùng** các mục cần duyệt.

Câu hỏi còn mở:
- Có cho nhóm "cần duyệt" (`node_modules`, `bin/obj`) tự dọn nếu người dùng bật riêng không? Đang nghiêng về **luôn xác nhận**.
- Trạng thái "vẫn vượt mốc sau khi tự dọn" hiển thị bằng banner trên Tổng quan hay thông báo hệ thống?
- Chống lặp: chỉ báo một lần, kích hoạt lại khi dung lượng xuống dưới mốc rồi vượt lại hoặc hết thời gian hoãn.
- Thanh dung lượng nên tô sẵn đoạn "dọn được tự động" và cảnh báo nếu mốc không thể đạt chỉ bằng tự dọn.

## 5. Nguyên tắc làm việc rút ra

- Đánh giá đàng hoàng rồi mới sửa. Không lao vào làm.
- Thêm, bỏ nút, màn, luồng phải đối chiếu mockup và file này trước.
- Kiểm bằng giao diện chạy thật, so với mockup, không chỉ test pass.

## 6. Tiến độ UI (2026-11-11)

Đã chỉnh trong `ui/viz.js`, `ui/p-disk.js`, `ui/p-proc.js`, `ui/app.css` và kiểm bằng ảnh chụp giao diện thật (Edge, 1440px, 980px, theme tối), kèm thao tác chuột:

- Luồng thủ công trên máy thật (không bấm xoá): chọn "Chọn mục rủi ro thấp" → thanh có đoạn gạch chéo "Sẽ dọn", chú thích "Trống 246 MB → 8,0 GB", nút "Dọn 4 mục (7,8 GB)" → hộp xác nhận đúng số liệu, có thanh trước → sau.
- Kéo mốc tự dọn bằng chuột: chi tiết đổi theo lúc kéo, thanh "Chính sách đã đổi" hiện, Huỷ thì trả về như cũ.
- Quét lại khi đã có kết quả: giữ bản đồ cũ kèm dòng "Đang quét lại…", không còn đổi sang cách phân loại khác rồi nhảy số.
- Kết quả dọn hiển thị tiếng Việt thay cho `deleted 1 files (0 MB) with admin rights`.

Chưa làm hoặc chưa kiểm:
- **U7** nhóm "Tệp tạm & cache" gom từ nhiều nơi (cần đối chiếu backend `New-CleanupPlan`/`rg-scan`).
- **Trang đầu bị trống tới 25 giây** ("đang kết nối…") khi chưa có mẫu SSE đầu tiên; cần hiển thị dữ liệu từ API trước.
- Một lượt dọn thật trên fixture (PIN, admin, zip), màn Tổng quan ở theme tối và 400px, chỉ bàn phím, ổ D.
- Bộ `tests/Acceptance.ps1` chưa chạy lại (ổ C của máy đang đầy, sợ ghi fixture); `Check-Syntax` đã OK.
- Số "14 ngày qua chạm … lần" trong chi tiết mốc chưa nối dữ liệu (đang bỏ qua nếu thiếu).

Ghi chú môi trường: ổ C của máy đang còn dưới 0,3 GB nên mọi thao tác ghi file (ảnh chụp, state) có thể lỗi `ENOSPC`.

## 7. Hướng trợ lý tự động hoá (chốt 2026-11-11)

Quyết định của chủ sản phẩm:

- Nhắm tới **agent tự động hoá**, làm song song với việc lấp GAP (xem §10), không chờ UI xong.
- Người dùng phải **cảm nhận có một trợ lý AI quản lý resource máy mình**: lập báo cáo những file nên xoá, nén hoặc nên chuyển nhóm sang mức tự động dọn. Với tiến trình, phải cho biết cái nào là cái nào, nguồn gốc, công việc nào đang dùng, để làm gì.
- **Không bắt agent đọc từng file.** Đơn vị đánh giá là **cụm** gom từ metadata, không phải từng mục đủ lớn. Ví dụ: hơn 20 file Excel trong Downloads (mỗi file nhẹ), database cũ lâu không dùng nằm ở góc khuất.
- Nguyên tắc ở §3 giữ nguyên: agent đề xuất, Policy Engine thi hành; học tách khỏi đổi chính sách; Phase 1 phải đáng tin khi không có AI.

Vấn đề hiện tại dẫn tới quyết định này: theo README, `large-item` chỉ nhận mục từ 500 MB và mục chưa đủ tuổi phải từ 100 MB (`cleanup.youngMinMB`) mới vào danh sách. Mục nhẹ hoặc ở góc khuất không bao giờ đến được agent đánh giá.

## 8. Kết thúc tiến trình từ app (đảo quyết định cũ, 2026-11-11)

- Chủ sản phẩm muốn người dùng **kết thúc tiến trình ngay trong app** thay vì mở Task Manager. Quyết định này **thay thế** câu "không có nút kết thúc tiến trình" ở README (mục Tiến trình), TECHNOTE §8 (route `/api/process/priority`) và dòng 2 của `scripts/rg-proc.ps1`. Các nơi đó **chưa được sửa**.
- Tiến trình quan trọng (hệ thống, bảo mật, dịch vụ, chính Resource Guard, vùng người dùng đã bảo vệ) **không bao giờ** nằm trong danh sách có thể kết thúc.
- Số phận của một tiến trình do kết quả đánh giá quyết định.

Ghi chú thiết kế (đề xuất, chưa chốt):

- Danh sách đủ điều kiện xây theo allowlist theo lớp, không chỉ denylist (cùng nguyên tắc với `Get-RgDeleteBlocker`).
- Kết thúc êm trước, buộc dừng sau; kiểm lại PID + start time + tên bằng `Test-RgProcessIdentity` ngay trước khi thực thi; tiến trình đang giữ lease của agent thì cảnh báo rõ.
- Hiện kill chỉ đi qua `Invoke-RgApply` cho tiến trình có trong ledger và thuộc nhóm build/test/dev (`scripts/rg-common.ps1`:1122-1133). Đường kết thúc cho tiến trình ngoài ledger chưa tồn tại.

## 9. Câu hỏi còn mở

- Cơ chế duyệt kết thúc tiến trình: một cú bấm hay cần PIN.
- Chính sách khi preflight không nhận được trả lời từ server: build/test cho chạy tiếp hay chặn; subagent khi máy ở trạng thái Hạn chế hoặc Nguy cấp.
- Job Object và giới hạn process group (ép giới hạn RAM/CPU lên cả nhóm tiến trình ở tầng Windows): chưa quyết, đề xuất để ngoài phạm vi.
- Mức tự động cao nhất cho file cá nhân (hiện không bao giờ tự xoá, TECHNOTE §7.2). Đề xuất: "chờ duyệt rồi nén".
- Nhóm tự động đầu tiên sau chế độ chạy thử. Đề xuất: cache dev đủ tuổi.
- Đã xác minh ở spike C1 (xem §12): `Zone.Identifier`, thời gian mở file gần nhất, Restart Manager (giữ file), hook Claude Code. Còn chưa xác minh: giao thức hook của Codex (máy dev không cài), `SubagentStop`/`PreToolUse` trong thực tế.

## 10. Đánh giá GAP (2026-11-11, đối chiếu code)

| GAP | Trạng thái | Bằng chứng |
|---|---|---|
| Ownership và lifecycle | Nền đã có (định danh PID + start + tên, ledger có chủ, orphan). Còn thiếu: ledger do agent tự đăng ký, không có TTL/heartbeat, không có cây tiến trình, kill chỉ một PID | `rg-common.ps1`:254-260, :282-320, :1168 |
| Tiến trình nào được xử lý | Gần như đã có: nhóm cho phép + phải có trong ledger + giới hạn mỗi lượt | `rg-common.ps1`:1122-1133 |
| Quản lý trước khi workload chạy | Preflight chỉ kiểm tra tại một thời điểm: chưa giữ chỗ, chưa có hook Claude/Codex, chưa đếm subagent đang chạy | `rg-common.ps1`:427-483; README (mục giới hạn) |
| Cleanup phục hồi và xác minh | Đã có plan hash, approval, revalidate, zip có xác minh. Còn thiếu: kill chưa chờ và xác minh thoát, kind không nén xoá thẳng, chưa có journal ghi trước | `rg-common.ps1`:1042-1107, :1144-1147, :1170-1188, :1168-1169 |
| Benchmark | Đã có từ A5 (`tests/Bench-Watcher.ps1`). Acceptance chạy lại 2026-11-11: 725 pass / 0 fail; README và TECHNOTE đã đồng bộ 725 | `tests/Acceptance.ps1`; §6 |
| U7 (nhóm "Tệp tạm & cache") | Chưa làm, cần biết tiến trình nào đang giữ file | §2 |

## 11. Lộ trình đề xuất (chưa chốt)

1. Số liệu và hậu kiểm: journal, kill có xác minh, metrics, đo overhead watcher.
2. Hook lifecycle và ledger hai tầng (khai báo + quan sát).
3. Lease có fencing, giữ chỗ cho preflight, probe tiến trình đang giữ file (U7).
4. Trợ lý hiểu máy ở chế độ chạy thử: cụm, hồ sơ từng cụm, báo cáo, giải thích tiến trình. Phần báo cáo chỉ đọc nên có thể làm song song từ bước 2.
5. Tự động có ngân sách: vòng lặp thi hành trong phạm vi được cấp, đề nghị nâng mức theo số liệu (người dùng cấp bằng PIN), tự hạ mức khi bị khôi phục nhiều, có nút dừng khẩn cấp.

## 12. Kết quả spike C1 (2026-11-11, máy dev Windows 11 build 26200, không admin)

Chạy bằng `scripts/spikes/rm-probe.ps1 -Json` và `scripts/spikes/hook-probe.ps1 -Json` (chỉ đọc, file tạm trong `%TEMP%`, tự xoá). Trả lời mục "Chưa xác minh" ở §9.

| Câu hỏi | Kết quả | Hệ quả cho phase sau |
|---|---|---|
| Restart Manager (`RmGetList`) cho biết process nào đang giữ file, không cần admin? | Có. Thấy cả process hiện tại, process con, và file mở `FileShare.None`; trả PID, tên, loại (`console`, `service`…), start time khớp `Win32_Process.CreationDate`. ~11–14 ms/lần hỏi. | C2 dùng được. Start time cho phép kiểm danh tính (PID + start). |
| RM với **thư mục**? | Không: `RmGetList` trả lỗi 5 (access denied) khi đăng ký thư mục. | C2 phải hỏi **từng file** (mẫu giới hạn, ưu tiên file lớn/mới sửa), không hỏi cả thư mục; mục không probe được thì coi là "không rõ", không xoá tự động. |
| `Zone.Identifier` (nguồn tải) đọc được bằng PS 5.1? | Có: `Get-Content -Stream Zone.Identifier` đọc `ZoneId`, `HostUrl`; `Copy-Item` giữ luồng. | D1 có thể ghi `zoneId` (chỉ số, không ghi URL vào payload gửi agent). Mục không có luồng này là bình thường. |
| Thời gian truy cập cuối (atime) có cập nhật? | Máy này: `DisableLastAccess = 2` (hệ thống quản lý, **bật**); đọc file làm atime nhảy. Máy khác có thể tắt (giá trị 1/3). | D1 chỉ dùng atime như gợi ý phụ, luôn kèm mtime; không tin atime khi `fsutil` báo tắt. |
| Hook của Claude Code chạy được với settings tạm (`claude -p --settings <file>`)? | Có, không động tới `~/.claude/settings.json`. Hook nhận **JSON qua stdin**. Sự kiện quan sát: `SessionStart` (`source`), `UserPromptSubmit`, `Stop`, `SessionEnd` (`reason`). `PreToolUse`, `PostToolUse`, `SubagentStop` có khai báo nhưng chưa kích hoạt vì lượt thử không dùng tool. | C3 dùng `SessionStart/SessionEnd` để đăng ký/huỷ lease, `Stop` để heartbeat. Đếm subagent qua `SubagentStop` cần kiểm thêm trong C3 bằng một lượt có Task. |
| Trường chung của payload hook | `session_id`, `transcript_path`, `cwd`, `hook_event_name`; thêm theo sự kiện (`source`, `reason`, `prompt`, `permission_mode`, `last_assistant_message`…). | Ledger lấy `session_id` làm khoá lease; **không** lưu `prompt`/`last_assistant_message`/`transcript_path` vào state. |
| Codex? | Máy này **không cài** `codex`: giao thức chưa xác minh. | C3 chỉ hỗ trợ Claude Code bằng hook; tiến trình Codex vẫn được quan sát qua cây tiến trình (tầng 2 của ledger). |

Ghi chú: CLI `claude` in cảnh báo đăng nhập hết hạn trên stderr nhưng lượt thử vẫn chạy (exit 0). Spike không đổi code sản phẩm.

## 13. Kết quả triển khai `plan-automation` (2026-11-11)

Đã làm A1–E4 (journal, kill có xác minh, ledger hai tầng + hook, kiểm kê → cụm → báo cáo trợ lý, giải thích tiến trình, action registry, mức tự chủ L0–L3, chống lặp, tự hạ mức, dừng khẩn cấp). Cách chi tiết ở TECHNOTE §7 và §8, README mục "Trợ lý tự động hoá".

**Các giả định ở §9 đã được áp dụng trong code và chủ sản phẩm đã xác nhận cả 5 (2026-11-11):**
1. Kết thúc tiến trình: một cú bấm + hộp xác nhận trước → sau; chỉ cần PIN khi tiến trình đang giữ lease/ledger của agent.
2. Preflight không có trả lời từ server: build/test chạy tiếp (ghi cảnh báo); subagent bị chặn khi Nguy cấp, hoãn khi Hạn chế.
3. Nhóm tự động đầu tiên là cache dev đủ tuổi; file cá nhân tối đa là “duyệt rồi nén”, không bao giờ tự xoá; `node_modules`, `bin/obj` luôn cần xác nhận (trần L2).
4. Job Object: ngoài phạm vi.
5. Giữ `claude -p --model haiku`; payload chỉ metadata cụm.

**Chỗ lệch khỏi plan hoặc giới hạn đã biết:**
- Mức mặc định là L1, nhưng nhóm có category cũ (`cache-aged`, `temp-entry`…) kế thừa category (auto=L3, ask=L2, keep=L0) để không đổi hành vi dọn tự động hiện có của người đã dùng.
- `Documents` và `Desktop` nằm trong `protected.segments` mặc định nên cụm file thực tế chỉ ra từ `Downloads` (và cụm góc khuất ở `AppData`, chỉ báo cáo). Người dùng muốn trợ lý nhìn thư mục khác phải sửa danh sách bảo vệ.
- D4: giải thích tiến trình hoàn toàn tất định; chưa cho agent diễn giải lại dữ liệu có cấu trúc.
- Hook chỉ có cho Claude Code (`rg hooks print`, không tự sửa settings); Codex chưa xác minh giao thức nên chỉ quan sát qua cây tiến trình.
- Chưa bật L3 cho nhóm nào ở máy thật: cần chạy thử ≥ 1 tuần rồi xem số liệu ở thẻ Mức tự chủ.
- `docs/img` đã chụp lại sau đợt đổi UI (2026-11-11), trên sandbox trống dữ liệu: ô "Việc có thể làm" và "Báo cáo của trợ lý" đang ở trạng thái trống trong ảnh.
- E2e trên fixture (scratchpad, config override trỏ vào fixture): nén cụm xlsx và khôi phục — đã chạy; PIN nâng L3 (sai PIN, thiếu PIN, đúng PIN) và dừng khẩn cấp (bật on → panic → off) — đã chạy. **Chưa xong:** kết thúc tiến trình giả — `/api/processes` chưa đưa tiến trình node mới vào cache sau ~1 phút (nhóm `other`, `start` rỗng), nên server từ chối kết thúc; hành vi an toàn nhưng chưa rõ chu kỳ làm mới cache.
- **Lỗi đã sửa trong đợt này:** khôi phục song song làm mất cờ `restoredUtc` (archives.json đọc-sửa-ghi không khoá: 12 job → mất 11). Nay có khoá `Local\ResourceGuardArchives` và đọc nghiêm ngặt; test hồi quy trong `Acceptance-Auto.ps1`.
- **Chưa quyết định (cần chủ sản phẩm):** ước lượng dung lượng khi nén cố định 50% (`rg-assistant.ps1`), nên cụm `.xlsx` (vốn là zip) báo "tiết kiệm ~39 MB" nhưng thực tế giải phóng 0. Đề xuất: loại đuôi đã nén (xlsx, docx, pptx, zip, jpg, mp4…) khỏi verdict `compress`. Đổi này làm đổi 4 khẳng định trong `Acceptance-Auto.ps1` (dòng 429, 449, 502, 608) và cần duyệt trước.
