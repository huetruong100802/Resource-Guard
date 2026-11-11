# Resource Guard — Yêu cầu UI và quyết định (ghi nhận 2026-11-11)

File này ghi lại điều chủ sản phẩm đã nói, tách khỏi plan phase. Khi mâu thuẫn với README hoặc code, **file này và mockup (`docs/mockup/index.html`) đi trước**.

## 1. Việc ưu tiên hiện tại

1. **UI phải rõ ràng trước.** Giao diện thực tế đang lệch mockup, xấu và lộn xộn.
2. **Luồng thủ công (manual) phải chạy đầy đủ**: xem ổ đĩa, hiểu cái gì chiếm chỗ, chọn nhóm, xem trước ảnh hưởng, dọn, khôi phục.
3. Agent AI và tự động hoá **để sau**. Chưa triển khai vội.

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
