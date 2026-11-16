# Nhật ký thay đổi

Theo [Keep a Changelog](https://keepachangelog.com/vi/1.1.0/); số phiên bản theo [SemVer](https://semver.org/lang/vi/). Phiên bản hiện tại nằm trong file `VERSION`.

## [0.9.0] - 2026-11-14

Bản đầu tiên đóng gói như một ứng dụng: có trình cài và trình gỡ, số phiên bản, kết nối được nhiều loại agent.

### Thêm
- **Cài đặt / gỡ**: `install.ps1` (cài vào `%LOCALAPPDATA%\Programs\ResourceGuard`, lối tắt Start Menu, đăng ký Settings → Apps, tuỳ chọn `-Autostart`, `-Desktop`, `-AddToPath`) và `uninstall.ps1` (giữ dữ liệu trừ khi `-PurgeData`). Không cần quyền admin.
- Giao diện mở trong **cửa sổ ứng dụng** riêng (Edge/Chrome `--app`), dự phòng trình duyệt mặc định (`ui.openAs`).
- Lệnh **`rguard`**, không trùng ripgrep; `rg path` cảnh báo khi máy có `rg.exe` của ripgrep. Lệnh mới: `version`, `connect`, `wrap`, `mcp`.
- **Kết nối agent**: danh mục agent khai trong config (Claude Code, Codex CLI, Gemini CLI, Cursor, GitHub Copilot CLI, VS Code, Windsurf, opencode, Goose, Aider, Ollama); MCP server qua stdio với 5 công cụ chỉ đọc/tư vấn; hook cho Gemini CLI và Cursor; kênh HTTP `/api/connect/v1/*` cho script và CI; bọc lệnh `rguard wrap`.
- **Trợ lý AI đánh giá** chọn được nhà cung cấp: Claude Code, Codex CLI, Gemini CLI, Ollama, API tương thích OpenAI. Kết quả của mọi nhà cung cấp đi qua cùng một bộ kiểm schema. Khoá API chỉ đọc từ biến môi trường.
- Cài đặt: thẻ **Kết nối agent** (trạng thái từng agent, hướng dẫn kèm nút Sao chép), **Trợ lý AI đánh giá** (chọn nhà cung cấp, Thử kết nối), **Giới thiệu** (phiên bản, nơi lưu dữ liệu, chi phí thực đo). Số phiên bản ở chân thanh bên.
- `tests/Acceptance-Agents.ps1`: danh mục, chuẩn hoá hook, MCP qua stdio thật, nhà cung cấp CLI/HTTP giả, kiểm khoá API không lọt vào log.

### Sửa
- Ghi file nguyên tử: `[IO.File]::Replace` luôn lỗi trên PowerShell 5.1 (`$null` thành `""`), mỗi lần ghi mất khoảng 650 ms và không còn nguyên tử.
- Hiệu năng: cache cấu hình, lượt lấy mẫu nhẹ hơn (bỏ truy vấn pagefile, ghi `status.html` thưa hơn), cache phản hồi cho các API nặng, phục vụ nhiều request mỗi vòng, `ETag` cho file tĩnh.
- Thanh “Chính sách đã đổi” hiện dù người dùng chưa sửa gì.
- Hai bước trùng tên (“Đóng Trình duyệt”) ở Tổng quan: thêm tên tiến trình.
- Chấm kết nối đỏ “đang kết nối…” khi số liệu đã hiện.
- Thẻ ở Cài đặt bị kéo cao theo thẻ bên cạnh; nhóm “nhóm nhỏ khác · 0 B” ở Ổ đĩa.
- Hook đọc stdin có BOM / đường dẫn có dấu.

### Đổi
- Giao diện không còn nhắc cứng “claude”: dùng tên nhà cung cấp đang chọn.
- Chỉ hỗ trợ Windows PowerShell 5.1 (không cần `pwsh`).
