# Hexer — Thiết kế giao diện

Tài liệu này mô tả thiết kế của Hexer theo bản vẽ trên Claude Design và theo giao diện đang chạy trong app. Khi sửa UI, cập nhật **cả ba**: mã nguồn, canvas, và file này.

- **Canvas (nguồn gốc):** https://claude.ai/artifact/JBSgQBQpVLtMWto8QECZgb (version 22, ngày 2026-10-25)
- **Nền tảng:** thiết kế cho macOS 27 "Golden Gate" với Liquid Glass; chạy từ macOS 15 (xem §11). SwiftUI + AppKit, không dùng Xcode.
- **Ngôn ngữ UI:** tiếng Anh (khoá gốc) và tiếng Việt
- **Bàn giao kỹ thuật:** xem [HANDOFF.md](HANDOFF.md)

## 1. Các artboard trên canvas

| Artboard | Nội dung | Mã nguồn chính |
|---|---|---|
| `Main.dc.html` (light) / `MainDark.dc.html` | Cửa sổ chính: sidebar, toolbar, lưới hex, find bar, drawer kết quả, status bar, Data Inspector. Có tương tác (đổi tab drawer, di chuyển caret). | `Views/DocumentWindowView.swift`, `SidebarView.swift`, `InspectorView.swift`, `StatusBarView.swift`, `ResultsDrawer.swift`, `HexGrid/*` |
| `FindBar.dc.html` | Find bar kính nổi, hàng Replace, popover tuỳ chọn (Text/Hex/Integer/Float), 4 trạng thái | `Views/FindBar.swift`, `GlassBarStyle.swift` |
| `Sheets.dc.html` | Go to Offset, Select Block, Insert Bytes, Fill Selection, Filter Characters, Compare | `Views/Sheets/*`, `Views/Analysis/CompareViews.swift` |
| `Analysis.dc.html` | Sheet Generate Checksums, cửa sổ Statistics | `Views/Analysis/ChecksumViews.swift`, `StatisticsView.swift` |
| `CompareDisk.dc.html` | Chế độ so sánh hai cửa sổ, tài liệu ổ đĩa chỉ đọc với sector navigator | `CompareViews.swift`, `SectorNavigator.swift` |
| `Settings.dc.html` | Cửa sổ Settings 5 pane (bấm được) | `Views/SettingsWindowController.swift` |
| `MenusVI.dc.html` | Bản đồ menu + phím tắt; các thành phần bằng tiếng Việt | `App/MainMenu.swift`, `Resources/Localization/vi.lproj` |
| `Tools.dc.html` | Open Disk (+ cảnh báo mở để ghi), Clone Disk, Split, Concatenate (đang chạy), Wipe Securely | `Views/Tools/DiskViews.swift`, `FileToolViews.swift` |
| `Compat.dc.html` | Find bar, hàng Replace và chip chế độ: kính (macOS 26 trở lên) đặt cạnh material (macOS 15), ở cả sáng và tối | `Views/GlassBarStyle.swift` |
| `Import.dc.html` | Tài liệu import Intel Hex: sidebar Sections liệt kê vùng undefined, dòng gập (thường và có caret), quy tắc gập, mục View ▸ Fold Undefined Sections | `HexGrid/HexCanvasView.swift`, `HexEditorView.swift`, `HexerCore/Layout/RowMap.swift` |
| `Welcome.dc.html` | Màn hình chào lần mở đầu: 4 trang (Welcome, Edit, Find, Disks), khi nào hiện, chuyển động, bàn phím và trợ năng | `Views/Welcome/*` |
| `Update.dc.html` | Cửa sổ Software Update: có bản mới, đang tải, đang xác minh, sẵn sàng cài, đã mới nhất, lỗi, không tự thay được (tối, tiếng Việt) | `Views/SoftwareUpdateView.swift`, `App/SoftwareUpdate.swift` |

Bố cục canvas: hàng 1 cửa sổ chính (sáng/tối) · hàng 2 tìm kiếm và sheet · hàng 3 phân tích, so sánh, ổ đĩa · hàng 4 Settings, menu, tiếng Việt · hàng 5 công cụ tệp và ổ đĩa, dữ liệu import có vùng gập · hàng 6 macOS 15 · hàng 7 lần mở đầu (màn hình chào) và cập nhật phần mềm. Thứ tự và vị trí board nằm trong `project/canvas.json`.

## 2. Nguyên tắc (macOS 27 HIG, bản 6/2026)

Apple đưa lại các Design Principles (Purpose, Agency, Responsibility, Familiarity, Flexibility, Simplicity, Craft, Delight). Áp dụng vào Hexer:

1. **Pane hệ thống, sát mép cửa sổ.** Sidebar là `NavigationSplitView` với `List(.sidebar)`; inspector là `.inspector(isPresented:)`. Cả hai chạy sát mép cửa sổ, nội dung chảy phía sau. Không tự vẽ sidebar hay inspector dạng thẻ kính nổi. Đó là kiểu macOS 26 mà bản thiết kế đầu tiên đã dùng sai.
2. **Kính chỉ dành cho control.** Liquid Glass chỉ dùng cho nút, capsule và thanh nổi (find bar, compare capsule, sector navigator, chip chế độ). Không bao giờ đặt kính lên lưới hex, bảng hay văn bản trạng thái. Thông báo lỗi nằm trên material chuẩn, không dùng kính.
3. **Hiệu ứng mép cuộn để hệ thống tự lo.** Không thêm `.soft` hay hiệu ứng mép cuộn trang trí.
4. **Toolbar tối đa 3 nhóm.** Mọi mục trên toolbar đều có trong menu bar.
5. **Không đặt thông tin quan trọng ở đáy sidebar.**
6. **Sheet và alert dùng material chuẩn của hệ thống.** Nút mặc định ở bên phải; Return xác nhận, Esc huỷ.
7. **Settings:** tiêu đề cửa sổ là tên pane đang mở; cửa sổ vừa khít nội dung pane.
8. **An toàn trước:** ổ đĩa mở chỉ đọc theo mặc định; ổ khởi động có khoá; thao tác không hoàn tác được phải ghi rõ "(cannot be undone)".
9. **Cửa sổ riêng mở ở giữa màn hình**, canh theo cỡ thật của nội dung: cửa sổ công cụ (Open Disk, Clone Disk, Split, Concatenate, Wipe), Software Update, Settings, Hexer Help, Acknowledgements, About, màn hình chào; Statistics thì lần đầu ở giữa, sau đó nhớ vị trí. Cửa sổ có nội dung SwiftUI gọi `NSWindow.centerAtContentSize()` thay cho `center()`.

## 3. Token

### 3.1 Màu

Canvas dùng biến CSS. Trong app, màu lưới nằm ở `HexTheme` (`HexGrid/HexTheme.swift`); phần còn lại dùng màu hệ thống.

| Token | Sáng | Tối | Trong app |
|---|---|---|---|
| `--accent` | `#0A64D8` | `#4AA3FF` | `Color.accentColor` (theo hệ thống) |
| `--accent-soft` (vùng chọn ở cột đang focus) | accent 16% | accent 28% | selection của `HexCanvasView` |
| `--accent-dim` (vùng chọn ở cột còn lại, nền caret) | accent 8% | accent 13% | |
| `--ghost` (ghost caret, viền 1.5 pt) | accent 55% | accent 70% | |
| `--offset` (cột offset, số hex) | `#0B47B8` | `#7CB9FF` | `HexTheme.offset` |
| `--odd` (nhóm byte lẻ) | `#7A5652` | `#D1AAA3` | `HexTheme.oddColumn` |
| `--mod` (byte đã sửa, đậm) | `#D70015` | `#FF6B63` | `HexTheme.modified` |
| `--hit` (kết quả tìm kiếm) | `#FFC400` 42% | `#FFD60A` 35% | `HexTheme.searchHit` |
| diff (khác biệt khi so sánh) | `#FF9500` 30% | `#FF9F0A` 35% | `HexTheme.difference` |
| bookmark | system orange | system orange | `HexTheme.bookmark` |
| `--hdr` (hàng tiêu đề cột) | `#F7F7F9` | `#232326` (app: `#202023`) | `HexTheme.headerBackground` |
| undefined (vùng trống khi import) | tertiary label | tertiary label | `HexTheme.undefined` |
| fold (nền và chữ của dòng gập) | quaternary system fill · secondary label | như bên sáng | `HexTheme.foldBackground`, `HexTheme.foldText` |
| `--grid` | `#FFFFFF` | `#1B1B1D` | `textBackgroundColor` |
| `--fg` / `--fg2` / `--fg3` | `#1D1D1F` / `#5F5F66` / `#8E8E93` | `#F2F2F5` / `#A8A8AE` / `#77777D` | label / secondary / tertiary |
| `--pane` (sidebar, inspector) | `rgba(244,245,248,.9)` | `rgba(38,38,42,.92)` | do hệ thống vẽ |
| `--glass` | trắng 70% + blur 24 | `rgba(66,66,72,.6)` | `.glassEffect(.regular…)` |

Giá trị không hợp lệ trong inspector (`Invalid`) dùng phông thường, màu tertiary; giá trị hợp lệ dùng phông mono.

### 3.2 Chữ

| Vai trò | Kiểu |
|---|---|
| Lưới hex | SF Mono 13 pt (Settings ▸ Format cho chọn 9–28 pt, SF Mono/Menlo/Monaco/Courier New); chiều cao hàng = line height + 5 |
| Nội dung chung, nhãn form, nút | SF Pro 13 |
| Hàng inspector, bảng kết quả, status bar | 12 (giá trị inspector: mono 12) |
| Tiêu đề nhóm (sidebar, inspector, cột Sums/CRC/Digests) | 11 đậm, màu secondary |
| Chú thích, chip, phím tắt | 11 |
| Tiêu đề sheet | headline (13 đậm) |

### 3.3 Kích thước và khoảng cách

| Thành phần | Giá trị | Nguồn |
|---|---|---|
| Sidebar | min 210 · ideal 240 · max 340 | `DocumentWindowView` |
| Inspector | min 260 · ideal 300 · max 420 | `DocumentWindowView` |
| Thanh kính (capsule find bar, compare, sector navigator) | cao **36**, bo 18, padding ngang 16 | `GlassBar.height` |
| Nút icon trong thanh kính | 28 × 28 | `GlassBar.iconSize`, `GlassBarIconButton` |
| Find bar | neo góc trên phải lưới: top 34, trailing 16 | `DocumentWindowView` |
| Overlay đáy (compare capsule, sector navigator) | cách đáy lưới 16 | |
| Drawer kết quả | cao 210 | |
| Status bar | cao 30, padding ngang 14 | `StatusBarView` |
| Sheet | padding 20, khoảng cách dọc 16, rộng tối thiểu 380 | `SheetScaffold` |
| Cửa sổ công cụ | padding 20; Open Disk rộng 680, các cửa sổ khác 600 | `FileToolViews`, `DiskViews` |
| Settings | pane rộng 520, cao theo nội dung (Inspector cố định 520) | `SettingsWindowController` |
| Nút sheet | regular control size (cao 28 trên canvas, bo tròn) | |

## 4. Cửa sổ chính

```
┌─ Sidebar 240 ──┬──────────────── Nội dung ──────────────────────┬─ Inspector 300 ──┐
│ ●●●  [▯]       │ [Open Save Undo Redo]  HxD64.exe   [Insert|Overwrite|Read-only] │ [Find GoTo ▯]    │
│ Bookmarks      │ Offset(h) 00 01 … 0F  Decoded text              │ Data Inspector ⋯ │
│  ● 00032220 ⌃1 │ 00032220  54 46 6F 72 …  TFormHexView┌─Find bar─┐│ [LE|BE] ☐ Hex    │
│ Sections       │ …                                     └──────────┘│ Integers         │
│  ● 0–695FFF    │                                                  │  Binary  0101…   │
│ Document       │          (Compare capsule / Sector navigator)    │ Characters …     │
│  Size, Modified│──── Drawer 210: Search Results | Checksums | Compare ────│ Disassembly      │
│  Encoding …    │ Offset: … Block: … Length: …   Windows-1252 [Overwrite] │ Step as Int32 ▾  │
└────────────────┴──────────────────────────────────────────────────┴──────────────────┘
```

- **Khi mở app:** nếu không có tài liệu nào (không mở kèm tệp, không có cửa sổ được khôi phục), app hiện ngay bảng Open của hệ thống, giống TextEdit. Bấm icon Dock lúc không còn cửa sổ nào cũng hiện bảng này. App không tạo cửa sổ trống. Riêng **lần đầu** mở app không kèm tệp thì màn hình chào (§6.9) hiện thay bảng Open.
- **Toolbar (3 nhóm):** navigation = Open, Save, Undo, Redo · principal = segmented Insert/Overwrite/Read-only (ẩn khi đang so sánh) · primaryAction = Find, Go to Offset, Inspector. Tiêu đề là tên tệp, phụ đề là kích thước và chế độ.
- **Sidebar:**
  - *Bookmarks:* chấm cam, offset, phím ⌃0–9. Khi trống, hiện dòng hướng dẫn (xuống dòng được).
  - *Sections:* các vùng có dữ liệu, kèm chú thích.
  - *Document:* Size, Modified, Encoding, Layout. Chỉ giá trị Modified tô đỏ, và chỉ khi khác 0.
- **Lưới hex:**
  - Các cột: offset (xanh), hex chia theo nhóm byte (nhóm lẻ màu `--odd`), text đã giải mã.
  - Hàng tiêu đề nền `--hdr`; cột chứa caret được tô accent đậm.
  - Byte đã sửa màu đỏ đậm. Caret có gạch chân accent; cột còn lại hiện ghost caret (viền).
  - Vùng undefined phủ trọn từ 2 dòng trở lên được gập thành một dòng (xem §6.5).
  - Không dùng kính trong lưới.
- **Drawer:** 3 tab segmented cỡ nhỏ (tab chọn nền accent). Bên phải có phần phụ:
  - Search Results: "159 matches" + Clear.
  - Checksums: ô "Expected result" (240 pt, hẹp thì 140 pt, hẹp nữa thì ẩn) + Refresh.
  - Nút đóng ở cuối.
  - Các bảng:
    - Results: Offset | Excerpt (hex) | Excerpt (text).
    - Checksums: # | Algorithm | Checksum | Usage.
    - Compare: danh sách khác biệt, hoặc "Not Comparing".
- **Status bar:** `Offset:`, `Block:` (`—` khi không chọn), `Length:` dạng `C (12)`, tên bảng mã ngắn, hệ cơ số offset, chip chế độ (kính có tint accent, bấm được). Khi hẹp, giá trị các trường cắt giữa (Block co trước) chứ không làm cửa sổ rộng ra; bảng mã và hệ cơ số ẩn đi trước.
- **Inspector:**
  - Header "Data Inspector" + menu ⋯ (Hex, Choose Types… mở Settings ▸ Inspector).
  - Segmented Little/Big endian + checkbox Hex.
  - Các nhóm: Integers, Characters, Floating point, Date & time, Other (GUID), Disassembly (x86-16/32/64, ARM64).
  - Hàng gọn 12 pt. Nhấp đúp để sửa; tooltip ghi "Double-click to edit".
  - Footer "Step as Int32 ▾" + 4 nút bước. Không có nút ẩn bên trong pane (dùng nút toolbar).

## 5. Thành phần

| Thành phần | Quy tắc |
|---|---|
| `GlassCapsuleButtonStyle` (`.glassCapsule`, `.glassCapsuleProminent`) | Mọi nút chữ trên thanh kính: cao 36, padding 16, capsule. Prominent = tint accent, dùng cho hành động chính (Find All, Replace All). |
| `GlassBarIconButton` | Nút icon 28 × 28, borderless, luôn có `help` (tooltip) và nhãn accessibility. |
| Capsule nhóm | Các nút liên quan gộp chung một capsule (▲▼; Replace ⇄ + Close ✕). Dùng `GlassEffectContainer` + `glassEffectID` để hàng Replace "mọc" ra từ hàng Find. |
| Segmented | Mode picker: kích thước toolbar. Tab drawer: nhỏ, tab chọn nền accent. Inspector LE/BE: nhỏ. Ô chọn hệ cơ số `hex · dec · oct`: segmented nhỏ, đổi hệ thì chuyển đổi luôn giá trị đã nhập. |
| Ô số (`NumberField`) | Phông mono, viền tròn, chữ đỏ khi không phải số hợp lệ; nút mặc định bị khoá cho đến khi hợp lệ. |
| `SheetScaffold` | Tiêu đề headline → nội dung dạng grid, nhãn căn phải → Cancel + nút mặc định ở góc phải. |
| `ToolFooter` | Cancel + nút chính. Khi đang chạy: thanh tiến độ 180 + % + Stop. Lỗi hiện thành sheet trên chính cửa sổ đó. |
| `FileField` | Đường dẫn rút gọn ở giữa trên nền quaternary + nút Choose…. |
| Alert | Alert hệ thống. Thông báo ngắn kiểu câu hỏi ("Open disk6 with write access?") + giải thích hậu quả. Nút của thao tác không hoàn tác được (Write to Disk, Write Directly, Overwrite, Wipe and Delete, Open for Writing) dùng `addDestructiveButton` (`App/Alerts.swift`): tô đỏ, không bao giờ là nút mặc định, Return không kích hoạt; Esc vẫn huỷ. |
| Bảng | `NSTableView`/`Table` hệ thống, hàng xen kẽ; cột offset mono màu `--offset`. |
| Form Settings | `Form.grouped`: switch và popup ở mép phải; stepper đặt bên trong `LabeledContent` để giá trị nằm cạnh nút ⇅; chú thích dùng `Section` footer. |

## 6. Màn hình và trạng thái

### 6.1 Find & Replace (⌘F, ⌥⌘F)
- **Hàng Find:**
  - [🔍 ô tìm 200 pt · "3 of 159" · nút kiểu dữ liệu "Text ▾"]
  - Khi lưới hẹp (ví dụ cửa sổ 1024 pt, tiếng Việt), ô tìm và ô thay thế co xuống tối thiểu 90 pt. Nhãn trong capsule (nút, checkbox) luôn một dòng (`lineLimit(1)` + `fixedSize`), không bao giờ xuống dòng tràn khỏi capsule. Find bar cách hai mép lưới 16 pt.
  - [▲ ▼]
  - [Find All] (prominent)
  - [⇄ hiện Replace · ✕]
- **Hàng Replace:** [☑ Prompt on replace] [⇄ ô thay thế] [Replace] (glass) [Replace All] (prominent).
- **Popover tuỳ chọn:**
  - Data type: Text / Hex / Integer / Float.
  - Text: Encoding "Editor (Windows-1252)" hoặc "Unicode UTF-16 LE"; Case sensitive.
  - Hex: chú thích về ⌘E.
  - Integer: Bit width "(any)", Byte order, Sign Either/Signed/Unsigned.
  - Float: Single / Double / Real48 / Extended kèm số byte; Byte order.
  - Direction All / Forward / Backward, kèm chú thích "“All” searches the whole file, wrapping around at the end."
- **Trạng thái:**
  - Trống: placeholder đổi theo kiểu dữ liệu; Find All bị khoá.
  - Pattern sai: viền đỏ + thông báo trên material.
  - Đang tìm: spinner + Stop trong capsule; tiến độ hiện ở status bar.
  - Hỏi khi thay thế: alert "Replace this occurrence at …?", "Occurrence n of N.", các nút Replace / Skip / All / Cancel.

### 6.2 Sheets
- **Go to Offset (⌘L):**
  - Offset + hex/dec/oct.
  - Relative to: Beginning of the file / Current offset (+ or −) / End of the file (backwards).
  - Dòng "Destination: …".
  - Nút Go. Nhớ hệ cơ số và gốc giữa các lần mở.
- **Select Block (⇧⌘A):** Start offset; popup End offset/Length + ô số; Numbers in; dòng "N bytes" hoặc "The block is empty or outside the file."
- **Insert Bytes (⇧⌘I):** Byte count + hệ cơ số; Fill pattern (hex lặp lại); câu tóm tắt kết quả.
- **Fill Selection:**
  - Danh sách pass (220 × 150), Add/Remove.
  - Presets: DoD Sanitizing, Zero Bytes.
  - "Pattern of pass n": Hex values, hoặc Random bytes From/to (decimal).
  - "Write directly to disk (cannot be undone)", kèm chú thích đổi theo lựa chọn.
- **Filter Characters (View):**
  - Lựa chọn: All characters / ASCII only (20–7E) / Letters and digits / Custom byte ranges.
  - Bảng xem trước 16 × 16 theo bảng mã hiện tại.
- **Compare (⌘K):**
  - 1. Data source (tệp hiện tại).
  - 2. Data source (popup + Open File…).
  - Windows: Side by side / One above the other.
  - Scope: Whole files / Selected data, kèm chú thích.

### 6.3 Phân tích
- **Generate Checksums (⇧⌘K):**
  - Ba cột:
    - Sums: Checksum-8/16/32/64, Custom….
    - CRC: CRC-16, CRC-16/CCITT-FALSE, CRC-32, CRC-32C, Custom CRC….
    - Digests: MD2, MD4, MD5, SHA-1/256/384/512.
  - Custom mở tuỳ chọn ngay bên dưới (độ rộng, polynomial, init, XOR, reflection).
  - Scope Whole file/Selection; "Compare with expected value" + ô nhập; Calculate.
- **Statistics:**
  - Whole file/Selection, Hide maximum, "256 of 256 values present", Refresh.
  - Biểu đồ 256 cột; bấm một cột để giữ lựa chọn.
  - Panel "Selected value": Character, Count, Share, Bytes, Entropy.

### 6.4 So sánh và ổ đĩa
- **So sánh:**
  - Hai cửa sổ đặt cạnh nhau (hoặc trên dưới); sidebar, inspector và mode picker được ẩn để nhường chỗ.
  - Byte khác biệt tô cam.
  - Capsule đáy: "Difference at 104 · 3 bytes ▲ ▼ ✕"; F6 / ⇧F6.
  - Drawer Compare liệt kê Offset | Length | dữ liệu từng bên.
- **Tài liệu ổ đĩa:**
  - Tiêu đề "disk4 — HEXER", phụ đề "8.4 MB · Read-only"; mode picker khoá ở Read-only.
  - Sector navigator: ⏮ ‹ Sector [n] of N › ⏭.
  - Mở ảnh đĩa thì hỏi sector size (512 / 2048 / 4096).

### 6.5 Dữ liệu import: gập vùng undefined
- Sau khi import Intel Hex/S-Record/ETL, các khoảng trống giữa các bản ghi là vùng undefined (sidebar ▸ Sections).
- Dòng nằm trọn trong vùng (từ `RowMap.minimumFoldedRows` = 2 dòng) gập thành **một dòng gập**:
  - Cột offset: byte ẩn đầu tiên.
  - Capsule `foldBackground` trải hết cột hex + text, nhãn phông hệ thống nhỏ hơn lưới 2 pt, màu `foldText`: "▸  1,840 undefined bytes · Click to show".
  - Không phải kính; là nội dung lưới.
- Dòng có byte định nghĩa vẫn hiện bình thường, phần trống là `??`.
- Bấm dòng gập để mở vùng đó. Go to Offset, Find, bookmark hay sidebar dẫn vào bên trong vùng đang gập thì tự mở vùng.
- ↑ ↓ và Page Up/Down đi theo dòng trên màn hình; tới dòng gập thì caret nằm ở byte ẩn đầu tiên, dòng gập được viền accent 2 pt. Home/End không làm gì trên dòng gập.
- View ▸ Fold Undefined Sections (bật sẵn) tắt/bật gập cho cả tài liệu; bật lại thì gập lại cả các vùng đã mở.
- Hai cửa sổ so sánh cuộn theo byte, nên vẫn khớp khi hai bên gập khác nhau.

### 6.6 Settings (⌘,)
Tab trên toolbar, mỗi tab có icon và nhãn; tiêu đề cửa sổ là tên pane.
- **General:**
  - Notifications: Warn when opening a disk with write access ✓; Confirm file size changes ✓; Tell me when copied text was filtered ✓; Tell me when selected characters were filtered ✗.
  - Safety: Open disks as read-only ✓; Keep a backup (.bak) when saving ✗; New documents open in = Overwrite.
  - Software Update: Check for updates automatically ✓; Include beta versions ✗; Last checked (ngày giờ, hoặc "Never") + nút Check Now (mở cửa sổ Software Update). Bản không cập nhật được (chạy `swift run`, thiếu khoá) thì ẩn cả phần này.
- **Format:** Size (13 pt, stepper), Typeface (SF Mono).
- **View:**
  - Layout: Bytes per row 16, Fit to window width, Byte group size 1, Columns = Hex and Text.
  - Text and numbers: Text encoding = Windows (ANSI), Offset base = Hexadecimal, Lowercase hex digits.
  - Footer: "These defaults apply to newly opened documents…"
- **Inspector:** Types shown (30 kiểu, mặc định bật hết) + Reset.
- **Export:** Line break determined by (Bytes per line / Characters per line = 80); Motorola S-Record 32 byte/dòng; Intel Hex 32 byte/dòng.

### 6.7 Công cụ
- **Open Disk (⌥⌘O):**
  - Bảng Name | Type | Size | Hardware, chia nhóm Physical disks / Logical volumes. Icon: khoá cho ổ khởi động, ổ đĩa, volume.
  - ☑ Open as read-only; nút Refresh.
  - Chú thích về mật khẩu quản trị.
  - Mở để ghi thì hiện alert: **Open Read-only** (mặc định, Return) / Open for Writing (destructive) / Cancel (Esc).
- **Clone Disk:** Source / Target (ổ đĩa hoặc "Disk image file" + FileField); cảnh báo ghi đè; không thể chọn ổ khởi động làm đích.
- **Split File:**
  - File, Part base name.
  - Part size: các preset đĩa mềm / Zip / CD, hoặc Custom.
  - Naming: .001 / hỏi từng tên.
  - Dòng "Creates N parts."
- **Concatenate Files:** danh sách có số thứ tự (kéo để sắp xếp), Add…/Remove/Clear, Output file.
- **Wipe Securely:** File; Method DoD 5220.22-M (3 passes) / Zero / Random; cảnh báo về SSD/APFS; nút "Wipe and Delete" + alert xác nhận.

### 6.8 Menu và phím tắt
Thứ tự menu: Hexer · File · Edit · Search · View · Analysis · Tools · Window · Help. Menu Hexer: About Hexer, Check for Updates…, Settings… (⌘,), Services, Hide/Show, Quit. Open Recent ngay sau Open… là mục của AppKit (tự chèn và điền danh sách, chuỗi tiếng Việt của hệ thống); không tự dựng mục này trong `MainMenu.swift`. Phím tắt chính:

| Lệnh | Phím |
|---|---|
| Open Disk… | ⌥⌘O |
| Reload from Disk | ⌘R |
| Paste Overwrite | ⌘B |
| Toggle Insert/Overwrite | ⌘I |
| Copy Offset | ⌥⌘C |
| Select Block… | ⇧⌘A |
| Insert Bytes… | ⇧⌘I |
| Find / Replace | ⌘F / ⌥⌘F |
| Find Next / Previous | ⌘G / ⇧⌘G |
| Use Selection for Find | ⌘E |
| Go to Offset… | ⌘L |
| Set / Go to Bookmark | ⌃⇧0–9 / ⌃0–9 |
| Show Sidebar / Inspector | ⌃⌘S / ⌥⌘I |
| Drawer: Search Results / Checksums / Compare | ⌥⌘1 / 2 / 3 |
| Checksums… | ⇧⌘K |
| Compare… | ⌘K |
| Next / Previous Difference | F6 / ⇧F6 |
| Tab 1–9 | ⌘1–9 |

Danh sách đầy đủ nằm trong `App/MainMenu.swift` và artboard `MenusVI`.

### 6.9 Màn hình chào (lần mở đầu)
- **Khi nào hiện:**
  - Lần đầu app mở mà không có tài liệu: hiện thay bảng Open. Khoá `WelcomeShown` trong UserDefaults được đặt ngay khi màn hình hiện, nên chỉ hiện một lần.
  - Help ▸ Welcome to Hexer mở lại bất cứ lúc nào.
  - Mở kèm tệp hoặc chạy có cờ `-Hexer…` thì không hiện (khoá vẫn chưa đặt, lần mở trống sau sẽ hiện).
- **Cửa sổ:** 680 × 560 pt, cố định, chỉ có nút đóng; tiêu đề ẩn, thanh tiêu đề trong suốt, kéo được bằng nền.
- **4 trang:**
  1. *Welcome:* icon app, "Welcome to Hexer", câu giới thiệu, và một hàng hex trong thẻ: byte ngẫu nhiên lần lượt "chốt" thành `48 65 78 65 72`, caret chạy theo, chữ "Hexer" hiện dần ở cột văn bản.
  2. *Edit:* lưới mini 3 dòng; gõ đè "hello" thành "HEXER" (từng nibble, đỏ đậm như byte đã sửa), chip Overwrite, rồi phím ⌘Z hiện và hoàn tác từng byte.
  3. *Find:* lưới mini 4 dòng có 3 chỗ `FF D8 FF`, capsule tìm kiếm "1 of 3" và thẻ Data Inspector (Int8, UInt16, Int32); kết quả hiện tại chuyển lần lượt.
  4. *Disks:* thẻ ổ đĩa "disk4 — HEXER" có khoá xanh và chip Read-only, 2 dòng hex của sector, capsule sector navigator đếm sector.
  - Mỗi trang tính năng: hình minh hoạ 520 × 200, tiêu đề 26 pt đậm, 3 dòng mô tả 14 pt kèm SF Symbol màu của trang.
- **Màu của trang:** accent (Welcome), đỏ `HexTheme.modified` (Edit), cam (Find), xanh lá (Disks). Dùng cho quầng sáng phía trên (radial gradient 20%), symbol, chấm trang và vòng lan khi đổi trang.
- **Thanh dưới:** Skip (borderless, trái; Esc) · chấm trang ở giữa (chấm hiện tại dài 22 pt, bấm để nhảy trang) · Back + Continue (prominent, Return), cỡ large. Trang cuối: không có Skip, nút chính là "Open a File…".
- **Kết thúc:** "Open a File…" luôn mở bảng Open. Khi màn hình hiện lúc mở app, Skip, Esc hay nút đóng cũng dẫn tới bảng Open (như lần mở không có màn chào); mở từ menu Help thì chỉ đóng.
- **Chuyển động:**
  - *Nền:* lưới byte hex trôi lên chậm (6 pt/s), mờ phía sau nội dung (lớp phủ màu nền cửa sổ hình elip và ở đáy), rõ hơn ở mép. Thỉnh thoảng một dải chọn chéo quét qua; vài byte loé đỏ như vừa bị ghi đè; khi đổi trang, một vòng màu của trang lan từ giữa ra.
  - *Đổi trang:* trang cũ mờ, nhoè và trượt ra; trang mới trượt vào theo hướng đi (tiến từ phải, lùi từ trái). Các phần tử trong trang lần lượt nổi lên (mờ → rõ, dịch lên 18 pt, spring, trễ 0,08 s mỗi phần tử).
  - *Hình minh hoạ:* đổi theo từng bước như editor khi gõ phím, không nội suy giữa các bước (xem HANDOFF §3 về hiệu năng).
- **Reduce Motion:** trang cross-fade, nội dung hiện ngay, nền đứng yên, hình minh hoạ giữ một khoảnh khắc tiêu biểu.
- **Bàn phím:** Return = Continue/Open a File…, Esc = Skip (trang cuối: đóng), ← → lật trang.
- **Kính:** chỉ các capsule nhỏ trong hình minh hoạ (mô phỏng find bar, chip, sector navigator) dùng `barGlass`; nút là nút hệ thống.

### 6.10 Cập nhật phần mềm (Hexer ▸ Check for Updates…)
- **Cửa sổ:** một cửa sổ thường (titled, closable, không resize), rộng 520 pt, tiêu đề "Software Update". Bố cục như alert: icon app 64 pt bên trái; bên phải là thông báo đậm (`.headline`), chi tiết màu secondary, rồi hàng nút ở mép phải, nút mặc định đứng cuối (Return), nút huỷ nhận Esc. Không dùng kính (đây là cửa sổ, không phải control nổi). Chiều cao theo nội dung của từng trạng thái.
- **Trạng thái:**

| Trạng thái | Thông báo | Nút |
|---|---|---|
| Đang kiểm tra (chỉ khi người dùng bấm) | Checking for updates… + thanh tiến độ không xác định | Cancel |
| Có bản mới | Hexer X is available · You have version Y… · khung What's New (danh sách từ CHANGELOG, tối đa 150 pt rồi cuộn) + link Release Notes on GitHub | Skip This Version (trái) · Remind Me Later · **Install Update** |
| Không tự thay được (app bị translocate, hoặc không có quyền ghi thư mục) | như trên + dòng cảnh báo có biểu tượng tam giác vàng, chỉ ghi tên thư mục | Skip This Version · Remind Me Later · **Download…** (mở trang release) |
| Đang tải | Downloading Hexer X… + thanh tiến độ + "2.5 MB of 6.9 MB" | Cancel (quay về "Có bản mới") |
| Đang xác minh | Verifying Hexer X… + câu giải thích + thanh không xác định | Cancel |
| Sẵn sàng | Hexer X is ready to install · Relaunch… hoặc cài khi thoát; nếu có tài liệu chưa lưu thì thêm dòng "Before quitting, Hexer asks whether to save your changes." | Install on Quit · **Relaunch** |
| Đã mới nhất | Hexer is up to date · Version X is the newest version available. | **OK** |
| Lỗi | Couldn't check for updates / Couldn't install the update + thông báo lỗi (chọn được chữ) | Open Download Page (khi lỗi lúc cài) · **OK** |

- **Đóng cửa sổ** = Remind Me Later; lúc đang tải hay xác minh thì huỷ; khi đã sẵn sàng thì bản cập nhật vẫn được cài lúc thoát.
- **Khi nào hiện:** kiểm tra tự động không bao giờ hiện gì trừ khi có bản mới; nếu lúc đó bảng Open (modal) đang mở thì đợi bảng đóng rồi mới hiện. Check for Updates… và Check Now hiện mọi kết quả, kể cả bản đã bỏ qua.
- **What's New** lấy mục "What's new" / "Có gì mới" trong ghi chú release (tức mục của phiên bản trong CHANGELOG.md), theo ngôn ngữ giao diện; markdown inline (đậm, code, link) được hiển thị.

## 7. Bản địa hoá

- Khoá là chuỗi tiếng Anh trong `Text("…")`, `L("…")` và các API nhận `LocalizedStringKey`. Bản dịch nằm trong `Scripts/l10n/vi.py`, script này sinh ra `Resources/Localization/vi.lproj/Localizable.strings`.
- `Scripts/l10n_audit.swift` chạy trong `bundle.sh` và làm build thất bại nếu có chuỗi chưa dịch. Audit nhận cả các helper `field(…)`, `fact(…)`, `group(…)`, `GlassBarIconButton(_, "…")`, tham số `placeholder:` và hai nhánh của `Text(điều kiện ? "A" : "B")`. Hiện có 666 khoá, đã dịch đủ.
- Lỗi từ HexerCore/HexerPlatform (tiếng Anh, CLI dùng nguyên văn) được dịch ở tầng app trong `App/ErrorMessages.swift`; `AppDelegate.application(_:willPresentError:)` áp dụng cho mọi `presentError`, còn `NSAlert(error:)` và nhãn lỗi của find bar dùng `error.localizedForDisplay` / `error.displayMessage`. Phần mô tả errno (`strerror`) vẫn là tiếng Anh của hệ thống.
- Không dịch tên kiểu kỹ thuật: Int32, UTF-8, GUID, FILETIME, x86-64, ARM64, Little-endian/Big-endian.
- Một số bản dịch đã chốt:

| Tiếng Anh | Tiếng Việt |
|---|---|
| File / Edit / Search / View / Analysis / Tools / Window / Help | Tệp / Sửa / Tìm kiếm / Hiển thị / Phân tích / Công cụ / Cửa sổ / Trợ giúp |
| Insert / Overwrite / Read-only | Chèn / Ghi đè / Chỉ đọc |
| Find All / Replace / Replace All | Tìm tất cả / Thay thế / Thay thế tất cả |
| Search Results / Checksums / Compare | Kết quả tìm kiếm / Tổng kiểm tra / So sánh |
| Data Inspector | Trình kiểm tra dữ liệu |
| Offset: / Block: / Length: | Vị trí: / Khối: / Độ dài: |
| Invalid | Không hợp lệ |
| Software Update / Check for Updates… | Cập nhật phần mềm / Kiểm tra cập nhật… |
| Install Update / Remind Me Later / Skip This Version | Cài bản cập nhật / Nhắc tôi sau / Bỏ qua phiên bản này |
| Relaunch / Install on Quit | Mở lại / Cài khi thoát |

- Chuỗi tiếng Việt dài hơn tiếng Anh khoảng 20–40%. Kiểm tra cắt chữ bằng `-AppleLanguages '(vi)'`, nhất là ở toolbar, find bar, tab drawer và tab Settings.

## 8. Trợ năng

- Lưới hex có hỗ trợ VoiceOver (`HexCanvasView+Accessibility.swift`): đọc offset, giá trị và vùng chọn.
- Mọi nút chỉ có icon đều có `help` và nhãn accessibility. Trên canvas, các nút này dùng `aria-label`.
- Mọi lệnh đều đi được bằng bàn phím: có trong menu, có phím tắt; sheet dùng Return/Esc.
- Màn hình chào: nền và hình minh hoạ ẩn với VoiceOver; mỗi chấm trang đọc "Page 2 of 4"; tôn trọng Reduce Motion (§6.9).
- Không dùng màu làm tín hiệu duy nhất:
  - Byte đã sửa vừa đỏ vừa đậm.
  - Lỗi pattern có thêm câu thông báo.
  - Ổ đĩa bị khoá có icon khoá.

## 9. Nên và không nên

| Nên | Không nên |
|---|---|
| Dùng pane hệ thống (sidebar, inspector), sheet và alert hệ thống | Tự vẽ thẻ kính nổi cho sidebar hoặc inspector |
| Kính chỉ trên control nổi, cao 36 pt thống nhất | Kính lên lưới, bảng, status text; trộn các chiều cao 28/32/36 trên cùng một thanh |
| Mỗi lệnh toolbar có trong menu và có phím tắt | Thêm nhóm toolbar thứ 4 |
| Mặc định an toàn (chỉ đọc, xác nhận trước khi xoá hoặc ghi đĩa) | Ghi xuống đĩa trước khi người dùng bấm Save |
| Cập nhật canvas và DESIGN.md cùng lúc với mã UI | Để canvas lệch so với app |

## 10. Quy trình sửa canvas

1. Đọc lại file trên artifact (`Artifact` action `read`, `path: project/<File>.dc.html`). Bản làm việc lưu trong scratchpad, ví dụ `…/scratchpad/canvas/project/`.
2. Sửa các file `.dc.html` trong cùng một thư mục gốc. Quy tắc định dạng:
   - `{{hole}}` chỉ dùng để tra giá trị.
   - Sự kiện viết dạng `onClick="{{fn}}"`.
   - `<sc-for>`/`<sc-if>` phải có `hint-*`.
   - Logic đặt trong `class Component extends DCLogic` với `renderVals()`.
   - `data-props` là JSON đặt trong nháy đơn.
3. Publish một lần với `url`, `root`, `file_path`, và `files` cho các file còn lại. Chỉ gửi `canvas.json` khi thêm, bớt hoặc đổi kích thước board; đọc lại `canvas.json` trước khi gửi.
4. Không kiểm tra canvas bằng cách render hoặc chụp màn hình. Kiểm tra app thật bằng `-HexerSnapshot` (xem HANDOFF.md).

## 11. Chạy trên macOS 15 (không có Liquid Glass)

App chạy từ macOS 15 Sequoia. Liquid Glass chỉ có từ macOS 26, nên mọi control nổi đi qua các helper trong `Views/GlassBarStyle.swift`. Không gọi `glassEffect`, `glassEffectID` hay `GlassEffectContainer` trực tiếp.

| Helper | macOS 26 trở lên | macOS 15 |
|---|---|---|
| `.barGlass()` | `glassEffect(.regular.interactive(), in: .capsule)` | `.regularMaterial` dạng capsule, viền `separator` 0,5 pt, bóng đen 12% (bán kính 6, lệch xuống 2) |
| `.barGlass(tint:)` | kính có tint (nút prominent, chip chế độ) | nền màu tint đặc (accent cho Find All/Replace All, accent 18% cho chip) |
| `.barGlass(interactive: false)` | kính không tương tác (checkbox "Prompt on replace") | như `.barGlass()` |
| `.barGlassID(_:in:)` | `glassEffectID` (hàng Replace "mọc" từ hàng Find) | không làm gì |
| `GlassGroup(spacing:)` | `GlassEffectContainer` | nội dung giữ nguyên |

- Kích thước, khoảng cách và chiều cao 36 pt giống hệt trên hai hệ điều hành; chỉ khác chất liệu.
- Kiểm giao diện macOS 15 ngay trên máy mới bằng cờ `-HexerNoGlass 1`. Cờ này chỉ đổi phần kính, không giả lập các khác biệt khác của macOS 15 (toolbar, sidebar, inspector do hệ thống vẽ).
- Toolbar, sidebar, inspector, sheet và alert là của hệ thống nên tự theo giao diện của từng phiên bản macOS.
