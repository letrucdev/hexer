# Hexer — Bàn giao kỹ thuật

Cập nhật lần cuối: 2026-10-26. Đọc file này trước khi code tiếp; phần thiết kế giao diện nằm ở [DESIGN.md](DESIGN.md).

Hexer là trình sửa hex thiết kế cho macOS 27, viết bằng SwiftUI + AppKit với Liquid Glass, và **chạy từ macOS 15** (macOS 15 không có kính, xem DESIGN.md §11). Mục tiêu là đủ tính năng như **HxD 2.5**, được dựng lại từ `HxD64.exe` bằng REA.

| Tài liệu | Đường dẫn |
|---|---|
| Kế hoạch gốc (10 phase, kiến trúc, rủi ro) | `~/.claude/plans/d-ng-rea-ph-n-t-ch-wiggly-metcalfe.md` |
| Thiết kế UI (canvas Claude Design) | https://claude.ai/artifact/JBSgQBQpVLtMWto8QECZgb · [DESIGN.md](DESIGN.md) |
| Bản HxD dùng để đối chiếu | `~/Downloads/HxD/HxD64.exe` (crosscheck cũng dùng file này) |

## 1. Trạng thái nhanh

- Phase 1–9 đã xong. Phase 10 (đối chiếu chi tiết với HxD bằng REA) đã áp dụng các phát hiện chính.
- **Đã kiểm tra lại ngày 2026-10-25:**
  - `Scripts/test.sh`: 193 test đều đạt (HexerCore 139, HexerDisasm 12, HexerPlatform 42).
  - `Scripts/crosscheck.sh`: 287/287 đạt.
  - `Scripts/bundle.sh`: build không có warning, ngoại trừ cảnh báo search path của linker.
  - Đã kiểm l10n: 666 khoá có tiếng Việt (audit giờ nhận thêm nhiều mẫu, xem §2).
- **Bản mới nhất: v0.4.0** (2026-10-26), bản cầu nối sang máy chủ cập nhật trên Cloudflare R2 (`https://pub-78e377a21a0d499cb607f4ad3d0c899d.r2.dev/update.json`): 0.3.x tìm thấy nó qua GitHub API như trước, từ 0.4.0 trở đi app đọc manifest trên R2 (GitHub Release là nguồn dự phòng). Secret `HEXER_UPDATE_KEY` và 3 secret `UPDATE_S3_*` đã có trên GitHub. Người đang dùng 0.2.0 trở xuống phải tải bằng tay một lần.
- **Git:** nhánh `main`, remote `origin` = `git@github-letrucdev:letrucdev/hexer.git` (host SSH `github-letrucdev` là alias trong `~/.ssh/config` của máy). Commit đầu tiên đã push ngày 2026-10-24. Chỉ commit hoặc push khi người dùng yêu cầu.

## 2. Môi trường và lệnh

Máy chỉ có **Command Line Tools**, không có Xcode: Swift 6.4, SDK MacOSX27, SwiftPM tools 6.2, Swift 6 language mode. Deployment target **macOS 15** (`Package.swift`, `LSMinimumSystemVersion`); `bundle.sh` ghi `minos 15.0`, `sdk 27.0` vào binary.

| Lệnh | Tác dụng |
|---|---|
| `Scripts/bundle.sh` | Build release → `build/Hexer.app`. Chạy `vtool` (SDK 27), l10n audit, `plutil -lint`, `iconutil`, codesign ad-hoc. Build **thất bại nếu có chuỗi UI chưa dịch**. Phiên bản lấy từ `$VERSION` (workflow Release đặt theo tag), nếu không có thì từ tag `v*` gần nhất (`git describe --tags --abbrev=0`); chỉ khi không có tag (clone nông như CI thường) mới giữ `0.1` của `Resources/Info.plist`. |
| `CONFIG=debug Scripts/bundle.sh` · `UNIVERSAL=1 Scripts/bundle.sh` · `Scripts/bundle.sh --run [args]` | Bản debug · bản arm64 + x86_64 · build rồi chạy luôn |
| `SIGN_IDENTITY=… Scripts/bundle.sh` | Ký bằng identity thật. Ký ad-hoc làm macOS **mất quyền Screen Recording sau mỗi lần build**. |
| `Scripts/test.sh` | `swift test --disable-xctest` (swift-testing). Test platform có attach ảnh đĩa thật bằng `hdiutil`. Quá `$TEST_TIMEOUT` giây (mặc định 900, tính cả build) thì dừng và in các dòng `error:`: tiến trình con còn chạy (ví dụ một `hdiutil` treo) và các frame của code Hexer trong stack của tiến trình test (lấy bằng `sample`). Trên CI, các dòng này thành annotation đọc được không cần đăng nhập. swift-testing không in gì cho tới khi chạy xong nếu output không phải terminal, kể cả `--event-stream-output-path`. |
| `Scripts/crosscheck.sh` | So `hexer-cli` với xxd, grep, perl, md5, shasum, cksum, cmp… trên HxD64.exe và các tệp ngẫu nhiên |
| `swift Scripts/record_demo.swift && swift Scripts/make_promo.swift [--lang vi]` | Video giới thiệu `build/promo/hexer-tour.mp4` (bản phụ đề tiếng Việt: `hexer-tour-vi.mp4`), 1920×1080, 60 fps, H.264 + AAC, 120 giây, khoảng 175 MB, **không commit**. `record_demo` chạy app với `-HexerDemo` (kịch bản `App/DemoScript.swift` tự thao tác qua API của app, không phát sự kiện chuột/phím ra hệ thống) và quay **chỉ cửa sổ Hexer** ở 60 fps bằng ScreenCaptureKit. `make_promo` dựng khung hình bằng Core Image trên GPU (render mất khoảng 30 giây): mở đầu với sàn byte 3D, icon và chữ "Hexer"; cửa sổ trồi lên khi nhịp vào; con trỏ (đường hơi cong, tốc độ kiểu minimum-jerk), hiệu ứng click, badge phím; camera trượt mượt theo các sự kiện `focus` trong `timeline.json` (smootherstep 1,6 s vào, 1,5 s ra, zoom theo thang log quanh điểm đứng yên); caption kính có số chương (thu gọn khi zoom); chuyển chương đúng beat; cuối video có lưới tính năng và link. Nhạc nền nhẹ 80 BPM do `Scripts/make_music.py` (numpy, tự tổng hợp, không dùng sample) tạo từ `cues.json` mà `make_promo` ghi ra, ghép vào bằng `afconvert` và `AVAssetExportSession`. `--stills 6.5,20` chỉ xuất các khung đó ra PNG để xem nhanh. Chỉ báo chia sẻ màu tím được vá bằng ảnh sạch (cửa sổ chính) và bằng cách dò từng khung (cửa sổ Statistics). Cần quyền Screen Recording, numpy, và chạy `Scripts/bundle.sh` trước. |
| `Scripts/vm_test.sh start` · `deploy` · `selftest` · `shot NAME [GIÂY] -- ARGS` · `capture` · `burst` · `keys` · `press` · `menu` · `close` · `ax` · `ssh CMD` | Test trên máy ảo macOS trong UTM qua SSH. `start` bật máy ảo (`utmctl`) rồi đợi SSH. `deploy` chép `Hexer.app`, `hexer-cli`, tệp mẫu (`$P/Hexer`, `$P/Hexer-b`, `$P/firmware.hex`) và `vm_agent`. `shot` mở app với các cờ `-Hexer…`, chụp **cửa sổ UTM** rồi cắt theo cửa sổ Hexer, lưu vào `build/vm/shots/`; `capture` chụp ngay lúc đó; `burst` bấm phím rồi chụp liền nhiều khung để xem animation. `keys` (`left`, `return`, `escape`, `cmd+o`…), `press`, `menu`, `close` và `ax windows|tree|frame` điều khiển Hexer trong máy ảo qua `Scripts/vm_agent.swift` (sự kiện phím gửi thẳng vào tiến trình, nút và menu qua Accessibility API), không đụng chuột hay bàn phím của máy này. Cấu hình trong `build/vm/config` (`VM_HOST`, `VM_USER`, `VM_KEY`, `VM_NAME`; máy hiện tại: macOS 15.0, `letrucdev@192.168.64.2`). Một lần trong máy ảo: bật Remote Login, thêm public key vào `~/.ssh/authorized_keys`, và cho `/usr/libexec/sshd-keygen-wrapper` quyền Accessibility (máy hiện tại đã có). MCP `utm` cũng bật/tắt được máy ảo và lấy IP (`start_vm`, `get_vm_ip`…). |
| `Scripts/make_dmg.sh` · `--no-build` | Bản phát hành cho người khác: build universal rồi tạo `build/Hexer-<version>.dmg` gồm `Hexer.app`, lối tắt `Applications`, biểu tượng ổ đĩa và hai hướng dẫn RTF ("Install Hexer.rtf", "Hướng dẫn cài đặt Hexer.rtf", sinh từ `Distribution/install-{en,vi}.html` bằng `textutil`). App ký ad hoc và chưa notarize, nên hướng dẫn chỉ cách cho phép lần mở đầu (Privacy & Security ▸ Open Anyway, hoặc `xattr -dr com.apple.quarantine`). Có `SIGN_IDENTITY` thì ký cả DMG. Tên nút trong hướng dẫn lấy từ bảng bản địa hoá của hệ thống (CoreServicesUIAgent, SecurityPrivacyExtension). |
| `Scripts/sign_update.sh VERSION` | Ký `build/Hexer-VERSION.dmg` bằng khoá trong `$HEXER_UPDATE_KEY` → `.dmg.sig`, rồi kiểm lại bằng `HexerUpdatePublicKey` trong `build/Hexer.app`; khoá không khớp thì dừng. Workflow Release chạy sau `make_dmg.sh`. Thử ở máy này: `HEXER_UPDATE_KEY="$(security find-generic-password -a letrucdev/hexer -s 'Hexer update signing key' -w)" Scripts/sign_update.sh 0.1` (xoá `.sig` sau khi thử). |
| `Scripts/publish_update.sh VERSION NOTES_FILE` | Đẩy `build/Hexer-VERSION.dmg` và `update.json` (manifest cũ trên máy chủ + bản này) lên máy chủ cập nhật qua API S3; cần `UPDATE_S3_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. Workflow Release chạy sau `sign_update.sh`. Xem "Máy chủ cập nhật" bên dưới. |
| `Scripts/fetch_capstone.sh` | Tải lại hoặc cập nhật Capstone 5.0.9 vào `Sources/CCapstone` (đã kiểm sha256) |
| `swift build --product hexer-cli` | CLI: `dump`, `find`, `replace`, `checksum`, `stats`, `diff`, `export`, `import` (`ihex`/`srec`/`etl`), `disasm`, `edit`, `split`, `concat`, `disks` (`list`/`read`), `update` (`keygen`/`public-key`/`sign`/`verify` cho chữ ký bản cập nhật; `manifest`/`download`/`upload` cho máy chủ cập nhật), `bench`, `selftest`, `help` |
| `hexer-cli selftest` | Kiểm known-answer ngay trong binary (checksum, digest, bảng mã, piece tree, tìm kiếm, Intel Hex/S-Record, lưu tệp, Capstone). Dùng cho bản build không chạy được test suite, ví dụ lát x86_64 của bản universal: `arch -x86_64 hexer-cli selftest`. |

### CI và phát hành (GitHub Actions)
- **`.github/workflows/ci.yml`:**
  - Chạy khi push lên `main` hoặc mở pull request (bỏ qua thay đổi chỉ ở `*.md`, `docs/`, `Distribution/`), hoặc chạy tay.
  - Chạy `Scripts/test.sh`, `Scripts/crosscheck.sh` (HxD64.exe không có trên runner nên bị bỏ qua) và `Scripts/bundle.sh`; tải `Hexer.app` lên làm artifact, giữ 7 ngày.
- **`.github/workflows/release.yml`:**
  - Chạy khi push tag `v*`. Quy tắc đặt tên và lệnh tạo tag nằm trong CLAUDE.md (mục "Phát hành"), ví dụ `git tag -a v0.1.1 -m "Hexer 0.1.1" && git push origin v0.1.1`.
  - Job `notes` chạy trước: `Scripts/release_notes.sh` phải tìm thấy mục của phiên bản trong `CHANGELOG.md`, nếu không thì dừng.
  - Job `notes` cũng dừng nếu thiếu secret `HEXER_UPDATE_KEY` (xem "Khoá ký bản cập nhật" bên dưới).
  - Job `notes` cũng dừng nếu thiếu secret `UPDATE_S3_URL`, `UPDATE_S3_ACCESS_KEY_ID` hay `UPDATE_S3_SECRET_ACCESS_KEY`, hoặc `HexerUpdateFeedURLs` trong Info.plist còn địa chỉ giữ chỗ `REPLACE-ME` (xem "Máy chủ cập nhật" bên dưới).
  - Sau đó gọi lại `ci.yml`; nếu đạt thì lấy phiên bản từ tag, ghi vào `CFBundleShortVersionString`, chạy `Scripts/make_dmg.sh`, rồi `Scripts/sign_update.sh` (ký DMG, kiểm chữ ký bằng khoá công khai trong app vừa build).
  - Ghi chú do `Scripts/release_notes.sh` dựng vào `build/release-notes.md`: mục của phiên bản trong `CHANGELOG.md` (thay chỗ `@CHANGES@` trong `Distribution/release-notes.md`), hướng dẫn cài đặt, link so sánh với tag trước, rồi dòng SHA-256.
  - `Scripts/publish_update.sh` đẩy lên máy chủ cập nhật: tải `update.json` hiện có (qua API S3, không qua cache), thêm bản mới bằng `hexer-cli update manifest` (notes = `release-notes.md`, `urls` = DMG trên máy chủ rồi DMG trên GitHub Release), upload DMG (`Cache-Control: immutable`) rồi mới upload `update.json` (`max-age=300`), cuối cùng `curl` kiểm DMG đã công khai ở địa chỉ app sẽ đọc.
  - Tạo release bằng `gh release create`, kèm DMG, tệp `.sha256`, tệp `.sig` (bản 0.3.x cần) và bản chép `update.json` (nguồn dự phòng của app). Tag có dấu `-` (ví dụ `v0.2.0-beta.1`) thành pre-release.
- **Runner:** `xcode-27` (macOS 27, Xcode 27.0, SDK 27; nhãn còn ở dạng preview), chọn qua `DEVELOPER_DIR`. Khi `DEVELOPER_DIR` trỏ tới một Xcode, Package.swift không thêm `-plugin-path` của CLT.
- **Repo public** (https://github.com/letrucdev/hexer). Không đăng nhập vẫn xem được trạng thái từng bước qua API (`/actions/runs`, `/actions/runs/<id>/jobs`), nhưng log thì phải đăng nhập. Vì vậy `Scripts/ci_run.sh` lặp lại các dòng lỗi của bước bị lỗi thành annotation (`/check-runs/<id>/annotations`), đọc công khai được. Máy này chưa cài `gh`; Python của máy thiếu chứng chỉ SSL, nên gọi API bằng `curl`.
- **Kết quả:** CI mất khoảng 4–5 phút; workflow Release (gồm cả CI) khoảng 7–8 phút.
- **Giới hạn API khi theo dõi:** không đăng nhập thì chỉ có 60 lần gọi mỗi giờ cho mỗi IP; Hexer 0.3.x trên cùng mạng cũng dùng chung hạn mức đó để kiểm tra cập nhật (từ 0.4.0 thì không: app đọc manifest, không gọi API). Theo dõi một workflow thì hỏi mỗi 60 s là đủ. Phiên 7 dùng hết hạn mức (mỗi 30 s, nhiều workflow liền nhau), app 0.3.0 kiểm tra thì nhận 403. Trang release và link tải asset (`/releases/download/…`) không tính vào hạn mức.
- **Máy chủ cập nhật (Cloudflare R2, API S3):**
  - Một bucket R2 công khai chứa `update.json` và các `Hexer-X.Y.Z.dmg`. App đọc ở địa chỉ công khai (`HexerUpdateFeedURLs[0]` trong `Resources/Info.plist`, dạng `https://pub-….r2.dev/update.json`; sau này đổi sang tên miền riêng thì chỉ sửa chỗ này và phát hành bản mới, các bản cũ hơn vẫn đọc được qua nguồn dự phòng trên GitHub). `publish_update.sh` suy ra địa chỉ công khai của DMG từ chính khoá này nên không có biến nào phải khớp bằng tay. Lưu ý Cloudflare nói `r2.dev` bị giới hạn tốc độ và không dành cho sản phẩm; khi có tên miền riêng thì gắn vào bucket (Settings ▸ Custom Domains).
  - **Tạo một lần (người dùng tự làm trên Cloudflare):** R2 ▸ Create bucket (tên ví dụ `hexer-updates`, location Automatic) ▸ Settings ▸ Public access ▸ bật r2.dev subdomain, chép địa chỉ `https://pub-….r2.dev`. R2 ▸ Manage R2 API Tokens ▸ Create API token: quyền **Object Read & Write**, giới hạn vào bucket đó, TTL vô hạn; chép Access Key ID, Secret Access Key và endpoint `https://<account id>.r2.cloudflarestorage.com`.
  - **Secret trên GitHub** (Settings ▸ Secrets and variables ▸ Actions): `UPDATE_S3_URL` = `https://<account id>.r2.cloudflarestorage.com/<bucket>` (endpoint + tên bucket, không có dấu `/` cuối), `UPDATE_S3_ACCESS_KEY_ID`, `UPDATE_S3_SECRET_ACCESS_KEY`. Workflow đặt hai khoá vào `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` cho `hexer-cli` (tên chuẩn của mọi công cụ S3; region `AWS_REGION`, mặc định `auto` của R2).
  - **Chữ ký S3 (AWS SigV4)** tự viết trong `HexerCore/Update/AWSSignatureV4.swift` (CryptoKit, có test theo hai ví dụ trong tài liệu S3 của Amazon), nên runner không cần `aws` hay `wrangler`. `hexer-cli update download|upload` gửi bằng URLSession. Bucket nào tương thích S3 (B2, MinIO, S3) cũng dùng được, chỉ đổi `UPDATE_S3_URL`.
  - Thử ở máy này không cần tạo release: `UPDATE_S3_URL=… AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… hexer-cli update download --if-missing-ok "$UPDATE_S3_URL/update.json"` (404 là bình thường khi bucket trống; 403 là token sai quyền). Lần upload thật đầu tiên là release 0.4.0 (workflow đạt ngay lần đầu, xem nhật ký phiên 9).
  - `update.json` trên máy chủ là nguồn sự thật của danh sách 10 bản mới nhất; mất nó thì release sau tạo lại manifest chỉ có bản mới (bản cũ không còn được đề nghị cho người bật beta, nhưng bản ổn định mới nhất vẫn có).
- **Khoá ký bản cập nhật (Ed25519):**
  - Khoá bí mật nằm trong Keychain đăng nhập của máy này: mục "Hexer update signing key", account `letrucdev/hexer` (tạo ngày 2026-10-25 bằng `hexer-cli update keygen`, không in ra màn hình). Khoá công khai `qQH58WYIAJxTACG1jnB/eweAvWnoo3oMkTYQWfKo+MI=` nằm ở `HexerUpdatePublicKey` trong `Resources/Info.plist`.
  - Đưa lên GitHub (một lần, người dùng tự làm vì máy không có `gh`): chạy `security find-generic-password -a letrucdev/hexer -s 'Hexer update signing key' -w | pbcopy`, rồi dán vào Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret, tên `HEXER_UPDATE_KEY`. Nên cất thêm một bản trong trình quản lý mật khẩu.
  - Mất khoá thì không ký được bản mới cho các bản đã cài; phải phát hành bản có khoá công khai mới và người dùng tải tay một lần. Lộ khoá thì cũng vậy (đổi khoá và báo người dùng).
- **Chi phí:** phút chạy runner macOS bị tính nhiều hơn Linux (gần đây là gấp 10 lần) vào hạn mức Actions của repo private; nên kiểm tra mức dùng trong Settings ▸ Billing.

### Những điểm dễ vấp
- **`@State` không biên dịch được**, vì CLT thiếu SwiftUIMacros. Dùng model `@Observable` + `@Bindable`. `@FocusState`, `@Namespace` và `@AppStorage` vẫn dùng được.
- **Test target cần `-plugin-path …/host/plugins/testing`.** Hằng `testSettings` trong `Package.swift` lo việc này; thiếu nó thì thỉnh thoảng báo không tìm thấy TestingMacros.
- **SourceKit báo "No such module 'HexerPlatform'"** trong editor. Lỗi này giả, vì không có project Xcode; cứ build bằng script là được.
- **API mới hơn macOS 15:** trình biên dịch báo lỗi nếu dùng mà không có `if #available`. Kính luôn đi qua helper trong `GlassBarStyle.swift` (`barGlass`, `barGlassID`, `GlassGroup`). Kiểm giao diện macOS 15 bằng `-HexerNoGlass 1`.
- **Lỗi isolation của Swift 6:** module app chạy với `defaultIsolation(MainActor)`. Hằng `static let` hay helper dùng từ nền phải đánh dấu `nonisolated`.
  - Closure đưa cho AppKit hay SwiftUI gọi lại cũng mặc định MainActor, và **trap lúc chạy** nếu bị gọi từ luồng khác. Ví dụ: dynamic provider của `NSColor` bị SwiftUI gọi trên luồng render khi animate. Hàm tạo ra closure loại này phải là `nonisolated` (xem `NSColor.dynamic` trong `HexTheme.swift`).
- **Bundle cần thêm chuỗi tiếng Việt.** Mỗi chuỗi UI mới phải có bản dịch trong `Scripts/l10n/vi.py`. Chạy `python3 -I Scripts/l10n/vi.py` để sinh `Resources/Localization/vi.lproj/Localizable.strings`; nếu thiếu, `bundle.sh` dừng. Pattern mà audit nhận diện nằm trong `Scripts/l10n_audit.swift`: `Text`/`Button`/`L(…)`…, helper `item`/`menu`/`sub`/`pane`/`field`/`fact`/`group`, nút icon (`GlassBarIconButton`, `iconButton`…), `title:`/`placeholder:` và hai nhánh `Text(c ? "A" : "B")`. Helper mới nhận chuỗi UI thì thêm vào danh sách này.
- **Khoá dịch không được chứa `\n`.** Câu nhiều dòng thì ghép từ nhiều `L(…)` (xem `App/ErrorMessages.swift`).
- **Canh giữa cửa sổ có nội dung SwiftUI:** `NSHostingController` chỉ đưa cỡ cho cửa sổ sau một lượt layout (`layoutIfNeeded()` cũng không đủ), nên `center()` gọi ngay sau khi gán `contentViewController` sẽ canh theo cỡ 0, rồi cửa sổ phình sang phải và xuống dưới từ giữa màn hình. Dùng `NSWindow.centerAtContentSize()` (`App/NSWindow+Centering.swift`, đặt cỡ theo `fittingSize` rồi mới canh). `NSTabViewController` (Settings) chỉ đổi cỡ cửa sổ theo pane khi cửa sổ hiện lên, nên Settings canh giữa sau `showWindow` lần đầu. Đo vị trí cửa sổ không cần quyền Screen Recording: `CGWindowListCopyWindowInfo` trả về `kCGWindowBounds`.
- **Selector trùng với NSApplication:** action không có target đi qua responder chain tới `NSApp` **trước** app delegate, nên delegate không được đặt action trùng tên method của `NSApplication`. `showHelp:` từng làm Help ▸ Hexer Help hiện "Help isn't available for Hexer"; giờ là `showHexerHelp:`.
- **NSAlert trên macOS 27:** khi `runModal` chạy, Return được chuyển từ `keyEquivalent` của nút đầu sang `window.defaultButtonCell`. Muốn nút nào không nhận Return thì dùng `alert.addDestructiveButton(withTitle:)` (`App/Alerts.swift`), đừng tự gán `keyEquivalent`.

### Chạy app có kịch bản (`App/DebugLaunchArguments.swift`)
Ví dụ:

```sh
build/Hexer.app/Contents/MacOS/Hexer file.bin -HexerGoTo 0x100 -HexerAction goToOffset: -HexerSnapshot /path/shot.png -HexerQuit 1
```

- Các cờ: `-HexerAction sel:`, `-HexerSnapshot path`, `-HexerSnapshotShadow 1` (giữ bóng cửa sổ trên nền trong suốt, dùng cho ảnh README), `-HexerAppearance light|dark` (ép giao diện qua `NSApp.appearance`; đừng dùng `-NSRequiresAquaSystemAppearance`, cờ đó làm toolbar trong suốt), `-HexerFindAllSelect n` (chọn kết quả thứ n sau Find All, mặc định 2), `-HexerDemo DIR` + `-HexerDemoFirmware HEX` (kịch bản quay video, xem bảng lệnh), `-HexerNoGlass 1` (giao diện macOS 15, không kính), `-HexerAlertSnapshot path` (chụp alert modal kế tiếp, in nút nào nhận Return/Esc, rồi huỷ alert), `-HexerQuit 1`, `-HexerFind/-HexerFindType/-HexerFindAll`, `-HexerReplace/-HexerReplaceAll`, `-HexerSave`, `-HexerUndoAll`, `-HexerChecksums`, `-HexerExpected`, `-HexerCompare/-HexerCompareSteps/-HexerCompareList`, `-HexerCopyAs`, `-HexerImport path` (nhận thêm `-HexerWindowSize`, `-HexerGoTo`, `-HexerAction`), `-HexerOpenDisk diskN` (+ `-HexerOpenDiskWritable 1`, chỉ áp dụng cho ảnh đĩa), `-HexerPrintPDF`, `-HexerSectorSize`, `-HexerWindowSize WxH`, `-HexerGoTo`, `-HexerSelect a-b`, `-HexerMode`, `-HexerEncoding`, `-HexerBytesPerRow`, `-HexerDrawer`, `-HexerHideInspector`, `-HexerSettingsPane n`.
- Có bất kỳ cờ `-Hexer…` nào thì app không hiện bảng Open hay màn hình chào lúc khởi động (`DebugLaunchArguments.isScripted`).
- Màn hình chào: `-HexerWelcome n` mở ở trang n (0–3) mà không đánh dấu đã xem; `-HexerWelcomeTour s` lật trang mỗi s giây; `-HexerWelcomeEnd skip|open|close` kết thúc như khi bấm Skip, Open a File… hay nút đóng, coi như đang ở lúc mở app (để kiểm bảng Open hiện sau đó); `-HexerSnapshot path` chụp sau `-HexerSnapshotDelay` giây (mặc định 2,5).
- Cửa sổ cập nhật: `-HexerUpdatePreview checking|upToDate|available|downloading|verifying|ready|failed|failedCheck` hiện trạng thái đó với một release mẫu (0.3.0) để chụp. `-HexerUpdateFeed URL` thay nguồn (HTTPS, hoặc `file://` mà asset cũng là `file://`); `-HexerUpdateCheck 1` kiểm ngay, `-HexerUpdateInstall 1` cài bản tìm được, `-HexerUpdateRelaunch 1` relaunch khi xong. Trạng thái được in ra dạng `HexerUpdatePhase …`. Chữ ký vẫn kiểm bằng khoá trong Info.plist, nên muốn thử trọn luồng thì dựng một bản sao app có bundle ID và khoá thử riêng (cách làm ở nhật ký phiên 7).
- Xem lại màn hình chào như lần đầu: `defaults delete com.nongdandev.hexer WelcomeShown` rồi `open build/Hexer.app`. **Xoá lại khoá này sau khi thử**, để người dùng vẫn thấy màn hình chào lần đầu.
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
                  SectorNavigator, GlassBarStyle, SettingsWindowController, Sheets/, Analysis/, Tools/,
                  Welcome/ (màn hình chào: controller + model, các trang, hình minh hoạ, nền Core Animation)
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
- **Màn hình chào lần đầu (`Views/Welcome/`):** `AppDelegate.applicationOpenUntitledFile` gọi `WelcomeWindowController.showIfFirstLaunch()` trước; nếu khoá `WelcomeShown` chưa có thì hiện màn hình chào thay bảng Open. Thiết kế ở DESIGN.md §6.9.
  - **Hiệu năng (đo bằng `ps -o time` trên 6 s):** SwiftUI trong cửa sổ này vẽ bằng CoreGraphics trên CPU (`CGDrawingLayer` / `RBInterpolatedDisplayListContents` trong `sample`), nên mỗi khung hình của một animation tốn khoảng 13 ms. Bản đầu dùng `TimelineView(.animation)` + `Canvas` cho nền và hình minh hoạ: 25–40% một nhân. Hiện tại: 0–2% (trang Edit khoảng 6%). Phiên 5 đo lại trang đầu được 7–8% trên máy này, chưa rõ vì sao (xem nhật ký phiên 5).
  - Nền byte hex là Core Animation (`WelcomeHexFieldView`): byte vẽ một lần vào mask, các layer cuộn bằng `CABasicAnimation`, dải quét và vòng lan là `CAGradientLayer` làm mask; byte loé đỏ là layer nhỏ do timer 0,3 s thêm vào. View này nằm **dưới** `NSHostingView` trong một container, không phải `NSViewRepresentable`.
  - Hình minh hoạ chạy theo `WelcomeSchedule` (chỉ cập nhật ở các mốc thay đổi) và **không** nội suy giữa các mốc. Đừng thêm `.animation`, `contentTransition` hay `symbolEffect` lặp lại trong đó.
  - Lớp phủ (veil) dùng `windowBackgroundColor`, nên `WelcomeHexFieldView` tự tô nền bằng đúng màu đó; nền cửa sổ trên macOS 26+ khác màu một chút, làm lớp phủ lộ thành mảng.
  - `blur` bán kính lớn bị vẽ sai trong đường vẽ CG; quầng sáng là `RadialGradient`.
- **Bảng Open lúc khởi động:** `AppDelegate.applicationOpenUntitledFile` gọi `openDocument(nil)` (qua `DispatchQueue.main.async`, để sự kiện khởi động xử lý xong trước). AppKit gọi hàm này cả khi mở app không kèm tệp lẫn khi bấm Dock lúc không còn cửa sổ, nên không cần `applicationShouldHandleReopen`. Đã thử: bấm Dock trong lúc bảng đang mở không sinh bảng thứ hai, kể cả sau khi bấm Cancel.
- **Tự cập nhật** (`HexerCore/Update`, `HexerPlatform/{Downloads,MountedDiskImage,CodeSignature,UpdateStaging}.swift`, `App/SoftwareUpdate.swift`, `Views/SoftwareUpdateView.swift`; giao diện ở DESIGN.md §6.10):
  - **Nguồn (từ 0.4.0):** manifest `update.json` (`HexerCore/Update/UpdateManifest.swift`: `format` 1, mỗi release có `version`, `prerelease`, `page`, `notes`, `size`, `sha256`, `signature` Base64 và `urls` là các nơi tải DMG theo thứ tự ưu tiên; giữ 10 bản mới nhất). App thử lần lượt các địa chỉ trong `HexerUpdateFeedURLs` của Info.plist (máy chủ cập nhật trên Cloudflare R2, rồi bản chép trên GitHub Release `releases/latest/download/update.json`), lấy danh sách của nguồn đầu tiên đọc được; tải DMG thì thử từng `urls` cho tới khi được. Session ephemeral, User-Agent `Hexer/<version>`. Chỉ nhận release có phiên bản hợp lệ, có chữ ký và ít nhất một URL HTTPS. Manifest không cần đáng tin: chữ ký kiểm bằng khoá trong app, nên máy chủ chỉ có thể giấu bản mới, không thể tráo. **Bản 0.3.x** vẫn đọc API GitHub `GET /repos/letrucdev/hexer/releases` và cần `.dmg` + `.sig` trên trang release, nên workflow vẫn đăng cả hai lên GitHub; 0.3.x tìm thấy 0.4.0 qua đó rồi từ 0.4.0 đọc manifest. Pre-release chỉ tính khi bật "Include beta versions" hoặc khi đang chạy một bản beta.
  - **Lịch:** 5 s sau khi mở rồi mỗi giờ, tối đa một lần mỗi ngày; lần mở đầu tiên không kiểm (khoá `UpdateChecksSince`). Chạy có cờ `-Hexer…` thì không kiểm, trừ khi có `-HexerUpdateFeed`. Kiểm tự động chỉ lên tiếng khi có bản mới; lỗi mạng hay 403/429 ("máy chủ cập nhật đã nhận quá nhiều yêu cầu") thì im lặng. Khoá UserDefaults: `CheckForUpdatesAutomatically`, `UpdateIncludesBetas`, `LastUpdateCheck`, `SkippedUpdateVersion`, `UpdateStagingFolder`.
  - **Xác thực, theo thứ tự:** chữ ký Ed25519 trên thông điệp `hexer-update-v1\n<version>\n<sha256 hex của DMG>\n` (gắn cả phiên bản, nên không dùng lại được chữ ký của bản khác); gắn DMG chỉ đọc (`hdiutil attach -nobrowse -noverify -mountrandom`); `Hexer.app` bên trong phải đúng bundle ID, đúng phiên bản của release, `LSMinimumSystemVersion` ≤ macOS đang chạy; code signature nguyên vẹn (`SecStaticCodeCheckValidity`, strict, mọi kiến trúc, nested code). App đang ký ad hoc nên chỉ yêu cầu `identifier "com.nongdandev.hexer"`; khi có Developer ID (Team ID), tự chuyển sang yêu cầu designated requirement của bản đang chạy (cùng nhà phát triển). Sau khi chép bằng `ditto` thì kiểm code signature lần nữa.
  - **Cài:** bản mới chờ trong thư mục tạm `itemReplacementDirectory` trên cùng volume với app. Khi app thoát (`applicationWillTerminate`), `renamex_np(RENAME_SWAP)` đổi chỗ hai bundle trong một bước nguyên tử, rồi xoá bản cũ; tên app người dùng đặt được giữ nguyên. Relaunch = `NSApp.terminate` (vẫn hỏi lưu tài liệu như khi thoát), sau khi đổi chỗ thì một `/bin/sh` nhỏ đợi tiến trình cũ kết thúc rồi `open` bản mới.
  - **Không tự thay được** khi app bị App Translocation (chạy thẳng từ chỗ tải về, chưa chuyển vào Applications) hoặc thiếu quyền ghi bundle hay thư mục chứa nó: cửa sổ báo lý do và nút chính thành Download… (mở trang release).
  - **Chưa xử lý:** nếu bấm Relaunch rồi huỷ ở hộp thoại lưu tài liệu, cờ relaunch vẫn còn, nên lần thoát sau Hexer sẽ tự mở lại (bản cập nhật vẫn được cài như "Install on Quit").
  - macOS 26 báo `hdiutil attach`/`create` là deprecated (thay bằng `diskutil image`, không có trên macOS 15); vẫn chạy, cảnh báo bị lọc khỏi thông báo lỗi.
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
| Cập nhật | Hexer ▸ Check for Updates…, kiểm tra tự động mỗi ngày (tắt được, có tuỳ chọn bản beta), bỏ qua một phiên bản, tải có tiến độ, kiểm chữ ký Ed25519 và code signature, cài khi thoát hoặc Relaunch |
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
11. **Tự cập nhật, phần còn lại:**
    - Chưa thử trên máy ảo macOS 15 (ở macOS 27 đã thử trọn luồng, xem nhật ký phiên 7). Nên thử `-HexerUpdateCheck 1 -HexerUpdateInstall 1 -HexerUpdateRelaunch 1` với bản sao app như phiên 7.
    - Chưa thử cài thật 0.3.2 → 0.4.0 (qua GitHub API) hay 0.4.0 → bản sau (qua manifest trên R2); mới kiểm tới bước "0.4.0 is available" với manifest thật (nhật ký phiên 9).
    - Chưa có cập nhật cho người dùng không phải admin khi app nằm trong /Applications của admin: hiện chỉ báo lý do và mở trang tải về (Sparkle thì xin mật khẩu admin).
    - Cờ relaunch còn sót khi huỷ hộp thoại lưu (§3, "Tự cập nhật").
    - Không có bản cập nhật delta; mỗi lần tải cả DMG (khoảng 7 MB).
12. **Hiệu năng:** chạy `hexer-cli bench` và mở tệp thưa 6 GB (`mkfile -n 6g`) sau các thay đổi lớn ở Storage hoặc HexGrid. Đã kiểm lại sau khi thêm gập vùng (2026-10-24): tệp 6 GB mở và nhảy tới cuối bình thường.

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
  - **GitHub Actions** (theo yêu cầu của người dùng): `ci.yml` và `release.yml` (xem §2 "CI và phát hành").
    - Trước khi push, đã chạy lại các bước của CI trong một bản sao sạch của repo: test, crosscheck, bundle và DMG đều đạt.
    - Người dùng đã chuyển repo sang **public**, nên đọc được trạng thái Actions qua API công khai. Log chi tiết vẫn phải đăng nhập mới xem được.
    - Lần chạy CI đầu lỗi ở `DiskEnumeratorTests`: ổ khởi động của runner (máy ảo) không có `busProtocol`; máy ảo UTM cũng vậy. Test giờ chấp nhận ổ chỉ có model hoặc tên media. Sau đó CI xanh trên `xcode-27`.
    - **Release đầu tiên `v0.1`:** https://github.com/letrucdev/hexer/releases/tag/v0.1, gồm `Hexer-0.1.dmg` (6,5 MB, universal, build 9) và `Hexer-0.1.dmg.sha256`. Đã tải về kiểm: checksum khớp, chữ ký hợp lệ, `minos 15.0`.
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
- **Phiên 4 (2026-10-24):**
  - **Hiện bảng Open ngay khi mở app** (theo yêu cầu của người dùng). Trước đây `applicationShouldOpenUntitledFile` trả `false`, nên app mở lên không có cửa sổ nào, phải bấm Dock mới hiện bảng Open.
    - Giờ mở app không kèm tệp thì bảng Open hiện ngay, app đứng trước. Bấm Dock lúc không còn cửa sổ vẫn hiện bảng như cũ (xem §3 "Các quyết định chính").
    - Mở kèm tệp (`open -a Hexer file`) hoặc chạy có cờ `-Hexer…` thì không hiện bảng. Khi macOS khôi phục cửa sổ cũ, AppKit cũng không gọi tới bảng này (chưa thử trực tiếp).
    - Kiểm: mở `build/Hexer.app` qua `open` (bảng "Open" hiện, Hexer là app đứng trước); mở kèm tệp; chạy `-HexerSnapshot` và `-HexerImport`. Kịch bản bấm Dock (lúc đang mở bảng, và sau khi Cancel) được thử trên một app mẫu cùng logic, có tự bấm Cancel, vì Terminal không có quyền Accessibility để gửi phím.
    - Canvas không đổi, vì bảng Open là bảng của hệ thống. DESIGN.md §4 có thêm dòng mô tả lúc mở app.
  - **CI của commit `1eab47a` lỗi ở `AttachedImageTests.readWriteAndCloneOnARawDevice`:** `openFailed(path: "/dev/rdisk7", code: 13)`, tức EACCES. Lỗi xảy ra ngay sau khi `isOurWritableImage()` đã thấy node ghi được (`access` R/W = 0). Commit này chỉ sửa app; test đó đã đạt hai lần trên runner ở `c5e8d9c` (CI và Release).
    - Không tái hiện được trên máy này: 40 vòng gắn/gỡ nhanh (luôn dùng lại `rdisk4`) và 8 lần chạy suite đều đạt; quyền node là uid 501, 0640 ngay từ lúc gắn. Chưa rõ nguyên nhân trên runner. Log đầy đủ cần đăng nhập, annotation không có thêm thông tin.
    - Test giờ mở thiết bị qua `AttachedImage.openRaw(writable:)` (`TestSupport.swift`): EACCES/EPERM được thử lại trong 5 s, mở được sau khi thử lại thì in `AttachedImage: … opened after N permission retries`. Lỗi kéo dài thì báo uid/gid/mode của node, uid của test và uid của console. **Nếu lỗi lặp lại, đọc các số đó trong annotation trước khi đoán tiếp.** Code sản phẩm không đổi, vì app gặp EACCES thì đã hỏi quyền qua `authopen`.
    - Đã thử cả hai nhánh bằng test tạm (`chmod 000` lên node của chính mình): khôi phục quyền sau 1 s thì mở được sau 10 lần thử; để nguyên thì báo `node: uid 501, gid 20, mode 0`.
  - **Release `v0.1.1`** (theo yêu cầu của người dùng): tag annotated "Hexer 0.1.1" trên `138b70a` (CI đạt), đã push và workflow Release đã chạy. Quy tắc đặt tên tag và cách phát hành đã được thêm vào CLAUDE.md (mục "Phát hành"); ví dụ trong §2 và trong chú thích của `release.yml` đã sửa cho khớp.
    - Kết quả: https://github.com/letrucdev/hexer/releases/tag/v0.1.1, gồm `Hexer-0.1.1.dmg` (6,5 MB) và `Hexer-0.1.1.dmg.sha256`. Workflow mất khoảng 6 phút (test 3 phút, release 2 phút). Đã tải về kiểm: checksum khớp, chữ ký hợp lệ, `CFBundleShortVersionString` 0.1.1, build 12, universal (x86_64 + arm64), `minos 15.0`.
    - Script theo dõi workflow đầu tiên bị lỗi cú pháp Python (`\"` trong phần `{…}` của f-string, viết ngay trong `python3 -c '…'`), nên lặp im lặng đến hết giờ. Khi theo dõi Actions, để phần Python trong một tệp riêng, chạy thử một lần ở foreground, và cho script dừng khi lỗi liên tiếp.
  - **Ghi chú release có phần thay đổi** (theo yêu cầu của người dùng): thêm `CHANGELOG.md` (mục 0.1.1 và 0.1, tiếng Anh + tiếng Việt), `Scripts/release_notes.sh`, chỗ `@CHANGES@` trong `Distribution/release-notes.md`, và job `notes` trong `release.yml`. Quy tắc nằm trong CLAUDE.md (mục "Phát hành").
    - Đã thử script: có mục, bản đầu tiên (không có link so sánh), thiếu mục (dừng, exit 1, thông báo `error:` nên `ci_run.sh` đưa ra annotation), và `0.1` không khớp nhầm `0.1.1`. YAML đọc được bằng Ruby; workflow mới **chưa chạy thật** (chỉ chạy khi có tag mới).
    - Release `v0.1.1` đã đăng trước thay đổi này nên chưa có phần thay đổi. Sửa trên GitHub cần đăng nhập (máy này không có `gh`).
  - **Màn hình chào lần đầu** (theo yêu cầu của người dùng: giới thiệu app, animation bắt mắt, chuyển cảnh mượt, chỉ hiện lần đầu). Mô tả ở DESIGN.md §6.9 và board `Welcome.dc.html` trên canvas (version 20). Có thêm mục Help ▸ Welcome to Hexer để xem lại.
    - Lời giới thiệu viết theo nguyên tắc của skill `design:ux-copy` (mỗi trang một ý, nút bắt đầu bằng động từ và khớp kết quả: nút cuối là "Open a File…" vì nó mở bảng Open). Thêm 18 chuỗi tiếng Việt.
    - Kiểm bằng ảnh chụp cửa sổ: 4 trang ở sáng, tối và tiếng Việt; chuỗi khung hình lúc đổi trang (vòng lan, trang trượt, phần tử nổi lần lượt).
    - Kiểm luồng:
      - `open build/Hexer.app` khi chưa có khoá thì hiện màn hình chào (app đứng trước) và đặt khoá; lần mở sau hiện bảng Open.
      - `-HexerWelcomeEnd skip|open|close` lúc mở app đều dẫn tới bảng Open.
      - ← → Return Esc thử bằng sự kiện phím gửi vào chính app (đoạn mã thử tạm, đã gỡ): ← → lật trang, Return đi tiếp rồi mở bảng Open ở trang cuối, Esc đóng.
    - Đã xoá lại khoá `WelcomeShown` sau khi thử.
    - Reduce Motion không kiểm trên máy này vì phải đổi cài đặt hệ thống của người dùng; đã kiểm trên máy ảo ở phiên 5 và tìm ra một lỗi crash.
    - Hiệu năng: xem §3 "Màn hình chào lần đầu". Bản đầu tốn 25–40% CPU; sau khi chuyển nền sang Core Animation và bỏ nội suy ở hình minh hoạ còn 0–6%.
- **Phiên 5 (2026-10-24):**
  - **Cài MCP `utm`** (theo yêu cầu của người dùng; https://github.com/neverprepared/mcp-utm, commit `5f6bab5`, chỉ gọi `osascript` tới UTM và `arp -a`).
    - Cài vào venv `~/.local/share/mcp-utm` từ mã nguồn GitHub đã đọc qua, không lấy từ PyPI. Máy không có `uv`.
    - Phải ghim `mcp<2` (hiện là 1.30.0): package chỉ ghi `mcp>=1.9`, mà mcp 2.x đã bỏ `mcp.server.fastmcp`, nên server dừng ngay lúc khởi động.
    - Đăng ký bằng `claude mcp add utm -- ~/.local/share/mcp-utm/bin/mcp-utm`, scope local (chỉ cho project này). Tools có từ phiên Claude Code mới; trong phiên này phải gọi server qua stdio bằng một script Python tạm.
  - **Kiểm màn hình chào trên máy ảo macOS 15.0** (theo yêu cầu của người dùng). Máy ảo `macOS_15` được bật bằng MCP, IP `192.168.64.2`.
    - Chụp 4 trang ở giao diện sáng, tối và tiếng Việt: bố cục khớp với macOS 27, không có chữ bị cắt. Chuyển trang (vòng lan, trượt, blur, phần tử nổi lần lượt) chạy đúng.
    - **Luồng lúc mở app:**
      - Chưa có khoá `WelcomeShown` thì hiện màn hình chào và đặt khoá; lần mở sau hiện thẳng bảng Open.
      - Skip, nút đóng, Esc ở trang cuối và Open a File… đều dẫn tới bảng Open.
    - **Luồng từ Help ▸ Welcome to Hexer:** Skip và nút đóng không mở bảng Open; Open a File… thì mở. Chọn menu hai lần vẫn chỉ có một cửa sổ.
    - **Điều khiển:** ← → lật trang, Return đi tiếp; chấm trang, Back và Continue hoạt động; cây Accessibility có nhãn "Page n of 4".
    - **Lỗi crash khi bật Reduce Motion (đã sửa):**
      - App crash (`EXC_BREAKPOINT` trong `dispatch_assert_queue`) ngay lần đổi trang đầu tiên, 3/3 lần.
      - Nguyên nhân: SwiftUI animate trên luồng render (`renderFromAsyncDisplayLink`) và resolve màu `NSColor.dynamic(light:dark:)`. Provider của màu đó mặc định là MainActor, nên runtime kiểm executor và trap.
      - Sửa: thêm `nonisolated` vào `NSColor.dynamic` (`HexTheme.swift`). Lỗi có từ commit đầu, nên có thể xảy ra ở bất cứ chỗ nào SwiftUI resolve màu `HexTheme` ngoài main thread, không riêng màn hình chào.
      - Sau khi sửa: 3 lần lật hết 4 trang rồi lùi lại, không crash. Với Reduce Motion, trang cross-fade và hình minh hoạ hiện ngay trạng thái cuối.
    - **CPU** (`ps -o time`, đo 6 s sau khi trang ổn định):
      - Máy ảo, trang 1–4: 7,3%, 5,3%, 1,8%, 0,7%.
      - Máy này: trang 1 là 6,7–8% (đo 12 s cho kết quả 8%), trang 2 là 6,8%.
      - Trang đầu cao hơn con số 0–2% ghi ở §3. Chưa tìm nguyên nhân; có thể là hàng giải mã "Hexer" chạy lại (1,2 s ở 20 Hz, mỗi 10 s) cộng với timer loé byte.
    - **Cách điều khiển máy ảo:** lúc đầu dùng các công cụ tạm, sau đó gộp vào `Scripts/vm_test.sh` (theo yêu cầu của người dùng): `start`, `capture`, `burst`, `keys`, `press`, `menu`, `close`, `ax`, và `shot` giờ cắt ảnh theo cửa sổ Hexer.
      - Trong máy ảo không có quyền Screen Recording, nên `-HexerSnapshot` báo lỗi. Vì vậy script chụp cửa sổ UTM rồi cắt theo khung cửa sổ Hexer (`vm_agent frame`, đọc qua Accessibility nên bắt được cả bảng Open).
      - Màn hình máy ảo là 1512×908 pt (`vm_agent screen`). Cửa sổ UTM có lúc đổi cỡ, nên tỉ lệ tính từ kích thước ảnh chụp, giả định màn hình máy ảo phủ hết chiều ngang cửa sổ UTM.
      - Phím gửi bằng `CGEvent.postToPid`. Nút, menu và cây Accessibility đi qua AX API. Quyền Accessibility của phiên SSH là của `/usr/libexec/sshd-keygen-wrapper` (đã kiểm trong TCC.db của máy ảo).
      - Đã thử từng lệnh trên máy ảo: `start`, `deploy`, `selftest`, `shot`, `capture` (cả bảng Open), `burst`, `keys` (cả `cmd+.` đóng bảng Open), `press`, `menu`, `close`, `ax`.
      - Dễ vấp khi viết script: `screencapture` không ghi được vào tên tệp bắt đầu bằng dấu chấm. `/bin/sh` (bash 3.2) hiểu dấu `'` trong `"${x:+…}"` là mở chuỗi.
    - Đã trả máy ảo về như cũ: xoá `com.apple.universalaccess reduceMotion` và `WelcomeShown` (cả hai đều chưa có từ trước). Máy ảo vẫn đang chạy.
  - Kiểm: `Scripts/test.sh` 166 test đạt, `Scripts/crosscheck.sh` 281/281, `Scripts/bundle.sh` không có warning. Canvas và DESIGN.md không đổi, vì giao diện không đổi.
  - **Commit và push** (theo yêu cầu của người dùng), gồm 4 commit trên `main`: `4a1fb12` màn hình chào (phần làm từ phiên 4, lúc đó chưa commit; HANDOFF.md của commit này chỉ có ghi chú về màn hình chào), `55d233e` sửa crash, `5d1dd69` công cụ máy ảo kèm nhật ký phiên này, `7d26647` CHANGELOG 0.2.0.
  - **Release `v0.2.0`** (theo yêu cầu của người dùng: "tạo releases mới nếu cần"). Bản này có tính năng mới, nên tăng số giữa.
    - Mục `## 0.2.0` trong CHANGELOG.md chỉ ghi màn hình chào. Bản sửa crash không được ghi: crash chỉ gặp ở màn hình chào, vốn mới có trong bản này, nên người dùng 0.1.1 không thấy gì khác.
    - CI của `5d1dd69` đạt (run 40090906595), rồi mới đặt tag annotated "Hexer 0.2.0" trên `7d26647`.
    - Workflow Release đạt ở cả ba job notes, test, release (run 40091189598). Đây là lần đầu job `notes` chạy thật.
    - Kết quả: https://github.com/letrucdev/hexer/releases/tag/v0.2.0, gồm `Hexer-0.2.0.dmg` (6,8 MB) và `Hexer-0.2.0.dmg.sha256`. Đã tải DMG về kiểm, SHA-256 khớp.
    - Ghi chú release mở đầu bằng phần thay đổi (tiếng Anh và tiếng Việt), có link so sánh với v0.1.1 và dòng SHA-256.
- **Phiên 6 (2026-10-24):**
  - **Video giới thiệu mới, có nhạc nền** (theo yêu cầu của người dùng: có con trỏ, có thao tác, animation bắt mắt, chuyển cảnh mượt, nhạc hợp nội dung). Không có skill render video nào, nên nâng cấp pipeline sẵn có thay vì thêm Remotion hay ffmpeg.
    - **Kịch bản quay** (`App/DemoScript.swift`): 8 chương, mỗi chương ghi `caption` kèm `id`, rồi dừng 0,7 s cho phần chuyển cảnh. Thêm 2 chương:
      - "Read machine code": mở popover kiểu dữ liệu, chọn Hex, tìm `FD 7B BF A9`, bấm vào byte tìm được, cuộn Data Inspector xuống phần Disassembly (ARM64 hiện `stp x29, x30, [sp, #-0x10]!`).
      - "See the shape of your data": mở cửa sổ Statistics giữa cửa sổ chính, quét con trỏ qua biểu đồ (cập nhật `hovered`), chọn cột cao nhất rồi bấm nút đóng. Khung cửa sổ đã lưu (`NSWindow Frame HexerStatisticsWindow`) được trả lại sau đó.
      - Byte order gộp vào chương đầu. Badge phím có thêm kiểu (`shortcut`, `typing`, `menu`).
    - **Thay đổi trong code app (chỉ phục vụ demo, giao diện không đổi):** thêm `demoAnchor` "Find type", "Find field", "Find data type" (FindBar) và "Statistics plot" (một `Color.clear` không nhận click, đặt trên vùng vẽ của biểu đồ). `StatisticsWindowController.model` bỏ `private`. Anchor ở cửa sổ khác (popover, Statistics) được đổi toạ độ qua `NSHostingView` của cửa sổ đó.
    - **Compositor** (`Scripts/make_promo.swift`, viết lại):
      - Mỗi chương dài số nguyên beat (120 BPM). Bản quay trong chương được tua nhanh hoặc chậm vài phần trăm cho khớp; chương cuối giữ khung cuối đến hết ô nhịp.
      - Mấy khung cuối của bản quay trống vì app thoát ngay sau `end`, nên chương cuối dừng ở `end - 0.05`.
      - Camera là lò xo theo các sự kiện `focus` (zoom nhân 1,25 vì cửa sổ chiếm nhiều khung hơn). Khi zoom, cửa sổ luôn phủ kín khung bên dưới caption đã thu gọn.
      - Chỉ báo chia sẻ trên cửa sổ Statistics có animation mở/đóng, nên mỗi khung được dò tìm màu (117, 117, 223), tức xanh có R≈G, khác chữ offset xanh của app. Chỉ dò khi cửa sổ đang mở, rồi phủ màu thanh tiêu đề và đèn giao thông lấy từ ảnh sạch.
    - **Nhạc** (`Scripts/make_music.py`): Am7 Fmaj7 G ở phần mở đầu, rồi vòng Fmaj7 G Em7 Am7, kết ở Cmaj9. Riser và drop khi cửa sổ hạ cánh (6,0 s), whoosh trước mỗi chương, breakdown 2 ô nhịp ở giữa, tiếng click, gõ phím và menu khớp thời điểm trong bản quay.
      - Không nghe được nên kiểm bằng số đo. Bản đầu nặng sub (20–60 Hz chiếm −2,8 dB, trên 6 kHz chỉ −28,8 dB), đã cân lại còn −6,9 / −4,6 / −4,2 / −13,5 / −17,2 dB (các dải 20–60, 60–250, 250–2k, 2–6k, 6–20k Hz).
      - Độ lớn: intro −17,7 dB RMS, groove −14,2, breakdown −16,4; đỉnh −1 dBFS.
    - Kiểm bằng khung hình trích từ video: mở đầu, lúc cửa sổ trồi lên và hạ cánh, từng chuyển chương, popover, Disassembly, Statistics (vá đèn đúng cả trong lúc animation), firmware, sáng/tối, lưới tính năng, kết thúc. Bản tiếng Việt hiển thị dấu đúng, caption và ô tính năng vừa khung.
    - Kiểm: `Scripts/test.sh` 166 test đạt, `Scripts/crosscheck.sh` 281/281, `Scripts/bundle.sh` không có warning mới. Canvas và DESIGN.md không đổi, vì giao diện không đổi.
    - **Chưa làm:** người dùng chưa nghe nhạc thật. Nếu muốn đổi tempo, hợp âm hay độ dài, sửa `make_music.py` rồi chạy lại `make_promo.swift` (không cần quay lại).
  - **Sửa theo góp ý của người dùng** ("zoom chưa mượt", "thao tác quá nhanh", "nhạc to, tiết tấu nhanh", muốn nhạc êm như video giới thiệu sản phẩm của Apple):
    - **Zoom:** bỏ camera lò xo. Mỗi sự kiện `focus` thành một lần trượt smootherstep (vào 1,6 s, ra 1,5 s). Zoom nội suy theo log và quanh điểm đứng yên trên màn hình. Vị trí được kẹp ở hai đầu, không kẹp từng khung, nên không còn giật khi cửa sổ chạm mép. Đã kiểm bằng quỹ đạo từng khung: mép cửa sổ không đổi hướng giữa chừng, gia tốc không nhảy.
    - **Thao tác chậm lại** (bản quay 57 → 102 s, video 74 → 120 s):
      - `chapter` dừng 1,4 s; `focus` giờ là async và chờ camera xong mới thao tác tiếp.
      - Con trỏ đi 0,6–1,3 s, dừng một nhịp rồi mới click. Gõ hex 0,22 s mỗi ký tự. Các pause sau kết quả dài hơn khoảng 1,5 lần.
      - Trong compositor, con trỏ đi theo cung nhẹ, trừ khi quét biểu đồ (`straight`). Lắc 3D khi đổi chương nhẹ hơn (6°) và chậm hơn. Caption giữ mở 3 s rồi mới thu gọn.
    - **Nhạc mới** (`make_music.py` viết lại), 80 BPM, D trưởng: Gmaj9 A6/9 ở phần mở đầu, rồi Dmaj9 Bm9 (hoặc F#m7) Gmaj9 A6/9, kết Dmaj9.
      - Nhạc cụ: electric piano FM rải hợp âm, pad saw lọc ấm, mallet có echo ping-pong, bass sine, beat half-time rất nhẹ (kick, snap, shaker). Hall 3,6 s.
      - Mỗi chương có "swell" (echo đảo ngược) và một tiếng chuông. Có đoạn nghỉ 2 ô nhịp ở giữa.
      - Đo được: chương −20,2 dB RMS (trước −14,2), đỉnh −7 dBFS. Phổ ấm: 250–2k là −1,3 dB, 2–6k là −19,5 dB, trên 6k là −26,2 dB. Âm lượng chỉnh bằng `TARGET_RMS_DB`.
    - **Lỗi gặp khi quay lại:**
      - Hai click "Byte order" không được ghi: anchor được đo trước khi bật `isRecording`, và lúc ghi hay không tuỳ thời điểm. `DemoAnchors.isRecording` giờ bật ngay từ khi app khởi động với `-HexerDemo`.
      - Một lần `record_demo` quay nhầm một cửa sổ phụ 502×314 của Hexer. Trước đây chọn đúng chỉ nhờ thứ tự liệt kê. Giờ script chọn cửa sổ lớn nhất và in danh sách cửa sổ.
    - Kiểm: test 166 đạt, crosscheck 281/281, bundle đạt. Đã render lại cả hai bản (EN, VI). Người dùng vẫn chưa nghe bản nhạc mới.
  - **Commit và push** lên `main` (theo yêu cầu của người dùng), một commit gồm công cụ video, kịch bản demo và HANDOFF. Video không commit (`build/` bị `.gitignore`).
- **Phiên 7 (2026-10-25):**
  - **Tự cập nhật** (theo yêu cầu của người dùng: "tôi muốn tính năng auto update"). Người dùng chọn ký bản cập nhật bằng Ed25519 (thay vì chỉ dựa vào HTTPS + SHA-256), chấp nhận thêm một secret trên GitHub.
    - Tự viết thay vì dùng Sparkle: không có Xcode, Sparkle cần nhúng framework và các XPC service rồi ký lại, chưa chắc chạy với app ký ad hoc, và không có tiếng Việt. CryptoKit đã có sẵn Ed25519.
    - **Core** (`HexerCore/Update`): `AppVersion` (thứ tự SemVer, "0.1" = 0.1.0), `UpdateFeed` (đọc JSON release của GitHub, chọn bản mới nhất), `ReleaseNotes` (mục "What's new"/"Có gì mới" theo ngôn ngữ), `UpdateSignature` (Ed25519), `AppBundleInstaller` (kiểm Info.plist, kiểm quyền, `RENAME_SWAP`), `UpdateError`. 16 test, có một vector ký bằng OpenSSL 4.
    - **Platform:** `Downloads` (session ephemeral, có tiến độ, giới hạn kích thước), `MountedDiskImage` (hdiutil), `CodeSignature` (Security framework), `UpdateStaging` (ghép các bước kiểm rồi chép app ra). 6 test, có test dựng DMG chứa app ký ad hoc rồi cài thật: chữ ký sai phiên bản hoặc sai khoá, app bị sửa sau khi ký, sai bundle ID, sai phiên bản.
    - **App:** `SoftwareUpdate` (lịch kiểm, trạng thái, cài khi thoát, relaunch), cửa sổ Software Update, phần Software Update trong Settings ▸ General, menu Hexer ▸ Check for Updates…, lỗi tiếng Việt trong `ErrorMessages.swift`, 46 chuỗi mới trong `vi.py`, cờ `-HexerUpdate…`.
    - **CLI và phát hành:** `hexer-cli update keygen|public-key|sign|verify`; `Scripts/sign_update.sh`; `release.yml` kiểm secret ở job `notes`, ký DMG sau `make_dmg.sh` và đính kèm `.sig`. Crosscheck thêm 6 check so chữ ký hai chiều với OpenSSL (bỏ qua nếu `openssl` không có Ed25519, như LibreSSL 3.3 của macOS).
    - **Khoá thật:** tạo bằng `hexer-cli update keygen` vào tệp tạm 0600, đưa vào Keychain bằng `security add-generic-password`, xoá tệp bằng `rm -P`; khoá bí mật không in ra màn hình. Đã kiểm khoá trong Keychain sinh đúng khoá công khai trong Info.plist; `sign_update.sh` với khoá thật ký và kiểm được DMG 0.1 universal (đã xoá `.sig` thử), với khoá sai hoặc không có khoá thì dừng với thông báo `error:`.
    - **Thử trọn luồng trên máy này:** bản sao app có bundle ID `com.nongdandev.hexer.e2e` (để không đụng cài đặt thật), phiên bản 0.2.9, khoá thử riêng; DMG 0.3.0 ký bằng khoá thử; feed `file://`. Kết quả: kiểm → tải → xác minh → sẵn sàng → relaunch: bundle đổi thành 0.3.0, code signature hợp lệ, tiến trình mới chạy từ cùng đường dẫn, thư mục tạm đã xoá. Install on Quit: đổi thành 0.3.0 khi thoát, không mở lại. Chữ ký làm cho 0.3.1: báo lỗi, app giữ 0.2.9. Thư mục không ghi được: hiện cảnh báo và nút Download…. Lần mở đầu không kiểm; sau một ngày (`UpdateChecksSince` lùi về trước) thì tự kiểm và hiện cửa sổ. Feed GitHub thật: "up to date", vì các release cũ chưa có `.sig`. Đã xoá domain `com.nongdandev.hexer.e2e` và các bản sao.
    - **Lỗi tìm thấy khi chụp và đã sửa:** nút "Open Download Page" bị cắt chữ khi có ba nút (đổi thành "Download…"); thông báo không có quyền ghi hiện cả đường dẫn dài (giờ chỉ tên thư mục, theo `displayName`); khung What's New thừa chỗ trống khi chỉ có một dòng; lần mở đầu ghi "Last checked" dù chưa kiểm (tách khoá `UpdateChecksSince`).
    - Gắn DMG không kiểm checksum (`-noverify`, 2,3 s → 0,18 s), vì chữ ký Ed25519 đã phủ toàn bộ tệp.
    - **CI treo ở bước Unit tests** (commit `433d847` và `28f901d`, hơn 14 phút so với 3 phút bình thường; không có log vì `test.sh` chỉ in khi xong). Nghi `MountedDiskImage` đọc stdout và stderr của `hdiutil attach` tới EOF: `hdiutil` sinh `diskimages-helper -uuid … -post-exec 4`, sống tới khi gỡ ảnh đĩa; nếu nó giữ pipe thì EOF không bao giờ tới. Trên máy này helper chuyển 0/1/2 sang `/dev/null` (xem bằng `lsof`) nên không treo; trên runner chưa chứng minh được. Đã loại giả thuyết TCC: app mở qua LaunchServices đọc DMG không bị hỏi quyền "ổ tháo rời".
      - Sửa: `HexerPlatform/Subprocess.swift` chờ tiến trình thoát (không chờ EOF), dừng nó sau 120 s; `MountedDiskImage` và `ditto` trong `UpdateStaging` dùng nó, các test mới cũng vậy. 5 test, có test tái hiện tiến trình con giữ pipe (`(sleep 30 &)`).
      - CI của `02e2e64`: hết treo (mọi test DMG đạt), nhưng test giữ pipe mất 13,4 s trên runner (1,2 s ở máy này, kể cả khi CPU bị dồn tải). Bản đầu đọc bằng `readabilityHandler` + `availableData`, mà `availableData` chặn khi pipe trống, và gỡ handler thì phải đợi handler đang chạy. Giờ đọc bằng `DispatchSourceRead` trên fd `O_NONBLOCK`, không có lệnh nào chặn.
      - `test.sh` có giới hạn thời gian và báo cáo khi treo (xem §2). Đã thử với `TEST_TIMEOUT=6`: liệt kê `hdiutil create`, hai `diskimages-helper`, và stack dừng ở `Subprocess.run` ← `MountedDiskImage.hdiutil` ← `UpdateStaging.stage`. Ảnh đĩa của test bị dừng giữa chừng vẫn còn gắn (`hdiutil info`); gỡ bằng `hdiutil detach`.
    - Chụp kiểm: mọi trạng thái của cửa sổ ở tối, sáng và tiếng Việt; Settings ▸ General ở tối (tiếng Anh) và sáng (tiếng Việt). Cửa sổ rộng cố định 520 pt nên không có trường hợp cửa sổ hẹp. Trong ảnh chụp, cửa sổ không phải cửa sổ chính (app chạy từ terminal), nên nút mặc định chưa tô xanh.
    - Canvas version 22: board mới `Update.dc.html`, thêm phần Software Update vào `Settings.dc.html`, thêm Check for Updates… vào `MenusVI.dc.html`. DESIGN.md: §1, §6.6, §6.8, §6.10 mới, §7. README: thêm dòng "Updates itself". CLAUDE.md (mục Phát hành): secret, không đổi khoá công khai, kiểm thêm `.sig` trên trang release.
    - **Sửa phiên bản của bản build trên máy** (người dùng báo: "phiên bản ở trong app đang không đúng với phiên bản trên github releases"). `bundle.sh` trước đây giữ `0.1` của `Resources/Info.plist`, nên About và cửa sổ cập nhật ghi 0.1 dù code đã sau 0.2.0; trình cập nhật còn báo "0.1 là bản mới nhất" vì bỏ qua 0.2.0 (chưa có `.sig`). Giờ `bundle.sh` lấy `$VERSION`, nếu không có thì lấy tag gần nhất: bản build ở máy ghi 0.2.0, kiểm với GitHub thật báo "Phiên bản 0.2.0 là bản mới nhất hiện có". Đã thử `VERSION=9.9.9 Scripts/bundle.sh` (ra 9.9.9).
  - **Release `v0.3.0`** (theo yêu cầu của người dùng): CI của `60504fa` đạt, tag annotated "Hexer 0.3.0", workflow Release đạt (job `notes` đã thấy secret). https://github.com/letrucdev/hexer/releases/tag/v0.3.0 có `Hexer-0.3.0.dmg` (7,2 MB), `.sha256`, `.sig`. Đã tải về kiểm: SHA-256 khớp, chữ ký Ed25519 hợp lệ với khoá trong Info.plist, app 0.3.0 build 25, universal, `minos 15.0`, code signature hợp lệ. Ghi chú release có phần thay đổi tiếng Anh/tiếng Việt và link so sánh với v0.2.0.
    - Chưa thử tự cập nhật thật từ GitHub (người dùng bảo tạm dừng). Cách thử: chép `build/Hexer.app` (bản build ở máy ghi phiên bản theo tag gần nhất) ra thư mục khác, sửa `CFBundleShortVersionString` thành bản cũ hơn bản trên GitHub, ký lại ad hoc, chạy `-HexerUpdateCheck 1 -HexerUpdateInstall 1 -HexerUpdateRelaunch 1`. Nhánh lỗi 403 (hết hạn mức API) đã thử với GitHub thật: hiện đúng thông báo tiếng Việt.
  - **Icon** (người dùng báo: "app của tôi bị mất icon", và muốn DMG có icon):
    - App không mất icon: `build/Hexer.app`, `/Applications/Hexer.app` và app trong DMG 0.3.0 đều có `AppIcon.icns`, và `NSWorkspace` trả về đúng icon. Nhưng Launch Services giữ nhiều bản ghi `com.nongdandev.hexer` ở đường dẫn đã xoá: chỗ gắn DMG khi kiểm release, `build/dmg/Hexer.app` của `make_dmg.sh`, `/Volumes/Hexer 0.1`, thư mục tạm của bản cập nhật. Chỉ cần gắn DMG (kể cả `-nobrowse`) hay chép app là có bản ghi. Khi macOS chọn trúng một bản ghi như vậy (Dock, Spotlight, Open With), icon hiện trống. Đã gỡ các bản ghi cũ trên máy này (`lsregister -u`) và đăng ký lại hai bản thật (`lsregister -f`).
    - Sửa: `HexerPlatform/LaunchServicesRecords.forget` (chạy `lsregister -u`). `UpdateStaging` quên app trên volume trước khi gỡ DMG; khi cài xong, `SoftwareUpdate` quên bản ở thư mục tạm và gọi `LSRegisterURL` cho app đã cài; xoá thư mục tạm cũng quên bản sao trong đó. `make_dmg.sh` quên bản sao trong `build/dmg`. Đã thử trọn luồng cập nhật: chỉ còn bản ghi của app đã cài.
    - **Icon của DMG:** volume của DMG 0.3.0 hiện icon ổ đĩa mặc định, vì `hdiutil create -srcfolder` không chép cờ custom icon của thư mục (`GetFileInfo -a` ra `c` thường), nên `SetFile` trong `make_dmg.sh` chưa bao giờ có tác dụng. Giờ tạo ảnh UDRW, gắn ghi được, `SetFile -a C` trên volume, rồi `hdiutil convert` sang UDZO. Kiểm: cờ `C`, icon của volume là icon Hexer. Icon của chính tệp `.dmg` vẫn là icon chung của macOS: icon riêng của một tệp nằm trong extended attribute, mà tải qua HTTP thì mất.
    - Còn lại: `NSIRD_Hexer_Be4Lxy` trong `TemporaryItems` (bản cập nhật đã chuẩn bị của bản thử bị `kill`, bundle ID `.e2e`, đã gỡ khỏi Launch Services) không xoá được từ sandbox; macOS tự dọn khi khởi động lại.
  - **Release `v0.3.1`** (theo yêu cầu của người dùng): icon của volume DMG và việc quên bản ghi Launch Services. CI của `c6396ec` đạt, tag annotated "Hexer 0.3.1", workflow Release đạt (khoảng 8 phút). https://github.com/letrucdev/hexer/releases/tag/v0.3.1 có `Hexer-0.3.1.dmg` (6,1 MB), `.sha256`, `.sig`. Đã tải về kiểm: SHA-256 khớp, chữ ký hợp lệ, app 0.3.1 build 27, universal, `minos 15.0`, code signature hợp lệ, thư mục gốc của volume có cờ `C` và hiện icon Hexer.
    - Lúc hết hạn mức API thì kiểm CI bằng badge (`/actions/workflows/ci.yml/badge.svg?branch=main`, chỉ cho biết lần chạy xong gần nhất trên `main`) và chờ release bằng link tải `.sig` (404 cho tới khi đăng). Cả hai không tính vào hạn mức.
    - Lần cập nhật 0.3.0 → 0.3.1 do code của 0.3.0 chạy, nên vẫn để lại bản ghi Launch Services ở chỗ gắn DMG và thư mục tạm; từ 0.3.1 trở đi thì không. Chưa thử cập nhật thật 0.3.0 → 0.3.1 (người dùng đã bảo tạm dừng phần thử): dùng app trong `Hexer-0.3.0.dmg` của trang release, chép ra thư mục khác rồi chạy `-HexerUpdateCheck 1 -HexerUpdateInstall 1 -HexerUpdateRelaunch 1`.
- **Phiên 8 (2026-10-25):**
  - **Canh giữa các cửa sổ riêng** (người dùng báo: "các dialog trong mục tools khi mở lên không hiện chính giữa"). Đo bằng `CGWindowListCopyWindowInfo` trên màn hình 1512 × 982:
    - Cả 5 cửa sổ Tools (Open Disk, Clone Disk, Split, Concatenate, Wipe) và Software Update có mép trái ở x = 756, đúng giữa màn hình: `center()` chạy khi cửa sổ còn cỡ 0, trước khi `NSHostingController` đưa cỡ nội dung. Sửa bằng `NSWindow.centerAtContentSize()` (mới, `App/NSWindow+Centering.swift`).
    - Settings lệch 10 pt sang phải và thấp hơn: canh theo cỡ mặc định 500 × 500 của `NSTabViewController`. Giờ canh sau `showWindow` lần đầu; `openSettings(pane:)` chọn pane trước rồi mới hiện, để canh đúng theo pane đó.
    - Statistics lần mở đầu nằm ở góc dưới trái (`contentRect` gốc 0,0, không `center()`). Giờ canh giữa trước `setFrameAutosaveName`, nên lần đầu ở giữa, các lần sau vẫn theo vị trí đã lưu. Đã thử bằng cách tạm xoá khoá `NSWindow Frame HexerStatisticsWindow` rồi ghi lại giá trị cũ.
    - About, Acknowledgements và màn hình chào vốn đã ở giữa. Alert và bảng Open/Save do hệ thống đặt.
  - **Help ▸ Hexer Help không mở được cửa sổ trợ giúp** (tìm thấy khi đo): action `showHelp:` được `NSApplication` xử lý trước app delegate, nên hiện "Help isn't available for Hexer". Đổi thành `showHexerHelp:`. Khi đã mở được, cửa sổ cao 2613 pt (vượt màn hình) vì hosting controller lấy chiều cao lý tưởng của bảng lệnh; giờ `sizingOptions = []`, cỡ 560 × 600, tối thiểu 420 × 320.
  - Kiểm: mọi cửa sổ trên có tâm ngang x = 756 ở sáng, tối và tiếng Việt; chụp từng cửa sổ (`screencapture -l`), nội dung không bị cắt. Các cửa sổ này có cỡ cố định hoặc tự chọn, nên không có trường hợp cửa sổ hẹp. Canvas không đổi: board chỉ vẽ cửa sổ, không vẽ vị trí trên màn hình. DESIGN.md: §2 mục 9.
  - `Scripts/test.sh`: 193 test đều đạt (HexerCore 139, HexerDisasm 12, HexerPlatform 42). `Scripts/crosscheck.sh`: 287/287. `Scripts/bundle.sh`: không có warning mới, 668 khoá đều có tiếng Việt.
  - **Menu File có hai mục Open Recent** (thấy trong Hexer Help, người dùng bảo sửa luôn). AppKit tự chèn một Open Recent sau Open… ("Mở mục gần đây", bản dịch của hệ thống), ngoài mục tự dựng trong `MainMenu.swift` sau Open Disk Image… ("Mở gần đây"). Dump menu bằng code tạm: mục của AppKit có delegate `NSDocumentControllerSubMenuDelegate`, còn mục tự dựng không có delegate, chỉ có Clear Menu và chưa bao giờ hiện tệp nào. AppKit chỉ nhận ra mục có sẵn qua tên menu riêng (`_setMenuName:`, API private), nên bỏ hẳn mục tự dựng và hai khoá dịch "Open Recent", "Clear Menu" (còn 666 khoá).
    - Kiểm trên máy ảo macOS 15: AppKit cũng chèn đúng một mục sau Open…; mở File ▸ Open Recent bằng AppleScript qua SSH (`osascript` + System Events, ăn theo quyền Accessibility của `sshd-keygen-wrapper`) đọc được `firmware.hex`, dấu phân cách, Clear Menu. Chạy app qua SSH phải dùng `open -n -W --stdout FILE …` (chạy thẳng binary thì treo, vì không ở trong phiên đồ hoạ). Máy ảo vẫn đang bật.
    - Canvas version 23: `MenusVI` đặt Open Recent ngay sau Open…, thêm Welcome to Hexer vào menu Help (trước đây thiếu), số khoá 666. DESIGN.md §6.8, §7.
    - Kiểm lại với code cuối: test 193/193, crosscheck 287/287, `bundle.sh` đạt (666 khoá). Đoạn dump menu tạm đã gỡ.
  - Commit `c826d0c` (theo yêu cầu của người dùng), CI đạt.
  - **Release `v0.3.2`** (theo yêu cầu của người dùng): mục 0.3.2 trong CHANGELOG (commit `9555e69`), tag annotated "Hexer 0.3.2", workflow Release đạt (khoảng 7 phút, theo dõi bằng API mỗi 75 s). https://github.com/letrucdev/hexer/releases/tag/v0.3.2 có `Hexer-0.3.2.dmg` (6,1 MB), `.sha256`, `.sig` và phần thay đổi tiếng Anh/tiếng Việt. Đã tải về kiểm: SHA-256 khớp, chữ ký hợp lệ với khoá trong Info.plist, app 0.3.2 build 30, universal, `minos 15.0`, code signature hợp lệ, volume có cờ `C`. Đã gỡ bản ghi Launch Services của app trên volume trước khi tháo DMG.
- **Phiên 9 (2026-10-25):**
  - **Kênh cập nhật không phụ thuộc GitHub** (người dùng hỏi "ngoài cách này còn có cách nào khác?", rồi chọn "linh hoạt và tránh phụ thuộc vào 1 nền tảng và bị rate limit, bị chặn", Cloudflare R2, bản cầu nối, tên miền `r2.dev` tạm, lưu cả manifest lẫn DMG trên R2).
    - **Lõi:** `UpdateManifest` (`update.json`, format 1, 10 bản mới nhất, chữ ký nằm ngay trong manifest, nhiều `urls` cho một DMG). `UpdateRelease` giờ có `diskImageURLs` và `signature: String`; bỏ hẳn phần đọc JSON của GitHub API và `UpdateSignatureSource`. `AWSSignatureV4` (SigV4 cho API S3, CryptoKit) để workflow không cần `aws`/`wrangler`.
    - **App:** `HexerUpdateFeedURL` → mảng `HexerUpdateFeedURLs`; `SoftwareUpdate` thử từng feed rồi từng URL tải. Bỏ header của GitHub API. Chuỗi lỗi 403/429 đổi thành "The update server has had too many requests…" (có tiếng Việt).
    - **CLI:** `update manifest`, `update download [--if-missing-ok]`, `update upload [--content-type] [--cache-control]`; khoá từ `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY`, region `AWS_REGION` (mặc định `auto`).
    - **Phát hành:** `Scripts/publish_update.sh`, `release.yml` thêm bước "Publish to the update server" trước `gh release create` và kiểm 3 secret `UPDATE_S3_*` + địa chỉ giữ chỗ ở job `notes`; GitHub Release vẫn có `.dmg`, `.sha256`, `.sig` (cho 0.3.x) và thêm `update.json` (nguồn dự phòng). CLAUDE.md mục Phát hành, CHANGELOG mục 0.4.0.
    - **Kiểm:** test 201/201 (HexerCore 147, gồm `UpdateManifestTests` và `AWSSignatureV4Tests` với hai ví dụ GET/PUT trong tài liệu S3 của Amazon, chữ ký khớp từng byte); crosscheck 287/287; `bundle.sh` đạt (667 khoá; phải chạy `python3 -I Scripts/l10n/vi.py` sau khi sửa `vi.py`, bundle không tự sinh). App thật với manifest `file://` (bản 9.9.9, URL đầu không tồn tại, chữ ký giả): checking → available → downloading (qua URL thứ hai) → failed "signature is not valid", đúng như mong đợi. `hexer-cli update download` với khoá giả tới S3 thật: 403 `InvalidAccessKeyId` (header đúng dạng). Ảnh chụp trạng thái failedCheck ở tối (tiếng Anh) và sáng (tiếng Việt): chuỗi mới hiện đúng; bố cục không đổi nên canvas và DESIGN.md giữ nguyên.
    - Người dùng đã tạo bucket và gửi địa chỉ `https://pub-78e377a21a0d499cb607f4ad3d0c899d.r2.dev`; đã ghi vào `Info.plist`, build lại đạt. Người dùng thêm 3 secret `UPDATE_S3_*`.
  - **Release `v0.4.0`** (theo yêu cầu của người dùng, 2026-10-26): commit `ed4bb8b` (code + CHANGELOG 0.4.0), CI đạt, tag annotated "Hexer 0.4.0", workflow Release đạt ngay lần đầu (3 job `notes`, `test`, `release`). Kiểm: `update.json` trên R2 (`Cache-Control: public, max-age=300`) có đúng một bản 0.4.0 với hai `urls` (R2 rồi GitHub); `Hexer-0.4.0.dmg` trên R2 (6,1 MB, `immutable`) có SHA-256 `a8a9f590…` khớp `.sha256` trên GitHub; chữ ký trong manifest hợp lệ với khoá trong app (`hexer-cli update verify`); app trong DMG là 0.4.0, universal, codesign hợp lệ, `HexerUpdateFeedURLs[0]` trỏ R2. Trang release có `.dmg`, `.sha256`, `.sig` và `update.json` (giống hệt bản trên R2). Bản build cục bộ (code mới, phiên bản 0.3.2 vì build trước khi có tag) chạy `-HexerUpdateFeed <R2> -HexerUpdateCheck 1`: checking → available, cửa sổ hiện "Hexer 0.4.0 is available" với đúng ghi chú của CHANGELOG. Khi kiểm thì `-HexerQuit 1` phải đi kèm `-HexerSnapshot … -HexerSnapshotDelay 8`, vì không có `-HexerUpdateInstall` thì app thoát ngay trước khi kiểm xong (và stdout không kịp flush nếu bị kill).
