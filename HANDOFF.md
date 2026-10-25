# Hexer — Technical handoff

Last updated: 2026-10-26. Read this file before continuing work; UI design is in [DESIGN.md](DESIGN.md).

Hexer is a hex editor designed for macOS 27, written in SwiftUI + AppKit with Liquid Glass, and it **runs on macOS 15 and later** (macOS 15 has no glass, see DESIGN.md §11). The goal is feature parity with **HxD 2.5**, reconstructed from `HxD64.exe` using REA.

| Document | Path |
|---|---|
| Original plan (10 phases, architecture, risks) | `~/.claude/plans/d-ng-rea-ph-n-t-ch-wiggly-metcalfe.md` |
| UI design (Claude Design canvas) | https://claude.ai/artifact/JBSgQBQpVLtMWto8QECZgb · [DESIGN.md](DESIGN.md) |
| HxD build used for comparison | `~/Downloads/HxD/HxD64.exe` (crosscheck uses this file too) |

## 1. Quick status

- Phases 1–9 are done. Phase 10 (detailed comparison with HxD using REA) has had its main findings applied.
- **Re-verified on 2026-10-26:**
  - `Scripts/test.sh`: all 201 tests pass (HexerCore 147, HexerDisasm 12, HexerPlatform 42).
  - `Scripts/crosscheck.sh`: 287/287 pass.
  - `Scripts/bundle.sh`: builds with no warnings except the linker search-path warning.
  - l10n checked: 666 keys have Vietnamese (the audit now recognizes many more patterns, see §2).
- **Latest release: v0.4.1** (2026-10-26): typing hex digits into the hex column (session 11). v0.4.0 (2026-10-26) was the bridge release to the Cloudflare R2 update server (`https://pub-78e377a21a0d499cb607f4ad3d0c899d.r2.dev/update.json`): 0.3.x finds it through the GitHub API as before; from 0.4.0 on the app reads the manifest on R2 (GitHub Release is the fallback). The `HEXER_UPDATE_KEY` secret and the 3 `UPDATE_S3_*` secrets are set on GitHub. Users on 0.2.0 or earlier must download manually once.
- **Promo film:** `Scripts/film/` (session 11); output in `build/film/`, not committed.
- **Git:** branch `main`, remote `origin` = `git@github-letrucdev:letrucdev/hexer.git` (SSH host `github-letrucdev` is an alias in this machine's `~/.ssh/config`). First commit pushed 2026-10-24. Commit or push only when the user asks.

## 2. Environment and commands

The machine has only **Command Line Tools**, no Xcode: Swift 6.4, SDK MacOSX27, SwiftPM tools 6.2, Swift 6 language mode. Deployment target **macOS 15** (`Package.swift`, `LSMinimumSystemVersion`); `bundle.sh` writes `minos 15.0`, `sdk 27.0` into the binary.

| Command | What it does |
|---|---|
| `Scripts/bundle.sh` | Release build → `build/Hexer.app`. Runs `vtool` (SDK 27), l10n audit, `plutil -lint`, `iconutil`, ad-hoc codesign. The build **fails if any UI string lacks a translation**. Version comes from `$VERSION` (the Release workflow sets it from the tag), otherwise from the latest `v*` tag (`git describe --tags --abbrev=0`); only with no tags (a shallow clone such as normal CI) does it keep `0.1` from `Resources/Info.plist`. |
| `CONFIG=debug Scripts/bundle.sh` · `UNIVERSAL=1 Scripts/bundle.sh` · `Scripts/bundle.sh --run [args]` | Debug build · arm64 + x86_64 build · build then run |
| `SIGN_IDENTITY=… Scripts/bundle.sh` | Sign with a real identity. Ad-hoc signing makes macOS **lose the Screen Recording permission after every build**. |
| `Scripts/test.sh` | `swift test --disable-xctest` (swift-testing). Platform tests attach real disk images with `hdiutil`. After `$TEST_TIMEOUT` seconds (default 900, build included) it stops and prints `error:` lines: child processes still running (e.g. a hung `hdiutil`) and the Hexer-code frames in the test process's stack (taken with `sample`). On CI these lines become annotations readable without logging in. swift-testing prints nothing until it finishes when output is not a terminal, even with `--event-stream-output-path`. |
| `Scripts/crosscheck.sh` | Compares `hexer-cli` against xxd, grep, perl, md5, shasum, cksum, cmp… on HxD64.exe and random files |
| `Scripts/film/make.sh` · `record [take…]` · `stills 5.5,17` | The promo film (rules in `VIDEO.md`): `build/film/hexer-film.mp4` (3840×2160, 60 fps, HEVC + AAC, 30 s, about 150 MB) and `hexer-film-1080p.mp4` (H.264), **not committed**. `record.swift` drives a copy of the app (`build/film/Hexer.app`, bundle ID `com.nongdandev.hexer.film`, so window frames and recents stay out of the user's Hexer) with **real mouse and keyboard events** and records Hexer's windows plus the real cursor with ScreenCaptureKit into `build/film/takes/` (HEVC with alpha + JSON of every click, key and marker). `record` takes over the mouse for about 3 minutes: ask the user first. `render.swift` cuts the 4K picture on the GPU (2.5D planes, camera, lights, depth of field, motion blur, type; ~1 min) and writes `cues.json`; `score.swift` synthesizes the 96 BPM score and sound design from it (~2 s); `render --mux` puts them together. Re-recording is only needed when the app's look or the actions change. Details in session 11. |
| `Scripts/vm_test.sh start` · `deploy` · `selftest` · `shot NAME [SECONDS] -- ARGS` · `capture` · `burst` · `keys` · `press` · `menu` · `close` · `ax` · `ssh CMD` | Tests in a macOS VM in UTM over SSH. `deploy` copies the app, `hexer-cli`, sample files and `vm_agent`. `shot` opens the app with `-Hexer…` flags, captures the **UTM window**, and crops to the Hexer window into `build/vm/shots/`; `burst` presses a key then captures several frames in a row. `keys`, `press`, `menu`, `close`, `ax` control Hexer through `Scripts/vm_agent.swift` (keys go straight to the process, buttons and menus via Accessibility), without touching this machine's mouse/keyboard. Config in `build/vm/config` (`VM_HOST`, `VM_USER`, `VM_KEY`, `VM_NAME`; currently macOS 15.0, `letrucdev@192.168.64.2`). One-time setup inside the VM: enable Remote Login, add the public key to `authorized_keys`, give `/usr/libexec/sshd-keygen-wrapper` Accessibility permission (already done). The `utm` MCP can also start/stop the VM and get its IP. |
| `Scripts/make_dmg.sh` · `--no-build` | Release for other people: builds universal, then creates `build/Hexer-<version>.dmg` containing `Hexer.app`, an `Applications` shortcut, a volume icon and two RTF guides ("Install Hexer.rtf", "Hướng dẫn cài đặt Hexer.rtf", generated from `Distribution/install-{en,vi}.html` with `textutil`). The app is ad-hoc signed and not notarized, so the guides explain how to allow the first launch (Privacy & Security ▸ Open Anyway, or `xattr -dr com.apple.quarantine`). With `SIGN_IDENTITY` the DMG is signed too. Button names in the guides come from the system localization tables (CoreServicesUIAgent, SecurityPrivacyExtension). |
| `Scripts/sign_update.sh VERSION` | Signs `build/Hexer-VERSION.dmg` with the key in `$HEXER_UPDATE_KEY` → `.dmg.sig`, then verifies with `HexerUpdatePublicKey` in `build/Hexer.app`; stops if the key does not match. The Release workflow runs it after `make_dmg.sh`. Try it on this machine: `HEXER_UPDATE_KEY="$(security find-generic-password -a letrucdev/hexer -s 'Hexer update signing key' -w)" Scripts/sign_update.sh 0.1` (delete the `.sig` afterwards). |
| `Scripts/publish_update.sh VERSION NOTES_FILE` | Pushes `build/Hexer-VERSION.dmg` and `update.json` (old manifest on the server + this version) to the update server over the S3 API; needs `UPDATE_S3_URL`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`. The Release workflow runs it after `sign_update.sh`. See "Update server" below. |
| `Scripts/fetch_capstone.sh` | Re-download or update Capstone 5.0.9 into `Sources/CCapstone` (sha256 checked) |
| `swift build --product hexer-cli` | CLI: `dump`, `find`, `replace`, `checksum`, `stats`, `diff`, `export`, `import` (`ihex`/`srec`/`etl`), `disasm`, `edit`, `split`, `concat`, `disks` (`list`/`read`), `update` (`keygen`/`public-key`/`sign`/`verify` for update signatures; `manifest`/`download`/`upload` for the update server), `bench`, `selftest`, `help` |
| `hexer-cli selftest` | Known-answer checks inside the binary (checksum, digest, encodings, piece tree, search, Intel Hex/S-Record, file save, Capstone). For builds that cannot run the test suite, e.g. the x86_64 slice of the universal build: `arch -x86_64 hexer-cli selftest`. |

### CI and releases
(GitHub Actions)
- **`.github/workflows/ci.yml`:**
  - Runs on push to `main` or on a pull request (ignoring changes only in `*.md`, `docs/`, `Distribution/`), or manually.
  - Runs `Scripts/test.sh`, `Scripts/crosscheck.sh` (HxD64.exe is not on the runner, so that part is skipped) and `Scripts/bundle.sh`; uploads `Hexer.app` as an artifact, kept 7 days.
- **`.github/workflows/release.yml`:**
  - Runs on push of a `v*` tag. Naming rules and the tag command are in CLAUDE.md (section "Releases"), e.g. `git tag -a v0.1.1 -m "Hexer 0.1.1" && git push origin v0.1.1`.
  - The `notes` job runs first: `Scripts/release_notes.sh` must find the version's section in `CHANGELOG.md`, otherwise it stops.
  - The `notes` job also stops if the `HEXER_UPDATE_KEY` secret is missing (see "Update signing key" below).
  - The `notes` job also stops if the `UPDATE_S3_URL`, `UPDATE_S3_ACCESS_KEY_ID` or `UPDATE_S3_SECRET_ACCESS_KEY` secret is missing, or if `HexerUpdateFeedURLs` in Info.plist still has the placeholder address `REPLACE-ME` (see "Update server" below).
  - Then it calls `ci.yml`; if that passes it takes the version from the tag, writes it to `CFBundleShortVersionString`, runs `Scripts/make_dmg.sh`, then `Scripts/sign_update.sh` (signs the DMG, verifies the signature with the public key in the app just built).
  - Release notes are built by `Scripts/release_notes.sh` into `build/release-notes.md`: the version's section from `CHANGELOG.md` (replacing `@CHANGES@` in `Distribution/release-notes.md`), the install guide, a compare link to the previous tag, then the SHA-256 line.
  - `Scripts/publish_update.sh` pushes to the update server: downloads the existing `update.json` (over the S3 API, bypassing caches), adds the new version with `hexer-cli update manifest` (notes = `release-notes.md`, `urls` = the DMG on the server then the DMG on the GitHub Release), uploads the DMG (`Cache-Control: immutable`), then uploads `update.json` (`max-age=300`), and finally `curl`s to check the DMG is public at the address the app will read.
  - Creates the release with `gh release create`, with the DMG, the `.sha256` file, the `.sig` file (needed by 0.3.x) and a copy of `update.json` (the app's fallback source). A tag containing `-` (e.g. `v0.2.0-beta.1`) becomes a pre-release.
- **Runner:** `xcode-27` (macOS 27, Xcode 27.0, SDK 27; the label is still preview), selected via `DEVELOPER_DIR`. When `DEVELOPER_DIR` points to an Xcode, Package.swift does not add the CLT `-plugin-path`.
- **Public repo** (https://github.com/letrucdev/hexer). Without logging in you can still see each step's status through the API (`/actions/runs`, `/actions/runs/<id>/jobs`), but logs require login. So `Scripts/ci_run.sh` repeats the failed step's error lines as annotations (`/check-runs/<id>/annotations`), readable publicly. `gh` is not installed on this machine; the machine's Python lacks SSL certificates, so call the API with `curl`.
- **Timings:** CI takes about 4–5 minutes; the Release workflow (including CI) about 7–8 minutes.
- **API limits when monitoring:** unauthenticated gives only 60 calls per hour per IP; Hexer 0.3.x on the same network shares that quota for update checks (from 0.4.0 it does not: the app reads the manifest, no API calls). Polling a workflow every 60 s is enough. Session 7 used up the quota (every 30 s, several workflows in a row), and the 0.3.0 app got a 403 when checking. Release pages and asset download links (`/releases/download/…`) do not count against the quota.

### Update server (Cloudflare R2, S3 API)
- A public R2 bucket holds `update.json` and the `Hexer-X.Y.Z.dmg` files. The app reads the public address (`HexerUpdateFeedURLs[0]` in `Resources/Info.plist`, of the form `https://pub-….r2.dev/update.json`; if it later moves to a custom domain, change only this and ship a new release; older versions still read through the GitHub fallback). `publish_update.sh` derives the DMG's public address from that same key, so no variable has to be kept in sync by hand. Note Cloudflare says `r2.dev` is rate limited and not meant for production; once there is a custom domain, attach it to the bucket (Settings ▸ Custom Domains).
- **One-time setup (the user does this on Cloudflare):** R2 ▸ Create bucket (e.g. name `hexer-updates`, location Automatic) ▸ Settings ▸ Public access ▸ enable the r2.dev subdomain, copy the address `https://pub-….r2.dev`. R2 ▸ Manage R2 API Tokens ▸ Create API token: **Object Read & Write** permission, scoped to that bucket, no TTL; copy the Access Key ID, Secret Access Key and endpoint `https://<account id>.r2.cloudflarestorage.com`.
- **GitHub secrets** (Settings ▸ Secrets and variables ▸ Actions): `UPDATE_S3_URL` = `https://<account id>.r2.cloudflarestorage.com/<bucket>` (endpoint + bucket name, no trailing `/`), `UPDATE_S3_ACCESS_KEY_ID`, `UPDATE_S3_SECRET_ACCESS_KEY`. The workflow puts the two keys in `AWS_ACCESS_KEY_ID`/`AWS_SECRET_ACCESS_KEY` for `hexer-cli` (the standard names for every S3 tool; region `AWS_REGION`, R2's default is `auto`).
- **S3 signature (AWS SigV4)** is hand-written in `HexerCore/Update/AWSSignatureV4.swift` (CryptoKit, tested against two examples in Amazon's S3 docs), so the runner needs neither `aws` nor `wrangler`. `hexer-cli update download|upload` send with URLSession. Any S3-compatible bucket (B2, MinIO, S3) works; just change `UPDATE_S3_URL`.
- Test on this machine without making a release: `UPDATE_S3_URL=… AWS_ACCESS_KEY_ID=… AWS_SECRET_ACCESS_KEY=… hexer-cli update download --if-missing-ok "$UPDATE_S3_URL/update.json"` (404 is normal when the bucket is empty; 403 means the token has the wrong permissions). The first real upload was the 0.4.0 release (the workflow passed on the first try, see session 9 in the log).
- `update.json` on the server is the source of truth for the list of the 10 latest versions; if it is lost, the next release recreates a manifest with only the new version (older versions are no longer offered to people with beta enabled, but the latest stable still is).

### Update signing key (Ed25519)
- The private key is in this machine's login Keychain: item "Hexer update signing key", account `letrucdev/hexer` (created 2026-10-25 with `hexer-cli update keygen`, never printed). The public key `qQH58WYIAJxTACG1jnB/eweAvWnoo3oMkTYQWfKo+MI=` is in `HexerUpdatePublicKey` in `Resources/Info.plist`.
- Getting it onto GitHub (once, the user does it since the machine has no `gh`): run `security find-generic-password -a letrucdev/hexer -s 'Hexer update signing key' -w | pbcopy`, then paste into Settings ▸ Secrets and variables ▸ Actions ▸ New repository secret, named `HEXER_UPDATE_KEY`. Also keep a copy in a password manager.
- If the key is lost, new versions cannot be signed for installed copies; you must ship a version with a new public key and users download manually once. The same applies if the key leaks (change the key and tell users).
- **Cost:** macOS runner minutes count much more than Linux (recently 10×) against the Actions quota of a private repo; check usage in Settings ▸ Billing.

### Gotchas
- **`@State` does not compile**, because CLT lacks SwiftUIMacros. Use an `@Observable` model + `@Bindable`. `@FocusState`, `@Namespace` and `@AppStorage` still work.
- **The test target needs `-plugin-path …/host/plugins/testing`.** The `testSettings` constant in `Package.swift` handles it; without it you occasionally get "TestingMacros not found".
- **SourceKit reports "No such module 'HexerPlatform'"** in the editor. This is a false error, since there is no Xcode project; just build with the scripts.
- **APIs newer than macOS 15:** the compiler errors if you use them without `if #available`. Glass always goes through the helpers in `GlassBarStyle.swift` (`barGlass`, `barGlassID`, `GlassGroup`). Check the macOS 15 look with `-HexerNoGlass 1`.
- **Swift 6 isolation errors:** the app module runs with `defaultIsolation(MainActor)`. A `static let` constant or a helper used from the background must be marked `nonisolated`.
  - Closures handed to AppKit or SwiftUI for callbacks also default to MainActor, and **trap at runtime** if called from another thread. Example: an `NSColor` dynamic provider is called by SwiftUI on the render thread during animation. A function that creates such a closure must be `nonisolated` (see `NSColor.dynamic` in `HexTheme.swift`).
- **The bundle needs Vietnamese strings.** Every new UI string must have a translation in `Scripts/l10n/vi.py`. Run `python3 -I Scripts/l10n/vi.py` to generate `Resources/Localization/vi.lproj/Localizable.strings`; if one is missing, `bundle.sh` stops. The patterns the audit recognizes are in `Scripts/l10n_audit.swift`: `Text`/`Button`/`L(…)`…, the helpers `item`/`menu`/`sub`/`pane`/`field`/`fact`/`group`, icon buttons (`GlassBarIconButton`, `iconButton`…), `title:`/`placeholder:` and the two-branch `Text(c ? "A" : "B")`. Add any new helper that takes UI strings to this list.
- **Translation keys must not contain `\n`.** Build multi-line text from several `L(…)` calls (see `App/ErrorMessages.swift`).
- **Centering a window with SwiftUI content:** `NSHostingController` only gives the window a size after a layout pass (`layoutIfNeeded()` is not enough), so calling `center()` right after assigning `contentViewController` centers on size 0, and then the window grows right and down from the screen center. Use `NSWindow.centerAtContentSize()` (`App/NSWindow+Centering.swift`, sets the size from `fittingSize` and only then centers). `NSTabViewController` (Settings) only resizes the window per pane when the window appears, so Settings is centered after the first `showWindow`. Measuring window position needs no Screen Recording permission: `CGWindowListCopyWindowInfo` returns `kCGWindowBounds`.
- **Selector clashing with NSApplication:** actions with no target go through the responder chain to `NSApp` **before** the app delegate, so the delegate must not define an action named like an `NSApplication` method. `showHelp:` once made Help ▸ Hexer Help show "Help isn't available for Hexer"; it is now `showHexerHelp:`.
- **NSAlert on macOS 27:** while `runModal` runs, Return moves from the first button's `keyEquivalent` to `window.defaultButtonCell`. To keep a button from receiving Return, use `alert.addDestructiveButton(withTitle:)` (`App/Alerts.swift`); do not set `keyEquivalent` yourself.

### Scripted app runs (`App/DebugLaunchArguments.swift`)
Example:

```sh
build/Hexer.app/Contents/MacOS/Hexer file.bin -HexerGoTo 0x100 -HexerAction goToOffset: -HexerSnapshot /path/shot.png -HexerQuit 1
```

- Flags: `-HexerAction sel:`, `-HexerSnapshot path`, `-HexerSnapshotShadow 1` (keeps the window shadow on a transparent background, used for README images), `-HexerAppearance light|dark` (forces appearance via `NSApp.appearance`; do not use `-NSRequiresAquaSystemAppearance`, that flag makes the toolbar transparent), `-HexerFindAllSelect n` (select the nth result after Find All, default 2), `-HexerNoGlass 1` (macOS 15 look, no glass), `-HexerAlertSnapshot path` (capture the next modal alert, print which button gets Return/Esc, then dismiss the alert), `-HexerQuit 1`, `-HexerFind/-HexerFindType/-HexerFindAll`, `-HexerReplace/-HexerReplaceAll`, `-HexerSave`, `-HexerUndoAll`, `-HexerChecksums`, `-HexerExpected`, `-HexerCompare/-HexerCompareSteps/-HexerCompareList`, `-HexerCopyAs`, `-HexerImport path` (also accepts `-HexerWindowSize`, `-HexerGoTo`, `-HexerAction`), `-HexerOpenDisk diskN` (+ `-HexerOpenDiskWritable 1`, only applies to disk images), `-HexerPrintPDF`, `-HexerSectorSize`, `-HexerWindowSize WxH`, `-HexerGoTo`, `-HexerSelect a-b`, `-HexerMode`, `-HexerEncoding`, `-HexerBytesPerRow`, `-HexerDrawer`, `-HexerHideInspector`, `-HexerSettingsPane n`.
- With any `-Hexer…` flag the app shows neither the Open panel nor the welcome screen at launch (`DebugLaunchArguments.isScripted`).
- Welcome screen: `-HexerWelcome n` opens at page n (0–3) without marking it as seen; `-HexerWelcomeTour s` flips a page every s seconds; `-HexerWelcomeEnd skip|open|close` ends it as if Skip, Open a File… or the close button was clicked, treated as being at app launch (to check that the Open panel appears afterwards); `-HexerSnapshot path` captures after `-HexerSnapshotDelay` seconds (default 2.5).
- Update window: `-HexerUpdatePreview checking|upToDate|available|downloading|verifying|ready|failed|failedCheck` shows that state with a sample release (0.3.0) for screenshots. `-HexerUpdateFeed URL` replaces the source (HTTPS, or `file://` where the asset is also `file://`); `-HexerUpdateCheck 1` checks immediately, `-HexerUpdateInstall 1` installs the version found, `-HexerUpdateRelaunch 1` relaunches when done. The state is printed as `HexerUpdatePhase …`. The signature is still verified with the key in Info.plist, so to test the full flow build a copy of the app with its own test bundle ID and key (method in session 7 of the log).
- View the welcome screen as on first launch: `defaults delete com.nongdandev.hexer WelcomeShown` then `open build/Hexer.app`. **Delete this key again after testing**, so users still see the welcome screen on first launch.
- **Every flag must come with a value** (e.g. `1`). Otherwise AppKit treats the following word as a file name and opens it.
- Vietnamese: add `-AppleLanguages '(vi)'`.
- Screenshots use `screencapture -l <windowID>` (needs Screen Recording permission). **Never capture a screen region**, since it would catch other apps' windows.

## 3. Architecture

```
Sources/
  CCapstone/      Capstone 5.0.9 vendored (X86 + AArch64)
  CHexerSys/      C: receive fd from authopen (SCM_RIGHTS), ioctl DKIOC*
  HexerCore/      Pure Swift, no UI dependency
    Storage/      ByteSource, ChunkCache, PieceTree (persistent B+tree), EditableBuffer (unlimited undo),
                  AddBuffer, Generator (pattern/random), FileWriter (APFS clone + patch changed regions)
    Search/       SearchQuery, CompiledSearch, MatchScanner (memmem, case folding, UTF-16), Search/ReplaceEngine
    Analysis/     Checksum (Sum, CRC Rocksoft, hand-written MD2/MD4, MD5/SHA via CryptoKit), ByteStatistics, CompareEngine
    Codecs/       Export (Raw/Hex/Text, Pascal/C/C#/Java/VB.NET/PureBasic source, Editor view/HTML/RTF/TeX,
                  S19/S28/S37, Intel Hex 16/20/32), Import (Intel Hex, S-Record, ETL Extended)
    Inspector/    DataInspector (30 types), Codecs (LEB128, Real48, Ext80, OLE/FILETIME/DOS/time_t, GUID)
    Text/         TextEncoding (Windows-1252, CP437, Mac Roman, EBCDIC 500), CharacterFilter
    Layout/       HexLayout, VirtualScrollMapper (scaled scrolling for files of ~2^40 bytes), RowMap (display row ↔ data row when folding undefined sections)
    FileTools/    split, concatenate, overwrite, wipe
  HexerDisasm/    Swift wrapper for Capstone (x86-16/32/64, ARM64)
  HexerPlatform/  DiskEnumerator (IOKit + DiskArbitration), RawDeviceOpener (authopen), DiskByteSource,
                  DiskWriter (sector-wise read-modify-write), DiskCloner, DiskArbitrationSession (unmount)
  Hexer/          App: AppKit lifecycle, SwiftUI views
    App/          main, AppDelegate, MainMenu (menus built in code), AppSettings, L10n (L("…")), DebugLaunchArguments,
                  Alerts (destructive buttons), ErrorMessages (core errors → UI strings)
    Document/     HexDocument (NSDocument), HexWindowController, EditorSession (+Editing/+Search/+Tools),
                  CompareSession, ExportImport, Jobs (JobCenter: cancellable background tasks with progress), Print
    HexGrid/      HexCanvasView (CoreText drawing, input, IME, VoiceOver), HexEditorView, HexTheme
    Views/        DocumentWindowView, SidebarView, InspectorView, FindBar, ResultsDrawer, StatusBarView,
                  SectorNavigator, GlassBarStyle, SettingsWindowController, Sheets/, Analysis/, Tools/,
                  Welcome/ (welcome screen: controller + model, pages, illustrations, Core Animation background)
  HexerCLI/       hexer-cli
Tests/            HexerCoreTests, HexerDisasmTests, HexerPlatformTests (swift-testing)
Resources/        Info.plist, entitlements (no sandbox), Icon, Licenses, Localization/{en,vi}.lproj
```

### Key decisions
- **Saving files:**
  - `FileWriter` clones the original file (APFS `clonefile`) and patches only the changed regions.
  - If the size changes, it streams to a new file and replaces atomically.
  - Undo history can still read the old bytes after saving.
  - `.bak` is optional.
  - `NSFilePresenter` reports when the file is changed externally.
- **The hex grid** is a custom `NSView` that draws only the visible rows. `GlyphBatcher` flips the y axis because CoreText uses a flipped text matrix. `clipsToBounds` is on so the grid does not draw over the status bar.
- **Disks:**
  - Opens `/dev/rdiskN`; if denied, asks for permission with `AuthorizationCopyRights` + `authopen -stdoutpipe -extauth` (never `-w`, since it truncates the device).
  - Opens read-only by default; the boot disk can never be written.
  - Unmount before writing.
- **EBCDIC uses CP500**, exactly the table in HxD64.exe at 0x57c8c4, not CP037.
- **Compare** arranges the two windows without animation, after a 50 ms delay; animation once caused an Auto Layout loop. The diff-navigation capsule is an overlay at the bottom of the grid.
- **Window subtitle ("9.6 MB · Overwrite"):** from macOS 26, `HexWindowController` sets `NSWindow.subtitle`. Before macOS 26, SwiftUI's split view draws its own title bar and clears `NSWindow.subtitle`, so the host sets `sceneBridgingOptions = [.toolbars, .title]` and `DocumentWindowView` sets `.navigationSubtitle(session.windowSubtitle)`. The title is still managed by NSDocument.
- **Window "edited" dot:** since `HexDocument` overrides `isDocumentEdited`, NSDocument does not call `setDocumentEdited` on the window controllers itself (the dot in the close button does not appear, on both macOS 15 and 27). `bufferDidChange` calls it directly for every window controller.
- **Folding undefined sections:** `HexEditorView.rowMap` (`RowMap`, HexerCore) converts display row ↔ data row. Every place that computes rows (drawing, caret, hit-test, scrolling, IME, ↑↓/Page, compare, sector navigator) goes through it; do not reuse `offset / bytesPerRow` to get an on-screen row.
  - The canvas reads bytes in runs of contiguous data rows and never reads across a folded region (which can be GBs).
  - When the row layout changes (bytes per row, fold/unfold), the byte at the top of the screen is preserved.
  - State: `EditorSession.foldsUndefinedSections`, `unfoldedSections` (keyed by the region's first byte).
- **Core errors in Vietnamese:** the core keeps English sentences (the CLI prints them verbatim); the app maps each case in `App/ErrorMessages.swift`. Adding a new core error case means adding the matching branch there and a translation in `vi.py`.
- **First-run welcome screen (`Views/Welcome/`):** `AppDelegate.applicationOpenUntitledFile` calls `WelcomeWindowController.showIfFirstLaunch()` first; if the `WelcomeShown` key is not set it shows the welcome screen instead of the Open panel. Design in DESIGN.md §6.9.
  - **Performance (measured with `ps -o time` over 6 s):** SwiftUI in this window draws with CoreGraphics on the CPU (`CGDrawingLayer` / `RBInterpolatedDisplayListContents` in `sample`), so each animation frame costs about 13 ms. The first version used `TimelineView(.animation)` + `Canvas` for the background and illustrations: 25–40% of one core. Now: 0–2% (Edit page about 6%). Session 5 re-measured the first page at 7–8% on this machine, cause unknown (see session 5 in the log).
  - The hex-byte background is Core Animation (`WelcomeHexFieldView`): bytes are drawn once into a mask, layers scroll with `CABasicAnimation`, the sweep band and ripple ring are `CAGradientLayer` masks; red flashing bytes are small layers added by a 0.3 s timer. This view sits **below** the `NSHostingView` in a container; it is not an `NSViewRepresentable`.
  - Illustrations follow `WelcomeSchedule` (updated only at change points) and do **not** interpolate between points. Do not add `.animation`, `contentTransition` or repeating `symbolEffect` there.
  - The veil uses `windowBackgroundColor`, so `WelcomeHexFieldView` paints its own background with exactly that color; the window background on macOS 26+ differs slightly, making the veil show as a patch.
  - A large-radius `blur` is drawn wrongly in the CG drawing path; the glow is a `RadialGradient`.
- **Open panel at launch:** `AppDelegate.applicationOpenUntitledFile` calls `openDocument(nil)` (via `DispatchQueue.main.async`, so the launch event finishes first). AppKit calls this both when the app opens with no file and when the Dock icon is clicked with no windows, so `applicationShouldHandleReopen` is not needed. Tested: clicking the Dock while the panel is open does not create a second panel, even after clicking Cancel.
- **Self-update** (`HexerCore/Update`, `HexerPlatform/{Downloads,MountedDiskImage,CodeSignature,UpdateStaging}.swift`, `App/SoftwareUpdate.swift`, `Views/SoftwareUpdateView.swift`; UI in DESIGN.md §6.10):
  - **Source (since 0.4.0):** the `update.json` manifest (`HexerCore/Update/UpdateManifest.swift`: `format` 1, each release has `version`, `prerelease`, `page`, `notes`, `size`, `sha256`, Base64 `signature`, and `urls`, the DMG download locations in priority order; the 10 latest versions are kept). The app tries the addresses in `HexerUpdateFeedURLs` in Info.plist in turn (the update server on Cloudflare R2, then the copy on the GitHub Release `releases/latest/download/update.json`) and takes the list from the first one it can read; to download the DMG it tries each of `urls` until one works. Ephemeral session, User-Agent `Hexer/<version>`. Accepts only releases with a valid version, a signature and at least one HTTPS URL. The manifest need not be trusted: the signature is verified with the key in the app, so the server can only hide a new version, not swap it. **Version 0.3.x** still reads the GitHub API `GET /repos/letrucdev/hexer/releases` and needs the `.dmg` + `.sig` on the release page, so the workflow still posts both to GitHub; 0.3.x finds 0.4.0 that way and from 0.4.0 reads the manifest. Pre-releases count only when "Include beta versions" is on or when a beta is running.
  - **Schedule:** 5 s after launch, then hourly, at most once a day; the very first launch does not check (key `UpdateChecksSince`). Runs with any `-Hexer…` flag do not check, unless `-HexerUpdateFeed` is given. Automatic checks speak up only when a new version exists; network errors or 403/429 ("the update server received too many requests") stay silent. UserDefaults keys: `CheckForUpdatesAutomatically`, `UpdateIncludesBetas`, `LastUpdateCheck`, `SkippedUpdateVersion`, `UpdateStagingFolder`.
  - **Verification, in order:** Ed25519 signature over the message `hexer-update-v1\n<version>\n<sha256 hex of DMG>\n` (the version is included, so one version's signature cannot be reused for another); attach the DMG read-only (`hdiutil attach -nobrowse -noverify -mountrandom`); the `Hexer.app` inside must have the right bundle ID, the release's version, and `LSMinimumSystemVersion` ≤ the running macOS; intact code signature (`SecStaticCodeCheckValidity`, strict, all architectures, nested code). The app is ad-hoc signed so it requires only `identifier "com.nongdandev.hexer"`; when a Developer ID (Team ID) exists, it switches automatically to requiring the running copy's designated requirement (same developer). After copying with `ditto`, the code signature is checked again.
  - **Install:** the new version waits in a temporary `itemReplacementDirectory` on the same volume as the app. When the app quits (`applicationWillTerminate`), `renamex_np(RENAME_SWAP)` swaps the two bundles in one atomic step, then deletes the old one; the app name the user chose is preserved. Relaunch = `NSApp.terminate` (still asks to save documents like a normal quit); after the swap a small `/bin/sh` waits for the old process to end, then `open`s the new one.
  - **Cannot self-replace** when the app is under App Translocation (run straight from where it was downloaded, not moved to Applications) or lacks write permission on the bundle or its containing folder: the window says why and the primary button becomes Download… (opens the release page).
  - **Not handled:** if you click Relaunch and then cancel the save-documents dialog, the relaunch flag stays set, so the next time Hexer quits it will reopen itself (the update is still installed like "Install on Quit").
  - macOS 26 reports `hdiutil attach`/`create` as deprecated (replacement is `diskutil image`, not on macOS 15); it still works, the warning is filtered out of error messages.
- **Settings:** each pane uses `NSHostingController.sizingOptions = .preferredContentSize` and sets `title` (the window takes the pane name as its title). Without this the window defaults to 500×500 and content is centered.

## 4. Done (vs. HxD)

| Group | Features |
|---|---|
| File | New, Open, Open Recent, Close/Close All, Save/Save As/Save All, Save Selection As, Reload from Disk, `.bak`, external change detection, Page Setup/Print, native window tabs, Tile Vertically/Horizontally |
| Import/Export | Import Intel Hex, S-Record, ETL Extended (empty regions become undefined sections). Export and Copy As support every HxD format (§3); line length is adjustable in Settings ▸ Export. |
| Edit | Unlimited Undo/Redo, Cut/Copy/Paste Insert/Paste Overwrite/Delete, Copy Offset, Insert Bytes, Fill Selection (multiple passes, hex/random, DoD and Zero presets, written straight to disk), Select All/Block, Insert/Overwrite/Read-only modes, nibble entry, IME |
| Search | Find/Replace/Find Next/Previous, Use Selection; types Text (editor encoding or UTF-16LE, case sensitive), Hex, Integer (any, 8–64, LE/BE, signed or unsigned), Float (Single/Double/Real48/Extended); directions All/Forward/Backward; Find All into the drawer; confirm before replace; search runs in the background with Stop |
| Navigation | Go to Offset (origin: file start, current position, file end; hex/dec/oct), bookmarks 0–9, sector navigator |
| Display | Bytes per row (8–4096, Custom…, fit window), grouping 1/2/4/8/16, Hex/Text columns, hex/dec/oct offsets, 4 encodings, lowercase hex, Filter Characters, ghost caret, odd-column tint, modified bytes in red, folding of undefined sections after import (click to open, View ▸ Fold Undefined Sections) |
| Data Inspector | 30 types (including LEB128, OLETIME, FILETIME, DOS, time_t, GUID, x86-16/32/64 + ARM64 disassembly), LE/BE, Hex, direct editing, step by type, each type toggled in Settings |
| Analysis | Checksums (Sum 8–64, Custom, CRC-16, CRC-16/CCITT-FALSE, CRC-32, CRC-32C, Custom CRC, MD2/4/5, SHA-1/256/384/512, compare with expected value, Copy / Copy with Details), Statistics (chart, Hide maximum, entropy), Compare (two windows, F6/⇧F6, difference list) |
| Disks | Open Disk (physical/logical), Open Disk Image (choose sector size), Clone Disk (disk ↔ image), sector-wise writes, warning when opening for write |
| Tools | Split (presets, Custom, .001 numbering or ask for names), Concatenate, Wipe Securely (DoD/Zero/Random, with SSD/APFS warning) |
| Updates | Hexer ▸ Check for Updates…, daily automatic check (can be turned off, optional beta versions), skip a version, download with progress, Ed25519 signature and code signature verification, install on quit or Relaunch |
| Other | Settings (General/Format/View/Inspector/Export), About, Help, Acknowledgements, VoiceOver for the grid, universal build, English + Vietnamese (including error messages from the core) |
| Safety | Alerts for irreversible actions use destructive buttons, Return does not trigger them; the alert for opening a disk for writing defaults to "Open Read-only" |
| CLI | All commands in the plan: added `edit`, `split`, `concat`, `disks list/read`, `selftest`; crosscheck compares against split/cat/perl/diskutil/dd |
| macOS 27 UI | System sidebar and inspector run edge to edge; 3-group toolbar; uniform 36 pt glass bars (`GlassBarStyle.swift`); canvas redrawn to match the app (versions 14–17) |

## 5. Not done

| Item | Notes |
|---|---|
| Rename / reorder types in the Data Inspector | Settings only toggles for now. Planned: Phase 4. |
| Recent (raw) disks list | HxD has "recent disk images"; Hexer only has Open Recent for files. Need to check whether disk images enter that list. |
| `Scripts/snapshot.sh`, `Scripts/make_fixtures.sh` | Not created. Currently screenshots go through `-Hexer…` flags and crosscheck generates its own fixtures. |
| RAM/process editor | Deferred by the user's decision (needs `task_for_pid` / entitlement) |
| Dynamic glass-style app icon | Not possible without `actool` (Xcode) |

## 6. To improve (highest priority first)

1. **Telex tools that retype with Backspace (OpenKey, also Unikey/EVKey style):** in the decoded-text column in Overwrite mode, Telex sequences ("ex", "as", "aw"…) make the tool send Backspace and a new character; Backspace deletes a byte, so Hexer asks "Change the file size?". Typing Vietnamese in the text column is a stated feature, so consider treating that Backspace as part of the composition (e.g. step back without deleting while a typing run is open in Overwrite mode), or document it.
2. **CI (optional).** The repo is on GitHub. A macOS workflow could run `Scripts/test.sh` and `Scripts/crosscheck.sh`. Crosscheck needs its hardcoded path to `HxD64.exe` fixed (`HXD=` in the script; skip if the file is missing) and needs `hdiutil` for the disk part.
3. **Try on macOS 26.** macOS 15 was checked on a UTM VM (see session 3 in the log). macOS 26 has not been checked; you could create another UTM VM and use `Scripts/vm_test.sh` with the matching `VM_NAME`/`VM_HOST`.
4. **Test on real disks.**
   - The authopen prompt on an internal disk (needs the admin password) has not been tried.
   - The disk write path only has unit tests on attached disk images. Try on a real USB drive: write, unmount, compare with `dd`. `hexer-cli disks read diskN` (with sudo) helps a quick comparison.
5. **Find bar glass over the grid (light mode).** Grid text behind still shows faintly through the search field. Still readable, but less clear than dark mode. This is the system's `.glassEffect(.regular)`; adjust only if users find it hard to read.
6. **Folding undefined sections, what remains:**
   - Moving across a folded row with ↑/↓ makes the caret lose its column (it goes to the region's first byte).
   - Print does not fold.
   - There is no way to re-fold a single opened region, other than toggling View ▸ Fold Undefined Sections off and on. A "Fold Section" context menu could be added.
7. **Minimum width when the Checksums drawer is open:** about 1270 pt (English) and 1300 pt (Vietnamese), versus 1166 pt without the drawer. The remaining culprit may be the table or the drawer's segmented tab; measure by comparing `-HexerWindowSize 1100x700` with and without `-HexerDrawer checksums`.
8. **NSTableView reentrancy warning:** "Application performed a reentrant operation in its NSTableView delegate". Reproduced (2026-10-24), every time, on both arm64 and x86_64: `build/Hexer.app/Contents/MacOS/Hexer FILE -HexerWindowSize 1100x700 -HexerFind Hexer -HexerFindType text -HexerFindAll 1 -HexerDrawer searchResults -HexerQuit 1`. Suspect the Search Results table: `searchResultSelection` is set (and `onChange` changes the selection and scrolls the grid) while the table is updating after Find All.
9. **Segmented control role (SDK 27).** SwiftUI cannot yet set the `tabs` / `valueSelection` role of `NSSegmentedControl`. If strict HIG is needed, wrap AppKit for the drawer tabs.
10. **App signing.** Use `SIGN_IDENTITY` (Developer ID or a self-signed certificate) so Screen Recording permission is not lost after every build.
11. **Remaining localization gaps:** the errno description (`strerror`) in error messages is still English; numbers in strings use the system region format (e.g. "1,840" when only the language is switched to Vietnamese).
12. **Self-update, what remains:**
    - Not tried on the macOS 15 VM (the full flow was tried on macOS 27, see session 7 in the log). Try `-HexerUpdateCheck 1 -HexerUpdateInstall 1 -HexerUpdateRelaunch 1` with an app copy as in session 7.
    - A real install of 0.3.2 → 0.4.0 (via the GitHub API) or 0.4.0 → later (via the R2 manifest) has not been tried; only checked up to "0.4.0 is available" with the real manifest (session 9 in the log).
    - No update path for non-admin users when the app is in an admin's /Applications: it only reports the reason and opens the download page (Sparkle would ask for the admin password).
    - Leftover relaunch flag when the save dialog is cancelled (§3, "Self-update").
    - No delta updates; each update downloads the whole DMG (about 7 MB).
13. **Performance:** run `hexer-cli bench` and open a 6 GB sparse file (`mkfile -n 6g`) after major changes to Storage or HexGrid. Re-checked after adding folding (2026-10-24): a 6 GB file opens and jumps to the end normally.

## 7. Coding conventions

- **Read DESIGN.md before touching UI.** Liquid Glass is for controls only; sidebar, inspector, sheet and alert use the system's; glass bars are `GlassBar.height` (36) tall. After changing UI, update the canvas and DESIGN.md (procedure in DESIGN.md §10).
- **UI strings:** write them in English in `Text("…")` or `L("…")`, add the translation to `Scripts/l10n/vi.py`, then run `bundle.sh` to audit.
- **Pure logic** goes in HexerCore with swift-testing tests. If a matching CLI command exists, add a check to `crosscheck.sh`.
- **Every UI change** must be checked with real screenshots: light, dark, Vietnamese, and a narrow window of about 1024 pt. Use `-HexerSnapshot`.
- **Before reporting done:** run `Scripts/test.sh`, `Scripts/crosscheck.sh` and `Scripts/bundle.sh`; all must pass.
- Code comments are written in English, with the same density as the surrounding code.

## 8. Session log

Condensed: only work done, decisions and lessons that are still useful. How things work now is in §2–§3; for per-run details see `git log`.

- **Session 1–2 (2026-10-23):** analyzed HxD64.exe with REA (38 DFM forms), planned 10 phases, finished phases 1–9 and the phase 10 findings. Rebalanced the sidebar/inspector per HIG macOS 27 (system panes edge to edge, 3-group toolbar, 36 pt glass bars), redrew the canvas, fixed Settings, wrote DESIGN.md and HANDOFF.md.
- **Session 3 (2026-10-24):**
  - **Safety:** `NSAlert.addDestructiveButton` for every irreversible action; the alert for opening a disk for writing defaults to Open Read-only. Core errors translated to Vietnamese via `App/ErrorMessages.swift`.
  - **Folding undefined sections:** `RowMap` (with a test against a naive computation on random input); grid/caret/compare/inspector all go through it (see §3). A 6 GB sparse file opens normally.
  - **CLI:** added `edit`, `split`, `concat`, `disks`, `selftest`; crosscheck compares against `split`, `cat`, `perl`, `diskutil`, `dd`.
  - **Real light mode:** the "transparent toolbar" came only from the `-NSRequiresAquaSystemAppearance` flag; check light mode with real light mode. Find bar in a narrow window with Vietnamese: the capsule label is always one line, the search field shrinks to 90 pt.
  - **macOS 15:** lowered the deployment target; glass gathered into `barGlass`/`barGlassID`/`GlassGroup`. Checked on the UTM macOS 15.0 VM (`Scripts/vm_test.sh`): selftest, edit/save, `disks read` matches `dd`, all main windows. Fixed the window subtitle and the "edited" dot not showing. Accepted difference: in a narrow window the macOS 15 sidebar/inspector take up space.
  - **DMG, CI, release `v0.1`:** `make_dmg.sh` and the install guides; `ci.yml`, `release.yml`. CI failed `DiskEnumeratorTests` because the runner's disks have no `busProtocol` (test relaxed). The Gatekeeper dialog was not tried on the VM.
  - **README** (screenshots from the real app in `docs/images`; rebuild with `-HexerSnapshotShadow` then `sips -Z 1600`) and the **promo video** (see session 6). Lesson: `SCStream.startCapture` (async) hangs if the process is not running the `NSApplication` run loop; use the completion-handler version inside `nsapp.run()`.
  - **Window auto-expanding** when selecting a large block or opening the Checksums drawer: SwiftUI counted the ideal width of the status bar field, table columns and the "Expected result" field into the minimum size. Fixed (the field can shrink, `ViewThatFits`); the Checksums drawer still raises the minimum to about 1270 pt (§6).
- **Session 4 (2026-10-24):**
  - Opening the app without a file shows the Open panel immediately (§3).
  - **CI flake `AttachedImageTests.readWriteAndCloneOnARawDevice`:** `openFailed(code: 13)` (EACCES) right after the node became writable, seen only once on the runner, not reproducible on this machine. The test now opens via `AttachedImage.openRaw(writable:)` (retries EACCES/EPERM for 5 s, prints the retry count). **If the failure recurs, read the uid/gid/mode in the annotation before guessing further.** Product code unchanged.
  - **Release `v0.1.1`**; tag and release rules went into CLAUDE.md. Lesson: when writing a workflow-monitoring script, keep the Python part in a separate file, test it in the foreground, and stop on consecutive errors (a script with a syntax error once looped silently until the timeout).
  - **Release notes with a changes section:** `CHANGELOG.md`, `Scripts/release_notes.sh`, the `notes` job (ran for real at v0.2.0).
  - **First-run welcome screen** (DESIGN.md §6.9, canvas version 20; Help ▸ Welcome to Hexer to view again). Copy written with the `design:ux-copy` skill. The first version cost 25–40% CPU; moving the background to Core Animation and dropping interpolation in the illustrations brought it to 0–6% (§3).
- **Session 5 (2026-10-24):**
  - **`utm` MCP** installed in the venv `~/.local/share/mcp-utm` from the GitHub source (`neverprepared/mcp-utm`, commit `5f6bab5`), registered with `claude mcp add utm` (local scope). Must pin `mcp<2` (mcp 2.x removed `mcp.server.fastmcp`).
  - **macOS 15 VM:** checked the welcome screen in light/dark/Vietnamese, the flow at app launch and from the Help menu, keys and Accessibility. `Scripts/vm_test.sh` bundles the control tools. The VM has no Screen Recording, so the script captures the UTM window and crops to the Hexer frame (read via Accessibility); keys are sent with `CGEvent.postToPid`. Pitfalls: `screencapture` does not write to a file name starting with a dot; `/bin/sh` (bash 3.2) treats `'` inside `"${x:+…}"` as opening a string.
  - **Crash with Reduce Motion on (fixed):** SwiftUI animates on the render thread and resolves the `NSColor.dynamic` color; the default provider is MainActor so it trapped. Added `nonisolated` (§2 "Gotchas").
  - Welcome screen CPU: VM pages 1–4 are 7.3 / 5.3 / 1.8 / 0.7%; on this machine page 1 is 7–8%, higher than the 0–2% noted in §3 (cause unknown; suspect the "Hexer" decode row and the byte-flash timer).
  - **Release `v0.2.0`** (welcome screen).
- **Session 6 (2026-10-24):** a 120-second promo tour with synthesized music, driven through the app's own API (`DemoScript`). Replaced by the film and removed in session 11.
- **Session 7 (2026-10-25):**
  - **Self-update** (§3 "Self-update"). Hand-written instead of Sparkle (no Xcode; Sparkle needs an embedded framework/XPC and re-signing, may not work with ad-hoc signing, no Vietnamese). The user chose Ed25519 signing and added the `HEXER_UPDATE_KEY` secret. The real key was created with `hexer-cli update keygen`, put in the Keychain, never printed. Tested the full flow with an app copy with bundle ID `com.nongdandev.hexer.e2e`, version 0.2.9, its own test key, a 0.3.0 DMG signed with the test key, and a `file://` feed (check → download → verify → relaunch; Install on Quit; wrong signature rejected; unwritable folder shows Download…). The DMG is attached without checksum verification (`-noverify`) because the signature already covers the whole file.
  - **CI hung at the Unit tests step** (over 14 minutes): suspect `hdiutil attach` spawns a `diskimages-helper` that holds the pipe, so reading to EOF never finishes. Fix: `HexerPlatform/Subprocess.swift` waits for the process to exit (not for EOF), reads with `DispatchSourceRead` on an `O_NONBLOCK` fd, and stops after 120 s. `test.sh` has a time limit and reports on hangs (§2); test disk images interrupted midway stay attached; detach them with `hdiutil detach`.
  - **Version of local builds** comes from the latest tag (§2, `bundle.sh`); before, it wrote `0.1`, so the update window reported wrongly.
  - **Icon:** the app does not lose its icon; Launch Services keeps records of `com.nongdandev.hexer` at deleted paths (DMG mount point, `build/dmg`, temp folders) and sometimes picks one. Added `LaunchServicesRecords.forget` (`lsregister -u`) to `UpdateStaging`, `SoftwareUpdate`, `make_dmg.sh`. DMG volume icon: `hdiutil create -srcfolder` does not copy the custom-icon flag, so `make_dmg.sh` creates a UDRW image, `SetFile -a C`, then `convert`s to UDZO. The `.dmg` file's own icon is still generic (the extended attribute is lost when downloaded over HTTP).
  - **Releases `v0.3.0`, `v0.3.1`** (downloaded and checked checksum, signature, universal, `minos 15.0`). When the GitHub API quota ran out, CI was checked with the badge (`/actions/workflows/ci.yml/badge.svg?branch=main`) and release was awaited via the `.sig` download link (404 until posted); neither counts against the quota. A real 0.3.0 → 0.3.1 update has not been tried: copy the app from the 0.3.0 DMG to another folder, then run `-HexerUpdateCheck 1 -HexerUpdateInstall 1 -HexerUpdateRelaunch 1`.
- **Session 8 (2026-10-25):**
  - **Centering the dedicated windows:** the 5 Tools windows and Software Update were off because `center()` ran while the window was still size 0; Settings was off by 10 pt; Statistics first appeared at the bottom-left corner. Fixed with `NSWindow.centerAtContentSize()` (§2). Measured with `CGWindowListCopyWindowInfo`. DESIGN.md §2 item 9.
  - **Help ▸ Hexer Help** did not open because `showHelp:` clashes with `NSApplication` (renamed `showHexerHelp:`); the help window was once 2613 pt tall (now `sizingOptions = []`, 560 × 600).
  - **File had two Open Recent items:** AppKit inserts one itself; the hand-built one had no delegate and never showed files. Removed the hand-built item and two translation keys. Checked on the macOS 15 VM with AppleScript over SSH; running the app over SSH needs `open -n -W --stdout FILE …`. Canvas version 23.
  - **Release `v0.3.2`.**
- **Session 9 (2026-10-25/26):**
  - **Update channel independent of GitHub** (the user wanted to avoid rate limits and dependence on one platform; chose Cloudflare R2, a bridge release, temporary `r2.dev` domain, storing both manifest and DMG). `UpdateManifest`, `AWSSignatureV4`, `hexer-cli update manifest|download|upload`, `Scripts/publish_update.sh`, `HexerUpdateFeedURLs` (§2–§3). Removed the GitHub API reading from the app entirely.
  - Tested with a `file://` manifest (first URL broken, fake signature): checking → available → downloading via the second URL → failed "signature is not valid". `hexer-cli update download` with a fake key against the real S3: 403 `InvalidAccessKeyId`.
  - **Release `v0.4.0`:** the workflow passed on the first try. Verified: `update.json` on R2 has exactly one version with two `urls` (R2 then GitHub), the DMG on R2 matches the `.sha256` on GitHub, the signature is valid with the key in the app, the release page has `.dmg`, `.sha256`, `.sig`, `update.json`. A local build run with `-HexerUpdateFeed <R2> -HexerUpdateCheck 1` saw "Hexer 0.4.0 is available". For this kind of check, `-HexerQuit 1` must go with `-HexerSnapshot … -HexerSnapshotDelay 8`, otherwise the app quits before the check finishes.
- **Session 10 (2026-10-26):** compacted this file (session log condensed from ~220 to ~50 lines, two long table rows shortened) and translated HANDOFF.md, CLAUDE.md and DESIGN.md to English to save tokens in later sessions. The Vietnamese UI translations, the Vietnamese table in DESIGN.md §7 and the bilingual CHANGELOG format are unchanged. Error messages in `sign_update.sh` and `publish_update.sh` and the README now point to the English section names.
- **Session 11 (2026-10-25/26): the 30-second promo film** (the user asked for a new video under the rules in `VIDEO.md`, not reusing the old tour or its rules; background music; real interaction with the app; unhurried actions). Commands in the §2 table.
  - **Structure (96 BPM, a bar is 2.5 s, every cut on a beat):** 0–5 s tease (an extreme close-up of the Mach-O magic lit by a moving pool of light, the caret stepping on the beat; then the window drawn by rim light and a rush into the grid), 5–15 s drop (four 2.5 s shots, each a macro angle with the type plus a wider angle: typing "Patch" into the decoded text, Find All for `__TEXT`, an instruction and the inspector's disassembly, the histogram), 15–25 s hero (the dark window on black glass with "Liquid Glass.", the light window on a white stage, three windows for files, disks and firmware), 25–30 s icon and name. Type is SF Pro Heavy, 1–3 words a shot. The recordings always play at real speed; only the camera moves fast.
  - **Recording with real input:** mouse moves are minimum-jerk arcs at 120 Hz through the HID tap (0.6–1.15 s, a pause before each click); the take stops if the cursor is not where it was left, if Hexer is not frontmost, or if the window under a click is not Hexer's. Lessons:
    - The grid's text input only accepts keys from the HID tap; `postToPid` keys work for shortcuts and text fields. A Unicode string on the event stops menu key equivalents from matching.
    - **OpenKey runs on this machine** and rewrites HID typing ("__TEXT" became "__TẼT"), so keys go to the process (`Route.process`) except typing into the grid, which types a word Telex leaves alone ("Patch").
    - During a capture macOS adds a small purple "recording" window over the traffic lights of each captured window. It cannot be filtered out (excluding it from the `SCContentFilter` still draws it), it swallows clicks on the close button (close windows with ⌘W instead), and it shows up in AX window lists (filter windows under 60 pt tall). The edit covers it with patches from `screencapture -l` shots taken before recording (also of the Statistics window and of the inactive main window).
    - `hdiutil create` is not permitted from this sandboxed shell; the FAT16 sample volume is written by hand and attached with `-imagekey diskimage-class=CRawDiskImage`.
    - `AVAudioFile` only finishes the WAV header on `close()` (a global never deinitializes).
  - **Score:** all synthesized in `score.swift` (polyBLEP saws, TPT state-variable filters, Freeverb, ping-pong echo, kick sidechain): a drone and ticks with a riser and snare roll in the tease, four on the floor with a pumping bass and a sixteenth-note arpeggio (Dm B♭ F C), supersaw chords and a hook in the hero, one ringing chord for the title; whooshes, impacts, snaps, caret ticks and mouse/key clicks placed from `cues.json`. Measured: −1 dBFS peak, sections −22 (tease), −16.6 (drop), −14.6 (hero), −15.8 dB RMS (title); bands 20–60 / 60–250 / 250–2k / 2–6k / 6–20k Hz = −5.5 / −4.2 / −5.8 / −12.8 / −16.6 dB. **The user has not heard it yet**; tune levels and sounds in `score.swift` and rerun `make.sh` (no re-recording needed).
  - **Typing hex digits into the hex column did nothing** (found while filming, reproduced with System Events keystrokes, which take the keyboard's path; arrows and the text column worked). `HexCanvasView.inputContext` is `nil` in the hex column, so `interpretKeyEvents` sends text to the responder's one-argument `insertText(_:)`, which the canvas did not implement. Fixed by forwarding it to `insertText(_:replacementRange:)`; checked through System Events: "48" and "4865786572" overwrite 1 and 5 bytes, "g" is refused, Tab to the text column and "Hello" then Tab back and "ff" give 6 bytes. Earlier checks typed through the session API or `CGEvent.postToPid` (which never reaches the text input system), so they could not catch it. Released as v0.4.1.
  - Telex tools that retype with Backspace still interfere with the text column in Overwrite mode (§6 item 1).
  - **Removed the old tour toolkit** (the user's request): `Scripts/record_demo.swift`, `Scripts/make_promo.swift`, `Scripts/make_music.py`, `App/DemoScript.swift`, the `-HexerDemo`/`-HexerDemoFirmware` flags, the `.demoAnchor` modifiers in FindBar, InspectorView, ResultsDrawer and StatisticsView (with the invisible plot overlay), and `StatisticsWindowController.model` is private again. Its old output in `build/promo/` (not committed) was left in place.
  - **Commits and release `v0.4.1`** (the user's request): `bdaff68` hex typing, `430e420` toolkit removal, `fa0aeb8` the film (CI passed, run 40217399760), `608a05c` CHANGELOG, tagged `v0.4.1`. The Release workflow passed (run 40217752270). Verified: the release page has `.dmg`, `.sha256`, `.sig`, `update.json` and the notes; `update.json` on R2 lists 0.4.1 then 0.4.0, each with the R2 and GitHub URLs; the DMG downloaded from R2 matches the `.sha256`, and `hexer-cli update verify --app build/Hexer.app` says the signature is valid.
