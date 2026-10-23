# Hexer

Trình sửa hex cho macOS 27, viết bằng SwiftUI + AppKit với Liquid Glass. Mục tiêu là đủ tính năng như HxD 2.5. Giao diện có tiếng Anh và tiếng Việt.

## Đọc trước
- **[HANDOFF.md](HANDOFF.md):** đọc khi bắt đầu một việc mới. File ghi trạng thái, kiến trúc, việc chưa làm, việc cần cải thiện và nhật ký các phiên.
- **[DESIGN.md](DESIGN.md):** đọc trước khi sửa bất kỳ UI nào. Canvas gốc nằm ở https://claude.ai/artifact/JBSgQBQpVLtMWto8QECZgb.

## Build và kiểm tra (không có Xcode, chỉ có Command Line Tools)
- `Scripts/bundle.sh` build ra `build/Hexer.app`. Build dừng nếu có chuỗi UI chưa dịch tiếng Việt.
- `Scripts/test.sh` chạy swift-testing (không có XCTest).
- `Scripts/crosscheck.sh` so `hexer-cli` với các công cụ hệ thống.
- Trước khi báo xong, cả ba lệnh trên đều phải đạt.

## Quy tắc
- **Không dùng `@State`**, vì CLT thiếu SwiftUIMacros. Dùng model `@Observable` + `@Bindable`.
- **Chuỗi UI mới:** viết khoá tiếng Anh trong `Text("…")` hoặc `L("…")`, rồi thêm bản dịch vào `Scripts/l10n/vi.py`.
- **Đặt code đúng tầng:** logic thuần nằm trong `HexerCore` và phải có test; ổ đĩa nằm trong `HexerPlatform`; app nằm trong `Sources/Hexer`, mặc định chạy trên MainActor.
- **Giao diện theo HIG macOS 27:**
  - Sidebar, inspector, sheet và alert dùng của hệ thống.
  - Liquid Glass chỉ dùng cho control nổi, cao `GlassBar.height` (36).
  - Toolbar tối đa 3 nhóm.
- **Sửa UI xong** thì cập nhật luôn canvas và DESIGN.md.
- **Kiểm UI bằng ảnh chụp app thật:**
  - Dùng `-HexerSnapshot` và các cờ `-Hexer…`; mỗi cờ phải kèm một giá trị.
  - Kiểm cả giao diện sáng, tối, tiếng Việt (`-AppleLanguages '(vi)'`) và cửa sổ hẹp.
  - Chỉ chụp theo cửa sổ (`screencapture -l`), không bao giờ chụp vùng màn hình.
- **Ổ đĩa:** mặc định chỉ đọc; không ghi vào ổ khởi động; không dùng `authopen -w`.
- **Git:** thư mục chưa có repo. Chỉ `git init` hoặc commit khi người dùng yêu cầu.
- **Cuối mỗi phiên:** cập nhật HANDOFF.md (đã làm, chưa làm, nhật ký).
