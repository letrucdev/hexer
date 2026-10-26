# Changelog

Each version's section opens its release notes on GitHub, in English and Vietnamese. Write it for
people who use Hexer, before tagging the release (see CLAUDE.md, "Phát hành").

## 0.6.0 — 2026-10-26

### What's new
- Rename the Data Inspector's types and change their order: in Settings ▸ Inspector, each type's ⋯ button has Rename…, Move Up and Move Down, within its group. The inspector and its Step as menu use your names and order. Restore Defaults puts everything back.
- File ▸ Open Recent Disk Image lists the disk images you opened lately and reopens each one with the sector size you chose, without asking again. Clear Menu empties the list. Before, a disk image showed up in File ▸ Open Recent and reopened from there as an ordinary file, without its sector size.
- A new document window now fills the screen (below the menu bar, beside the Dock) instead of opening at a smaller size.
- In Settings ▸ General, Last checked shows the whole date and time; it used to be cut short.

### Có gì mới
- Đổi tên và đổi thứ tự các kiểu trong Trình kiểm tra dữ liệu: trong Cài đặt ▸ Trình kiểm tra, nút ⋯ của mỗi kiểu có Đổi tên…, Chuyển lên và Chuyển xuống, trong nhóm của kiểu đó. Trình kiểm tra và menu Bước theo dùng tên và thứ tự bạn đặt. Khôi phục mặc định đưa mọi thứ về như cũ.
- Tệp ▸ Mở ảnh đĩa gần đây liệt kê các ảnh đĩa bạn mở gần đây và mở lại từng ảnh với kích thước sector bạn đã chọn, không hỏi lại. Xóa menu làm trống danh sách. Trước đây ảnh đĩa hiện trong Tệp ▸ Mở mục gần đây và mở lại từ đó thành tệp thường, mất kích thước sector.
- Cửa sổ tài liệu mới giờ phủ kín màn hình (dưới thanh menu, cạnh Dock) thay vì mở ở kích thước nhỏ hơn.
- Trong Cài đặt ▸ Chung, Lần kiểm tra gần nhất hiện đủ ngày giờ; trước đây bị cắt mất phần cuối.

## 0.5.0 — 2026-10-26

### What's new
- Typing Vietnamese with OpenKey, Unikey or EVKey in the Decoded text column works in Overwrite mode: "a" then "s" turns the byte into "á". Before, the tool's correction deleted a byte and Hexer asked whether to change the file size.
- In imported files with folded undefined sections, right-click inside a section you opened and choose Fold Section to fold just that one again.
- Moving with ↑ and ↓ past a folded section keeps the caret in its column. Before, it jumped to the start of the row.
- File ▸ Print folds undefined sections like the editor, so a printout no longer runs to pages of "??".
- Opening Search Results, Checksums or Compare below the grid no longer makes the window wider. Their tabs look like standard macOS tabs.
- If Hexer is in a folder you can't change, such as an administrator's Applications folder, it still installs updates: it asks for an administrator's name and password when it quits. Before, it could only open the download page.
- If you choose Relaunch to install an update and then cancel when Hexer asks to save your changes, Hexer no longer reopens itself the next time you quit.
- Common system errors, such as "Permission denied" or "No space left on device", appear in Vietnamese when Hexer is in Vietnamese.

### Có gì mới
- Gõ tiếng Việt bằng OpenKey, Unikey hay EVKey ở cột Văn bản giải mã giờ dùng được ở chế độ Ghi đè: gõ "a" rồi "s" biến byte đó thành "á". Trước đây lần sửa chữ của bộ gõ xoá mất một byte, và Hexer hỏi có muốn đổi kích thước tệp không.
- Trong tệp nhập có các vùng chưa xác định được gập lại, bấm chuột phải vào một vùng bạn đã mở rồi chọn Gập vùng này để chỉ gập lại vùng đó.
- Di chuyển bằng ↑ và ↓ qua một vùng đã gập giờ giữ con trỏ ở đúng cột. Trước đây con trỏ nhảy về đầu hàng.
- Tệp ▸ In… gập các vùng chưa xác định giống trình soạn thảo, nên bản in không còn kéo dài nhiều trang toàn "??".
- Mở Kết quả tìm kiếm, Tổng kiểm tra hay So sánh bên dưới lưới không còn làm cửa sổ rộng ra. Các thẻ của chúng trông như thẻ chuẩn của macOS.
- Nếu Hexer nằm trong thư mục bạn không có quyền thay đổi, chẳng hạn thư mục Ứng dụng của quản trị viên, Hexer vẫn cài được bản cập nhật: nó hỏi tên và mật khẩu quản trị viên khi thoát. Trước đây Hexer chỉ mở được trang tải về.
- Nếu bạn chọn Mở lại để cài bản cập nhật rồi bấm Huỷ khi Hexer hỏi lưu thay đổi, Hexer không còn tự mở lại vào lần thoát sau.
- Các lỗi hệ thống thường gặp, như "Không có quyền truy cập" hay "Thiết bị hết chỗ trống", giờ hiện bằng tiếng Việt khi Hexer dùng tiếng Việt.

## 0.4.1 — 2026-10-26

### What's new
- Typing hex digits in the hex column changes the bytes. Before, nothing happened when you typed there with the keyboard (typing in the Decoded text column worked).

### Có gì mới
- Gõ chữ số hex ở cột hex giờ sửa được byte. Trước đây gõ bằng bàn phím ở cột này không có tác dụng gì (gõ ở cột Văn bản giải mã thì vẫn được).

## 0.4.0 — 2026-10-25

### What's new
- Hexer now checks for updates on its own update server (on Cloudflare) and downloads them from there, with the GitHub release as a fallback. Before, every check went to GitHub's API, which allows 60 requests an hour per network: on a busy network, or after watching a build, Check for Updates… could fail with "GitHub has had too many requests", and where GitHub is slow or blocked, updates didn't arrive at all. Hexer 0.3.x finds this version through GitHub as usual; from here on, updates come from the new server.

### Có gì mới
- Hexer giờ kiểm tra và tải bản cập nhật từ máy chủ cập nhật riêng (đặt trên Cloudflare), còn trang phát hành trên GitHub là nguồn dự phòng. Trước đây mỗi lần kiểm tra đều gọi API của GitHub, vốn chỉ cho 60 lần mỗi giờ trên một mạng: ở mạng đông người, hoặc sau khi theo dõi một bản build, Kiểm tra cập nhật… có thể báo "GitHub đã nhận quá nhiều yêu cầu", còn ở nơi GitHub chậm hoặc bị chặn thì không nhận được bản cập nhật. Hexer 0.3.x vẫn tìm thấy bản này qua GitHub như trước; từ bản này trở đi, bản cập nhật đến từ máy chủ mới.

## 0.3.2 — 2026-10-25

### What's new
- The Tools windows (Open Disk, Clone Disk, Split File, Concatenate Files, Wipe Securely), Software Update and Settings open in the middle of the screen. Before, they opened off to the right and lower down. Statistics opens in the middle the first time too, then where you left it.
- Help ▸ Hexer Help (⌘?) opens the list of every command and its keyboard shortcut. Before, it said help wasn't available.
- The File menu has a single Open Recent, right after Open…, listing the files you opened recently. Before, a second Open Recent further down was always empty.

### Có gì mới
- Các cửa sổ công cụ (Mở ổ đĩa, Nhân bản ổ đĩa, Tách tệp, Ghép tệp, Xoá an toàn), Cập nhật phần mềm và Cài đặt giờ mở ở giữa màn hình. Trước đây chúng mở lệch sang phải và xuống dưới. Thống kê cũng mở ở giữa trong lần đầu, sau đó mở ở chỗ bạn để lại.
- Trợ giúp ▸ Trợ giúp Hexer (⌘?) mở danh sách mọi lệnh kèm phím tắt. Trước đây app báo không có trợ giúp.
- Menu Tệp chỉ còn một mục Mở mục gần đây, ngay sau Mở…, liệt kê các tệp bạn mở gần đây. Trước đây còn một mục Mở gần đây thứ hai ở bên dưới, lúc nào cũng trống.

## 0.3.1 — 2026-10-25

### What's new
- When you open the Hexer disk image, its volume shows Hexer's icon instead of a plain disk.
- Updating Hexer no longer leaves macOS pointing at the temporary copy it installed from, which could make Hexer's icon appear blank in the Dock, Spotlight or Open With.

### Có gì mới
- Khi mở ảnh đĩa cài đặt Hexer, volume của nó hiện icon Hexer thay vì icon ổ đĩa thông thường.
- Sau khi Hexer tự cập nhật, macOS không còn trỏ tới bản sao tạm dùng để cài, vốn có thể làm icon Hexer hiện trống trên Dock, Spotlight hay trong menu Mở bằng.

## 0.3.0 — 2026-10-25

### What's new
- Hexer updates itself. Once a day it looks for a new version; when there is one, it shows what's new and installs it when you agree, after checking that the update is signed by Hexer's developer and hasn't been changed. Choose Hexer ▸ Check for Updates… to look now. In Settings ▸ General you can turn off the daily check or include beta versions.
- This is the first version that can update itself. If you use Hexer 0.2.0 or earlier, install this one by hand; later versions then come to you.

### Có gì mới
- Hexer tự cập nhật. Mỗi ngày một lần, app tìm phiên bản mới; khi có, app cho biết có gì mới và cài khi bạn đồng ý, sau khi kiểm tra bản cập nhật có chữ ký của nhà phát triển Hexer và không bị sửa đổi. Chọn Hexer ▸ Kiểm tra cập nhật… để tìm ngay. Trong Cài đặt ▸ Chung, bạn có thể tắt việc kiểm tra hằng ngày hoặc nhận cả bản thử nghiệm.
- Đây là phiên bản đầu tiên tự cập nhật được. Nếu bạn đang dùng Hexer 0.2.0 trở xuống, hãy cài bản này bằng tay; các phiên bản sau sẽ tự đến.

## 0.2.0 — 2026-10-24

### What's new
- The first time Hexer starts without a file, a short welcome tour shows what it can do: edit files of any size, find, inspect and compare, and open disks safely. Open a File… on the last page brings up the Open panel. To see the tour again, choose Help ▸ Welcome to Hexer.

### Có gì mới
- Lần đầu Hexer mở mà không kèm tệp, một màn hình chào ngắn sẽ giới thiệu những gì app làm được: sửa tệp ở mọi kích thước; tìm, kiểm tra và so sánh; mở ổ đĩa an toàn. Nút Mở tệp… ở trang cuối mở bảng Open. Muốn xem lại thì chọn Trợ giúp ▸ Chào mừng đến với Hexer.

## 0.1.1 — 2026-10-24

### What's new
- Hexer shows the Open panel as soon as it starts without a file. Before, it opened no window until you clicked its Dock icon.

### Có gì mới
- Mở Hexer mà không kèm tệp thì bảng Open hiện ngay. Trước đây app không mở cửa sổ nào cho tới khi bấm icon Hexer trên Dock.

## 0.1 — 2026-10-24

### What's new
- First release. The README lists the features.

### Có gì mới
- Bản phát hành đầu tiên. Danh sách tính năng nằm trong README.
