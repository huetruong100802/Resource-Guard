# Plan: đưa Resource Guard lên mức sản phẩm + kết nối nhiều loại agent

> Lập ngày 2026-11-14 trên nhánh `feature/automation-assistant` (HEAD `0136230`).
> File này là nguồn sự thật duy nhất về tiến độ. Ai tiếp tục (người hoặc model khác) chỉ cần đọc mục 0 và mục 6.

## 0. Cách tiếp tục khi đổi người/model

1. Đọc **mục 6 (Nhật ký bàn giao)** để biết đã làm tới đâu; ô `[x]` ở mục 3–5 là việc đã xong và đã có test.
2. Quy ước bắt buộc của repo:
   - Mục tiêu là **Windows PowerShell 5.1** (`powershell.exe`), không yêu cầu `pwsh`.
   - Mọi `*.ps1` là **UTF-8 có BOM + CRLF**. Sửa bằng công cụ Edit (giữ nguyên BOM/CRLF); không dùng `sed -i`, không ghi chữ Việt vào `.ps1` từ bash heredoc. File `.ps1` mới: tạo xong phải chuyển sang BOM + CRLF (xem lệnh ở mục 7).
   - `ui/*.js|css|html` là LF, không BOM. Không thêm thư viện ngoài.
   - Bẫy PS 5.1: `ConvertFrom-Json` không trải mảng (luôn `| ForEach-Object { $_ }`); `ConvertFrom-Json '[]'` trả `$null`; `$null` truyền vào tham số .NET kiểu `string` thành `""` (dùng `[NullString]::Value`); `[math]::Max(0, <long>)` chọn Int32.
3. Bất biến an toàn **không được nới**: mọi lần xoá/kết thúc tiến trình đi qua `plan → approve → apply` + kiểm lại; vùng bảo vệ thắng mọi thứ; file cá nhân không bao giờ tự xoá; **agent chỉ đề xuất, không thi hành**; UI và agent chỉ gửi `key`/`pid`/`clusterId`, không gửi đường dẫn.
4. Kiểm thử (dừng mọi server Resource Guard trước, vì mutex `Local\ResourceGuardWatcher` dùng chung toàn máy):
   ```powershell
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Check-Syntax.ps1
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Acceptance.ps1      # dòng cuối: "Kết quả: N pass, M fail" (~7 phút)
   powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests\Acceptance-Auto.ps1 # dòng cuối: "AUTO-RESULT pass=N fail=M"
   ```
5. Chạy thử UI không đụng dữ liệu thật: đặt `AGENT_RESOURCE_HOME` sang thư mục tạm rồi `scripts\rg-server.ps1 -Port 8791 -Detach -NoOpen -NoToast`; dừng bằng `scripts\rg-server.ps1 -Stop` (cùng biến môi trường).

## 1. Số đo trước khi sửa (máy dev, 8 GB RAM, 263 tiến trình, PS 5.1)

| Hạng mục | Số đo | Nguyên nhân |
|---|---|---|
| Một lượt lấy mẫu (tick) | trung bình **1 469 ms**, p95 1 963 ms, đỉnh 5 981 ms; 0,9 giây CPU/tick | xem các dòng dưới |
| `Write-RgFileAtomic` ghi đè file đã có | **~650 ms mỗi lần** và **không còn nguyên tử** | `[IO.File]::Replace($tmp, $Path, $null)`: PS 5.1 đổi `$null` thành `""` → luôn ném "path is not of a legal form" → thử lại 5 lần (ngủ 600 ms) rồi ghi thẳng. Mỗi tick ghi 2 file (`watcher.json`, `live.json`); mọi job ghi tiến độ cũng dính |
| `Get-RgSnapshot` | 105 ms | 2 truy vấn CIM (`Win32_OperatingSystem`, `Win32_PageFileUsage`) |
| `Get-RgProcessTable` + workload map | 260 + 60 ms mỗi 30 giây | CIM `Win32_Process` + phân nhóm |
| `Write-RgStatusHtml` | 70–85 ms mỗi tick | đọc lại 240 dòng metrics + `ConvertFrom-Json` từng dòng |
| `Get-RgConfig` | 4 ms × ~10 lần/tick | đọc + parse JSON mỗi lần gọi, không cache |
| Server đơn luồng | request xếp hàng **1–3,6 giây** khi mở trang (10–14 request/trang) | request không được phục vụ trong lúc tick; route chậm chặn route nhanh |
| `/api/processes` | 610–790 ms, 230 KB | tính verdict + identity cho từng tiến trình ở mỗi request |
| `/api/setup` | 650–2 260 ms | dò Scheduled Task mỗi request |
| `/api/autonomy` · `/api/insight` · `/api/advice` | 250–370 · 190–320 · 150–640 ms | tính lại từ file ở mỗi request |
| RAM của server | 183 MB | tiến trình PowerShell + bảng tiến trình |
| Test nền | 723 pass / **2 fail** | `rg-hook.ps1` qua stdin thật (xem G2.6) |

Mục tiêu sau khi sửa: tick thường ≤ 250 ms (≤ 600 ms ở lượt làm mới bảng tiến trình); không request nào của trang chủ chờ quá 500 ms khi máy không bận; test 100% xanh.

## 2. Lỗi giao diện và độ hoàn thiện đã thấy

- Thanh “Chính sách đã đổi · chưa áp dụng” hiện ở Ổ đĩa và Cài đặt **dù người dùng chưa sửa gì** (bản nháp bị chuẩn hoá `drives` → khác bản gốc).
- Tổng quan: hai bước liền nhau cùng tên “Đóng Trình duyệt” (msedge và msedgewebview2), không phân biệt được.
- Chấm kết nối còn đỏ “đang kết nối…” khi số liệu đã hiện (SSE bị xếp hàng sau request chậm).
- Cài đặt: thẻ “Chu kỳ lấy mẫu” và “An toàn” bị kéo cao, trống; không có mục **Giới thiệu** (phiên bản, thư mục dữ liệu, log), không có mục **Kết nối agent**.
- Ổ đĩa: nhóm “1 nhóm nhỏ khác … 0 B” vô nghĩa với người dùng.
- Sản phẩm: không có số phiên bản, không có trình cài/gỡ (phải `git clone`), lối tắt mở tab trình duyệt thường thay vì cửa sổ ứng dụng; lệnh `rg` **trùng tên ripgrep** (`rg path` có thể che ripgrep của người dùng); README ghi “132 passing”; thư mục rác `System.Collections.Hashtable/` ở gốc repo; ảnh `docs/img` là giao diện cũ.
- Kết nối agent: chỉ `claude` (gọi cứng trong `rg-agent.ps1`, hai hàm gần trùng nhau); hook chỉ cho Claude Code; nhận diện tiến trình agent chỉ có `claude*`/`codex*`.

## 3. Giai đoạn G1 — Hiệu suất ổn định

- [x] **G1.1** `Write-RgFileAtomic`: dùng `[IO.File]::Replace($tmp, $Path, [NullString]::Value)`; lỗi thật mới thử lại. Test: ghi đè 20 lần < 400 ms và file tạm không còn sót.
- [x] **G1.2** `Get-RgConfig` cache theo (đường dẫn, `LastWriteTimeUtc`, kích thước) của `config.default.json` + `config.json`; `Initialize-RgHome` chỉ tạo thư mục một lần cho mỗi giá trị home. Test: sửa `config.json` thì lần gọi sau thấy giá trị mới.
- [x] **G1.3** Tick nhẹ hơn: bỏ `Win32_PageFileUsage` khỏi đường tick (`-SkipPageFiles`); RAM/commit đọc bằng `GlobalMemoryStatusEx` (P/Invoke, dự phòng CIM khi lỗi); `status.html` ghi tối đa 60 giây một lần; `Get-RgIoHealth`/overhead giữ nguyên.
- [x] **G1.4** Bộ nhớ đệm phản hồi cho GET nặng trong `rg-server.ps1` (`Get-RgCached <khoá> <ttl> { ... }`): `/api/processes`, `/api/insight`, `/api/advice` (tới tick kế), `/api/autonomy` (5 s), `/api/setup` (60 s). Mọi POST thành công xoá toàn bộ cache. Test API: hai GET liên tiếp, lần hai < 100 ms.
- [x] **G1.5** Phục vụ nhiều request mỗi vòng (rút hết hàng đợi `GetContextAsync` trước khi tick, tối đa 25 request/vòng) để tick không chen giữa loạt request mở trang; file tĩnh có `ETag`/`Cache-Control: no-cache` + 304.
- [x] **G1.6** Đo lại bằng `tests\Bench-Watcher.ps1`, ghi số vào mục 6 và README.

## 4. Giai đoạn G2 — Giao diện và độ hoàn thiện

- [x] **G2.1** `RG.policyDirty()` trong `core.js`: so sánh sau khi chuẩn hoá (`drives` rỗng/mảng/null là như nhau); `p-disk.js`, `p-overview.js`, `p-agent.js` dùng chung.
- [x] **G2.2** Tổng quan: bước RAM trùng tiêu đề thì kèm tên tiến trình trong ngoặc (`rg-insight.ps1` → `New-RgAdvice`), hoặc gộp ở UI.
- [x] **G2.3** Cài đặt: lưới không kéo giãn thẻ (`align-items:start`), thêm thẻ **Giới thiệu** (phiên bản, thư mục dữ liệu, đường dẫn log, overhead thực đo của watcher) từ `GET /api/about`.
- [x] **G2.4** Ổ đĩa: ẩn nhóm tổng 0 B.
- [x] **G2.5** Chấm kết nối: coi là “trực tiếp” ngay khi có tin SSE đầu tiên hoặc `/api/state` trả về.
- [x] **G2.6** `rg-hook.ps1`: bỏ BOM/ký tự rác đầu stdin trước khi parse JSON (2 test đang đỏ).
- [x] **G2.7** Sản phẩm:
  - `VERSION` ở gốc repo + `Get-RgVersion`; hiện ở `rg status`, `/api/about`, chân thanh bên.
  - `install.ps1` / `uninstall.ps1`: chép vào `%LOCALAPPDATA%\Programs\ResourceGuard`, tạo lối tắt, tuỳ chọn autostart; gỡ thì giữ dữ liệu trừ khi `-PurgeData`.
  - Lối tắt mở **cửa sổ ứng dụng** (`msedge --app=URL`, dự phòng trình duyệt mặc định): `rg start -App`.
  - Lệnh thứ hai **`rguard`** (`rguard.cmd`) không trùng ripgrep; `rg path` cảnh báo nếu máy có `rg.exe` của ripgrep.
  - README (badge số test, mục Cài đặt, mục Kết nối agent), `CHANGELOG.md`, xoá thư mục rác + `.gitignore`.

## 5. Giai đoạn G3 — Kết nối agent hiện đại, đa dạng

Hiện trạng có hai chiều kết nối, cả hai đều gắn cứng với Claude Code. Thiết kế mới tách thành ba lớp độc lập, mỗi lớp dùng **dữ liệu khai báo** nên thêm agent mới không cần sửa code:

```
                      ┌────────────────────────── Resource Guard ──────────────────────────┐
 Agent bất kỳ ──MCP──►│ rg-mcp.ps1 (stdio)  ─┐                                             │
 Agent có hook ──────►│ rg-hook.ps1 -Agent X ├─► Invoke-RgAgentEvent (chuẩn hoá) ─► lease, │
 Script/CI ──HTTP────►│ /api/agent/v1/*      ─┘    preflight, giữ chỗ, đếm subagent        │
                      │                                                                    │
                      │ rg-providers.ps1: claude | codex | gemini | ollama | openai-compat │──► LLM đánh giá (chỉ metadata)
                      │ agents.catalog (config): nhận diện tiến trình + thư mục cấu hình   │
                      └────────────────────────────────────────────────────────────────────┘
```

### G3.1 Danh mục agent (`agents.catalog` trong `config.default.json`)
- [x] Mỗi mục: `id`, `label`, `processNames[]`, `cmdRegex`, `configDirs[]` (segment được bảo vệ), `connect` (`hooks` | `mcp` | `wrapper`), `cli` (tên lệnh để dò trong PATH).
- [x] Có sẵn: Claude Code, Codex CLI, Gemini CLI, Cursor (agent/IDE), GitHub Copilot CLI, Aider, opencode, Goose, Cline/Roo (trong VS Code: chỉ MCP), Windsurf, Ollama (runtime LLM cục bộ: nhóm `infra`, ngốn RAM).
- [x] `Get-RgAgentCatalog`, `Get-RgAgentOf($Name,$Cmd)`; `Get-RgGroup`, `Find-RgAgentOwnerPid`, identity (“Trợ lý AI · <label>”), `protected.segments`, `tempExclude` đọc từ danh mục (giữ tương thích khoá cũ `agentCmdRegex`, `groups.agent`, `lease.agentProcessNames`).

### G3.2 Nhà cung cấp LLM đánh giá (`scripts/rg-providers.ps1`)
- [x] `agents.evaluator` trong config: `provider` (`auto` = cái đầu tiên dùng được), `model`, `timeoutSec`, `maxBudgetUsd`; `agents.providers.<id>` ghi đè từng nhà cung cấp.
- [x] Hai kiểu vận chuyển:
  - `cli`: mẫu đối số có `{model}`, `{schemaFile}`, `{promptFile}`; prompt qua stdin; mặc định cho `claude` (như cũ), `codex` (`exec` + `--output-schema`), `gemini` (`-p`).
  - `http`: `ollama` (`/api/chat`, `format` = schema; **hoàn toàn cục bộ**) và `openai-compatible` (`/v1/chat/completions`, `response_format: json_schema`; dùng được với OpenAI, OpenRouter, LM Studio, vLLM...). Khoá API **chỉ đọc từ biến môi trường** có tên khai trong `apiKeyEnv`; không bao giờ ghi khoá vào file hay log. Chỉ gọi host ngoài `localhost` khi người dùng tự khai `baseUrl`.
- [x] Đầu ra của mọi nhà cung cấp đi qua **cùng một cửa**: tách khối JSON đầu tiên → kiểm bằng bộ kiểm schema tối thiểu của ta (`Test-RgJsonShape`: kiểu, `required`, `enum`) → rồi mới tới bộ lọc an toàn sẵn có (`ConvertTo-RgSafeVerdicts`, lọc key bịa…). Nhà cung cấp không ép được schema vẫn an toàn.
- [x] `rg-agent.ps1`: bỏ hai đoạn gọi `claude` trùng nhau, dùng `Invoke-RgLlmJson`. `/api/settings.agentAvailable` = có ít nhất một nhà cung cấp dùng được.
- [x] `GET /api/agents` (danh mục + phát hiện cài đặt/đang chạy/đang giữ lease + nhà cung cấp + cái đang chọn), `POST /api/agents/evaluator {provider, model}`, `POST /api/agents/test {provider}` (gửi một câu hỏi schema nhỏ, không kèm dữ liệu máy).
- Ghi chú trung thực: máy phát triển chỉ có `claude`; `codex`, `gemini`, `ollama`, `openai-compatible` được kiểm bằng **máy chủ/lệnh giả** trong test (đúng hợp đồng vào/ra), chưa chạy với sản phẩm thật. Cờ dòng lệnh của CLI bên thứ ba nằm trong config để người dùng chỉnh khi bản CLI của họ khác.

### G3.3 Agent báo cho Resource Guard (lease, preflight, subagent)
- [x] **MCP server** `scripts/rg-mcp.ps1` (stdio, JSON-RPC 2.0, mỗi dòng một thông điệp): `initialize`, `tools/list`, `tools/call`, `ping`. Công cụ **chỉ đọc + tư vấn** (không có công cụ xoá/kết thúc):
  - `resource_status` — trạng thái máy, RAM/ổ trống, lý do.
  - `preflight {task: build|test|subagent, reserve?}` — `allow|warn|deny` + lý do; có giữ chỗ.
  - `release {reservationId|task}` — nhả giữ chỗ.
  - `session {action: start|heartbeat|end, agent, sessionId?}` — lease.
  - `cleanup_candidates {limit?}` — danh sách dọn được (đường dẫn đã thay `~`), chỉ đọc.
  - `explain_process {pid}` — tiến trình là gì, có nên đụng không.
  - Dùng được cho mọi agent hỗ trợ MCP: Claude Code, Codex CLI, Gemini CLI, Cursor, Windsurf, Copilot, Cline, opencode, Goose…
- [x] **HTTP cho agent** `POST /api/agent/v1/{session,preflight,release}`, `GET /api/agent/v1/status` (header `X-RG-Client: agent`): cho script/CI/agent tự viết.
- [x] **Hook đa agent**: `Invoke-RgHookEvent` nhận sự kiện đã chuẩn hoá; bảng ánh xạ theo agent trong `agents.catalog.<id>.hookMap` (tên sự kiện, tên trường session/tool/command, tên tool là subagent/shell). Có sẵn cho Claude Code (đã đo), Gemini CLI và Cursor (theo tài liệu công khai, **chưa đo trên máy thật** → ghi rõ ở đầu ra của `rg connect`).
- [x] **Bọc lệnh** cho agent không có hook lẫn MCP: `rguard run -Agent aider -- <lệnh>` lập lease, chạy lệnh, trả lease khi thoát.
- [x] `rguard connect <agent> [-Write]`: in đoạn cấu hình (MCP json / hooks / lệnh `claude mcp add`…) và nói rõ file cần sửa. Mặc định **chỉ in**; không tự sửa file của người dùng.

### G3.4 Giao diện
- [x] Thẻ **Kết nối agent** ở Cài đặt: mỗi agent một dòng (đã cài? đang chạy? đang giữ lease? cách kết nối), nút “Cách kết nối” mở ngăn kéo có đoạn cấu hình + nút Sao chép; chọn nhà cung cấp đánh giá + nút Thử.
- [x] Chữ trên UI không còn nhắc cứng “claude”: dùng nhãn nhà cung cấp đang chọn.

### G3.5 Test và tài liệu
- [x] `tests/Acceptance-Agents.ps1` (được `Acceptance.ps1` gọi): danh mục/nhận diện, chuẩn hoá hook 3 agent, MCP qua stdio thật (initialize → tools/list → tools/call), nhà cung cấp `cli` giả + `http` giả (HttpListener cục bộ), bộ kiểm schema, khoá API không lọt vào log.
- [x] README + TECHNOTE: mục “Kết nối agent”, bảng agent × cách kết nối × mức đã kiểm.

## 6. Nhật ký bàn giao

| Ngày | Ai | Việc | Kết quả |
|---|---|---|---|
| 2026-11-14 | Claude (Fable 5.2) | Khảo sát, đo, lập plan | Mốc: 723 pass / 2 fail; số đo ở mục 1 |
| 2026-11-14 | Claude (Fable 5.2) | G1.1–G1.5, G2.1–G2.6, G3 phần server (`rg-agents.ps1`, `rg-mcp.ps1`, API, `rg connect/wrap/mcp/version`) | Dừng giữa chừng vì hết hạn mức |
| 2026-11-14 | Claude (Opus 5.5) | G3.4 UI (`ui/p-connect.js`: Kết nối agent, Trợ lý AI đánh giá, Giới thiệu), G2.5, `install.ps1`/`uninstall.ps1` (đã cài/gỡ thử vào thư mục tạm), cảnh báo ripgrep, `tests/Acceptance-Agents.ps1` (71 test), README/TECHNOTE/CHANGELOG; sửa JSON hook Gemini/Cursor thiếu escape `"` | **796 pass / 0 fail**. Bench 12 tick: lượt thường ~130 ms (trước: 1 469 ms), lượt đầu nguội 4–5 s, 0,4 s CPU/tick, ~140 MB |

Lệch so với plan (cố ý): kênh HTTP cho agent là `/api/connect/v1/*` (không phải `/api/agent/v1/*`, vì `/api/agent/*` đã dùng cho trợ lý đánh giá); bọc lệnh là `rguard wrap` (không phải `run`, vì `run` đã là “chạy server ở cửa sổ này”); `rguard connect` chỉ in, không có `-Write`.

Còn lại: xoá tay thư mục rác `System.Collections.Hashtable/` ở gốc repo (sót từ lỗi test cũ, không bị tạo lại); chụp lại `docs/img` theo giao diện mới; kiểm tay UI trên máy thật; commit.

## 7. Lệnh tiện dùng

```powershell
# Chuyển một .ps1 mới sang UTF-8 BOM + CRLF
$f = 'scripts\ten-file.ps1'; $t = [IO.File]::ReadAllText($f) -replace "`r?`n", "`r`n"; [IO.File]::WriteAllText($f, $t, (New-Object Text.UTF8Encoding($true)))
```
