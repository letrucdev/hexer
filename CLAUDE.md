# Hexer

Hex editor for macOS 27, written in SwiftUI + AppKit with Liquid Glass. Goal: feature parity with HxD 2.5. The UI ships in English and Vietnamese.

## Read first
- **[HANDOFF.md](HANDOFF.md):** read when starting a new task. Holds status, architecture, what is not done, what to improve, and the session log.
- **[DESIGN.md](DESIGN.md):** read before changing any UI. The source canvas is at https://claude.ai/artifact/JBSgQBQpVLtMWto8QECZgb.
- These docs are written in English to save tokens; keep them in English.

## Build and checks (no Xcode, Command Line Tools only)
- `Scripts/bundle.sh` builds `build/Hexer.app`. The build fails if any UI string lacks a Vietnamese translation.
- `Scripts/test.sh` runs swift-testing (no XCTest).
- `Scripts/crosscheck.sh` compares `hexer-cli` against system tools.
- All three must pass before reporting done.

## Rules
- **No `@State`**: the CLT lack SwiftUIMacros. Use an `@Observable` model + `@Bindable`.
- **New UI strings:** write the English key in `Text("…")` or `L("…")`, then add the translation to `Scripts/l10n/vi.py`.
- **Put code in the right layer:** pure logic goes in `HexerCore` and needs tests; disk access goes in `HexerPlatform`; the app lives in `Sources/Hexer` and runs on the MainActor by default.
- **UI follows the macOS 27 HIG:**
  - Sidebar, inspector, sheets and alerts are the system's.
  - Liquid Glass only for floating controls, `GlassBar.height` (36) tall.
  - At most 3 toolbar groups.
- **After changing UI**, update the canvas and DESIGN.md too.
- **Verify UI with screenshots of the real app:**
  - Use `-HexerSnapshot` and the other `-Hexer…` flags; every flag must be followed by a value.
  - Check light, dark, Vietnamese (`-AppleLanguages '(vi)'`) and a narrow window.
  - Capture by window only (`screencapture -l`), never a screen region.
- **Disks:** read-only by default; never write to the boot disk; never use `authopen -w`.
- **Git:** repo `letrucdev/hexer`, branch `main`. Commit, push or tag only when the user asks.
- **Releases:** pushing to `main` does not release; only pushing a version tag does (`.github/workflows/release.yml`).
  - Tags are `vX.Y.Z`, e.g. `v0.1.1`. Bug fixes and small changes bump Z. New features bump Y and reset Z to 0. Big changes bump X.
  - Pre-releases add `-beta.N`, e.g. `v0.2.0-beta.1`; the workflow marks them as pre-release.
  - **Every release must say what changed.** Before tagging, add a `## X.Y.Z — YYYY-MM-DD` section at the top of `CHANGELOG.md` with `### What's new` (English) and `### Có gì mới` (Vietnamese).
    - Write for users: what looks different when using the app. Don't copy commit titles; skip changes that only touch tests, CI or docs.
    - The section opens the GitHub release notes. Preview with `Scripts/release_notes.sh X.Y.Z vPREVIOUS`.
    - Without the section the Release workflow stops at the `notes` job, before tests or build.
  - Use an annotated tag with message `Hexer X.Y.Z`. Commit and push `CHANGELOG.md` to `main` first, then tag that commit: `git tag -a v0.1.1 -m "Hexer 0.1.1" <commit> && git push origin v0.1.1`.
    - CI for the code must already be green. A commit touching only `.md` files doesn't run CI; the Release workflow reruns all of CI itself.
  - Don't edit `CFBundleShortVersionString` by hand: the workflow takes the version from the tag. Local builds use the latest `v*` tag (`Scripts/bundle.sh`).
  - **Self-update:** the workflow signs the DMG with secret `HEXER_UPDATE_KEY` (Ed25519 key, original in this machine's Keychain; see HANDOFF.md, "Update signing key"), then uploads the DMG and `update.json` to the update server (Cloudflare R2 bucket via the S3 API; secrets `UPDATE_S3_URL`, `UPDATE_S3_ACCESS_KEY_ID`, `UPDATE_S3_SECRET_ACCESS_KEY`; see HANDOFF.md, "Update server") with `Scripts/publish_update.sh`; a missing secret stops the workflow at the `notes` job. The app reads `update.json` from the addresses in `HexerUpdateFeedURLs` in `Resources/Info.plist`, in order: update server first, the copy on the GitHub Release second. Never change `HexerUpdatePublicKey` in `Resources/Info.plist`: installed copies trust only that key, and changing it stops them from updating.
  - After pushing a tag, watch the Release workflow until it finishes (about 7 minutes). Then check that `update.json` on the update server lists the new version, and that the release page has `Hexer-X.Y.Z.dmg`, `Hexer-X.Y.Z.dmg.sha256`, `Hexer-X.Y.Z.dmg.sig`, `update.json` and the version's change notes.
- **End of every session:** update HANDOFF.md (done, not done, log).
