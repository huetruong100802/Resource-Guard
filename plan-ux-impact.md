# Resource Guard — Plan cải tiến UI/UX "thấy trước ảnh hưởng"

> Lập ngày 2026-11-10. Plan theo định dạng skill `plan-phases` (gate: `~/.claude/skills/plan-phases/scripts/plan-gate.ps1`).
> Phiên chính điều phối; mỗi executor chỉ làm MỘT phase, đọc mục "Quy ước chung" + đặc tả phase của mình.

## Mục tiêu sản phẩm (nguồn chân lý)

Resource Guard = trợ lý quản lý tài nguyên máy tính tự động. 4 nhiệm vụ: Monitor, Manage, Optimize, Automate. Agent là trợ lý, không phải trung tâm. Thành công = người dùng gần như không cần quan tâm, nhưng máy luôn sẵn sàng.

Bốn yêu cầu của chủ sản phẩm mà plan này phải đạt:

1. **Thấy trước ảnh hưởng.** Mọi hành động (xoá, bảo vệ, hạ ưu tiên tiến trình, đổi chính sách) phải cho người dùng thấy bằng hình: mục này nằm ở đâu, chiếm bao nhiêu, trước → sau thế nào, và sau khi làm thì để lại dấu trên biểu đồ.
2. **Trợ lý lấp khoảng trống "không biết nên làm gì".** Thay vì đổ cả danh sách, app đưa một kế hoạch ngắn có thứ tự: làm gì trước, được bao nhiêu, vì sao, hậu quả gì.
3. **Tự động hoá hiểu được.** Người dùng thấy ngay chính sách này sẽ làm gì, hiệu quả ra sao, và chỉnh bằng thao tác trực quan.
4. **Nhanh.** Quét ổ tập trung vào phần dọn được, bỏ qua phần cố định; kết quả hiện dần; nhiều thông tin nhưng không ngợp.

## Giai đoạn

- [ ] P1 Biên lai ứng viên + Check-Syntax — touches: tests/Check-Syntax.ps1, scripts/rg-common.ps1, scripts/rg-scan.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P2 Lịch sử theo tiến trình — deps: P1 — touches: scripts/rg-watcher.ps1, scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P3 Insight: sẵn sàng + dự báo — deps: P2 — touches: scripts/rg-insight.ps1, scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P4 Advice: kế hoạch đề xuất tất định — deps: P3 — touches: scripts/rg-insight.ps1, scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P5 Xem trước chính sách + bằng chứng chạy thử — deps: P4 — touches: scripts/rg-policy.ps1, scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P6 Hạ ưu tiên tiến trình (đảo ngược được) — deps: P5 — touches: scripts/rg-proc.ps1, scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `pwsh -NoProfile -File tests/Acceptance.ps1`
- [ ] P7 Setup API + thông báo tiếng Việt — deps: P6 — touches: scripts/rg-server.ps1, scripts/rg-watcher.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: medium — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P8 Kiểm backend trên cả hai PowerShell — deps: P7 — kind: verify — model: sonnet — effort: low — exit: `pwsh -NoProfile -File tests/Acceptance.ps1 && powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [ ] P9 Scanner v2: Win32 enumerator, vùng quét, cây thư mục — deps: P8 — touches: scripts/rg-scan.ps1, scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: opus — effort: high — risk: high — exit: `pwsh -NoProfile -File tests/Acceptance.ps1`
- [ ] P10 Quét nền tự làm mới — deps: P9 — touches: scripts/rg-server.ps1, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: medium — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P11 Spike: đọc USN journal không cần admin — touches: scripts/spikes/usn-probe.ps1 — kind: code — model: sonnet — effort: high — risk: low — exit: `pwsh -NoProfile -File scripts/spikes/usn-probe.ps1 -Drive C -Json`
- [ ] P12 Khung UI: điều hướng mới, ngôn ngữ, giờ địa phương — deps: P8 — touches: ui/boot.js, ui/core.js, ui/index.html, ui/app.css, ui/p-overview.js — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P13 Thư viện hình ảnh hoá viz.js — deps: P12 — touches: ui/viz.js, ui/core.js, ui/app.css, ui/index.html — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P14 Trang chủ: sẵn sàng, kế hoạch đề xuất, hoạt động — deps: P13 — touches: ui/p-home.js, ui/p-overview.js, ui/boot.js, ui/index.html, ui/app.css — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P15 Trang Dọn dẹp: nhóm theo bước, thanh ảnh hưởng trực tiếp — deps: P14 — touches: ui/p-clean.js, ui/app.css — kind: code — model: sonnet — effort: high — risk: high — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P16 Trang Tự động hoá: câu mô tả, kéo ngưỡng, xem trước — deps: P15 — touches: ui/p-auto.js, ui/p-clean.js, ui/index.html, ui/app.css — kind: code — model: sonnet — effort: high — risk: high — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P17 Trang Ổ đĩa: treemap đào sâu + lớp phủ hành động — deps: P16, P10 — touches: ui/p-disk.js, ui/app.css — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P18 Trang Tiến trình: ai đang chiếm, dòng thời gian, what-if — deps: P17 — touches: ui/p-proc.js, ui/p-overview.js, ui/index.html, ui/app.css — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P19 Trợ lý: agent hoà vào kế hoạch, bỏ tab riêng — deps: P18 — touches: scripts/rg-agent.ps1, ui/p-agent.js, ui/p-home.js, ui/p-clean.js, ui/boot.js, tests/Acceptance.ps1 — kind: code — model: sonnet — effort: high — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P20 Thiết lập lần đầu trong UI — deps: P19 — touches: ui/p-setup.js, ui/boot.js, ui/index.html, ui/app.css — kind: code — model: sonnet — effort: medium — risk: medium — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
- [ ] P21 Kiểm toàn bộ — deps: P20, P11 — kind: verify — model: sonnet — effort: low — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1 && pwsh -NoProfile -File tests/Acceptance.ps1 && powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/Acceptance.ps1`
- [ ] P22 Tài liệu — deps: P21 — touches: README.md, docs/TECHNOTE.md — kind: code — model: sonnet — effort: low — risk: low — exit: `pwsh -NoProfile -File tests/Check-Syntax.ps1`
hot-files: scripts/rg-server.ps1, ui/core.js, ui/boot.js, ui/index.html, ui/app.css, ui/p-clean.js, tests/Acceptance.ps1
commit: none
workdir: C:/Users/HueTruong/Work/Repositories/Researchs/DEVELOPER WORKSPACE JANITOR/resource-guard

## Điều chỉnh

- PLAN: Giả định chưa được chủ sản phẩm xác nhận: (a) sau thiết lập lần đầu, chế độ tự động mặc định là **Chạy thử**; (b) KHÔNG mở rộng quyền kết thúc tiến trình ngoài ledger agent, chỉ thêm "hạ ưu tiên" (P6). Nếu chủ sản phẩm quyết khác, sửa P6/P20 trước khi dispatch.
- PLAN: Phase "quét tăng dần bằng USN journal" CHƯA có trong danh sách. Chỉ lập sau khi P11 trả kết quả (xem "Quyết định thiết kế › Quét ổ").
- PLAN: Mọi phase UI dùng chung `ui/app.css` nên chạy tuần tự (`-MaxParallel 1`). P11 độc lập, có thể chạy bất cứ lúc nào.

---

## Quy ước chung (mọi executor đọc)

**Ràng buộc kỹ thuật**
- Không thêm phụ thuộc. Backend là PowerShell chạy được trên **cả 5.1 và 7+**; C# nhúng qua `Add-Type` phải là **cú pháp C# 5** (không `?.`, `$""`, `out var`, expression-bodied, pattern matching).
- UI là vanilla JS kiểu ES5 như code hiện có (`var`, `function`, IIFE, đăng ký vào `window.RG`), SVG tự vẽ, không thư viện ngoài.
- File tĩnh mới phải khớp regex route hiện có `^/static/([a-z0-9._-]+\.(css|js|svg))$` và được thêm thẻ `<script>` trong `ui/index.html` **trước** `boot.js`.
- Mọi POST cần header `X-RG-Client` (đã có trong `RG.api`). UI **chỉ gửi key/pid, không bao giờ gửi đường dẫn** để xoá.
- Việc dài chạy qua `Start-RgJob` (process riêng) + file `state\<job>.progress.json`; server là vòng lặp đơn luồng, route mới phải trả trong vài chục ms (đọc file cache, không quét).
- Ghi file bằng `Write-RgFileAtomic`. Ghi log bằng `Write-RgLog '<event>' <data>`.

**Bất biến an toàn không được đổi** (đều có test, không sửa test để né)
- `plan → approve → apply`; kiểm lại từng mục ngay trước khi thực thi; vùng bảo vệ thắng mọi thứ.
- Mục `young`, `report`, agent-keep không bao giờ tự dọn. Không kill tiến trình ngoài ledger.
- Agent chỉ nhận metadata, chỉ thêm được bảo vệ, không gỡ được.
- **Không đổi các chuỗi `reason` hiện có** ở backend (`rg-common.ps1`, `rg-policy.ps1`, `Get-RgBudget`): test đang so khớp chúng. Chữ cho người dùng lấy từ trường mới (P1) hoặc dựng ở UI từ dữ liệu có cấu trúc.

**Nguyên tắc UX áp cho mọi trang**
- *Một câu trước, số liệu sau.* Mỗi khối mở đầu bằng một câu tiếng Việt thường ("Ổ C sắp đầy, còn khoảng 9 ngày"), chi tiết kỹ thuật nằm dưới hoặc trong ngăn kéo.
- *Trước → sau.* Bất kỳ nút nào thay đổi trạng thái máy đều đi kèm hình trước → sau (thanh ảnh hưởng) ngay cạnh nút, cập nhật khi người dùng tick/kéo.
- *Tối đa 3 cấp.* Tóm tắt (luôn thấy) → nhóm (mở ra) → mục (ngăn kéo). Không đưa bảng phẳng hơn 12 dòng lên cấp đầu.
- *Hành động để lại dấu.* Sau khi làm, biểu đồ liên quan có điểm đánh dấu và trang Hoạt động có một dòng biên lai.
- Từ dùng cho người dùng: Ổn / Cần chú ý / Hạn chế / Nguy cấp (thay Normal/Caution/Restricted/Critical); "Bộ nhớ cam kết" (thay Commit); "mục có thể dọn" (thay ứng viên). Giờ hiển thị là giờ địa phương.
- Giữ được: bàn phím (Tab/Enter/Esc), `aria-*`, theme sáng/tối bằng biến CSS sẵn có, `prefers-reduced-motion`, bố cục ≤ 980px.

**Khi xong phase**: ghi 1–5 dòng NOTES (`CONTRACT:` cho chữ ký phase sau cần). Không commit, không sửa plan.

---

## Hợp đồng dùng chung (chốt trước, không đổi giữa chừng)

### Dữ liệu backend

**Biên lai mục dọn (P1)** — thêm vào mỗi phần tử `items[]` của `state\scan-candidates.json` và `GET /api/candidates`:

| Trường | Kiểu | Ý nghĩa |
|---|---|---|
| `why` | string (vi) | Vì sao mục này được đề xuất, kèm con số ("File tạm không được dùng 197 ngày") |
| `impact` | string (vi) | Chuyện gì xảy ra sau khi xoá |
| `regen` | `auto` \| `rebuild` \| `redownload` \| `restore-zip` \| `none` | Cách lấy lại |
| `regenHint` | string (vi) | Cách lấy lại, viết cho người dùng |
| `riskLevel` | `low` \| `medium` \| `high` | Mục `young` tăng một bậc |

Bảng ánh xạ theo `kind` (dựng ở MỘT hàm `Get-RgItemReceipt`, gọi cuối `Get-RgCandidates`; không sửa từng lời gọi `New-RgItem`):

| kind | impact | regen | riskLevel |
|---|---|---|---|
| `temp-entry` | Không ảnh hưởng; chương trình tự tạo lại khi cần | auto | low |
| `dotnet-artifact` | Lần build kế tiếp của dự án này chậm hơn vì build lại từ đầu | rebuild | low |
| `node_modules` | Phải chạy lại lệnh cài gói trước khi chạy dự án; cần mạng | redownload | medium |
| `cache-aged` | Lần restore sau tải lại gói còn thiếu; cần mạng | redownload | low (toàn bộ cache: medium) |
| `stale-repo` | Mã đã có trên remote, clone lại khi cần; có bản zip nếu chọn nén | restore-zip | medium |
| `large-item` | Không tự tạo lại được; có bản zip nếu chọn nén | restore-zip | high |
| `process` | Tiến trình bị kết thúc; việc chưa lưu trong tiến trình đó sẽ mất | none | medium |
| `app`, vhdx (report) | Chỉ báo cáo; Resource Guard không xoá loại này | none | high |

**`GET /api/process/history?name=<tên>&min=<phút, mặc định 60, tối đa 1440>` (P2)**
```json
{ "name": "node", "totalRamMB": 16270,
  "points": [ { "ts": "2026-11-10 17:04:12", "cpu": 12.5, "ramMB": 1683, "n": 7 } ] }
```
Nguồn: trường mới `procTop` trong mỗi bản ghi `metrics-*.jsonl` = top 12 **nhóm theo tên** xếp theo RAM, hợp với top 8 theo CPU: `[{ name, n, cpu, ramMB }]`. Điểm thiếu (tiến trình không nằm trong top) bị bỏ, không nội suy. SSE `live` cũng mang `procTop`.

**`GET /api/insight` (P3)**
```json
{ "readiness": [ { "task": "build", "ok": true, "needGB": 2.0, "haveGB": 5.1, "blocker": "" },
                 { "task": "test",  "ok": false, "needGB": 3.0, "haveGB": 2.1, "blocker": "ram" } ],
  "drives": [ { "drive": "C", "freeGB": 8.6, "state": "Critical",
                "slopeGBPerDay": -0.9, "daysToCaution": 0, "daysToCritical": 0, "daysToFull": 9,
                "confidence": "medium", "sampleDays": 11,
                "goal": { "toState": "Normal", "needGB": 11.4 } } ],
  "ram": { "availGB": 2.1, "state": "Restricted", "goal": { "toState": "Normal", "needGB": 2.9 } } }
```
- `readiness`: gọi `Get-RgBudget -Task build|test|subagent` với snapshot + bảng tiến trình server đang giữ (không lấy mẫu mới).
- Dự báo: hồi quy tuyến tính trên mẫu ổ đĩa lấy thưa (mỗi giờ một điểm) từ tối đa 14 file metrics; đọc file theo `-Tail`/lấy thưa, cache kết quả 10 phút trong server. `confidence`: `low` nếu < 3 ngày dữ liệu hoặc dốc ≥ 0 (khi đó các `daysTo*` là `null`), `medium` 3–7 ngày, `high` > 7 ngày.
- `goal.needGB` = lượng còn thiếu để về ngưỡng Ổn của chính ổ đó (ngưỡng từ `Get-RgDrives`/config); `null` nếu đã Ổn.

**`GET /api/advice` (P4)** — kế hoạch đề xuất tất định, không cần LLM:
```json
{ "generatedUtc": "...", "candidatesUtc": "...", "stale": false,
  "goals": [ { "drive": "C", "freeGB": 8.6, "needBytes": 12240000000, "toState": "Normal" } ],
  "steps": [ { "id": "C:cache-aged", "drive": "C", "kind": "cache-aged", "title": "Gói NuGet không dùng 14 ngày",
               "keys": ["ab12..."], "count": 1, "bytes": 7840000000,
               "riskLevel": "low", "regen": "redownload", "regenHint": "...", "why": "...", "impact": "...",
               "auto": "ask", "cumBytes": 7840000000, "reachesGoal": false, "agent": null } ],
  "review": { "count": 3, "bytes": 0, "keys": ["..."] },
  "afterPlan": [ { "drive": "C", "freeGB": 16.4, "state": "Caution", "shortBytes": 4400000000 } ],
  "beyond": [ { "drive": "C", "cat": "programs", "bytes": 54800000000, "hint": "Gỡ ứng dụng ít dùng ở Cài đặt > Ứng dụng" } ] }
```
Quy tắc (ghi nguyên vào docstring hàm `Get-RgAdvice`):
1. Loại: `action=report`, mục trong vùng bảo vệ, agent-keep. Mục `young` và mục `needsAdmin` vào `review`, không vào `steps`.
2. Gộp theo `(drive, kind)` thành bước. Điểm bước = Σ bytes × hệ số regen (`auto` 1.0, `rebuild` 0.9, `redownload` 0.7, `restore-zip` 0.4, `none` 0.3) × hệ số rủi ro (`low` 1.0, `medium` 0.6, `high` 0.3).
3. Sắp theo điểm giảm dần trong từng ổ; ổ có `goal` đứng trước. Bước < 50 MB gộp vào một bước "Các mục nhỏ". Tối đa 5 bước mỗi ổ.
4. `cumBytes` cộng dồn; `reachesGoal=true` ở bước đầu tiên làm tổng ≥ `needBytes`.
5. `afterPlan` = trạng thái ổ nếu làm hết các bước; `shortBytes` > 0 nghĩa là dọn hết vẫn chưa đủ → UI hiện `beyond` (3 nhóm lớn nhất từ `scan-breakdown` không thuộc loại dọn được) để dẫn người dùng sang việc tự làm.
6. Nếu `agent-last.json` mới hơn lượt quét ứng viên: gắn `agent: { verdict, reason, confidence }` theo key; key bị agent "keep" rời khỏi bước; không đổi thứ tự bước.
7. `stale=true` khi lượt quét ứng viên cũ hơn 6 giờ.

**`POST /api/auto/preview` body `{ "policy": <bản nháp> }` (P5)** — chỉ đọc, không cần PIN, không lưu:
```json
{ "ok": true,
  "now":    { "wouldRun": false, "because": "Ổ C chưa tới ngưỡng kích hoạt" },
  "forced": { "selected": [ { "key": "...", "kind": "temp-entry", "target": "...", "sizeBytes": 0, "drive": "C" } ],
              "skipped":  [ { "target": "...", "kind": "cache-aged", "reason": "..." } ],
              "perDrive": [ { "drive": "C", "freeGB": 8.6, "afterGB": 12.7, "stateBefore": "Critical", "stateAfter": "Caution", "targetFreeGB": 25 } ],
              "kills": 0 },
  "triggers14d": [ { "drive": "C", "count": 6, "lastUtc": "..." } ],
  "evidence":    [ { "kind": "temp-entry", "dryRuns": 9, "items": 41, "bytes": 5200000000, "sinceUtc": "..." } ],
  "needsPin": true }
```
- Chuẩn hoá bản nháp bằng `ConvertTo-RgPolicy`; `forced` = `Select-RgAutoItems` với stress ép bật cho mọi ổ, dùng `scan-candidates.json` đã cache (không quét).
- `triggers14d`: đếm số lần trạng thái ổ đi từ nhẹ hơn sang ≥ ngưỡng kích hoạt của bản nháp trong metrics 14 ngày (dùng lại bộ đọc lấy thưa của P3).
- `evidence`: cộng từ log `auto-run`; để có số theo nhóm, `Invoke-RgAutoRun` ghi thêm `byKind: { <kind>: { items, bytes } }` vào sự kiện `auto-run` (trường mới, không đổi trường cũ).
- `needsPin` = `Test-RgPolicyNeedsPin` giữa chính sách đang lưu và bản nháp.

**`POST /api/process/priority` body `{ "pid": 1234, "start": "<stamp>", "level": "below" | "normal" }` (P6)**
- Kiểm trước khi làm: PID + start time + tên khớp bảng tiến trình; không thuộc nhóm `agent`/`infra`; không khớp `protectProcesses`; không phải tiến trình của chính Resource Guard; tiến trình thuộc phiên người dùng hiện tại (không phải session 0). Sai bất kỳ điều nào → 400 kèm lý do tiếng Việt, không làm gì.
- `below` đặt `PriorityClass = BelowNormal`; `normal` trả về `Normal`. Ghi log `proc-priority { pid, name, from, to }`. Trạng thái "đang bị hạ" lưu ở `state\proc-priority.json` (pid + start) để UI hiện nhãn và nút hoàn tác; mục có PID không còn sống bị dọn khi đọc.
- `GET /api/processes` thêm cho mỗi dòng: `start`, `lowered: bool`, `canLower: bool`, `whyNot: string`.

**Setup (P7)**: `GET /api/setup` → `{ autostart, shortcut, pinConfigured, mode, firstRun }`; `POST /api/setup` body `{ autostart?: bool, shortcut?: bool, firstRunDone?: true }` gọi lại đúng logic `rg autostart on|off` và `rg shortcut` (tách hàm dùng chung nếu cần; đặt PIN vẫn **chỉ ở console**). `firstRun` = chưa có `state\setup.json`.

**Sự kiện cho điểm đánh dấu**: `Get-RgRecentEvents` nhận thêm `proc-priority`; `GET /api/events?max=<n ≤ 200>`.

**Scanner v2 (P9)**
- `rg-scan.ps1 -Mode breakdown -Drive X -Scope focus|full` (mặc định `focus`). `POST /api/disk/scan` nhận thêm `scope`.
- Kết quả `scan-breakdown-<X>.json` thêm: `scope`; mỗi category thêm `zone: fixed|warm|hot`, `actionable: fixed|review|cleanable`, `scannedUtc`, `carried: bool`.
- File mới `state\scan-tree-<X>.json` + `GET /api/disk/tree?drive=X`:
  `{ drive, usedBytes, finishedUtc, root: { name, path, bytes, files, newestUtc, cat, zone, children: [...] } }`. Sâu tối đa 5 cấp dưới mỗi tiền tố rule; nút nhỏ hơn max(100 MB, 0,2% dung lượng đã dùng) gộp vào nút `{ name: "(khác)", rest: true }`.
- Tiến độ `scan-breakdown.progress.json` thêm `cats: [{ cat, bytes }]` (ảnh chụp tạm, cập nhật mỗi ~1 giây) để UI vẽ dần.

### Thành phần UI (P13, file `ui/viz.js`, đăng ký vào `RG.viz` và `RG`)

| Hàm | Chữ ký | Việc |
|---|---|---|
| `RG.human` | `{ state(st), kind(k), regen(r), risk(r), reasons(live) }` | Chữ tiếng Việt cho người dùng. `reasons(live)` dựng câu từ số liệu có cấu trúc của `live` (RAM, ổ, commit), không phân tích chuỗi `reasons` tiếng Anh. (Tạo ở P12 trong `core.js`.) |
| `RG.viz.impactBar` | `(el, { totalBytes, freeBytes, gainBytes, cautionBytes, normalBytes, label, unit })` | Thanh ngang: đã dùng · phần sẽ giải phóng (gạch chéo) · trống. Vạch ngưỡng Cần chú ý/Ổn. Chú thích "Trống 8,6 GB → 16,0 GB · Nguy cấp → Cần chú ý". Dùng cho cả ổ đĩa và RAM. Gọi lại với số mới là cập nhật tại chỗ. |
| `RG.viz.treemap` | `(el, rootNode, { overlay(node), onPick(node), onDrill(node), maxTiles })` | Treemap squarified bằng SVG, tối đa 60 ô mỗi cấp. `overlay` trả `sel` \| `cand` \| `prot` \| `fixed` \| `null` → kiểu viền/hoạ tiết. Bấm = `onPick` (mở ngăn kéo); bấm đúp hoặc Enter = đào sâu; có đường dẫn breadcrumb để lùi. Mỗi ô có `title` và `aria-label` "tên · dung lượng · %". |
| `RG.viz.stackArea` | `(svg, { series: [{ name, color, points: [{ t, v }] }], max, unit, onPick(name) })` | Miền xếp chồng (RAM theo nhóm tiến trình). Bấm vào một dải = `onPick`. |
| `RG.lineChart` (mở rộng, `core.js`) | thêm `o.markers: [{ ts, type, label }]`, `o.onMarker(m)`, `o.dragLine: { v, min, max, onChange(v) }` | Vạch dọc có biểu tượng cho sự kiện; đường ngưỡng kéo được (chuột + phím mũi tên). Không đổi hành vi của lời gọi cũ. |
| `RG.drawer` | `({ title, html, actions: [{ label, cls, onClick }], onClose })` | Ngăn kéo bên phải, Esc đóng, giữ focus, một ngăn tại một thời điểm. |
| `RG.receipt` | `(item) → html` | 4 dòng cố định: **Cái gì** (tên, đường dẫn, dung lượng) · **Vì sao** (`why`) · **Ảnh hưởng** (`impact`) · **Lấy lại** (`regenHint`). |

Bảng màu hoạ tiết lớp phủ dùng chung mọi trang: sẽ giải phóng = gạch chéo xanh lá; đang chọn = viền đậm màu nhấn; được bảo vệ = viền nét đứt + biểu tượng khiên; cố định không dọn được = xám nhạt.

### Điều hướng mới (P12)

| Mục | Hash | Nội dung | Nguồn code |
|---|---|---|---|
| Trang chủ | `#home` | Sẵn sàng, kế hoạch đề xuất, hoạt động | mới `p-home.js` (P14); tới lúc đó dùng trang overview cũ |
| Dọn dẹp | `#clean` | Như cũ, làm lại ở P15 | `p-clean.js` |
| Ổ đĩa | `#disk` | Treemap | `p-disk.js` |
| Tiến trình | `#cpu` | CPU + RAM + tiến trình | `p-overview.js` → `p-proc.js` (P18) |
| Tự động hoá | `#policy` | Chính sách | `p-clean.js` → `p-auto.js` (P16) |
| Cài đặt | `#settings` | Như cũ | `p-overview.js` |

Hash cũ `#overview` trỏ về `#home`. `#agent` giữ tới P19 rồi trỏ về `#home`.

---

## Quyết định thiết kế

### Quét ổ nhanh

Hiện trạng đo được: quét ổ C mất ~124 giây cho 1,42 triệu file (`DirectoryInfo.EnumerateFileSystemInfos`, 4 luồng, luôn quét toàn ổ); quét ứng viên ~49 giây.

| Phương án | Kết luận | Lý do |
|---|---|---|
| **Vùng quét + giữ lại kết quả vùng cố định** | **Làm (P9)** | Đúng ý chủ sản phẩm: Windows, Program Files, ProgramData, hồ sơ người dùng khác, pagefile/hiberfil không dọn được và ít đổi. Quét `focus` bỏ qua chúng, lấy số từ lượt `full` gần nhất (gắn nhãn thời điểm). Chưa có lượt `full` thì hiện một khối "Hệ thống & chương trình (chưa quét chi tiết)" = đã dùng − đã quét. |
| **Liệt kê bằng `FindFirstFileExW` + `FindExInfoBasic` + `FIND_FIRST_EX_LARGE_FETCH`** | **Làm (P9)** | Bỏ cấp phát `FileSystemInfo` cho từng file, lấy kích thước và thời gian ngay trong bản ghi tìm kiếm. Một phép đo công khai cho quét cây song song: 54,7 s → 27,8 s nhờ cờ large-fetch. Lợi ích trên máy này **phải đo**, không giả định. |
| **Kết quả hiện dần** | **Làm (P9 + P17)** | Thời gian chờ cảm nhận giảm kể cả khi tổng thời gian không đổi. |
| **Quét nền tự làm mới** | **Làm (P10)** | Người dùng mở app là có số mới; không phải bấm rồi chờ. |
| **Quét tăng dần bằng USN journal không cần admin** (`FSCTL_READ_UNPRIVILEGED_USN_JOURNAL`) | **Spike trước (P11)** | Tiềm năng lớn nhất (làm mới trong vài giây), nhưng FSCTL này Microsoft không có tài liệu, bản ghi không kèm tên file (chỉ FRN + FRN cha), và bằng chứng công khai là trên Windows 11 24H2+, trong khi máy đích là Windows 10 19045. Chỉ lập phase triển khai khi spike chạy được ở máy này. |
| Đọc thẳng MFT như WizTree | **Không làm** | Cần quyền admin cho mọi lượt quét và phải tự phân tích cấu trúc `$MFT` (USN enum không trả kích thước file). Trái nguyên tắc chạy quyền thường, rủi ro bảo trì cao. |

Phân vùng (ổ hệ thống): `fixed` = `Windows`, `Program Files`, `Program Files (x86)`, `ProgramData`, `Users\<người khác>`, file hệ thống ở gốc ổ. `hot` = `%TEMP%`, thư mục cache dev, workspace roots, `Downloads`, `$Recycle.Bin`. `warm` = phần còn lại của hồ sơ người dùng (AppData, Documents…). Ổ không phải ổ hệ thống: tất cả là `hot`. `focus` quét `hot` + `warm`.

### Vai trò của trợ lý (agent)

- Lớp 1, luôn có, không cần LLM: `Get-RgAdvice` (P4) biến danh sách thành kế hoạch 1–5 bước theo mục tiêu "đưa ổ về mức Ổn".
- Lớp 2, tuỳ chọn, là agent hiện có: chỉ xử lý phần máy không tự quyết được, tức nhóm "Cần xem lại" (mục `young`, mục rủi ro cao, tiến trình lạ), và viết lời giải thích bằng tiếng thường. Kết quả gắn vào đúng bước/mục, không có trang riêng.
- Người dùng luôn thấy nguồn của lời khuyên: nhãn "Quy tắc" hoặc "Trợ lý AI" trên từng dòng.

### Tự động hoá

Trang Tự động hoá trả lời ba câu theo thứ tự: *Nó sẽ làm gì* (một câu sinh từ chính sách) → *Hiệu quả ra sao* (thanh trước → sau + số lần đã kích hoạt 14 ngày) → *Tôi chỉnh thế nào* (kéo đường ngưỡng trên biểu đồ, 3 mức sẵn, công tắc theo nhóm). Tham số số học nằm trong mục "Nâng cao" gập sẵn.

---

## Đặc tả từng phase

### P1 Biên lai ứng viên + Check-Syntax
- Tạo `tests/Check-Syntax.ps1`: phân tích cú pháp mọi `scripts/*.ps1`, `rg.ps1`, `tests/*.ps1` bằng `[System.Management.Automation.Language.Parser]::ParseFile`; chạy `node --check` cho mọi `ui/*.js` (bỏ qua kèm cảnh báo nếu không có `node`); thoát 1 nếu có lỗi. Không ghi file nào.
- Thêm `Get-RgItemReceipt($Item, $Cfg)` vào `rg-common.ps1` theo bảng hợp đồng; gọi ở cuối `Get-RgCandidates` cho mọi mục; `rg-scan.ps1` (nhánh `candidates`) xuất thêm 5 trường.
- Test: mỗi `kind` có đủ 5 trường không rỗng; mục `young` có `riskLevel` cao hơn bản thường; các trường `reason`/`risk` cũ không đổi.

### P2 Lịch sử theo tiến trình
- `Invoke-RgWatchTick`: thêm `procTop` vào `$rec` (gộp theo tên từ `$procs`).
- Route `GET /api/process/history`; hàm đọc đặt trong `rg-watcher.ps1` cạnh `Read-RgMetricsTail`; kiểm tham số `name` bằng regex `^[a-z0-9._ -]{1,64}$`.
- `GET /api/events` nhận `max`. Test: bản ghi có `procTop`; hàm history trả đúng điểm từ file metrics giả.

### P3 Insight
- File mới `scripts/rg-insight.ps1` (dot-source trong `rg-server.ps1` theo cách các file khác đang được nạp): `Get-RgForecast`, `Get-RgReadiness`, `Get-RgInsight`.
- Test với metrics giả: ổ giảm đều 1 GB/ngày cho `daysToFull` đúng ±1; dữ liệu 1 ngày cho `confidence = low` và `daysTo* = null`; dốc dương cho `null`.

### P4 Advice
- `Get-RgAdvice` trong `rg-insight.ps1` + route. Đọc `scan-candidates.json`, `scan-breakdown-<X>.json`, `agent-last.json`, chính sách; không quét.
- Test từng quy tắc 1–7 bằng dữ liệu giả (đặc biệt: mục bảo vệ/young/report không vào `steps`; `reachesGoal` đúng bước; `shortBytes` > 0 sinh `beyond`).

### P5 Xem trước chính sách
- `Get-RgAutoPreview($DraftPolicy)` trong `rg-policy.ps1` + route; thêm `byKind` vào log `auto-run`.
- Test: bản nháp không bị lưu; `forced.selected` khớp `Select-RgAutoItems` với cùng đầu vào; `needsPin` đúng khi nới lỏng lúc chế độ Bật.

### P6 Hạ ưu tiên tiến trình — risk: high
- File mới `scripts/rg-proc.ps1`: `Test-RgProcLowerable`, `Set-RgProcPriority`, `Read-RgProcPriority`. Route POST + mở rộng `GET /api/processes`.
- Hành vi nghiệm thu (đều phải có test, dùng tiến trình con do test tự tạo): hạ rồi hoàn tác trả đúng `PriorityClass`; sai start time → từ chối; nhóm `agent`/`infra`/tên được bảo vệ → từ chối; PID đã chết → từ chối và không ném lỗi; PID của chính server → từ chối.
- Không thêm bất kỳ đường kill mới nào.

### P7 Setup API + thông báo
- Route `GET/POST /api/setup`. Nội dung toast (`Invoke-RgWatchTick`) dùng tên trạng thái tiếng Việt và câu dựng từ số liệu ("Ổ C còn 8,6 GB. Mở Resource Guard để xem kế hoạch dọn."), không dán `reasons` thô.
- Test: `firstRun` chuyển `false` sau `firstRunDone`; POST không có `X-RG-Client` bị từ chối như các POST khác.

### P9 Scanner v2 — risk: high
- Thay vòng liệt kê bằng P/Invoke `FindFirstFileExW`/`FindNextFileW`/`FindClose`; giữ nguyên: bỏ reparse point, bỏ file offline/cloud, tiền tố `\\?\`, luồng ưu tiên BelowNormal, huỷ được, luật phân nhóm hiện có. Số luồng mặc định `min(8, số nhân logic)`.
- Thêm `-Scope`, vùng quét, mang kết quả vùng `fixed` từ file cũ, file cây, `cats` trong tiến độ, tham số chỉ-dùng-cho-test `-RootOverride <dir>` (quét một thư mục như thể là gốc ổ, ghi ra `-OutDir`).
- Hành vi nghiệm thu: trên cây thư mục giả, tổng bytes và số file của bản mới **bằng đúng** bản cũ (chạy bản cũ trước khi sửa và ghi số vào test); junction không bị đi vào; `focus` không liệt kê thư mục `fixed`; file cây có tổng con ≤ cha.
- Bắt buộc ghi NOTES: thời gian thật trên ổ C trước/sau cho `full` và `focus`. Không đạt (focus > 50% thời gian full cũ) thì vẫn báo số thật.

### P10 Quét nền tự làm mới
- Trong vòng chính của server: nếu không có job nào chạy, CPU trung bình 3 mẫu gần nhất < 40%, và kết quả `focus` của một ổ cũ hơn `scan.autoRefreshHours` (mặc định 6; 0 = tắt) → `Start-RgJob` quét `focus` ổ đó; `full` khi cũ hơn 7 ngày. Mỗi lần một ổ, cách nhau ≥ 10 phút. Quét ứng viên cũng tự làm mới theo cùng điều kiện.
- Quyết định "có nên quét" tách thành hàm thuần `Test-RgScanDue` để test.

### P11 Spike USN
- `scripts/spikes/usn-probe.ps1 -Drive C -Json`: chỉ đọc. Mở volume không cần admin, gọi `FSCTL_QUERY_USN_JOURNAL` rồi `FSCTL_READ_UNPRIVILEGED_USN_JOURNAL` (0x903AB), đọc tối đa 1000 bản ghi.
- In JSON `{ osBuild, elevated, queryOk, readOk, records, withName, sampleReasons, error }`, luôn thoát 0 (thất bại của FSCTL là kết quả hợp lệ của spike).
- NOTES phải ghi: chạy được hay không ở Windows 10 19045 quyền thường, và kiểu handle đã dùng.

### P12 Khung UI
- `NAV` mới theo bảng điều hướng; ánh xạ hash cũ; đổi tiêu đề trang.
- Bỏ nút `#askBtn` khỏi topbar (`index.html`, `boot.js`). Badge trạng thái dùng `RG.human.state` và có `title` giải thích lý do.
- Thêm `RG.human` vào `core.js`; banner trang overview dùng `RG.human.reasons(live)`.
- Sự kiện: giờ địa phương; gộp các sự kiện liền nhau giống hệt thành "… (×11)".
- Sửa link trong banner trang Ổ đĩa không đọc được ở theme tối (dùng biến màu link của theme).

### P13 viz.js
- Cài các thành phần theo bảng hợp đồng. Thêm trang thử `#viz-demo` (không có trong NAV) hiển thị mỗi thành phần với dữ liệu mẫu ở cả hai theme, để phase sau và người kiểm thử nhìn được.
- Nghiệm thu: lời gọi `RG.lineChart` cũ (trang overview, cpu) vẽ như trước; treemap 1 nút, 0 byte, 500 nút không lỗi.

### P14 Trang chủ
Bố cục (trên xuống):
```
┌ Câu trạng thái ──────────────────────────────────────────────┐
│ "Máy đang thiếu chỗ: ổ C còn 8,6 GB, đầy trong khoảng 9 ngày" │
│ Sẵn sàng cho:  [Build ✓]  [Test ✗ thiếu 0,9 GB RAM]  [Agent ✓]│
├ Mỗi ổ một thanh ảnh hưởng (impactBar) + "đủ dùng ~N ngày" ───┤
├ Kế hoạch đề xuất ────────────────────────────────────────────┤
│ Mục tiêu: đưa ổ C về mức Ổn, cần thêm 11,4 GB                 │
│ 1. Gói NuGet không dùng 14 ngày   7,3 GB  rủi ro thấp  [Xem]  │
│ 2. bin/obj cũ                     4,1 GB  rủi ro thấp  [Xem]  │ ← "đủ mục tiêu ở bước này"
│ 3 mục cần bạn xem lại                         [Hỏi trợ lý]    │
│ [Xem và dọn theo kế hoạch]   thanh trước → sau của cả kế hoạch │
├ Resource Guard đã làm gì ────────────────────────────────────┤
│ Biểu đồ dung lượng trống 14 ngày có điểm đánh dấu từng lượt   │
│ dọn/đổi chính sách; bấm điểm → biên lai lượt đó               │
└──────────────────────────────────────────────────────────────┘
```
- Dữ liệu: `/api/insight`, `/api/advice`, `/api/events`, `S.live`. Rê chuột/focus vào một bước → thanh ảnh hưởng của ổ đó tô phần bước ấy sẽ giải phóng.
- "Xem và dọn theo kế hoạch" chuyển sang `#clean` với các key của mọi bước đến hết bước `reachesGoal` được chọn sẵn (ghi vào `S.selected`); **không xoá gì ở trang chủ**.
- Khi máy Ổn và không có mục tiêu: câu "Máy đang ổn. Không cần làm gì." + kế hoạch thu gọn thành một dòng "Có thể dọn thêm X GB".
- `afterPlan.shortBytes > 0`: hiện khối "Dọn hết vẫn thiếu Y GB" liệt kê `beyond` kèm nút sang `#disk`.
- Trang overview cũ bị thay; 4 biểu đồ realtime chuyển thành mục "Chỉ số chi tiết" gập sẵn ở cuối trang chủ (giữ `live()`).

### P15 Trang Dọn dẹp — risk: high
- Cột trái: các bước của `/api/advice` dạng nhóm mở được (tick cả nhóm hoặc từng mục), rồi nhóm "Cần xem lại", rồi "Chỉ báo cáo". Mục 0 byte cùng loại gộp một dòng "N mục nhỏ". Mỗi mục bấm vào mở `RG.drawer` với `RG.receipt` + nút Chọn/Bỏ chọn/Bảo vệ.
- Cột phải dính (sticky; xuống dưới ở màn hẹp): mỗi ổ có mục được chọn một `impactBar` cập nhật theo từng lần tick, kèm "đã chọn N mục · X GB" và trạng thái trước → sau; cảnh báo riêng nếu có mục `riskLevel=high`.
- Hộp xác nhận: `impactBar` + danh sách gộp theo nhóm, mỗi nhóm một dòng `impact`; nút "Xoá vĩnh viễn N mục (X GB)"; giữ ô nén zip và luồng PIN/admin hiện có.
- Sau khi dọn: kết quả hiển thị dự kiến so với thực tế (X GB dự kiến, Y GB thực), mục thất bại kèm lý do.
- Nghiệm thu hành vi (kiểm tay ở P21): giữ nguyên toàn bộ luồng hiện có — quét lại, lọc theo ổ, khối "Agent đang giữ", "Dọn bằng quyền admin", "Bản nén đã tạo" + giải nén, mục bảo vệ không tick được, thân POST `/api/cleanup/apply` không đổi.

### P16 Trang Tự động hoá — risk: high
- Chuyển `RG.pages.policy` và các hàm liên quan từ `p-clean.js` sang `p-auto.js` (xoá khỏi file cũ trong cùng phase).
- Khối 1 "Nó sẽ làm gì": một câu sinh từ bản nháp, ví dụ "Khi ổ C còn dưới 10 GB, tôi dọn file tạm và bin/obj cũ cho tới khi trống 25 GB, tối đa 10 GB mỗi lượt. Cache và node_modules: tôi hỏi bạn trước." Chế độ Tắt / Chạy thử / Bật ngay cạnh.
- Khối 2 "Hiệu quả": biểu đồ dung lượng trống 14 ngày của ổ đang chọn với `dragLine` là ngưỡng kích hoạt và một đường mục tiêu; dưới là `impactBar` từ `forced.perDrive`, dòng "14 ngày qua ngưỡng này đã chạm N lần", và danh sách mục sẽ dọn gộp theo nhóm. Mọi thay đổi bản nháp gọi `/api/auto/preview` (debounce 300 ms).
- Khối 3 "Từng nhóm": thẻ cho mỗi nhóm với công tắc Tự động / Hỏi tôi / Luôn giữ, dòng `impact` của nhóm, và bằng chứng từ `evidence` ("9 lượt chạy thử: 41 mục, 5,2 GB"). Nhóm đang "Hỏi tôi" có bằng chứng ≥ 3 lượt hiện gợi ý "Chuyển sang Tự động".
- Ba mức sẵn: Thận trọng / Cân bằng / Chủ động (chỉ điền bản nháp, vẫn phải Lưu).
- "Nâng cao" gập sẵn: nghỉ giữa hai lượt, GB tối đa mỗi lượt, số tiến trình tối đa, thứ tự ưu tiên, ghi đè theo ổ. Vùng bảo vệ giữ nguyên chức năng.
- Giữ nguyên: bản nháp/dirty, Lưu, hỏi PIN khi `needsPin`, "Chạy thử ngay".

### P17 Trang Ổ đĩa
- Thay biểu đồ tròn + danh sách trùng bằng: thanh tóm tắt theo nhóm (một dòng) + `RG.viz.treemap` từ `/api/disk/tree`.
- Lớp phủ: nút chứa mục có thể dọn (`S.cands`), nút được bảo vệ, nút vùng `fixed`. Chú giải 4 kiểu hoạ tiết ngay trên treemap.
- Bấm ô → ngăn kéo: đường dẫn, dung lượng, % ổ, lần sửa cuối, thuộc nhóm nào, "có N mục dọn được ở đây (X GB)" + nút Chọn để dọn (thêm key vào `S.selected`, hiện bộ đếm "đã chọn" dẫn sang `#clean`) và nút Bảo vệ thư mục này (`RG.toggleProtect`).
- Quét: nút "Quét nhanh" (`focus`) và "Quét đầy đủ" (`full`); khi đang quét vẽ dần từ `cats`. Nhóm `carried` ghi "số liệu từ lượt quét đầy đủ <thời điểm>".
- Giữ chế độ danh sách "Top lớn nhất" làm tab phụ.

### P18 Trang Tiến trình
- Chuyển `RG.pages.cpu` sang `p-proc.js` (xoá khỏi `p-overview.js` trong cùng phase).
- Trên cùng: `impactBar` cho RAM + `stackArea` RAM theo nhóm tiến trình (từ `procTop` trong `S.hist`), bên cạnh là biểu đồ CPU hiện có.
- Bảng tiến trình thêm cột "% RAM máy" và thanh nhỏ. Bấm một dòng hoặc một dải → ngăn kéo:
  - Dòng thời gian CPU và RAM của tiến trình đó (chọn 1 giờ / 6 giờ / 24 giờ) từ `/api/process/history`, ghi rõ nếu dữ liệu thưa.
  - "Nếu đóng ứng dụng này": `impactBar` RAM trước → sau, kèm chú thích là ước tính theo working set.
  - Hành động: Hạ ưu tiên / Trả về bình thường (P6, kèm câu giải thích "nhường CPU cho việc khác; không giải phóng RAM"), Bảo vệ khỏi tự dọn. Khi `canLower=false` hiện `whyNot`.
  - Không có nút kết thúc tiến trình cho tiến trình ngoài ledger; hiện câu hướng dẫn tự đóng ứng dụng.
- Điểm đánh dấu `proc-priority` trên biểu đồ CPU.

### P19 Trợ lý
- `rg-agent.ps1`: payload thêm `advice.steps` (id, kind, bytes, riskLevel) và `review.keys`; prompt yêu cầu agent ưu tiên đánh giá các key trong `review` và viết `summary` trả lời "nên làm gì trước, vì sao"; schema kết quả không bỏ trường cũ. Bộ lọc key bịa giữ nguyên.
- UI: `p-agent.js` thành ngăn kéo "Hỏi trợ lý" (mở từ trang chủ và trang Dọn dẹp): xem trước dữ liệu gửi, chạy, hiện tóm tắt + phát hiện. Verdict gắn vào từng mục dưới nhãn "Trợ lý AI". Gợi ý chính sách hiện ở trang Tự động hoá qua nút "Áp vào bản nháp" sẵn có.
- Bỏ mục Agent khỏi NAV; `#agent` trỏ về `#home` và mở ngăn kéo.
- Khi không có `claude` trong PATH: nút "Hỏi trợ lý" ẩn, kế hoạch tất định vẫn đầy đủ.

### P20 Thiết lập lần đầu
- Khi `/api/setup.firstRun`: hộp 3 bước, bỏ qua được. (1) Resource Guard làm gì, trong ba câu. (2) Chạy cùng Windows + lối tắt (hai công tắc gọi `POST /api/setup`). (3) Chế độ tự động: mặc định chọn **Chạy thử**, giải thích "một tuần nữa tôi sẽ cho bạn xem tôi sẽ dọn được gì"; chọn Bật thì hiện hướng dẫn `rg pin` vì PIN chỉ đặt được ở console.
- Cùng các công tắc này có trong trang Cài đặt.

### P21 Kiểm toàn bộ
Ngoài lệnh `exit`, phiên chính chạy app (`rg run`) và kiểm tay, ghi kết quả vào NOTES:
1. Trang chủ: câu trạng thái khớp số liệu; rê vào bước thì thanh ảnh hưởng đổi; bấm điểm đánh dấu mở biên lai.
2. Dọn dẹp: tick/bỏ tick đổi thanh ảnh hưởng tức thì; chạy một lượt dọn thật trên mục temp; kết quả có dự kiến/thực tế; điểm đánh dấu xuất hiện ở trang chủ.
3. Tự động hoá: kéo ngưỡng → câu mô tả, số lần chạm và danh sách đổi theo; Lưu khi nới lỏng ở chế độ Bật vẫn hỏi PIN.
4. Ổ đĩa: quét nhanh vẽ dần; đào sâu/lùi bằng chuột và bàn phím; bảo vệ một thư mục → ô đổi hoạ tiết và mục biến khỏi kế hoạch.
5. Tiến trình: hạ ưu tiên rồi hoàn tác một tiến trình thử; tiến trình hệ thống báo lý do không hạ được.
6. Cả hai theme, bề rộng 980px và 400px, điều hướng chỉ bằng bàn phím.

### P22 Tài liệu
- Cập nhật README (bảng tab, mục Agent, quét ổ, API mới) và `docs/TECHNOTE.md` (hợp đồng API, vùng quét, kết quả spike USN). Ghi rõ ảnh chụp trong `docs/img` cần chụp lại (không tự tạo ảnh).

---

## Ngoài phạm vi plan này

- Kết thúc tiến trình ngoài ledger; giải phóng RAM chủ động (trim working set); phát hiện tiến trình treo/rò rỉ.
- Thùng rác/giữ tạm trước khi xoá (đường lùi cho mọi loại mục).
- Biểu tượng khay hệ thống; tóm tắt hằng tuần.
- Quét tăng dần bằng USN (chờ P11).
