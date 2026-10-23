# Hexer — Bàn giao kỹ thuật

Cập nhật lần cuối: 2026-10-24. Đọc file này trước khi code tiếp; phần thiết kế giao diện nằm ở [DESIGN.md](DESIGN.md).

Hexer là trình sửa hex thiết kế cho macOS 27, viết bằng SwiftUI + AppKit với Liquid Glass, và **chạy từ macOS 15** (macOS 15 không có kính, xem DESIGN.md §11). Mục tiêu là đủ tính năng như **HxD 2.5**, được dựng lại từ `HxD64.exe` bằng REA.

| Tài liệu | Đường dẫn |
|---|---|
| Kế hoạch gốc (10 phase, kiến trúc, rủi ro) | `~/.claude/plans/d-ng-rea-ph-n-t-ch-wiggly-metcalfe.md` |
| Thiết kế UI (canvas Claude Design) | https://claude.ai/artifact/JBSgQBQpVLtMWto8QECZgb · [DESIGN.md](DESIGN.md) |
| Bản HxD dùng để đối chiếu | `~/Downloads/HxD/HxD64.exe` (crosscheck cũng dùng file này) |

## 1. Trạng thái nhanh

- Phase 1–9 đã xong. Phase 10 (đối chiếu chi tiết với HxD bằng REA) đã áp dụng các phát hiện chính.
- **Đã kiểm tra lại ngày 2026-10-24:**
  - `Scripts/test.sh`: 166 test đều đạt (HexerCore 123, HexerDisasm 12, HexerPlatform 31).
  - `Scripts/crosscheck.sh`: 281/281 đạt.
  - `Scripts/bundle.sh`: build không có warning, ngoại trừ cảnh báo search path của linker.
  - Đã kiểm l10n: 605 khoá có tiếng Việt (audit giờ nhận thêm nhiều mẫu, xem §2).
- **Git:** nhánh `main`, remote `origin` = `git@github-letrucdev:letrucdev/hexer.git` (host SSH `github-letrucdev` là alias trong `~/.ssh/config` của máy). Commit đầu tiên đã push ngày 2026-10-24. Chỉ commit hoặc push khi người dùng yêu cầu.

## 2. Môi trường và lệnh

Máy chỉ có **Command Line Tools**, không có Xcode: Swift 6.4, SDK MacOSX27, SwiftPM tools 6.2, Swift 6 language mode. Deployment target **macOS 15** (`Package.swift`, `LSMinimumSystemVersion`); `bundle.sh` ghi `minos 15.0`, `sdk 27.0` vào binary.

| Lệnh | Tác dụng |
|---|---|
| `Scripts/bundle.sh` | Build release → `build/Hexer.app`. Chạy `vtool` (SDK 27), l10n audit, `plutil -lint`, `iconutil`, codesign ad-hoc. Build **thất bại nếu có chuỗi UI chưa dịch**. |
| `CONFIG=debug Scripts/bundle.sh` · `UNIVERSAL=1 Scripts/bundle.sh` · `Scripts/bundle.sh --run [args]` | Bản debug · bản arm64 + x86_64 · build rồi chạy luôn |
| `SIGN_IDENTITY=… Scripts/bundle.sh` | Ký bằng identity thật. Ký ad-hoc làm macOS **mất quyền Screen Recording sau mỗi lần build**. |
| `Scripts/test.sh` | `swift test --disable-xctest` (swift-testing). Test platform có attach ảnh đĩa thật bằng `hdiutil`. |
| `Scripts/crosscheck.sh` | So `hexer-cli` với xxd, grep, perl, md5, shasum, cksum, cmp… trên HxD64.exe và các tệp ngẫu nhiên |
| `swift Scripts/record_demo.swift && swift Scripts/make_promo.swift` | Video giới thiệu `build/promo/hexer-tour.mp4` (1920×1080, H.264, khoảng 40 giây), **không commit**. `record_demo` chạy app với `-HexerDemo` (kịch bản `App/DemoScript.swift` tự thao tác qua API của app, không phát sự kiện chuột/phím ra hệ thống) và quay **chỉ cửa sổ Hexer** bằng ScreenCaptureKit. `make_promo` ghép bản quay với con trỏ, hiệu ứng click, nhãn phím, zoom và chú thích theo `timeline.json`, rồi vá chỉ báo chia sẻ màu tím trên đèn giao thông bằng ảnh sạch app chụp trước khi quay. Cần quyền Screen Recording; chạy `Scripts/bundle.sh` trước. |
| `Scripts/vm_test.sh deploy` · `selftest` · `shot NAME [GIÂY] -- ARGS` · `ssh CMD` | Test trên máy ảo macOS trong UTM qua SSH: chép `Hexer.app`, `hexer-cli` và tệp mẫu (`$P/Hexer`, `$P/Hexer-b`, `$P/firmware.hex`), chạy selftest, mở app với các cờ `-Hexer…` rồi chụp **cửa sổ UTM** về `build/vm/shots/`. Cấu hình trong `build/vm/config` (`VM_HOST`, `VM_USER`, `VM_KEY`, `VM_NAME`; máy hiện tại: macOS 15.0, `letrucdev@192.168.64.2`). Một lần trong máy ảo: bật Remote Login và thêm public key vào `~/.ssh/authorized_keys`. |
| `Scripts/make_dmg.sh` · `--no-build` | Bản phát hành cho người khác: build universal rồi tạo `build/Hexer-<version>.dmg` gồm `Hexer.app`, lối tắt `Applications`, biểu tượng ổ đĩa và hai hướng dẫn RTF ("Install Hexer.rtf", "Hướng dẫn cài đặt Hexer.rtf", sinh từ `Distribution/install-{en,vi}.html` bằng `textutil`). App ký ad hoc và chưa notarize, nên hướng dẫn chỉ cách cho phép lần mở đầu (Privacy & Security ▸ Open Anyway, hoặc `xattr -dr com.apple.quarantine`). Có `SIGN_IDENTITY` thì ký cả DMG. Tên nút trong hướng dẫn lấy từ bảng bản địa hoá của hệ thống (CoreServicesUIAgent, SecurityPrivacyExtension). |
| `Scripts/fetch_capstone.sh` | Tải lại hoặc cập nhật Capstone 5.0.9 vào `Sources/CCapstone` (đã kiểm sha256) |
| `swift build --product hexer-cli` | CLI: `dump`, `find`, `replace`, `checksum`, `stats`, `diff`, `export`, `import` (`ihex`/`srec`/`etl`), `disasm`, `edit`, `split`, `concat`, `disks` (`list`/`read`), `bench`, `selftest`, `help` |
| `hexer-cli selftest` | Kiểm known-answer ngay trong binary (checksum, digest, bảng mã, piece tree, tìm kiếm, Intel Hex/S-Record, lưu tệp, Capstone). Dùng cho bản build không chạy được test suite, ví dụ lát x86_64 của bản universal: `arch -x86_64 hexer-cli selftest`. |

### CI và phát hành (GitHub Actions)
- **`.github/workflows/ci.yml`:**
  - Chạy khi push lên `main` hoặc mở pull request (bỏ qua thay đổi chỉ ở `*.md`, `docs/`, `Distribution/`), hoặc chạy tay.
  - Chạy `Scripts/test.sh`, `Scripts/crosscheck.sh` (HxD64.exe không có trên runner nên bị bỏ qua) và `Scripts/bundle.sh`; tải `Hexer.app` lên làm artifact, giữ 7 ngày.
- **`.github/workflows/release.yml`:**
  - Chạy khi push tag `v*`, ví dụ `git tag v0.2 && git push origin v0.2`.
  - Gọi lại `ci.yml`; nếu đạt thì lấy phiên bản từ tag, ghi vào `CFBundleShortVersionString`, chạy `Scripts/make_dmg.sh`.
  - Tạo release bằng `gh release create`, kèm DMG, tệp `.sha256` và ghi chú từ `Distribution/release-notes.md`. Tag có dấu `-` (ví dụ `v1.0-beta`) thành pre-release.
- **Runner:** `xcode-27` (macOS 27, Xcode 27.0, SDK 27; nhãn còn ở dạng preview), chọn qua `DEVELOPER_DIR`. Khi `DEVELOPER_DIR` trỏ tới một Xcode, Package.swift không thêm `-plugin-path` của CLT.
- **Repo đang private:** API công khai trả 404, nên không xem được kết quả Actions nếu không đăng nhập (`gh` chưa cài trên máy này). Release của repo private chỉ người có quyền vào repo mới tải được.
- **Chi phí:** phút chạy runner macOS bị tính nhiều hơn Linux (gần đây là gấp 10 lần) vào hạn mức Actions của repo private; nên kiểm tra mức dùng trong Settings ▸ Billing.

### Những điểm dễ vấp
- **`@State` không biên dịch được**, vì CLT thiếu SwiftUIMacros. Dùng model `@Observable` + `@Bindable`. `@FocusState`, `@Namespace` và `@AppStorage` vẫn dùng được.
- **Test target cần `-plugin-path …/host/plugins/testing`.** Hằng `testSettings` trong `Package.swift` lo việc này; thiếu nó thì thỉnh thoảng báo không tìm thấy TestingMacros.
- **SourceKit báo "No such module 'HexerPlatform'"** trong editor. Lỗi này giả, vì không có project Xcode; cứ build bằng script là được.
- **API mới hơn macOS 15:** trình biên dịch báo lỗi nếu dùng mà không có `if #available`. Kính luôn đi qua helper trong `GlassBarStyle.swift` (`barGlass`, `barGlassID`, `GlassGroup`). Kiểm giao diện macOS 15 bằng `-HexerNoGlass 1`.
- **Lỗi isolation của Swift 6:** module app chạy với `defaultIsolation(MainActor)`. Hằng `static let` hay helper dùng từ nền phải đánh dấu `nonisolated`.
- **Bundle cần thêm chuỗi tiếng Việt.** Mỗi chuỗi UI mới phải có bản dịch trong `Scripts/l10n/vi.py`. Chạy `python3 -I Scripts/l10n/vi.py` để sinh `Resources/Localization/vi.lproj/Localizable.strings`; nếu thiếu, `bundle.sh` dừng. Pattern mà audit nhận diện nằm trong `Scripts/l10n_audit.swift`: `Text`/`Button`/`L(…)`…, helper `item`/`menu`/`sub`/`pane`/`field`/`fact`/`group`, nút icon (`GlassBarIconButton`, `iconButton`…), `title:`/`placeholder:` và hai nhánh `Text(c ? "A" : "B")`. Helper mới nhận chuỗi UI thì thêm vào danh sách này.
- **Khoá dịch không được chứa `\n`.** Câu nhiều dòng thì ghép từ nhiều `L(…)` (xem `App/ErrorMessages.swift`).
- **NSAlert trên macOS 27:** khi `runModal` chạy, Return được chuyển từ `keyEquivalent` của nút đầu sang `window.defaultButtonCell`. Muốn nút nào không nhận Return thì dùng `alert.addDestructiveButton(withTitle:)` (`App/Alerts.swift`), đừng tự gán `keyEquivalent`.

### Chạy app có kịch bản (`App/DebugLaunchArguments.swift`)
Ví dụ:

```sh
build/Hexer.app/Contents/MacOS/Hexer file.bin -HexerGoTo 0x100 -HexerAction goToOffset: -HexerSnapshot /path/shot.png -HexerQuit 1
```

- Các cờ: `-HexerAction sel:`, `-HexerSnapshot path`, `-HexerSnapshotShadow 1` (giữ bóng cửa sổ trên nền trong suốt, dùng cho ảnh README), `-HexerAppearance light|dark` (ép giao diện qua `NSApp.appearance`; đừng dùng `-NSRequiresAquaSystemAppearance`, cờ đó làm toolbar trong suốt), `-HexerFindAllSelect n` (chọn kết quả thứ n sau Find All, mặc định 2), `-HexerDemo DIR` + `-HexerDemoFirmware HEX` (kịch bản quay video, xem bảng lệnh), `-HexerNoGlass 1` (giao diện macOS 15, không kính), `-HexerAlertSnapshot path` (chụp alert modal kế tiếp, in nút nào nhận Return/Esc, rồi huỷ alert), `-HexerQuit 1`, `-HexerFind/-HexerFindType/-HexerFindAll`, `-HexerReplace/-HexerReplaceAll`, `-HexerSave`, `-HexerUndoAll`, `-HexerChecksums`, `-HexerExpected`, `-HexerCompare/-HexerCompareSteps/-HexerCompareList`, `-HexerCopyAs`, `-HexerImport path` (nhận thêm `-HexerWindowSize`, `-HexerGoTo`, `-HexerAction`), `-HexerOpenDisk diskN` (+ `-HexerOpenDiskWritable 1`, chỉ áp dụng cho ảnh đĩa), `-HexerPrintPDF`, `-HexerSectorSize`, `-HexerWindowSize WxH`, `-HexerGoTo`, `-HexerSelect a-b`, `-HexerMode`, `-HexerEncoding`, `-HexerBytesPerRow`, `-HexerDrawer`, `-HexerHideInspector`, `-HexerSettingsPane n`.
- **Cờ nào cũng phải kèm giá trị** (ví dụ `1`). Nếu không, AppKit coi chữ đứng sau là tên tệp và mở nó.
- Tiếng Việt: thêm `-AppleLanguages '(vi)'`.
- Ảnh chụp dùng `screencapture -l <windowID>` (cần quyền Screen Recording). **Không bao giờ chụp theo vùng màn hình**, vì sẽ dính cửa sổ app khác.

## 3. Kiến trúc

```
Sources/
  CCapstone/      Capstone 5.0.9 vendored (X86 + AArch64)
  CHexerSys/      C: nhận fd từ authopen (SCM_RIGHTS), ioctl DKIOC*
  HexerCore/      Swift thuần, không phụ thuộc UI
    Storage/      ByteSource, ChunkCache, PieceTree (B+tree persistent), EditableBuffer (undo vô hạn),
                  AddBuffer, Generator (pattern/random), FileWriter (clone APFS + vá các vùng đã đổi)
    Search/       SearchQuery, CompiledSearch, MatchScanner (memmem, gấp hoa/thường, UTF-16), Search/ReplaceEngine
    Analysis/     Checksum (Sum, CRC Rocksoft, MD2/MD4 tự viết, MD5/SHA qua CryptoKit), ByteStatistics, CompareEngine
    Codecs/       Export (Raw/Hex/Text, nguồn Pascal/C/C#/Java/VB.NET/PureBasic, Editor view/HTML/RTF/TeX,
                  S19/S28/S37, Intel Hex 16/20/32), Import (Intel Hex, S-Record, ETL Extended)
    Inspector/    DataInspector (30 kiểu), Codecs (LEB128, Real48, Ext80, OLE/FILETIME/DOS/time_t, GUID)
    Text/         TextEncoding (Windows-1252, CP437, Mac Roman, EBCDIC 500), CharacterFilter
    Layout/       HexLayout, VirtualScrollMapper (cuộn co giãn cho tệp ~2^40 byte), RowMap (dòng hiển thị ↔ dòng dữ liệu khi gập vùng undefined)
    FileTools/    split, concatenate, overwrite, wipe
  HexerDisasm/    Wrapper Swift cho Capstone (x86-16/32/64, ARM64)
  HexerPlatform/  DiskEnumerator (IOKit + DiskArbitration), RawDeviceOpener (authopen), DiskByteSource,
                  DiskWriter (đọc-sửa-ghi theo sector), DiskCloner, DiskArbitrationSession (unmount)
  Hexer/          App: vòng đời AppKit, view SwiftUI
    App/          main, AppDelegate, MainMenu (menu dựng bằng code), AppSettings, L10n (L("…")), DebugLaunchArguments,
                  Alerts (nút destructive), ErrorMessages (lỗi core → chuỗi UI)
    Document/     HexDocument (NSDocument), HexWindowController, EditorSession (+Editing/+Search/+Tools),
                  CompareSession, ExportImport, Jobs (JobCenter: tác vụ nền huỷ được, có tiến độ), Print
    HexGrid/      HexCanvasView (vẽ bằng CoreText, nhập liệu, IME, VoiceOver), HexEditorView, HexTheme
    Views/        DocumentWindowView, SidebarView, InspectorView, FindBar, ResultsDrawer, StatusBarView,
                  SectorNavigator, GlassBarStyle, SettingsWindowController, Sheets/, Analysis/, Tools/
  HexerCLI/       hexer-cli
Tests/            HexerCoreTests, HexerDisasmTests, HexerPlatformTests (swift-testing)
Resources/        Info.plist, entitlements (không sandbox), Icon, Licenses, Localization/{en,vi}.lproj
```

### Các quyết định chính
- **Lưu tệp:**
  - `FileWriter` clone tệp gốc (APFS `clonefile`) rồi chỉ vá các vùng đã đổi.
  - Nếu kích thước thay đổi, ghi stream ra tệp mới rồi thay thế nguyên tử.
  - Lịch sử undo vẫn đọc được byte cũ sau khi lưu.
  - `.bak` là tuỳ chọn.
  - `NSFilePresenter` báo khi tệp bị thay đổi từ bên ngoài.
- **Lưới hex** là `NSView` riêng, chỉ vẽ các hàng đang thấy. `GlyphBatcher` đảo trục y vì CoreText dùng text matrix lật. Bật `clipsToBounds` để lưới không vẽ đè lên status bar.
- **Ổ đĩa:**
  - Mở `/dev/rdiskN`; nếu bị từ chối thì xin quyền bằng `AuthorizationCopyRights` + `authopen -stdoutpipe -extauth` (không bao giờ dùng `-w`, vì nó cắt cụt thiết bị).
  - Mặc định mở chỉ đọc; ổ khởi động không bao giờ ghi được.
  - Unmount trước khi ghi.
- **EBCDIC dùng CP500**, đúng bảng trong HxD64.exe tại 0x57c8c4, không phải CP037.
- **Compare** xếp hai cửa sổ không dùng animation, sau trễ 50 ms; animation từng gây vòng lặp Auto Layout. Capsule điều hướng khác biệt là overlay ở đáy lưới.
- **Phụ đề cửa sổ ("9.6 MB · Overwrite"):** từ macOS 26, `HexWindowController` đặt `NSWindow.subtitle`. Trước macOS 26, split view của SwiftUI tự vẽ thanh tiêu đề và xoá `NSWindow.subtitle`, nên host bật `sceneBridgingOptions = [.toolbars, .title]` và `DocumentWindowView` đặt `.navigationSubtitle(session.windowSubtitle)`. Tiêu đề vẫn do NSDocument quản lý.
- **Dấu "đã sửa" của cửa sổ:** vì `HexDocument` override `isDocumentEdited`, NSDocument không tự gọi `setDocumentEdited` cho window controller (chấm trong nút đóng không hiện, trên cả macOS 15 và 27). `bufferDidChange` gọi trực tiếp cho mọi window controller.
- **Gập vùng undefined:** `HexEditorView.rowMap` (`RowMap`, HexerCore) quy đổi dòng hiển thị ↔ dòng dữ liệu. Mọi chỗ tính dòng (vẽ, caret, hit-test, cuộn, IME, ↑↓/Page, compare, sector navigator) đều đi qua nó; đừng dùng lại `offset / bytesPerRow` để ra dòng trên màn hình.
  - Canvas đọc byte theo từng đoạn dòng dữ liệu liền nhau, không bao giờ đọc xuyên qua vùng gập (có thể lớn hàng GB).
  - Khi bố cục dòng đổi (bytes per row, gập/mở), byte ở đầu màn hình được giữ nguyên.
  - State: `EditorSession.foldsUndefinedSections`, `unfoldedSections` (theo byte đầu của vùng).
- **Lỗi core sang tiếng Việt:** core giữ câu tiếng Anh (CLI in nguyên văn); app map từng case trong `App/ErrorMessages.swift`. Thêm case lỗi mới ở core thì thêm nhánh tương ứng ở đó và bản dịch trong `vi.py`.
- **Settings:** mỗi pane dùng `NSHostingController.sizingOptions = .preferredContentSize` và gán `title` (cửa sổ lấy tên pane làm tiêu đề). Thiếu dòng này thì cửa sổ mặc định 500×500 và nội dung bị đặt giữa.

## 4. Đã làm (so với HxD)

| Nhóm | Tính năng |
|---|---|
| Tệp | New, Open, Open Recent, Close/Close All, Save/Save As/Save All, Save Selection As, Reload from Disk, `.bak`, phát hiện thay đổi từ bên ngoài, Page Setup/Print, tab cửa sổ native, Tile Vertically/Horizontally |
| Import/Export | Import Intel Hex, S-Record, ETL Extended (vùng trống thành section undefined). Export và Copy As đủ định dạng HxD (§3); độ dài dòng chỉnh trong Settings ▸ Export. |
| Sửa | Undo/Redo không giới hạn, Cut/Copy/Paste Insert/Paste Overwrite/Delete, Copy Offset, Insert Bytes, Fill Selection (nhiều pass, hex/random, preset DoD và Zero, ghi thẳng xuống đĩa), Select All/Block, chế độ Insert/Overwrite/Read-only, nhập theo nibble, IME |
| Tìm kiếm | Find/Replace/Find Next/Previous, Use Selection; kiểu Text (bảng mã editor hoặc UTF-16LE, phân biệt hoa thường), Hex, Integer (bất kỳ, 8–64, LE/BE, có dấu hoặc không), Float (Single/Double/Real48/Extended); hướng All/Forward/Backward; Find All vào drawer; hỏi trước khi thay thế; tìm chạy nền có Stop |
| Điều hướng | Go to Offset (gốc: đầu tệp, vị trí hiện tại, cuối tệp; hex/dec/oct), bookmark 0–9, sector navigator |
| Hiển thị | Bytes per row (8–4096, Custom…, vừa cửa sổ), nhóm 1/2/4/8/16, các cột Hex/Text, offset hex/dec/oct, 4 bảng mã, hex chữ thường, Filter Characters, ghost caret, tô màu cột lẻ, byte đã sửa màu đỏ, gập vùng undefined sau khi import (bấm để mở, View ▸ Fold Undefined Sections) |
| Data Inspector | 30 kiểu (gồm LEB128, OLETIME, FILETIME, DOS, time_t, GUID, disassembly x86-16/32/64 + ARM64), LE/BE, Hex, sửa trực tiếp, bước theo kiểu, bật/tắt từng kiểu trong Settings |
| Phân tích | Checksums (Sum 8–64, Custom, CRC-16, CRC-16/CCITT-FALSE, CRC-32, CRC-32C, Custom CRC, MD2/4/5, SHA-1/256/384/512, so với giá trị mong đợi, Copy / Copy with Details), Statistics (biểu đồ, Hide maximum, entropy), Compare (hai cửa sổ, F6/⇧F6, danh sách khác biệt) |
| Ổ đĩa | Open Disk (vật lý/logic), Open Disk Image (chọn sector size), Clone Disk (ổ ↔ ảnh), ghi theo sector, cảnh báo khi mở để ghi |
| Công cụ | Split (preset, Custom, đánh số .001 hoặc hỏi tên), Concatenate, Wipe Securely (DoD/Zero/Random, có cảnh báo SSD/APFS) |
| Khác | Settings (General/Format/View/Inspector/Export), About, Help, Acknowledgements, VoiceOver cho lưới, bản universal, tiếng Anh + tiếng Việt (kể cả thông báo lỗi từ core) |
| An toàn | Alert của thao tác không hoàn tác được dùng nút destructive, Return không kích hoạt; alert mở ổ đĩa để ghi lấy "Open Read-only" làm mặc định |
| CLI | Đủ lệnh trong kế hoạch: thêm `edit`, `split`, `concat`, `disks list/read`, `selftest`; crosscheck so với split/cat/perl/diskutil/dd |
| UI macOS 27 | Sidebar và inspector của hệ thống chạy sát mép; toolbar 3 nhóm; thanh kính đồng nhất 36 pt (`GlassBarStyle.swift`); canvas đã vẽ lại khớp app (version 14–17) |

## 5. Chưa làm

| Hạng mục | Ghi chú |
|---|---|
| Đổi tên / sắp xếp kiểu trong Data Inspector | Settings mới cho bật/tắt. Kế hoạch: Phase 4. |
| Danh sách ổ đĩa (raw) gần đây | HxD có "recent disk images"; Hexer mới có Open Recent cho tệp. Cần kiểm tra xem ảnh đĩa có vào danh sách này không. |
| `Scripts/snapshot.sh`, `Scripts/make_fixtures.sh` | Chưa tạo. Hiện chụp ảnh qua cờ `-Hexer…` và crosscheck tự sinh fixture. |
| Trình sửa RAM/tiến trình | Đã hoãn theo quyết định của người dùng (cần `task_for_pid` / entitlement) |
| Icon app kiểu kính động | Không làm được khi không có `actool` (Xcode) |

## 6. Cần cải thiện (ưu tiên từ trên xuống)

1. **CI (tuỳ chọn).** Repo đã có trên GitHub. Có thể thêm workflow macOS chạy `Scripts/test.sh` và `Scripts/crosscheck.sh`. Crosscheck cần sửa đường dẫn cứng tới `HxD64.exe` (`HXD=` trong script; nếu không có tệp thì bỏ qua) và cần `hdiutil` cho phần ổ đĩa.
2. **Chạy thử trên macOS 26.** macOS 15 đã kiểm trên máy ảo UTM (xem nhật ký phiên 3). macOS 26 chưa kiểm; có thể tạo thêm một máy ảo UTM rồi dùng `Scripts/vm_test.sh` với `VM_NAME`/`VM_HOST` tương ứng.
3. **Kiểm thử ổ đĩa thật.**
   - Prompt của authopen trên ổ trong (cần mật khẩu admin) chưa được thử.
   - Đường ghi ổ đĩa mới chỉ có unit test trên ảnh đĩa attach. Cần thử trên USB thật: ghi, unmount, so `dd`. `hexer-cli disks read diskN` (với sudo) giúp so nhanh.
4. **Kính của find bar trên lưới (chế độ sáng).** Chữ của lưới phía sau vẫn lờ mờ xuyên qua ô tìm kiếm. Đọc vẫn được, nhưng kém rõ hơn chế độ tối. Đây là `.glassEffect(.regular)` của hệ thống; chỉ chỉnh nếu người dùng thấy khó đọc.
5. **Gập vùng undefined, phần còn lại:**
   - Đi qua dòng gập bằng ↑/↓ thì caret mất cột (về byte đầu của vùng).
   - Bản in (Print) không gập.
   - Chưa có cách gập lại riêng một vùng đã mở, ngoài việc tắt rồi bật lại View ▸ Fold Undefined Sections. Có thể thêm menu ngữ cảnh "Fold Section".
6. **Chiều rộng tối thiểu khi mở ngăn Checksums:** khoảng 1270 pt (tiếng Anh) và 1300 pt (tiếng Việt), so với 1166 pt khi không mở ngăn. Thủ phạm còn lại có thể là bảng hoặc segmented tab của drawer; đo bằng cách so `-HexerWindowSize 1100x700` có và không có `-HexerDrawer checksums`.
7. **Cảnh báo NSTableView reentrancy:** "Application performed a reentrant operation in its NSTableView delegate". Đã tái hiện được (2026-10-24), lần nào cũng ra, cả arm64 lẫn x86_64: `build/Hexer.app/Contents/MacOS/Hexer FILE -HexerWindowSize 1100x700 -HexerFind Hexer -HexerFindType text -HexerFindAll 1 -HexerDrawer searchResults -HexerQuit 1`. Nghi bảng Search Results: `searchResultSelection` được đặt (và `onChange` đổi selection, cuộn lưới) ngay trong lúc bảng đang cập nhật sau Find All.
8. **Role của segmented control (SDK 27).** SwiftUI chưa đặt được role `tabs` / `valueSelection` của `NSSegmentedControl`. Nếu cần đúng HIG, bọc AppKit cho tab drawer.
9. **Ký app.** Dùng `SIGN_IDENTITY` (Developer ID hoặc chứng chỉ tự ký) để không mất quyền Screen Recording sau mỗi lần build.
10. **Bản địa hoá còn sót:** phần mô tả errno (`strerror`) trong thông báo lỗi vẫn là tiếng Anh; số trong chuỗi dùng định dạng theo vùng của hệ thống (ví dụ "1,840" khi chỉ đổi ngôn ngữ sang tiếng Việt).
11. **Hiệu năng:** chạy `hexer-cli bench` và mở tệp thưa 6 GB (`mkfile -n 6g`) sau các thay đổi lớn ở Storage hoặc HexGrid. Đã kiểm lại sau khi thêm gập vùng (2026-10-24): tệp 6 GB mở và nhảy tới cuối bình thường.

## 7. Quy ước khi code tiếp

- **Đọc DESIGN.md trước khi đụng UI.** Liquid Glass chỉ dùng cho control; sidebar, inspector, sheet và alert dùng của hệ thống; thanh kính cao `GlassBar.height` (36). Sửa UI xong thì cập nhật canvas và DESIGN.md (quy trình ở DESIGN.md §10).
- **Chuỗi UI:** viết bằng tiếng Anh trong `Text("…")` hoặc `L("…")`, thêm bản dịch vào `Scripts/l10n/vi.py`, rồi chạy `bundle.sh` để audit.
- **Logic thuần** đặt trong HexerCore kèm test swift-testing. Nếu có lệnh CLI tương ứng thì thêm check vào `crosscheck.sh`.
- **Mỗi thay đổi UI** phải được kiểm bằng ảnh chụp thật: sáng, tối, tiếng Việt, cửa sổ hẹp khoảng 1024 pt. Dùng `-HexerSnapshot`.
- **Trước khi báo xong:** chạy `Scripts/test.sh`, `Scripts/crosscheck.sh` và `Scripts/bundle.sh`, tất cả phải đạt.
- Comment trong code viết bằng tiếng Anh, giữ mật độ như code xung quanh.

## 8. Nhật ký các phiên

- **Phiên 1:**
  - Phân tích HxD64.exe bằng REA và giải mã 38 form DFM.
  - Lên kế hoạch 10 phase, tạo canvas Claude Design (kiểu macOS 26).
  - Bắt đầu triển khai.
- **Phiên 2 (2026-10-23):**
  - Hoàn tất phase 1–9 và các phát hiện của phase 10.
  - Cân lại sidebar và inspector. Đối chiếu HIG macOS 27, rồi chuyển sang pane hệ thống sát mép và toolbar 3 nhóm.
  - Thống nhất chiều cao 36 pt cho thanh kính (Find All từng thấp hơn các nút bên cạnh).
  - Vẽ lại toàn bộ canvas cho khớp app và thêm board Tools.
  - Sửa cửa sổ Settings: bỏ khoảng trống, tiêu đề theo pane, đặt lại vị trí stepper, chuyển chú thích thành footer.
  - Viết DESIGN.md và HANDOFF.md.
- **Phiên 3 (2026-10-24):**
  - **Alert an toàn:**
    - Thêm `NSAlert.addDestructiveButton` (nút đỏ, không nhận Return) cho Write to Disk, Write Directly, Overwrite (clone) và Wipe and Delete.
    - Alert mở ổ đĩa để ghi đổi thứ tự: Open Read-only (mặc định) / Open for Writing / Cancel.
    - Kiểm bằng cờ mới `-HexerAlertSnapshot` trên ảnh đĩa thử.
  - **Lỗi core sang tiếng Việt:** thêm `App/ErrorMessages.swift` (48 câu) và hook `willPresentError`. Find bar đã hiện lỗi tiếng Việt.
  - **l10n:**
    - Mở rộng audit; nhờ đó tìm ra một chuỗi chưa dịch ("Choose a file").
    - Xoá 4 khoá không dùng ("Settings", "None", "Expected result:", "%@ bytes · group %@").
  - **CLI:**
    - Thêm `edit`, `split`, `concat`, `disks list/read`, `selftest`.
    - Crosscheck thêm 34 check, có so `disks read` với `dd` trên ảnh raw gắn tạm (không mount, không ghi).
  - **Gập vùng undefined:**
    - `RowMap` (HexerCore, 5 test có so ngẫu nhiên với cách tính ngây thơ).
    - Lưới vẽ dòng gập; bấm để mở; tự mở khi Go to / Find dẫn vào; ↑↓/Page theo dòng hiển thị; mục View ▸ Fold Undefined Sections.
    - Compare cuộn đồng bộ theo byte.
    - Data Inspector chỉ giải mã các byte định nghĩa tính từ caret; trong vùng undefined thì hiện "—" thay vì coi là 0.
    - Chụp kiểm: tối, sáng, tiếng Việt, cửa sổ 1024, Go to vào giữa vùng, tắt gập, compare, tệp 6 GB.
  - Canvas version 18 (board mới Import, sửa Tools và MenusVI), cập nhật DESIGN.md.
  - **Kiểm chế độ sáng thật** (người dùng đã chuyển máy sang Light):
    - Đã chụp cửa sổ chính, dòng gập, find bar và lỗi, Find All, Checksums, Go to, Statistics, 5 pane Settings, Open Disk, Wipe và alert mở ổ đĩa.
    - Toolbar kính hiển thị bình thường. Hiện tượng "toolbar trong suốt" lúc trước chỉ do cờ `-NSRequiresAquaSystemAppearance`; khi cần kiểm giao diện sáng thì dùng chế độ sáng thật.
    - Sửa find bar ở cửa sổ hẹp với tiếng Việt: trước đó "Hỏi trước khi thay thế" và "Thay thế tất cả" xuống dòng, tràn khỏi capsule 36 pt.
      - Nhãn capsule giờ luôn một dòng (`GlassCapsuleButtonStyle` và checkbox).
      - Ô tìm và ô thay thế co xuống tối thiểu 90 pt.
      - Find bar cách hai mép lưới 16 pt.
  - Commit đầu tiên và push lên `letrucdev/hexer` (theo yêu cầu của người dùng).
  - **Hỗ trợ macOS 15** (theo yêu cầu của người dùng):
    - Thử build bản sao với mức tối thiểu macOS 15: chỉ vướng 16 chỗ, toàn API kính trong 5 tệp. macOS 14 vướng thêm `Mutex` (Synchronization) ở HexerDisasm; macOS 13 trở xuống không khả thi vì `@Observable`.
    - Gom kính vào `barGlass`, `barGlassID`, `GlassGroup`. Trên macOS 15 dùng material chuẩn kèm viền mảnh; nút prominent và chip dùng nền accent.
    - Hạ deployment target và `LSMinimumSystemVersion` xuống 15.0.
    - Kiểm: ký hiệu kính được liên kết dạng weak (`dyld_info -imports`), framework liên kết đều có trên macOS 15, chụp `-HexerNoGlass 1` ở sáng, tối, tiếng Việt, cửa sổ hẹp, compare và sector navigator.
  - **Test trên macOS 15.0 thật (máy ảo UTM, người dùng cài):**
    - `hexer-cli selftest` đạt; sửa và lưu tệp ra đúng từng byte như `hexer-cli replace`; `disks list/read` trên ảnh đĩa gắn tạm khớp `dd` (kể cả đoạn không thẳng hàng).
    - Đã chụp: cửa sổ chính, find bar + Replace (sáng, tối, tiếng Việt, cửa sổ 1024), Find All, Checksums (ngăn và sheet), Go to (tiếng Việt), vùng gập sau khi import, so sánh hai cửa sổ, sector navigator, Statistics, 5 pane Settings, Open Disk (liệt kê ổ đĩa của máy ảo, ổ khởi động có khoá), alert mở ổ đĩa để ghi (Open Read-only mặc định, Open for Writing màu đỏ).
    - Lỗi tìm thấy và đã sửa: phụ đề cửa sổ không hiện trên macOS 15; chấm "đã sửa" không hiện trong nút đóng (lỗi có từ trước, cả trên macOS 27).
    - Khác biệt chấp nhận được: ở cửa sổ hẹp, sidebar và inspector của macOS 15 chiếm chỗ (không chảy sau nội dung như macOS 26+), lưới phải cuộn ngang và nhóm toolbar bên phải gập vào nút `»`.
    - Thêm `Scripts/vm_test.sh` để lặp lại các bước trên.
  - **DMG để phát hành** (theo yêu cầu của người dùng): `Scripts/make_dmg.sh`, hướng dẫn cài đặt tiếng Anh và tiếng Việt trong `Distribution/`.
    - Bản universal: phần x86_64 mở được qua Rosetta, `hexer-cli selftest` (x86_64) đạt.
    - Mô phỏng tải về trên máy này: app chép từ DMG có cờ quarantine mang theo cờ đó, Gatekeeper chặn (`spctl`: rejected); lệnh `xattr -dr` trong hướng dẫn gỡ được, chữ ký vẫn hợp lệ.
    - **Chưa** thử hộp thoại Gatekeeper và nút Open Anyway trên máy ảo macOS 15, vì máy ảo đang tắt.
  - **README:**
    - Thêm `README.md` (tiếng Anh): ảnh chính đổi theo giao diện sáng/tối (`<picture>`), tính năng, ảnh chụp, build, CLI, cấu trúc dự án.
    - Ảnh nằm trong `docs/images`, chụp từ app thật bằng `-HexerSnapshotShadow` trên dữ liệu của chính dự án (binary Hexer, Intel Hex dựng từ binary đó, ảnh đĩa FAT "HEXER").
    - Dựng lại ảnh: chạy lại các lệnh chụp (xem cờ ở §2), rồi thu ảnh về chiều dài nhất 1600 px bằng `sips -Z 1600`.
    - Repo chưa có LICENSE nên README không ghi license.
  - **Video giới thiệu quay thao tác thật** (người dùng yêu cầu: không dùng ảnh tĩnh, không đưa video lên GitHub):
    - Kịch bản `App/DemoScript.swift` (cờ `-HexerDemo DIR`): bấm byte, gõ đè hex rồi ⌘Z, ⌘F + Find All + ▼, đổi Big/Little endian, mở Checksums, import Intel Hex vào tab mới, mở vùng gập rồi gập lại, đổi sáng/tối.
    - Toạ độ nút SwiftUI lấy qua modifier `.demoAnchor(_:)` (chỉ ghi khi đang chạy demo). Cửa sổ demo đặt `ignoresMouseEvents` để con trỏ thật không gây hover/tooltip.
    - Quay bằng `Scripts/record_demo.swift`, ghép bằng `Scripts/make_promo.swift`; mọi thứ nằm trong `build/promo/` (đã bị `.gitignore`).
    - Bài học: `SCStream.startCapture` (async) treo nếu tiến trình không chạy `NSApplication` run loop; dùng bản completion handler trong `nsapp.run()`.
  - **Sửa lỗi phát hiện khi quay:** chọn một khối lớn hoặc mở ngăn Checksums làm cửa sổ tự nở rộng (1280 → 1344/1396 pt), vì SwiftUI tính chiều rộng lý tưởng của các trường status bar, cột bảng và ô "Expected result" vào kích thước tối thiểu của cửa sổ.
    - Trường status bar giờ co lại được (Block co trước) và cắt giữa.
    - Chiều rộng lý tưởng của cột bảng Search Results/Checksums nhỏ lại.
    - Ô "Expected result" dùng `ViewThatFits` (240 → 140 → ẩn).
    - Kiểm: 1280 pt giữ nguyên 1280 ở mọi trạng thái. Ngăn Checksums vẫn nâng chiều rộng tối thiểu lên khoảng 1270 pt (tiếng Anh) và 1300 pt (tiếng Việt), so với 1166 pt khi không mở ngăn (xem §6).
