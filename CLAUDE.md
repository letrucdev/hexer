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
- **Git:** repo `letrucdev/hexer`, nhánh `main`. Chỉ commit, push hoặc tạo tag khi người dùng yêu cầu.
- **Phát hành:** push lên `main` không tạo release; chỉ push tag phiên bản mới tạo release (`.github/workflows/release.yml`).
  - Tên tag dạng `vX.Y.Z`, ví dụ `v0.1.1`. Sửa lỗi hoặc thay đổi nhỏ thì tăng Z. Có tính năng mới thì tăng Y và đặt Z về 0. Thay đổi lớn thì tăng X.
  - Bản thử nghiệm thêm hậu tố `-beta.N`, ví dụ `v0.2.0-beta.1`; workflow sẽ đánh dấu là pre-release.
  - **Mỗi release phải ghi những gì thay đổi.** Trước khi tạo tag, thêm mục `## X.Y.Z — YYYY-MM-DD` lên đầu `CHANGELOG.md`, gồm `### What's new` (tiếng Anh) và `### Có gì mới` (tiếng Việt).
    - Viết cho người dùng: dùng app thì thấy gì khác. Không chép tiêu đề commit; bỏ qua thay đổi chỉ ở test, CI hay tài liệu.
    - Mục này mở đầu ghi chú release trên GitHub. Xem trước bằng `Scripts/release_notes.sh X.Y.Z vTRƯỚC`.
    - Thiếu mục thì workflow Release dừng ngay ở job `notes`, trước khi chạy test hay build.
  - Dùng tag annotated, nội dung `Hexer X.Y.Z`. Commit và push `CHANGELOG.md` lên `main` trước, rồi đặt tag trên commit đó: `git tag -a v0.1.1 -m "Hexer 0.1.1" <commit> && git push origin v0.1.1`.
    - CI của phần code phải đã đạt. Commit chỉ sửa tệp `.md` thì không chạy CI; workflow Release tự chạy lại toàn bộ CI.
  - Không sửa `CFBundleShortVersionString` bằng tay, vì workflow lấy phiên bản từ tag.
  - **Tự cập nhật:** workflow ký DMG bằng secret `HEXER_UPDATE_KEY` (khoá Ed25519, bản gốc trong Keychain của máy; xem HANDOFF.md, "Khoá ký bản cập nhật"); thiếu secret thì workflow dừng ở job `notes`. Không đổi `HexerUpdatePublicKey` trong `Resources/Info.plist`: các bản đã cài chỉ tin khoá đó, đổi là chúng không tự cập nhật được nữa.
  - Sau khi push tag, theo dõi workflow Release đến khi xong (khoảng 7 phút). Rồi kiểm tra trang release có `Hexer-X.Y.Z.dmg`, `Hexer-X.Y.Z.dmg.sha256`, `Hexer-X.Y.Z.dmg.sig` và phần thay đổi của phiên bản.
- **Cuối mỗi phiên:** cập nhật HANDOFF.md (đã làm, chưa làm, nhật ký).
