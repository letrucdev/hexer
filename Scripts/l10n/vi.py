# Vietnamese translations of Hexer's UI strings; generates Resources/Localization/vi.lproj.
# Usage: python3 -I Scripts/l10n/vi.py   (then: swift Scripts/l10n_audit.swift)
import os, sys

VI = {
    # Menus (macOS conventions, terms from the design canvas)
    "File": "Tệp", "Edit": "Sửa", "Search": "Tìm kiếm", "View": "Hiển thị", "Analysis": "Phân tích",
    "Tools": "Công cụ", "Window": "Cửa sổ", "Help": "Trợ giúp", "Services": "Dịch vụ",
    "About %@": "Giới thiệu về %@", "Settings…": "Cài đặt…", "Hide %@": "Ẩn %@",
    "Hide Others": "Ẩn các ứng dụng khác", "Show All": "Hiện tất cả", "Quit %@": "Thoát %@",
    "New": "Mới", "Open…": "Mở…", "Open Disk…": "Mở ổ đĩa…", "Open Disk Image…": "Mở ảnh đĩa…",
    "Open Recent": "Mở gần đây", "Clear Menu": "Xoá menu", "Close": "Đóng", "Close All": "Đóng tất cả",
    "Save": "Lưu", "Save As…": "Lưu thành…", "Save All": "Lưu tất cả", "Save Selection As…": "Lưu vùng chọn thành…",
    "Reload from Disk": "Tải lại từ đĩa", "Import": "Nhập", "Export": "Xuất", "Intel Hex…": "Intel Hex…",
    "Motorola S-Record…": "Motorola S-Record…", "ETL Extended…": "ETL Extended…",
    "Page Setup…": "Thiết lập trang…", "Print…": "In…",
    "Undo": "Hoàn tác", "Redo": "Làm lại", "Undo %@": "Hoàn tác %@", "Redo %@": "Làm lại %@",
    "Cut": "Cắt", "Copy": "Sao chép", "Copy As": "Sao chép dưới dạng", "Copy Offset": "Sao chép vị trí",
    "Paste": "Dán", "Paste Insert": "Dán chèn", "Paste Overwrite": "Dán ghi đè", "Delete": "Xoá",
    "Insert Bytes…": "Chèn byte…", "Fill Selection…": "Điền vùng chọn…", "Select All": "Chọn tất cả",
    "Select Block…": "Chọn khối…", "Insert Mode": "Chế độ chèn", "Overwrite Mode": "Chế độ ghi đè",
    "Read-only": "Chỉ đọc", "Toggle Insert/Overwrite": "Chuyển Chèn/Ghi đè",
    "Find…": "Tìm…", "Replace…": "Thay thế…", "Find Next": "Tìm tiếp", "Find Previous": "Tìm lùi",
    "Use Selection for Find": "Dùng vùng chọn để tìm", "Go to Offset…": "Đi tới vị trí…",
    "Set Bookmark": "Đặt dấu trang", "Go to Bookmark": "Tới dấu trang", "Bookmark %lld": "Dấu trang %lld",
    "Show Sidebar": "Hiện thanh bên", "Show Inspector": "Hiện trình kiểm tra", "Hide Inspector": "Ẩn trình kiểm tra",
    "Search Results": "Kết quả tìm kiếm", "Checksums": "Tổng kiểm tra", "Compare": "So sánh",
    "Bytes per Row": "Số byte mỗi hàng", "Custom…": "Tuỳ chỉnh…", "Fit to Window Width": "Vừa chiều rộng cửa sổ",
    "Byte Group Size": "Cỡ nhóm byte", "Columns": "Cột", "Hex and Text": "Hex và văn bản", "Hex Only": "Chỉ hex",
    "Text Only": "Chỉ văn bản", "Offset Base": "Hệ cơ số vị trí", "Hexadecimal": "Thập lục phân",
    "Decimal": "Thập phân", "Octal": "Bát phân", "Text Encoding": "Bảng mã văn bản",
    "Lowercase Hex Digits": "Chữ số hex viết thường", "Filter Characters…": "Lọc ký tự…",
    "Enter Full Screen": "Vào toàn màn hình", "Statistics": "Thống kê", "Checksums…": "Tổng kiểm tra…",
    "Compare…": "So sánh…", "Next Difference": "Khác biệt tiếp theo", "Previous Difference": "Khác biệt trước",
    "Concatenate Files…": "Ghép tệp…", "Split File…": "Tách tệp…", "Wipe Securely…": "Xoá an toàn…",
    "Clone Disk…": "Nhân bản ổ đĩa…", "Minimize": "Thu nhỏ", "Zoom": "Thu/Phóng", "Tile Vertically": "Xếp dọc",
    "Tile Horizontally": "Xếp ngang", "Tab %lld": "Thẻ %lld", "Bring All to Front": "Đưa tất cả ra trước",
    "Hexer Help": "Trợ giúp Hexer", "Acknowledgements": "Ghi nhận",
    # Export formats
    "Raw Data": "Dữ liệu thô", "Hexadecimal Values": "Giá trị thập lục phân", "Decoded Text": "Văn bản đã giải mã",
    "Editor view": "Dạng xem trình soạn thảo", "Rich Text Format": "Rich Text Format",
    "Intel Hex (16-bit)": "Intel Hex (16 bit)", "Intel Hex (20-bit)": "Intel Hex (20 bit)", "Intel Hex (32-bit)": "Intel Hex (32 bit)",
    "Motorola S19": "Motorola S19", "Motorola S28": "Motorola S28", "Motorola S37": "Motorola S37",
    "Intel Hex": "Intel Hex", "Motorola S-Record": "Motorola S-Record",
    "Exporting": "Đang xuất", "Exports the whole file as %@.": "Xuất toàn bộ tệp dưới dạng %@.",
    "Exports the selected %@ bytes as %@.": "Xuất %@ byte đã chọn dưới dạng %@.",
    "Choose a %@ file to import.": "Chọn tệp %@ để nhập.",
    "The selection is too large to copy as text.": "Vùng chọn quá lớn để sao chép dưới dạng văn bản.",
    "Use File ▸ Export to write it to a file instead.": "Hãy dùng Tệp ▸ Xuất để ghi ra tệp.",
    # Toolbar, status bar, modes
    "Open": "Mở", "Open a file (⌘O)": "Mở một tệp (⌘O)", "Save (⌘S)": "Lưu (⌘S)", "Undo (⌘Z)": "Hoàn tác (⌘Z)",
    "Redo (⇧⌘Z)": "Làm lại (⇧⌘Z)", "Edit Mode": "Chế độ sửa", "Insert": "Chèn", "Overwrite": "Ghi đè",
    "Insert inserts typed bytes; Overwrite replaces them; Read-only prevents changes":
        "Chèn thêm byte khi gõ; Ghi đè thay byte hiện có; Chỉ đọc chặn mọi thay đổi",
    "Find": "Tìm", "Find (⌘F)": "Tìm (⌘F)", "Go to Offset (⌘L)": "Đi tới vị trí (⌘L)", "Inspector": "Trình kiểm tra",
    "Show or hide the data inspector (⌥⌘I)": "Hiện hoặc ẩn trình kiểm tra dữ liệu (⌥⌘I)",
    "Offset": "Vị trí", "Offset:": "Vị trí:", "Block": "Khối", "Length": "Độ dài", "Length:": "Độ dài:",
    "Hex offsets": "Vị trí dạng hex", "Decimal offsets": "Vị trí dạng thập phân", "Octal offsets": "Vị trí dạng bát phân",
    "Click to switch between Insert and Overwrite (⌘I)": "Bấm để chuyển giữa Chèn và Ghi đè (⌘I)",
    "Stop": "Dừng", "Typing": "Gõ phím",
    # Sidebar
    "Bookmarks": "Dấu trang", "Sections": "Phân đoạn", "Document": "Tài liệu", "Size": "Kích thước",
    "Modified": "Đã sửa", "Encoding": "Bảng mã", "Layout": "Bố cục", "readable": "đọc được", "undefined": "chưa xác định",
    "Remove Bookmark": "Xoá dấu trang",
    "Undefined regions from Intel Hex and S-Record imports and unreadable disk sectors appear here.":
        "Các vùng chưa xác định từ tệp Intel Hex, S-Record và các sector ổ đĩa không đọc được sẽ hiện ở đây.", "%@ bytes": "%@ byte", "%lld bytes": "%lld byte",
    "%lld bytes · group %lld": "%lld byte · nhóm %lld",
    "Press ⌃⇧0–9 to bookmark the caret position; ⌃0–9 jumps back.": "Nhấn ⌃⇧0–9 để đánh dấu vị trí con trỏ; ⌃0–9 để quay lại.",
    # Results drawer
    "Results": "Kết quả", "Hide results": "Ẩn kết quả", "Clear": "Xoá", "%lld matches": "%lld kết quả",
    "No Search Results": "Không có kết quả tìm kiếm",
    "Press Find All in the find bar (⌘F) to list every match here.": "Bấm Tìm tất cả trên thanh tìm kiếm (⌘F) để liệt kê mọi kết quả ở đây.",
    "Excerpt (hex)": "Trích đoạn (hex)", "Excerpt (text)": "Trích đoạn (văn bản)",
    # Data inspector
    "Data Inspector": "Trình kiểm tra dữ liệu", "Byte order": "Thứ tự byte", "Little endian": "Little-endian",
    "Big endian": "Big-endian", "Hex": "Hex", "Show integers in hexadecimal": "Hiện số nguyên dạng thập lục phân",
    "Integers": "Số nguyên", "Characters": "Ký tự", "Floating point": "Số thực", "Date & time": "Ngày & giờ",
    "Other": "Khác", "Disassembly": "Hợp ngữ", "Disassembly (x86-16)": "Hợp ngữ (x86-16)",
    "Disassembly (x86-32)": "Hợp ngữ (x86-32)", "Disassembly (x86-64)": "Hợp ngữ (x86-64)", "Disassembly (ARM64)": "Hợp ngữ (ARM64)", "Binary (8 bit)": "Nhị phân (8 bit)", "AnsiChar": "Ký tự ANSI",
    "WideChar (UTF-16)": "Ký tự UTF-16", "UTF-8 code point": "Điểm mã UTF-8", "Single (float32)": "Số thực đơn (float32)",
    "Double (float64)": "Số thực kép (float64)", "OLETIME": "OLETIME", "FILETIME": "FILETIME", "DOS date": "Ngày DOS",
    "DOS time": "Giờ DOS", "DOS time & date": "Ngày giờ DOS", "time_t (32 bit)": "time_t (32 bit)", "time_t (64 bit)": "time_t (64 bit)",
    "Decoded text": "Văn bản giải mã", "Choose Types…": "Chọn kiểu dữ liệu…", "Double-click to edit": "Bấm đúp để sửa",
    "Inspector options": "Tuỳ chọn trình kiểm tra", "The data type whose size the arrows step by": "Kiểu dữ liệu quyết định bước nhảy của các mũi tên", "Value": "Giá trị", "Invalid": "Không hợp lệ", "Step as %@": "Bước theo %@", "Edit %@": "Sửa %@",
    "First array item": "Phần tử đầu tiên", "Previous array item": "Phần tử trước", "Next array item": "Phần tử tiếp theo",
    "Last array item": "Phần tử cuối cùng", "“%@” is not a valid %@ value.": "“%@” không phải giá trị %@ hợp lệ.",
    # Shared sheet parts
    "Cancel": "Huỷ", "OK": "OK", "Number base": "Hệ cơ số", "hex": "hex", "dec": "dec", "oct": "oct",
    "Numbers in:": "Số theo hệ:",
    # Go to / select block
    "Go to Offset": "Đi tới vị trí", "Go": "Đi", "Relative to": "Tính từ", "Relative to:": "Tính từ:",
    "Beginning of the file": "Đầu tệp", "Current offset (+ or −)": "Vị trí hiện tại (+ hoặc −)",
    "End of the file (backwards)": "Cuối tệp (đếm ngược)", "Destination: %@": "Đích: %@",
    "Select Block": "Chọn khối", "Select": "Chọn", "Start offset": "Vị trí đầu", "Start offset:": "Vị trí đầu:",
    "End": "Kết thúc", "End offset:": "Vị trí cuối:", "The block is empty or outside the file.": "Khối rỗng hoặc nằm ngoài tệp.",
    "%@ (selection).bin": "%@ (vùng chọn).bin", "Saving selection": "Đang lưu vùng chọn",
    # Insert / fill
    "Insert Bytes": "Chèn byte", "Byte count": "Số byte", "Byte count:": "Số byte:", "Fill pattern:": "Mẫu điền:",
    "Hex values": "Giá trị hex",
    "Hex values, repeated to fill. Inserts %@ bytes at offset %@ — the file grows to %@ bytes.":
        "Các giá trị hex được lặp lại để điền. Chèn %@ byte tại vị trí %@ — tệp tăng lên %@ byte.",
    "Enter a byte count and at least one hex value.": "Nhập số byte và ít nhất một giá trị hex.",
    "Fill Selection": "Điền vùng chọn", "Fill": "Điền", "Passes": "Lượt", "Add": "Thêm", "Remove": "Bớt",
    "Presets": "Mẫu có sẵn", "DoD Sanitizing": "Làm sạch DoD", "Zero Bytes": "Byte 0", "Pattern": "Mẫu",
    "Pattern of pass %lld": "Mẫu của lượt %lld", "Random bytes": "Byte ngẫu nhiên", "From": "Từ", "to": "đến", "To": "Đến",
    "(decimal)": "(thập phân)", "Hex values: %@": "Giá trị hex: %@", "Random bytes: %lld – %lld": "Byte ngẫu nhiên: %lld – %lld",
    "Write directly to disk (cannot be undone)": "Ghi trực tiếp xuống đĩa (không thể hoàn tác)",
    "Every pass is written to the file and flushed before the next one; undo history is cleared.":
        "Mỗi lượt được ghi vào tệp và đẩy xuống đĩa trước lượt tiếp theo; lịch sử hoàn tác bị xoá.",
    "Only the last pass is kept, as one undoable change. Earlier passes matter only when writing directly.":
        "Chỉ giữ lượt cuối, như một thay đổi có thể hoàn tác. Các lượt trước chỉ có tác dụng khi ghi trực tiếp.",
    "Save your changes first.": "Hãy lưu các thay đổi trước.",
    "Writing directly changes the file on disk, so it must match what Hexer shows.":
        "Ghi trực tiếp sẽ thay đổi tệp trên đĩa, nên tệp phải khớp với nội dung Hexer đang hiển thị.",
    "Overwrite %@ bytes of “%@” directly?": "Ghi đè trực tiếp %@ byte của “%@”?",
    "Each pass is written to the disk immediately. This cannot be undone.": "Mỗi lượt được ghi xuống đĩa ngay lập tức. Thao tác này không thể hoàn tác.",
    "Write Directly": "Ghi trực tiếp", "Writing directly": "Đang ghi trực tiếp",
    # Find bar
    "Find text": "Tìm văn bản", "Find hex values, e.g. 4D 5A": "Tìm giá trị hex, ví dụ 4D 5A", "Find an integer": "Tìm số nguyên",
    "Find a floating point number": "Tìm số thực", "Find All": "Tìm tất cả", "Find Previous (⇧⌘G)": "Tìm lùi (⇧⌘G)",
    "Find Next (⌘G)": "Tìm tiếp (⌘G)", "Close (Esc)": "Đóng (Esc)", "Data type and search options": "Kiểu dữ liệu và tuỳ chọn tìm",
    "Replace": "Thay thế", "Replace All": "Thay thế tất cả", "Replace with": "Thay bằng", "Prompt on replace": "Hỏi trước khi thay thế",
    "Text": "Văn bản", "Integer": "Số nguyên", "Float": "Số thực", "Data type": "Kiểu dữ liệu",
    "Type hex pairs, spaces optional: 54 46 6F 72 6D. ⌘E with bytes selected in the hex column fills this in.":
        "Nhập từng cặp hex, khoảng trắng tuỳ ý: 54 46 6F 72 6D. ⌘E khi đang chọn byte ở cột hex sẽ tự điền.",
    "Direction": "Hướng", "All": "Tất cả", "Forward": "Tiến", "Backward": "Lùi",
    "“All” searches the whole file, wrapping around at the end.": "“Tất cả” tìm toàn bộ tệp, hết tệp thì quay lại đầu.",
    "Editor (%@)": "Bảng mã trình soạn thảo (%@)", "Unicode UTF-16 LE": "Unicode UTF-16 LE", "Case sensitive": "Phân biệt hoa thường",
    "Bit width": "Độ rộng bit", "Bit width:": "Độ rộng bit:", "Sign": "Dấu", "Either": "Cả hai", "Signed": "Có dấu", "Unsigned": "Không dấu",
    "Type": "Kiểu", "%@ · %lld bytes": "%@ · %lld byte", "Searching": "Đang tìm", "Not found": "Không tìm thấy",
    "Search wrapped": "Đã quay lại đầu", "%lld of %lld": "%lld / %lld", "Finding matches": "Đang tìm các kết quả",
    "Replaced %lld occurrences": "Đã thay thế %lld chỗ", "Replace this occurrence at %@?": "Thay thế chỗ này tại %@?",
    "Occurrence %lld of %lld.": "Chỗ %lld / %lld.", "Skip": "Bỏ qua",
    # Checksums
    "Generate Checksums": "Tạo tổng kiểm tra", "Calculate": "Tính", "Sums": "Tổng", "CRC": "CRC", "Digests": "Mã băm",
    "Custom CRC…": "CRC tuỳ chỉnh…", "Custom CRC": "CRC tuỳ chỉnh", "Custom checksum": "Tổng kiểm tra tuỳ chỉnh",
    "Scope": "Phạm vi", "Scope:": "Phạm vi:", "Whole file": "Toàn bộ tệp", "Selection": "Vùng chọn", "Entire file": "Toàn bộ tệp",
    "Selection %@–%@": "Vùng chọn %@–%@", "Compare with expected value": "So với giá trị mong đợi", "Expected checksum": "Tổng kiểm tra mong đợi",
    "Result width:": "Độ rộng kết quả:", "Addend width:": "Độ rộng số hạng:", "Byte order:": "Thứ tự byte:",
    "Polynomial": "Đa thức", "Polynomial:": "Đa thức:", "Initial value": "Giá trị đầu", "Initial value:": "Giá trị đầu:",
    "Output XOR": "XOR đầu ra", "Output XOR:": "XOR đầu ra:", "Reflection:": "Đảo bit:", "Input": "Đầu vào", "Output": "Đầu ra",
    "%lld bits": "%lld bit", "Calculating checksums": "Đang tính tổng kiểm tra", "Algorithm": "Thuật toán", "Checksum": "Tổng kiểm tra",
    "Usage": "Phạm vi dùng", "Copy with Details": "Sao chép kèm chi tiết", "No Checksums": "Chưa có tổng kiểm tra",
    "Choose Analysis ▸ Checksums… to calculate checksums of the file or the selection.":
        "Chọn Phân tích ▸ Tổng kiểm tra… để tính tổng kiểm tra cho tệp hoặc vùng chọn.",
    "Matches the expected result": "Khớp với kết quả mong đợi", "Differs from the expected result": "Khác với kết quả mong đợi",
    "Expected result": "Kết quả mong đợi",
    "Compare every checksum with this value": "So sánh mọi tổng kiểm tra với giá trị này", "Refresh": "Làm mới",
    # Statistics
    "Statistics — %@": "Thống kê — %@", "Hide maximum": "Ẩn giá trị lớn nhất",
    "Leave out the most frequent byte so the other bars are readable": "Bỏ byte xuất hiện nhiều nhất để dễ đọc các cột khác",
    "%lld of 256 values present": "Có %lld / 256 giá trị", "Counting bytes": "Đang đếm byte", "Selected value": "Giá trị đang chọn",
    "Value under the pointer": "Giá trị dưới con trỏ", "Character": "Ký tự", "Count": "Số lần", "Share": "Tỉ lệ",
    "(control)": "(ký tự điều khiển)", "Bytes": "Byte", "Entropy": "Entropy", "%@ bits/byte": "%@ bit/byte",
    "Click a bar to keep it selected.": "Bấm vào một cột để giữ lựa chọn.",
    # Compare
    "1. Data source:": "1. Nguồn dữ liệu:", "2. Data source:": "2. Nguồn dữ liệu:", "Second data source": "Nguồn dữ liệu thứ hai",
    "Choose…": "Chọn…", "Open File…": "Mở tệp…", "Windows:": "Cửa sổ:", "Window arrangement": "Sắp xếp cửa sổ",
    "Side by side": "Cạnh nhau", "One above the other": "Trên dưới", "Whole files": "Toàn bộ tệp", "Selected data": "Dữ liệu đã chọn",
    "Selected data compares each window's selection (or from its caret to the end), aligned at their starts.":
        "“Dữ liệu đã chọn” so sánh vùng chọn của mỗi cửa sổ (hoặc từ con trỏ tới cuối), căn theo điểm bắt đầu.",
    "Choose the file to compare with “%@”.": "Chọn tệp để so sánh với “%@”.", "Comparing": "Đang so sánh",
    "Difference at %@ · %@ bytes": "Khác biệt tại %@ · %@ byte", "No more differences": "Hết khác biệt",
    "No earlier differences": "Không còn khác biệt phía trước", "F6: next difference": "F6: khác biệt tiếp theo",
    "Previous Difference (⇧F6)": "Khác biệt trước (⇧F6)", "Next Difference (F6)": "Khác biệt tiếp theo (F6)",
    "Stop Comparing": "Dừng so sánh", "List Differences": "Liệt kê khác biệt",
    "List every difference between the two windows.": "Liệt kê mọi khác biệt giữa hai cửa sổ.",
    "No Differences": "Không có khác biệt", "The compared data is identical.": "Dữ liệu được so sánh giống hệt nhau.",
    "Not Comparing": "Chưa so sánh",
    "Choose Analysis ▸ Compare… (⌘K) to compare this window with another file.":
        "Chọn Phân tích ▸ So sánh… (⌘K) để so sánh cửa sổ này với một tệp khác.",
    # Character filter
    "Filter Characters": "Lọc ký tự", "Show as characters": "Hiện dưới dạng ký tự", "All characters": "Mọi ký tự",
    "ASCII only (20–7E)": "Chỉ ASCII (20–7E)", "Letters and digits": "Chữ cái và chữ số", "Custom byte ranges:": "Dải byte tuỳ chỉnh:",
    "e.g. 20-7E, A0-FF": "ví dụ 20-7E, A0-FF",
    "Other bytes show as a dot in the text column. Searching and copying are not affected.":
        "Các byte khác hiện thành dấu chấm ở cột văn bản. Không ảnh hưởng tới tìm kiếm và sao chép.",
    "Preview in %@": "Xem trước với %@",
    # Accessibility, printing, about, help
    "hex editor": "trình sửa hex", "End of data, offset %@": "Hết dữ liệu, vị trí %@", "Offset %@: %@%@": "Vị trí %@: %@%@",
    "%@ bytes selected": "Đã chọn %@ byte", "The data is too large to print.": "Dữ liệu quá lớn để in.",
    "Select at most %@ to print, or use File ▸ Export ▸ Editor View.": "Hãy chọn tối đa %@ để in, hoặc dùng Tệp ▸ Xuất ▸ Dạng xem trình soạn thảo.",
    "A hex editor for macOS, modelled on HxD.": "Trình sửa hex cho macOS, theo mô hình HxD.",
    "Disassembly by Capstone %@ (BSD license).": "Dịch ngược bằng Capstone %@ (giấy phép BSD).",
    "No license files were found in the app bundle.": "Không tìm thấy tệp giấy phép trong gói ứng dụng.",
    "Every command of the menu bar, with its keyboard shortcut. Hexer follows HxD: edit in the hex or text column (Tab switches), Insert/Overwrite with ⌘I, and the inspector decodes the bytes at the caret.":
        "Mọi lệnh trên thanh menu kèm phím tắt. Hexer theo cách của HxD: sửa ở cột hex hoặc cột văn bản (Tab để chuyển), Chèn/Ghi đè bằng ⌘I, và trình kiểm tra giải mã các byte tại con trỏ.",
    "Search commands": "Tìm lệnh", "Menu": "Menu", "Command": "Lệnh", "Shortcut": "Phím tắt",
    # File tools
    "Split File": "Tách tệp", "Concatenate Files": "Ghép tệp", "Wipe Securely": "Xoá an toàn", "File:": "Tệp:",
    "Choose the file to split": "Chọn tệp cần tách", "Choose the file to split.": "Chọn tệp cần tách.",
    "Part base name:": "Tên gốc của các phần:", "Same as the file": "Giống tên tệp",
    "Parts are named after this, with .001, .002, … appended.": "Các phần được đặt theo tên này, thêm đuôi .001, .002, …",
    "Part size:": "Kích thước mỗi phần:", "Custom": "Tuỳ chỉnh", "bytes": "byte", "Naming:": "Đặt tên:",
    "Number consecutively (.001, .002…)": "Đánh số liên tiếp (.001, .002…)", "Ask for each name": "Hỏi tên từng phần",
    "Creates %lld parts.": "Tạo %lld phần.", "Split": "Tách", "Splitting": "Đang tách",
    "Name of part %lld of %lld": "Tên của phần %lld / %lld", "Add…": "Thêm…", "Drag to reorder": "Kéo để sắp xếp lại",
    "Output file:": "Tệp đầu ra:", "Choose where to save": "Chọn nơi lưu", "Save the joined file as:": "Lưu tệp đã ghép thành:",
    "Concatenate": "Ghép", "Concatenating": "Đang ghép", "Choose the files to join, in order.": "Chọn các tệp cần ghép, theo thứ tự.",
    "Choose the file to wipe": "Chọn tệp cần xoá", "Choose the file to overwrite and delete.": "Chọn tệp cần ghi đè rồi xoá.",
    "Method:": "Phương pháp:", "Method": "Phương pháp", "Naming": "Đặt tên", "Part size": "Kích thước mỗi phần", "DoD 5220.22-M (3 passes)": "DoD 5220.22-M (3 lượt)", "Zero bytes (1 pass)": "Byte 0 (1 lượt)",
    "Random bytes (1 pass)": "Byte ngẫu nhiên (1 lượt)",
    "On SSDs and APFS, copies of the data may remain (copy-on-write, snapshots, wear levelling). Use FileVault for guaranteed protection.":
        "Trên SSD và APFS, bản sao dữ liệu có thể vẫn còn (copy-on-write, snapshot, cân bằng hao mòn). Hãy dùng FileVault để được bảo vệ chắc chắn.",
    "Wipe and Delete": "Ghi đè và xoá", "Wipe “%@”?": "Xoá an toàn “%@”?",
    "The file is overwritten and deleted. It cannot be recovered.": "Tệp sẽ bị ghi đè rồi xoá, không thể khôi phục.", "Wiping": "Đang xoá an toàn",
    # Disks
    "Open Disk": "Mở ổ đĩa", "Clone Disk": "Nhân bản ổ đĩa", "Physical disks": "Ổ đĩa vật lý", "Logical volumes": "Ổ đĩa logic",
    "Name": "Tên", "Hardware": "Phần cứng", "Disk image": "Ảnh đĩa", "Internal": "Gắn trong", "External": "Gắn ngoài",
    "Open as read-only": "Mở ở chế độ chỉ đọc",
    "Raw access may ask for an administrator password. The startup disk can't be written.":
        "Truy cập trực tiếp có thể yêu cầu mật khẩu quản trị viên. Không thể ghi vào ổ đĩa khởi động.",
    "The startup disk can't be written.": "Không thể ghi vào ổ đĩa khởi động.", "%@ will open read-only.": "%@ sẽ được mở ở chế độ chỉ đọc.",
    "Open %@ with write access?": "Mở %@ với quyền ghi?",
    "Its volumes will be unmounted. Changes are written only when you save, but a mistake can destroy the data on the disk.":
        "Các ổ đĩa logic của nó sẽ bị tháo. Thay đổi chỉ được ghi khi bạn lưu, nhưng một sai sót có thể huỷ dữ liệu trên ổ đĩa.",
    "Changes are written only when you save, but a mistake can destroy the data on the disk.":
        "Thay đổi chỉ được ghi khi bạn lưu, nhưng một sai sót có thể huỷ dữ liệu trên ổ đĩa.",
    "Open for Writing": "Mở để ghi", "Open Read-only": "Mở chỉ đọc", "Write the changes to %@?": "Ghi các thay đổi vào %@?",
    "Its volumes are unmounted first. Writing to a disk cannot be undone, and the undo history is cleared afterwards.":
        "Các ổ đĩa logic sẽ được tháo trước. Ghi vào ổ đĩa không thể hoàn tác, và lịch sử hoàn tác sẽ bị xoá sau đó.",
    "Write to Disk": "Ghi vào ổ đĩa", "Writing to disk": "Đang ghi vào ổ đĩa", "Source:": "Nguồn:", "Target:": "Đích:",
    "Disk": "Ổ đĩa", "Disk image file": "Tệp ảnh đĩa", "Choose a file": "Chọn một tệp", "Choose the disk image to copy from.": "Chọn ảnh đĩa để sao chép.",
    "Save the disk image as:": "Lưu ảnh đĩa thành:",
    "Everything on the target is overwritten. The startup disk can't be a target.":
        "Mọi dữ liệu trên đích sẽ bị ghi đè. Ổ đĩa khởi động không thể làm đích.",
    "Overwrite %@?": "Ghi đè %@?", "All data on the disk is replaced. This cannot be undone.": "Mọi dữ liệu trên ổ đĩa sẽ bị thay thế. Thao tác này không thể hoàn tác.",
    "Clone": "Nhân bản", "Cloning": "Đang nhân bản", "Sector": "Sector", "of %@": "trên %@",
    "First sector": "Sector đầu tiên", "Previous sector": "Sector trước", "Next sector": "Sector tiếp theo", "Last sector": "Sector cuối cùng",
    "Sector size": "Kích thước sector", "Specify the sector size of “%@”.": "Chọn kích thước sector của “%@”.",
    "512 bytes (hard disks, USB drives)": "512 byte (ổ cứng, ổ USB)", "2048 bytes (CD, DVD)": "2048 byte (CD, DVD)",
    "4096 bytes (Advanced Format)": "4096 byte (Advanced Format)",
    "Choose a disk image to open. It keeps its size, like a disk: bytes can be overwritten but not inserted or deleted.":
        "Chọn ảnh đĩa để mở. Ảnh đĩa giữ nguyên kích thước như một ổ đĩa: có thể ghi đè byte nhưng không thể chèn hoặc xoá.",
    # Messages
    "Binary File": "Tệp nhị phân", "Change the file size?": "Thay đổi kích thước tệp?", "Change Size": "Đổi kích thước",
    "This edit inserts or removes bytes, so everything after it moves to a different offset.":
        "Thao tác này chèn hoặc xoá byte, nên mọi dữ liệu phía sau sẽ dời sang vị trí khác.",
    "Don't ask again": "Không hỏi lại", "The size of this data cannot change.": "Không thể thay đổi kích thước dữ liệu này.",
    "Disks and other fixed-size data can only be overwritten.": "Ổ đĩa và dữ liệu có kích thước cố định chỉ có thể ghi đè.",
    "The selection is too large to copy.": "Vùng chọn quá lớn để sao chép.",
    "Use File ▸ Save Selection As… to write large selections to a file.": "Hãy dùng Tệp ▸ Lưu vùng chọn thành… để ghi vùng chọn lớn ra tệp.",
    "Some characters were replaced by dots.": "Một số ký tự đã được thay bằng dấu chấm.",
    "Control characters and bytes without a character in %@ cannot be copied as text. Copy from the hex column to keep every byte.":
        "Ký tự điều khiển và các byte không có ký tự trong %@ không thể sao chép dạng văn bản. Hãy sao chép từ cột hex để giữ nguyên mọi byte.",
    "The clipboard does not contain valid hex values.": "Bộ nhớ tạm không chứa giá trị hex hợp lệ.",
    "To paste text, click in the text column first.": "Để dán văn bản, hãy bấm vào cột văn bản trước.",
    "The clipboard contains characters that %@ cannot represent.": "Bộ nhớ tạm chứa ký tự mà %@ không biểu diễn được.",
    "“%@” was changed by another application.": "“%@” đã bị một ứng dụng khác thay đổi.",
    "Reloading discards your unsaved changes.": "Tải lại sẽ bỏ các thay đổi chưa lưu.",
    "Reload it to see the current contents.": "Hãy tải lại để xem nội dung hiện tại.", "Reload": "Tải lại",
    "Keep Current Version": "Giữ phiên bản hiện tại", "Reload “%@” from disk?": "Tải lại “%@” từ đĩa?",
    # Welcome tour (Views/Welcome)
    "Welcome to Hexer": "Chào mừng đến với Hexer",
    "A fast hex editor for files and disks, modelled on HxD.": "Trình sửa hex nhanh cho tệp và ổ đĩa, theo mô hình HxD.",
    "Edit any file, whatever its size": "Sửa mọi tệp, dù lớn đến đâu",
    "Type over bytes or insert new ones, with unlimited undo.": "Gõ đè lên byte hoặc chèn byte mới, hoàn tác không giới hạn.",
    "Files of many gigabytes open at once.": "Tệp nặng nhiều gigabyte vẫn mở ngay lập tức.",
    "Import Intel Hex and S-Record, or export as C, Java, HTML and more.":
        "Nhập Intel Hex và S-Record, hoặc xuất ra C, Java, HTML và nhiều định dạng khác.",
    "Find, inspect and compare": "Tìm, kiểm tra và so sánh",
    "Search for text, hex values, integers or floating-point numbers.": "Tìm văn bản, giá trị hex, số nguyên hoặc số thực.",
    "The Data Inspector decodes the bytes at the caret in 30 formats.":
        "Trình kiểm tra dữ liệu giải mã các byte tại con trỏ theo 30 kiểu.",
    "Calculate checksums and statistics, or compare two files.": "Tính tổng kiểm tra và thống kê, hoặc so sánh hai tệp.",
    "Disks, safely": "Ổ đĩa, an toàn là trên hết",
    "Open physical disks, volumes and disk images.": "Mở ổ đĩa vật lý, ổ đĩa logic và ảnh đĩa.",
    "Disks open read-only until you choose to write.": "Ổ đĩa mở ở chế độ chỉ đọc cho đến khi bạn chọn ghi.",
    "Your startup disk is never written.": "Ổ đĩa khởi động không bao giờ bị ghi.",
    "Back": "Quay lại", "Continue": "Tiếp tục", "Open a File…": "Mở tệp…", "Page %lld of %lld": "Trang %lld / %lld",
    # Software update (App/SoftwareUpdate.swift, Views/SoftwareUpdateView.swift, Settings ▸ General)
    "Check for Updates…": "Kiểm tra cập nhật…", "Software Update": "Cập nhật phần mềm",
    "Checking for updates…": "Đang kiểm tra cập nhật…", "Hexer is up to date": "Hexer đã là bản mới nhất",
    "Version %@ is the newest version available.": "Phiên bản %@ là bản mới nhất hiện có.",
    "Hexer %@ is available": "Đã có Hexer %@",
    "You have version %@. Hexer downloads the update, checks it and installs it when it relaunches.":
        "Bạn đang dùng phiên bản %@. Hexer sẽ tải bản cập nhật, kiểm tra rồi cài khi mở lại.",
    "What’s New": "Có gì mới", "Release Notes on GitHub": "Ghi chú phát hành trên GitHub",
    "Skip This Version": "Bỏ qua phiên bản này", "Remind Me Later": "Nhắc tôi sau", "Install Update": "Cài bản cập nhật",
    "Open Download Page": "Mở trang tải về", "Download…": "Tải về…",
    "Opens the release’s page on GitHub": "Mở trang của phiên bản này trên GitHub", "Downloading Hexer %@…": "Đang tải Hexer %@…", "%@ of %@": "%@ / %@",
    "Verifying Hexer %@…": "Đang xác minh Hexer %@…",
    "Hexer checks the update’s signature and the app inside it before installing it.":
        "Hexer kiểm tra chữ ký của bản cập nhật và app bên trong trước khi cài.",
    "Hexer %@ is ready to install": "Hexer %@ đã sẵn sàng để cài",
    "Relaunch Hexer to start using it. If you keep working, the update installs when you quit Hexer.":
        "Mở lại Hexer để bắt đầu dùng bản mới. Nếu bạn tiếp tục làm việc, bản cập nhật sẽ được cài khi bạn thoát Hexer.",
    "Before quitting, Hexer asks whether to save your changes.": "Trước khi thoát, Hexer sẽ hỏi bạn có lưu các thay đổi không.",
    "Install on Quit": "Cài khi thoát", "Relaunch": "Mở lại",
    "Couldn’t check for updates": "Không kiểm tra được bản cập nhật", "Couldn’t install the update": "Không cài được bản cập nhật",
    "Check for updates automatically": "Tự động kiểm tra cập nhật", "Include beta versions": "Nhận cả bản thử nghiệm (beta)",
    "Last checked": "Lần kiểm tra gần nhất", "Never": "Chưa bao giờ", "Check Now": "Kiểm tra ngay",
    # Folded undefined sections
    "Fold Undefined Sections": "Gập các vùng chưa xác định", "%@ undefined bytes": "%@ byte chưa xác định",
    "Click to show": "Bấm để hiện",
    # Errors from HexerCore and HexerPlatform (App/ErrorMessages.swift)
    "The update server answered with status %lld.": "Máy chủ cập nhật trả về mã %lld.",
    "GitHub has had too many requests from this network. Try again in an hour.":
        "GitHub đã nhận quá nhiều yêu cầu từ mạng này. Hãy thử lại sau một giờ.",
    "The list of releases could not be read.": "Không đọc được danh sách phiên bản.",
    "The download is larger than an update of Hexer can be.": "Tệp tải về lớn hơn mức một bản cập nhật Hexer có thể có.",
    "This copy of Hexer has no valid key to check updates with.": "Bản Hexer này không có khoá hợp lệ để kiểm tra bản cập nhật.",
    "The signing key must be 32 bytes, Base64-encoded.": "Khoá ký phải dài 32 byte, mã hoá Base64.",
    "The update’s signature is not valid, so it was not installed.":
        "Chữ ký của bản cập nhật không hợp lệ nên bản cập nhật không được cài.",
    "The downloaded disk image doesn’t contain Hexer.": "Ảnh đĩa tải về không chứa Hexer.",
    "The downloaded app is version %@, not %@.": "App tải về là phiên bản %@, không phải %@.",
    "This version of Hexer requires macOS %@ or later.": "Phiên bản Hexer này cần macOS %@ trở lên.",
    "macOS runs Hexer from a temporary location because it wasn’t moved after downloading. Move Hexer to the Applications folder, open it from there and try again.":
        "macOS đang chạy Hexer từ một vị trí tạm vì app chưa được di chuyển sau khi tải về. Hãy chuyển Hexer vào thư mục Applications (Ứng dụng), mở từ đó rồi thử lại.",
    "Hexer can’t replace itself in “%@” because you don’t have permission to change it.":
        "Hexer không tự thay thế được trong “%@” vì bạn không có quyền thay đổi thư mục này.",
    "Replacing “%@” failed: %@.": "Không thay thế được “%@”: %@.",
    "The disk image could not be opened: %@": "Không mở được ảnh đĩa: %@",
    "The code signature of “%@” is not valid (%lld).": "Chữ ký mã của “%@” không hợp lệ (%lld).",
    "Enter a value to search for.": "Nhập giá trị cần tìm.",
    "The pattern has to contain at least one hex-value.": "Mẫu tìm phải có ít nhất một giá trị hex.",
    "The pattern '%@' contains invalid hex-values.": "Mẫu '%@' chứa giá trị hex không hợp lệ.",
    "The search- or replace-pattern contains characters that the selected text encoding (%@) cannot represent.":
        "Mẫu tìm hoặc mẫu thay thế chứa ký tự mà bảng mã đang chọn (%@) không biểu diễn được.",
    "“%@” is not a valid integer number.": "“%@” không phải là số nguyên hợp lệ.",
    "“%@” is out of range representable with %lld bits.": "“%@” nằm ngoài phạm vi biểu diễn được bằng %lld bit.",
    "“%@” is not a valid floating point number.": "“%@” không phải là số thực hợp lệ.",
    "“%@” cannot be represented as %@.": "Không thể biểu diễn “%@” dưới dạng %@.",
    "The size of the search- and the replace-pattern do not match (%lld <> %lld).":
        "Kích thước của mẫu tìm và mẫu thay thế không khớp nhau (%lld <> %lld).",
    "However this is necessary, since the chosen data stream has a fixed size.":
        "Hai mẫu phải dài bằng nhau vì luồng dữ liệu đang chọn có kích thước cố định.",
    "Parse error while importing “%@” in line %lld, column %lld:": "Lỗi phân tích khi nhập “%@” ở dòng %lld, cột %lld:",
    "“%@” expected, but found “%@”.": "Cần “%@”, nhưng gặp “%@”.",
    "Expected end of line, but found “%@”.": "Cần kết thúc dòng, nhưng gặp “%@”.",
    "Two hexadecimal digits in the range of %@-%@ were expected, but found “%@”.":
        "Cần hai chữ số hex trong khoảng %@-%@, nhưng gặp “%@”.",
    "Checksum %@ expected, but found %@.": "Cần tổng kiểm tra %@, nhưng gặp %@.",
    "No further lines permitted after EOF record.": "Không được có thêm dòng nào sau bản ghi EOF.",
    "An S-record type was expected (S1, S2, S3, S5, S7, S8, S9) but found “%@”.":
        "Cần một loại bản ghi S (S1, S2, S3, S5, S7, S8, S9), nhưng gặp “%@”.",
    "An ETL extended record type was expected (X0 to X9) but found “%@”.":
        "Cần một loại bản ghi ETL Extended (X0 đến X9), nhưng gặp “%@”.",
    "%lld data records (records of type S1, S2 or S3) were expected, but since the last S5-record or the beginning %lld data records were found.":
        "Cần %lld bản ghi dữ liệu (loại S1, S2 hoặc S3), nhưng kể từ bản ghi S5 gần nhất hoặc từ đầu tệp có %lld bản ghi dữ liệu.",
    "The byte count %lld is too small; at least %lld bytes are required for the address and checksum.":
        "Số byte %lld quá nhỏ; địa chỉ và tổng kiểm tra cần ít nhất %lld byte.",
    "A record of type %@ must contain %lld data bytes, but %lld were found.":
        "Bản ghi loại %@ phải chứa %lld byte dữ liệu, nhưng có %lld byte.",
    "The maximum supported file size (%@) of the “%@” file format was exceeded.":
        "Dữ liệu vượt quá kích thước tối đa (%@) mà định dạng “%@” hỗ trợ.",
    "Choose another format": "Hãy chọn định dạng khác",
    "Cannot open “%@”: %@.": "Không mở được “%@”: %@.", "Reading or writing “%@” failed: %@.": "Đọc hoặc ghi “%@” thất bại: %@.",
    "The part size must be at least one byte.": "Kích thước mỗi phần phải từ một byte trở lên.",
    "“%@” is not a disk identifier such as disk4 or disk4s1.": "“%@” không phải là mã ổ đĩa dạng disk4 hoặc disk4s1.",
    "Opening %@ was cancelled.": "Đã huỷ việc mở %@.",
    "You are not allowed to open %@. Opening a disk requires an administrator’s name and password.":
        "Bạn không được phép mở %@. Mở ổ đĩa cần tên và mật khẩu của quản trị viên.",
    "Could not get authorization to open %@: %@.": "Không xin được quyền mở %@: %@.", "error %lld": "lỗi %lld",
    "%@ is in use. Unmount its volumes before writing to it.": "%@ đang được dùng. Hãy tháo các ổ đĩa logic của nó trước khi ghi.",
    "%@ does not exist. The disk may have been ejected.": "%@ không tồn tại. Có thể ổ đĩa đã bị đẩy ra.",
    "Could not open %@: %@.": "Không mở được %@: %@.",
    "authopen could not open %@ (exit status %lld).": "authopen không mở được %@ (mã thoát %lld).",
    "authopen could not open %@: %@": "authopen không mở được %@: %@",
    "The disk %@ was not found. It may have been ejected.": "Không tìm thấy ổ đĩa %@. Có thể ổ đã bị đẩy ra.",
    "%@ is on the startup disk, which cannot be unmounted for writing.": "%@ nằm trên ổ đĩa khởi động, không thể tháo ra để ghi.",
    "%@ could not be unmounted or mounted: %@": "Không tháo hoặc gắn được %@: %@",
    "%@ is in use by another application.": "%@ đang được một ứng dụng khác sử dụng.",
    "%@ could not be unmounted or mounted (error 0x%@).": "Không tháo hoặc gắn được %@ (lỗi 0x%@).",
    "The operation was cancelled.": "Thao tác đã bị huỷ.",
    "Reading at offset %@ failed: %@.": "Đọc tại vị trí %@ thất bại: %@.", "Writing at offset %@ failed: %@.": "Ghi tại vị trí %@ thất bại: %@.",
    "The data (%lld bytes) does not fit on the destination (%lld bytes).": "Dữ liệu (%lld byte) không vừa với đích (%lld byte).",
    "%lld is not a valid sector size.": "%lld không phải là kích thước sector hợp lệ.",
    "Could not create %@: %@.": "Không tạo được %@: %@.",
    "Could not determine the size of the disk: %@.": "Không xác định được kích thước ổ đĩa: %@.",
    # Settings
    "General": "Chung", "Format": "Định dạng", "Notifications": "Thông báo", "Safety": "An toàn",
    "Warn when opening a disk with write access": "Cảnh báo khi mở ổ đĩa có quyền ghi", "Confirm file size changes": "Xác nhận khi đổi kích thước tệp",
    "Tell me when copied text was filtered": "Báo khi văn bản sao chép bị lọc", "Tell me when selected characters were filtered": "Báo khi ký tự được chọn bị lọc",
    "Open disks as read-only": "Mở ổ đĩa ở chế độ chỉ đọc", "Keep a backup (.bak) when saving": "Giữ bản sao lưu (.bak) khi lưu",
    "New documents open in": "Tài liệu mới mở ở chế độ", "Font": "Phông chữ", "Typeface": "Kiểu chữ", "Text and numbers": "Văn bản và số",
    "Text encoding": "Bảng mã văn bản", "Offset base": "Hệ cơ số vị trí", "Lowercase hex digits (abcdef)": "Chữ số hex viết thường (abcdef)",
    "Bytes per row": "Số byte mỗi hàng", "Byte group size": "Cỡ nhóm byte", "Fit to window width": "Vừa chiều rộng cửa sổ",
    "These defaults apply to newly opened documents. The View menu changes the current window.":
        "Các giá trị mặc định này áp dụng cho tài liệu mở sau. Menu Hiển thị thay đổi cửa sổ hiện tại.",
    "Line break determined by": "Xuống dòng theo", "Bytes per line": "Số byte mỗi dòng", "Characters per line": "Số ký tự mỗi dòng",
    "Types shown": "Kiểu được hiển thị", "Reset": "Đặt lại", "Source code": "Mã nguồn", "Width": "Độ rộng",
}

def escape(s):
    return s.replace("\\", "\\\\").replace('"', '\\"')

root = os.path.join(os.path.dirname(os.path.abspath(sys.argv[0])), "..", "..")
out = os.path.join(root, "Resources", "Localization", "vi.lproj", "Localizable.strings")
with open(out, "w", encoding="utf-8") as f:
    f.write("/* Vietnamese. Generated by Scripts/l10n/vi.py — edit that file, not this one. */\n")
    for key in sorted(VI):
        f.write('"%s" = "%s";\n' % (escape(key), escape(VI[key])))
print("wrote %d strings to %s" % (len(VI), os.path.normpath(out)))
