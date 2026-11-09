# Resource Guard — Technote

> Công cụ PowerShell quản lý dung lượng đĩa và bộ nhớ trên máy dev Windows: theo dõi liên tục, giao diện realtime trên localhost, agent AI chỉ *gợi ý*, và dọn nền tự động theo chính sách do người dùng đặt.
> Cập nhật: 2026-11-06. Nguyên tắc cốt lõi: **công cụ nắm toàn bộ dữ kiện và là bên duy nhất được xoá; AI chỉ đánh giá, không có quyền thực thi.**

---

## 1. Chạy nhanh

```powershell
# Khởi động watcher + UI (in URL, chạy nền)
powershell -NoProfile -File scripts\resource-manager.ps1 serve
# → Resource Guard chạy ngầm: http://localhost:8765/  (pid …)

# Đặt PIN (chỉ làm được ở console, không qua UI)
powershell -NoProfile -File scripts\resource-manager.ps1 serve setpin

# Dừng
powershell -NoProfile -File scripts\resource-manager.ps1 serve stop

# Test nghiệm thu (95 test, chạy được trên PS 7 và Windows PS 5.1)
pwsh -NoProfile -File tests\Acceptance.ps1
powershell -NoProfile -File tests\Acceptance.ps1
```

- Toolbox đăng ký: `resource-guard-manager` = `powershell -NoProfile -File scripts\resource-manager.ps1` + args `serve`.
- Dữ liệu runtime ở `~\.agent-resource\` (`state\`, log). Thư mục này nằm trong danh sách bảo vệ, không bao giờ bị dọn.
- Chu kỳ lấy mẫu mặc định **15 giây**, đổi ở trang Cài đặt.

## 2. Kiến trúc

```
resource-manager.ps1 serve
        │ (tiến trình nền, mutex Local\ResourceGuardWatcher)
        ▼
rg-server.ps1  ── vòng lặp đơn luồng: lấy mẫu → ghi state\live.json → phát SSE
   │  HttpListener localhost, REST + Server-Sent Events
   ├─ Start-RgJob ──► tiến trình ẩn riêng (không chặn watcher)
   │      rg-scan.ps1     quét đĩa / ứng viên dọn
   │      rg-cleanup.ps1  dọn mục người dùng tick
   │      rg-auto.ps1     một lượt dọn tự động theo chính sách
   │      rg-agent.ps1    gọi claude để đánh giá
   └─ ui\*  (vanilla JS, SVG, không phụ thuộc thư viện ngoài)
```

| Tệp | Vai trò |
|---|---|
| `rg-common.ps1` | Hàm dùng chung: log, ghi file atomic, đọc file chia sẻ (`Read-RgFileShared`), allowlist xoá, plan/approve/apply |
| `rg-policy.ps1` | Chính sách, PIN, engine tự động, trạng thái job (`Get/Write-RgJobState`) |
| `rg-server.ps1` | HTTP + SSE, router, auto-spawn khi chạm ngưỡng |
| `rg-scan.ps1` | Quét đĩa (nhân tố chiếm dung lượng) và danh sách ứng viên dọn |
| `rg-auto.ps1` | Một lượt dọn tự động trong process riêng |
| `rg-cleanup.ps1` | Dọn các mục người dùng chọn (theo key) |
| `rg-agent.ps1` | Dựng payload, prompt, gọi `claude`, lọc kết quả |
| `config.default.json` | Ngưỡng RAM/đĩa, nhóm tiến trình, đường dẫn cache, danh sách segment bảo vệ |

### Vì sao tách job ra process riêng
Quét đĩa mất 1–2 phút và agent mất ~40 giây. Làm trong vòng lặp watcher sẽ làm UI đứng và SSE ngắt. Job ghi tiến độ vào `state\<job>.progress.json`; server đọc qua `Get-RgJobState`. Job đang `running` mà pid đã chết được báo là `error`, tránh treo vĩnh viễn.

### Realtime
SSE thay cho polling. Mất kết nối thì UI tự nối lại. Mỗi tick server ghi `state\live.json` (RAM, commit, đĩa, CPU tổng, từng nhân, top CPU, số tiến trình, uptime, thông tin CPU) để job nền và agent dùng chung.

## 3. Giao diện

Sidebar + 6 trang, sáng/tối, responsive, có aria.

| Trang | Nội dung |
|---|---|
| Tổng quan | Mức RAM/đĩa (Normal → Critical), biểu đồ, cảnh báo |
| CPU & Tiến trình | Đồ thị tổng, lưới từng nhân, bảng tiến trình (gộp theo tên, sắp xếp, lọc, biểu tượng khiên) |
| Ổ đĩa | Donut theo nhóm; accordion liệt kê **mọi** nhân tố mỗi nhóm; chế độ Top 80; nút quét + tiến độ |
| Dọn dẹp | Bảng ứng viên, tick chọn, hộp xác nhận, kết quả lần dọn |
| Chính sách | Chế độ, ngưỡng kích hoạt, nhóm Tự động/Hỏi/Giữ, ưu tiên, vùng bảo vệ, chạy thử |
| Agent | Xem trước payload, chạy đánh giá, kết quả, áp gợi ý |

Kiểm thử UI bằng Edge headless qua CDP (`--screenshot` bị treo vì SSE nên không dùng được).

## 4. Chính sách tự động (`state\policy.json`)

| Trường | Giá trị / ý nghĩa |
|---|---|
| `mode` | `off` (mặc định) · `dry-run` · `on` |
| `diskTrigger` | `off` · `Caution` · `Critical` |
| `ramTrigger` | `off` · `Restricted` · `Critical` |
| `cooldownMin`, `maxGBPerRun`, `targetFreeGB`, `maxKillsPerRun` | Giới hạn mỗi lượt, kẹp bởi `ConvertTo-RgPolicy` |
| `categories` | `temp-entry`, `dotnet-artifact`, `cache-aged`, `node_modules`, `process` → `auto` / `ask` / `keep` |
| `priority` | Thứ tự dọn |
| `protectPaths` | So khớp tiền tố **hai chiều** (cha và con của vùng bảo vệ đều được giữ) |
| `protectProcesses` | Wildcard theo tên tiến trình |

Luồng một lượt tự động: `Get-RgStressInfo` → `Select-RgAutoItems` → `Invoke-RgAutoRun`.
- *Dry-run*: chỉ chọn và báo blocker, không xoá.
- *Real*: `New-RgPlan` → `Set-RgPlanApproval -By policy` → `Invoke-RgApply`.
- Nút "Chạy thử" dùng `-AssumeStress` để thử khi máy chưa tới ngưỡng.
- Server tự spawn `rg-auto.ps1 -Trigger state` khi mode ≠ off và `Test-RgAutoDue` (chốt 90 giây).

## 5. Dọn thủ công

UI chỉ gửi **key 12 hex**, không bao giờ gửi đường dẫn. `rg-cleanup.ps1` đọc lại `scan-candidates.json` và:
- từ chối mục `report` (chỉ báo cáo), mục nằm trong vùng bảo vệ, mục không còn trong danh sách;
- từ chối nếu dữ liệu quét cũ hơn **12 giờ**;
- đi qua plan → approve → `Invoke-RgApply` (có allowlist + revalidate);
- xoá mục đã xong khỏi danh sách ứng viên để UI không hiện lại.

## 6. Agent đánh giá

- Lệnh: `claude -p --model haiku --effort high`, schema qua `--json-schema`, prompt truyền bằng stdin (bytes).
- Payload **chỉ metadata** (tên, kích thước, tuổi, nhóm). Không gửi nội dung file; đường dẫn user profile thay bằng `~`. Có nút xem trước đúng payload sẽ gửi.
- Hậu xử lý:
  - bỏ mọi recommendation có key không nằm trong ứng viên (chống bịa);
  - mục thuộc vùng bảo vệ bị ép thành `keep`;
  - gợi ý chính sách trùng cài đặt hiện tại bị lọc.
- Gợi ý chỉ **chọn sẵn ô** ở trang Dọn dẹp; người dùng vẫn phải xác nhận.
- Đo thực tế: 1 lượt ≈ 37 giây, ≈ **$0.006**, payload ≈ 12 KB.

## 7. An toàn (các chốt chặn)

1. Tự động dọn **mặc định tắt**.
2. File cá nhân (Documents, Desktop, Downloads…) không bao giờ bị tự xoá; chỉ gợi ý.
3. Mọi lần xoá đi qua `Invoke-RgApply`; không có đường xoá khác.
4. Vùng bảo vệ luôn thắng — kể cả khi người dùng tick tay hoặc agent đề xuất.
5. Server chỉ nghe localhost, kiểm tra header `Host`; POST bắt buộc `X-RG-Client: ui`.
6. Static chỉ phục vụ whitelist đuôi css/js/svg.
7. **PIN** (PBKDF2, 120k vòng) bắt buộc khi chuyển sang mode `on` hoặc *nới lỏng* chính sách khi đang `on`; siết thêm bảo vệ thì không cần. Sai 5 lần → khoá 5 phút. Đặt PIN chỉ ở console.
8. Kill tiến trình chỉ với nhóm cho phép (`build`, `test`, `dev`), có giới hạn `maxKillsPerRun`.

## 8. API (rút gọn)

`GET /api/processes` · `/api/jobs` · `/api/disk` · `/api/candidates` · `/api/policy` · `/api/auto/last` · `/api/cleanup/last` · `/api/agent/{payload,last}`
`POST /api/disk/scan` · `/api/candidates/scan` · `/api/cleanup/apply` · `/api/policy` · `/api/auto/run` · `/api/agent/run`
Mã lỗi PIN: `pin-required` (không tính lần sai) · `pin-wrong` · `pin-locked` · `pin-not-set`.

## 9. Bẫy đã gặp (đọc trước khi sửa code)

| Bẫy | Cách xử lý |
|---|---|
| Windows PS 5.1: `-bor` trong danh sách đối số bị hiểu là mảng → `op_BitwiseOr` | Bọc ngoặc `([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)` |
| Thiếu BOM → 5.1 đọc `.ps1` sai tiếng Việt, lỗi parse | Mọi `.ps1` phải **UTF-8 BOM** |
| `Get-Content` không `-Encoding UTF8` làm hỏng tiếng Việt | Luôn chỉ định encoding (cả trong test) |
| `Sort-Object` không ổn định | Không dựa vào thứ tự phần tử bằng nhau |
| `Math.Max` với kiểu hỗn hợp | Ép `[long]` |
| `return , @()` làm hàm trả `Object[]` lồng | `ConvertTo-RgStringList` kết thúc bằng `return $out.ToArray()` |
| Tên hàm trùng alias PowerShell | Đặt tiền tố `Rg` |
| Lỗi route làm đứt kết nối im lặng | `catch` log `route-error` và trả JSON 500 |
| `msedge --screenshot` treo vì SSE | Dùng CDP qua node |

## 10. Giới hạn & việc có thể làm tiếp

- `Install-Watcher.ps1` (tự khởi động cùng Windows) chưa được cài trên máy này; hiện phải chạy `serve` thủ công.
- Quét đĩa là tác vụ nặng I/O 1–2 phút; chưa có quét tăng dần.
- Agent chỉ thấy metadata nên không phân biệt được file "trông như rác nhưng quan trọng" — đó là lý do cá nhân/không rõ nguồn gốc luôn ở dạng gợi ý.
- Chưa đo ảnh hưởng của chính watcher lên CPU/RAM trong nhiều giờ liên tục.
- Ảnh chụp di động sau khi sửa banner (`.alert` flex-wrap) chưa chụp lại.
