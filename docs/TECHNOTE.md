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

# Test nghiệm thu (725 test; chạy trên Windows PowerShell 5.1, không cần pwsh)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Acceptance.ps1
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
   │      rg-assistant-act.ps1  nén/dọn một cụm (qua Invoke-RgAction)
   ├─ Invoke-RgAction (rg-autonomy.ps1) ── cửa duy nhất vào Policy Engine
   │      registry action · mức L0–L3 theo nhóm · journal · nhật ký action
   ├─ rg-hook.ps1 ◄── hook Claude Code (lease, preflight, subagent), luôn thoát 0 khi lỗi nội bộ
   └─ ui\*  (vanilla JS, SVG, không phụ thuộc thư viện ngoài)
```

| Tệp | Vai trò |
|---|---|
| `rg-common.ps1` | Hàm dùng chung: log, ghi file atomic, đọc file chia sẻ (`Read-RgFileShared`), allowlist xoá, plan/approve/apply |
| `rg-policy.ps1` | Chính sách, PIN, engine tự động, trạng thái job (`Get/Write-RgJobState`) |
| `rg-server.ps1` | HTTP + SSE, router, auto-spawn khi chạm ngưỡng |
| `rg-scan.ps1` | Quét đĩa (Win32 `FindFirstFileExW`, đa luồng, phạm vi nhanh/đầy đủ, cây thư mục) và danh sách ứng viên dọn |
| `rg-insight.ps1` | Mức sẵn sàng build/test/agent, dự báo ngày đầy ổ, kế hoạch đề xuất tất định (`New-RgAdvice`) |
| `rg-proc.ps1` | Hạ ưu tiên tiến trình (đảo ngược được), lịch sử theo tiến trình, điều kiện kết thúc tiến trình (`Get-RgProcEndVerdict`), giải thích tiến trình (`Get-RgProcExplain`: vai trò, cây cha, service, đường cài, chữ ký, đang phục vụ job nào). File này **không** chứa `Stop-Process`; mọi lần kết thúc đi qua `Stop-RgProcessVerified` |
| `rg-assistant.ps1` | Kiểm kê metadata nhẹ → cụm tất định → verdict (luật + agent) → báo cáo trợ lý; `Invoke-RgClusterAction` (nén/dọn một cụm) |
| `rg-assistant-act.ps1` | Job nền nén/dọn một cụm, gọi `Invoke-RgAction -Actor human` |
| `rg-autonomy.ps1` | Action registry, mức tự chủ L0–L3 theo nhóm, `Invoke-RgAction`, trạng thái chống lặp, tự hạ mức, nút dừng khẩn cấp |
| `rg-hook.ps1` | Điểm vào cho hook Claude Code: lease phiên, preflight giữ chỗ RAM, đếm subagent; không lưu prompt/transcript |
| `rg-restore.ps1` | Khôi phục từ kho nén (zip có xác minh) |
| `rg-setup.ps1` | Chạy cùng Windows, lối tắt Start Menu, cờ lần đầu (`state\setup.json`) |
| `rg-auto.ps1` | Một lượt dọn tự động trong process riêng |
| `rg-cleanup.ps1` | Dọn các mục người dùng chọn (theo key) |
| `rg-agent.ps1` | Dựng payload, prompt, gọi `claude`, lọc kết quả |
| `config.default.json` | Ngưỡng RAM/đĩa, nhóm tiến trình, đường dẫn cache, danh sách segment bảo vệ |

### Vì sao tách job ra process riêng
Quét đĩa mất 1–2 phút và agent mất ~40 giây. Làm trong vòng lặp watcher sẽ làm UI đứng và SSE ngắt. Job ghi tiến độ vào `state\<job>.progress.json`; server đọc qua `Get-RgJobState`. Job đang `running` mà pid đã chết được báo là `error`, tránh treo vĩnh viễn.

### Realtime
SSE thay cho polling. Mất kết nối thì UI tự nối lại. Mỗi tick server ghi `state\live.json` (RAM, commit, đĩa, CPU tổng, từng nhân, top CPU, số tiến trình, uptime, thông tin CPU) để job nền và agent dùng chung.

## 3. Giao diện

Sidebar + 4 màn, sáng/tối, responsive (kiểm ở 1280/980/400 px), điều hướng được bằng bàn phím, có aria. Hash cũ được ánh xạ trong `boot.js` (`LEGACY`): `#overview`/`#agent` → `#home`, `#clean`/`#policy` → `#disk`, `#cpu` → `#mem`.

| Trang (hash) | Tệp | Nội dung |
|---|---|---|
| Trang chủ (`#home`) | `p-home.js` | Câu trạng thái, mức sẵn sàng, thanh tác động từng ổ, kế hoạch đề xuất, **Báo cáo của trợ lý** (cụm nên nén/dọn/giữ, nén → khôi phục), banner khi tự dọn xong vẫn vượt mốc, nút **Dừng khẩn cấp**, “Resource Guard đã làm gì” (điểm đánh dấu → biên lai), chỉ số chi tiết thu gọn |
| Ổ đĩa (`#disk`) | `p-disk.js` | Dọn dẹp + chính sách hợp nhất: thanh trước → sau, bản đồ + việc có thể làm (công tắc tự động ngay trên dòng), treemap, thanh lưu chính sách |
| Tiến trình (`#mem`, alias `#cpu`) | `p-proc.js` | RAM xếp chồng, CPU + điểm đánh dấu `proc-priority`, bảng, ngăn kéo (lịch sử, what-if, hạ ưu tiên, **Giải thích tiến trình**, kết thúc tiến trình có xác nhận trước → sau) |
| Cài đặt (`#settings`) | `p-overview.js` | Chu kỳ, ngưỡng, giao diện, chạy cùng Windows/lối tắt, thẻ **Mức tự chủ** theo nhóm (L0–L3, nâng L3 cần PIN) |

Thư viện dùng chung: `core.js` (`RG.human` — nhãn tiếng Việt cho lý do/sự kiện, `RG.lineChart` có `markers`/`dragLine`, `RG.fmtLocal` giờ địa phương), `viz.js` (`RG.viz.impactBar/treemap/stackArea`, `RG.drawer`, `RG.receipt`; trang thử `#viz-demo`), `p-setup.js` (hộp lần đầu), `p-agent.js` (`RG.askAgent`). UI luôn chỉ gửi key/pid, không gửi đường dẫn.

Kiểm thử UI bằng Edge headless qua CDP (`--screenshot` bị treo vì SSE nên không dùng được).

## 4. Chính sách tự động (`state\policy.json`)

| Trường | Giá trị / ý nghĩa |
|---|---|
| `mode` | `off` (mặc định) · `dry-run` · `on` |
| `diskTrigger` | `off` · `Caution` · `Critical` (giá trị chung cho mọi ổ) |
| `drives` | `{ "D": { diskTrigger, targetFreeGB } }`: ghi đè theo ổ (chữ A–Z), thiếu khoá thì dùng giá trị chung; `targetFreeGB` kẹp 1..10000 |
| `ramTrigger` | `off` · `Restricted` · `Critical` |
| `cooldownMin`, `maxGBPerRun`, `targetFreeGB`, `maxKillsPerRun` | Giới hạn mỗi lượt, kẹp bởi `ConvertTo-RgPolicy` |
| `categories` | `temp-entry`, `dotnet-artifact`, `cache-aged`, `node_modules`, `process` → `auto` / `ask` / `keep` |
| `priority` | Thứ tự dọn |
| `protectPaths` | So khớp tiền tố **hai chiều** (cha và con của vùng bảo vệ đều được giữ) |
| `protectProcesses` | Wildcard theo tên tiến trình |

Luồng một lượt tự động: `Get-RgStressInfo` → `Select-RgAutoItems` → `Invoke-RgAutoRun`.
- Theo ổ: `Get-RgStressInfo` trả `drives[] {drive, freeGB, totalGB, state, trigger, targetFreeGB, stress}`; `Select-RgAutoItems` tính nhu cầu và trần `maxGBPerRun` cho từng ổ (không có danh sách ổ thì quay về chế độ một ổ cũ). Trạng thái chung = xấu nhất các ổ (`Get-RgBudget`).
- *Dry-run*: chỉ chọn và báo blocker, không xoá.
- *Real*: `New-RgPlan` → `Set-RgPlanApproval -By policy` → `Invoke-RgApply`.
- Nút "Chạy thử" dùng `-AssumeStress` để thử khi máy chưa tới ngưỡng.
- Server tự spawn `rg-auto.ps1 -Trigger state` khi mode ≠ off và `Test-RgAutoDue` (chốt 90 giây).

## 5. Dọn thủ công

UI chỉ gửi **key 12 hex**, không bao giờ gửi đường dẫn. `rg-cleanup.ps1` đọc lại `scan-candidates.json` và:
- từ chối mục `report` (chỉ báo cáo), mục nằm trong vùng bảo vệ, mục không còn trong danh sách;
- từ chối nếu dữ liệu quét cũ hơn **12 giờ** (ngưỡng: `Get-RgScanMaxAgeHours` trong `rg-common.ps1`; không đọc được thời điểm quét thì coi là cũ);
- UI biết trước: quá ngưỡng thì tab Dọn dẹp hiện banner, khoá ô chọn và nút “Dọn”, nút “Quét lại ứng viên” ở đầu bảng. Ngưỡng lấy từ `maxAgeHours` của `/api/candidates`. Server vẫn kiểm lại (chốt cuối);
- Bảng và hộp xác nhận nói rõ **việc sẽ làm với từng mục** (cột “Hành động”): Xoá vĩnh viễn / Xoá (có thể nén zip) / Nén zip rồi xoá / Kết thúc tiến trình / Chỉ báo cáo / Cần quyền admin / Được bảo vệ. Hộp xác nhận liệt kê đủ mục theo nhóm hành động, có tổng ước tính; đổi tuỳ chọn nén zip cập nhật ngay. Thanh chọn tóm tắt số xoá và số kết thúc tiến trình. Dung lượng tiến trình không cộng vào ước tính đĩa.
- Cột “Chính sách” (tự động/hỏi tay/giữ) không còn ở bảng dọn vì không phản ánh việc sẽ làm; cài đặt đó xem ở tab Chính sách. Mục bị từ chối trong kết quả hiện tên mục thay vì key 12 ký tự.
- đi qua plan → approve → `Invoke-RgApply` (có allowlist + revalidate);
- xoá mục đã xong khỏi danh sách ứng viên để UI không hiện lại.

## 6. Agent đánh giá

- Lệnh: `claude -p --model haiku --effort high`, schema qua `--json-schema`, prompt truyền bằng stdin (bytes).
- Payload **chỉ metadata** (tên, kích thước, tuổi, nhóm). Không gửi nội dung file; đường dẫn user profile thay bằng `~`. Có nút xem trước đúng payload sẽ gửi.
- Hậu xử lý:
  - bỏ mọi recommendation có key không nằm trong ứng viên (chống bịa);
  - mục thuộc vùng bảo vệ (của người dùng hoặc agent còn hạn) bị ép thành `keep`;
  - verdict `keep` + `confidence = high` cho **đường dẫn** loại `delete` được ghi vào `state\agent-keep.json` (xem dưới);
  - gợi ý chính sách trùng cài đặt hiện tại bị lọc.
- Verdict `clean` chỉ **chọn sẵn ô** ở trang Ổ đĩa (ô Việc có thể làm); người dùng vẫn phải xác nhận, xoá vẫn qua plan → approve → apply.
- **Agent giữ** (`rg-policy.ps1`, `Add-RgAgentKeep` / `Get-RgAgentKeepMatch`): bảo vệ có thời hạn (30 ngày, tối đa 200 mục), tách khỏi `protectPaths` của người dùng.
  - `Test-RgPathProtected` (danh sách ứng viên, dọn tay, tự dọn) kiểm cả hai nguồn, cùng quy tắc tiền tố hai chiều; mục agent giữ bị ẩn khỏi danh sách dọn và hiện ở khối “Agent đang giữ”.
  - Chỉ làm chặt hơn nên không cần PIN. Đã giữ thì không gia hạn; hết hạn thì được đánh giá lại ở lượt sau.
  - Bỏ giữ từng mục: `POST /api/agent/keep/release {key}` (chỉ nhận key; không cần PIN vì chỉ trả mục về trạng thái policy người dùng đã đặt).
  - Không áp cho tiến trình: bảo vệ theo tên sẽ chặn cả nhóm tiến trình cùng tên; verdict `keep` của tiến trình vẫn chỉ là gợi ý.
- Hoà vào kế hoạch: payload có `advice.steps` và `review.keys` (mục chưa đủ tuổi); mục `review` luôn nằm trong `cleanupCandidates`; prompt yêu cầu đánh giá `review.keys` trước và để `summary` trả lời “nên làm gì trước”. Không đổi quyền: verdict vẫn chỉ chọn sẵn ô / bảo vệ có thời hạn. `/api/settings` có `agentAvailable` (có `claude` trong PATH) để UI ẩn nút.
- Đo thực tế: 1 lượt ≈ 37 giây, ≈ **$0.006**, payload ≈ 12 KB.

## 7. An toàn (các chốt chặn)

1. Tự động dọn **mặc định tắt**.
2. File cá nhân (Documents, Desktop, Downloads…) không bao giờ bị tự xoá; chỉ gợi ý.
3. Mọi lần xoá đi qua `Invoke-RgApply`; không có đường xoá khác.
4. Vùng bảo vệ luôn thắng — kể cả khi người dùng tick tay hoặc agent đề xuất. Agent chỉ được **thêm** bảo vệ có thời hạn (không bao giờ gỡ bảo vệ hay nới policy).
5. Server chỉ nghe localhost, kiểm tra header `Host`; POST bắt buộc `X-RG-Client: ui`.
6. Static chỉ phục vụ whitelist đuôi css/js/svg.
7. **PIN** (PBKDF2, 120k vòng) bắt buộc khi chuyển sang mode `on` hoặc *nới lỏng* chính sách khi đang `on`; siết thêm bảo vệ thì không cần. Sai 5 lần → khoá 5 phút. Đặt PIN chỉ ở console.
8. Kill tiến trình chỉ với nhóm cho phép (`build`, `test`, `dev`), có giới hạn `maxKillsPerRun`.
9. **Kết thúc tiến trình từ app** (`POST /api/process/end`): chỉ nhận `pid` + `start`; điều kiện ở `Get-RgProcEndVerdict` (allowlist lớp: build, test, máy chủ dev, trình quản lý gói, compiler, language server; hệ thống, bảo mật, dịch vụ, Docker/SQL/WSL, vùng bảo vệ và chính Resource Guard thì không bao giờ). Một đường duy nhất `Stop-RgProcessVerified`: kiểm lại PID + thời điểm khởi động + tên ngay trước khi làm → đóng êm → chờ → buộc dừng → xác minh đã thoát (cả cây con thuộc nhóm cho phép). Tiến trình đang giữ lease/ledger của agent cần thêm PIN. `rg-proc.ps1` không chứa `Stop-Process`/`.Kill(`/`taskkill`/`CloseMainWindow` (có test).
10. **Journal ghi-trước** (`state\journal.jsonl`): xoá, nén, khôi phục, kết thúc tiến trình ghi `intent` rồi `done|failed`; không ghi được `intent` thì không làm. Lần khởi động sau, `intent` mồ côi được báo và đóng là `interrupted`; plan xoá dở có thể chạy tiếp (kiểm lại từng mục). Lỗi ghi file/log không bị nuốt: `/api/health`, `state\io-health.json`. `plans\` giữ 60 ngày, log 30 ngày, journal tối đa 4096 KB (`retention.*`).
11. **Agent đề xuất, Policy Engine thi hành** (`rg-autonomy.ps1`): `Invoke-RgAction` là cửa duy nhất; agent chỉ chọn `id` trong registry (5 action: `clean-cache`, `archive-cluster`, `clean-cluster`, `end-process`, `lower-priority`), tham số lạ (đường dẫn, khoá không phải 12 hex, PID ≤ 4) bị từ chối. Tác nhân không phải người chỉ thi hành khi nhóm ở **L3** + quyền của action ở L3 + chính sách `mode` ≠ `off`; mục `young`, `report`, agent-keep và file cá nhân không bao giờ tự xoá (trần nhóm L2; file cá nhân tối đa là “duyệt rồi nén zip có xác minh”).
12. **Mức tự chủ** (`policy.autonomy.<nhóm>` = `L0` Tắt · `L1` Đề xuất · `L2` Chờ duyệt · `L3` Tự động): thiếu khoá = `L1`, riêng nhóm có category cũ (`cache-aged`, `temp-entry`…) kế thừa category (auto=L3, ask=L2, keep=L0) để không đổi hành vi cũ. Nâng lên L3 cần PIN (kể cả khi mode chưa bật); hạ mức thì không. Tự hạ khi bị khôi phục nhiều (`Invoke-RgAutonomyDemote`); đề nghị nâng khi N lượt chạy thử không bị khôi phục.
13. **Dừng khẩn cấp** (`POST /api/panic`, `rg.ps1 panic`, nút ở Trang chủ): đặt `mode=off` và huỷ job nền của Resource Guard (chỉ tiến trình có dòng lệnh khớp `rg-*.ps1`). Không cần PIN vì chỉ làm chặt hơn; bật lại chính sách thì cần PIN.
14. **Riêng tư của trợ lý**: hook không lưu prompt/transcript/tin nhắn cuối; payload gửi agent không có đường dẫn đầy đủ hay tên file (chỉ ≤ 5 tên mẫu trong cụm ở báo cáo cục bộ, không gửi đi); cụm ở `AppData` (góc khuất) chỉ báo cáo; API báo cáo bỏ `root` của cụm.

## 8. API (rút gọn)

`GET /api/processes` · `/api/jobs` · `/api/drives` (ổ + trạng thái + ngưỡng + chính sách hiệu lực + `workspaceRoots`) · `/api/disk?drive=X` · `/api/candidates` · `/api/policy` · `/api/auto/last` · `/api/cleanup/last` · `/api/agent/{payload,last}`
`POST /api/disk/scan {drive, scope}` (`scope` = `focus` | `full`, sai → 400; mỗi lần một ổ; mặc định `full` khi chưa có số vùng cố định) · `/api/candidates/scan` · `/api/cleanup/apply` · `/api/policy` · `/api/auto/run` · `/api/agent/run`

API thêm trong đợt đổi UX (mọi POST cần `X-RG-Client`):

| Route | Ý nghĩa |
|---|---|
| `GET /api/disk/tree?drive=X` | Cây thư mục đã cắt tỉa (độ sâu 5 theo tiền tố luật; nút nhỏ hơn max(100 MB, 0,2% dung lượng dùng) gộp vào `(khác)`) |
| `GET /api/insight` · `GET /api/advice` | Mức sẵn sàng + dự báo ngày đầy; kế hoạch đề xuất tất định (`steps`, `review`) |
| `GET /api/drive/history?drive=X&days=N` | Dung lượng trống theo giờ (biểu đồ 14 ngày) |
| `GET /api/process/history?name=X&min=N` | Lịch sử RAM/CPU của tiến trình theo tên (mặc định 60 phút, tối đa 1440) |
| `POST /api/process/priority {pid,start,level}` | Chỉ đổi PriorityClass `Normal` ↔ `BelowNormal` (`below` / `normal`); việc kết thúc tiến trình là route riêng `POST /api/process/end`. Đi qua `Invoke-RgAction -Id lower-priority`. Một hàm quyết định (`Get-RgProcLowerVerdict`) dùng chung cho `canLower/whyNot` ở danh sách và lúc thực thi; từ chối tiến trình Windows/giao diện và các tiến trình của chính Resource Guard; PID + start time + tên phải khớp dữ liệu sống |
| `POST /api/auto/preview {policy}` | Xem trước chính sách chưa lưu: số lần chạm, mục sẽ bị chọn, bằng chứng của lượt chạy thử |
| `GET/POST /api/setup` | `firstRun`, `autostart`, `shortcut`; POST chỉ nhận bool và `firstRunDone`; **PIN không đặt qua đây** |
| `POST /api/process/end {pid,start[,pin]}` | Kết thúc tiến trình có xác minh (`Stop-RgProcessVerified`); tiến trình đang giữ lease của agent cần `pin`; mã lỗi `bad-pid`, `bad-start`, `autonomy-off`, `pin-*` |
| `GET /api/process/explain?pid=N&start=S` | Giải thích tất định: vai trò, cây cha, service, đường cài, chữ ký, “đang phục vụ job nào” (ledger/lease), kèm nguồn; PID + start phải khớp tiến trình sống |
| `GET /api/leases` | Phiên agent đang giữ lease, giữ chỗ preflight, số subagent, tiến trình quan sát được từ cây tiến trình (chỉ đọc, không có prompt) |
| `GET /api/health` | Sức khoẻ ghi dữ liệu, journal mở, plan có thể chạy tiếp |
| `GET /api/assistant/report` | Báo cáo trợ lý: cụm + verdict + tổng hợp, kèm tiến độ quét kiểm kê/agent (không có đường dẫn từng file) |
| `POST /api/assistant/{scan,ask,act,dismiss}` | Quét kiểm kê nền · nhờ agent đánh giá cụm (vắng `claude` thì dùng luật) · nén/dọn một cụm `{clusterId, action: compress\|clean}` · ẩn cụm |
| `GET /api/autonomy` · `POST /api/autonomy/{level,snooze}` | Mức tự chủ theo nhóm + banner + đề nghị nâng/hạ + registry; đặt mức `{group, level[, pin]}` (nâng L3 cần PIN: `pin-required`/`pin-wrong`/`pin-locked`/`pin-not-set`; vượt trần `over-cap`); hoãn banner `{hours}` |
| `POST /api/panic` | Dừng khẩn cấp: `mode=off` + huỷ job nền; không cần PIN |
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
| `msedge --screenshot` treo vì SSE | Dùng CDP qua node, hoặc Playwright (`channel: 'msedge'`) + `page.route('**/events', …)` để mock luồng SSE |
| `[math]::Min(500, [math]::Max(0.1, x))` chọn overload `int` → 0.1 thành 0 | Dùng hằng double (`500.0`) |
| PS 5.1: `ConvertFrom-Json` không trải mảng | `| ForEach-Object { $_ }` (đã áp dụng ở `Read-RgLedger`, `Read-RgArchives`) |
| Máy chỉ có một ổ nên không kiểm được nhiều ổ thật | Test nhiều ổ dùng danh sách ổ giả (khối "nhiều ổ đĩa" trong `tests/Acceptance.ps1`) |

## 10. Giới hạn & việc có thể làm tiếp

- `Install-Watcher.ps1` (tự khởi động cùng Windows) chưa được cài trên máy này; hiện phải chạy `serve` thủ công.
- Quét đĩa nhanh hơn nhiều (xem mục 11) nhưng vẫn là tác vụ nặng I/O; chưa có quét tăng dần (USN) — xem mục 12.
- Mục tiêu hỗ trợ là Windows PowerShell 5.1 (có sẵn trên Windows, không phải máy nào cũng có `pwsh`); Acceptance 725 test chạy ở 5.1. PowerShell 7+ chưa được kiểm và không bắt buộc.
- Agent chỉ thấy metadata nên không phân biệt được file "trông như rác nhưng quan trọng" — đó là lý do cá nhân/không rõ nguồn gốc luôn ở dạng gợi ý.
- Ảnh hưởng của watcher lên CPU/RAM có công cụ đo (`tests/Bench-Watcher.ps1`) nhưng chưa có số đo nhiều giờ liên tục.
- Giải thích tiến trình hiện là tất định (không qua agent); hook chỉ có cho Claude Code, chưa có cho Codex.
- `Documents`/`Desktop` nằm trong `protected.segments` mặc định nên cụm file thực tế chủ yếu ra từ `Downloads`; cụm ở `AppData` chỉ báo cáo.
- Chạy thử ≥ 1 tuần ở máy thật trước khi bật L3 cho nhóm đầu tiên (số liệu ở thẻ Mức tự chủ).
- Ảnh trong `docs/img` chưa chụp lại sau đợt đổi UX/trợ lý.

## 11. Quét ổ v2: vùng quét và cây thư mục

- `rg-scan.ps1 -Mode breakdown -Drive X -Scope focus|full -Threads N` (`0` = tự chọn). C# trong `Add-Type`, duyệt bằng `FindFirstFileExW` (`FindExInfoBasic` + `LARGE_FETCH`), đa luồng, ưu tiên BelowNormal.
- **Vùng**: `fixed` (Windows, Program Files, ProgramData, hồ sơ người dùng khác; bị bỏ qua khi `focus`), `hot` và `warm` (nơi có ứng viên dọn). `scan-fixed-X.json` giữ số của vùng cố định từ lượt đầy đủ gần nhất.
- Đầu ra: `scan-breakdown-X.json` (theo nhóm), `scan-tree-X.json` (cây cắt tỉa cho treemap), `scan-fixed-X.json`. `RgDiskScanner.SnapshotCats` cấp `cats` cho progress nên UI vẽ thanh nhóm hiện dần.
- Làm mới nền: `Test-RgScanDue` (hàm thuần trong `rg-common.ps1`) quyết định theo: không có job nền nào chạy, CPU trung bình 3 mẫu cuối < `scan.cpuMaxPct`, cách lượt tự quét trước ≥ 10 phút, tuổi dữ liệu > `scan.autoRefreshHours` (ổ cũ nhất trước, hoặc quét ứng viên nếu nó cũ hơn); scope là `focus`, thành `full` nếu lượt đầy đủ gần nhất cũ hơn 7 ngày; vòng tick của server gọi nó (`$script:CpuRing`, `scan-auto`). Cấu hình: `scan.autoRefreshHours`, `scan.cpuMaxPct`. Test cấu hình `autoRefreshHours = 0` để server trong test không quét ổ thật.
- Đo ổ C máy phát triển: cũ 85,7 s → mới 23,8 s (đầy đủ) / 12,8 s (nhanh, ≈15%).

## 12. Spike USN journal (P11): đọc không cần admin

Mục tiêu: xem có thể quét **tăng dần** bằng USN journal mà không đòi quyền admin không. Script: `scripts/spikes/usn-probe.ps1 -Drive C -Json` (chỉ đọc, luôn thoát 0).

Kết quả trên Windows 11 build 26200 (không phải build 19045 như giả định ban đầu của plan), tài khoản không nâng quyền:

- Đọc được **không cần admin**, nhưng chỉ khi mở handle ở **thư mục gốc ổ** với `FILE_READ_ATTRIBUTES` + `FILE_FLAG_BACKUP_SEMANTICS`; mở handle volume (`\\.\C:`) thì hoặc FSCTL query báo lỗi 1 (`none`/`attr`) hoặc mở bị từ chối (lỗi 5, `read`). Đọc phải bắt đầu từ `FirstUsn` (nếu không gặp lỗi 87); `FSCTL_READ_USN_JOURNAL` đặc quyền không dùng được (lỗi 5).
- Bản ghi là V3 và **không kèm tên file** (`FileNameLength = 0`), chỉ có mã file và cờ lý do: muốn biết thư mục nào đổi phải tra ngược từng mã, đắt hơn lợi ích.
- Journal ổ C chỉ giữ **vài giờ** (đo được 0,6 giờ ở lần đầu và 6,7 giờ ở lần sau; `maxSize` 32 MB, quay vòng theo mức hoạt động); ổ D giữ khoảng 28 ngày: với ổ hệ thống, cửa sổ quá ngắn để thay một lượt quét định kỳ.

Kết luận: chưa triển khai quét tăng dần bằng USN. Quét nhanh + tự làm mới nền (mục 11) đã đủ nhanh; xem lại nếu có nhu cầu theo dõi ổ dữ liệu có journal dài.
