# Hexer — UI design

This document describes Hexer's design as drawn on Claude Design and as implemented in the running app. When changing UI, update **all three**: source code, canvas, and this file.

- **Canvas (source of truth):** https://claude.ai/artifact/JBSgQBQpVLtMWto8QECZgb (version 25, 2026-10-26)
- **Platform:** designed for macOS 27 "Golden Gate" with Liquid Glass; runs on macOS 15 and later (see §11). SwiftUI + AppKit, no Xcode.
- **UI languages:** English (source keys) and Vietnamese
- **Technical handoff:** see [HANDOFF.md](HANDOFF.md)

## 1. Canvas artboards

| Artboard | Content | Main source |
|---|---|---|
| `Main.dc.html` (light) / `MainDark.dc.html` | Main window: sidebar, toolbar, hex grid, find bar, results drawer, status bar, Data Inspector. Interactive (switch drawer tabs, move the caret). | `Views/DocumentWindowView.swift`, `SidebarView.swift`, `InspectorView.swift`, `StatusBarView.swift`, `ResultsDrawer.swift`, `HexGrid/*` |
| `FindBar.dc.html` | Floating glass find bar, Replace row, options popover (Text/Hex/Integer/Float), 4 states | `Views/FindBar.swift`, `GlassBarStyle.swift` |
| `Sheets.dc.html` | Go to Offset, Select Block, Insert Bytes, Fill Selection, Filter Characters, Compare | `Views/Sheets/*`, `Views/Analysis/CompareViews.swift` |
| `Analysis.dc.html` | Generate Checksums sheet, Statistics window | `Views/Analysis/ChecksumViews.swift`, `StatisticsView.swift` |
| `CompareDisk.dc.html` | Two-window compare mode, read-only disk document with sector navigator | `CompareViews.swift`, `SectorNavigator.swift` |
| `Settings.dc.html` | Settings window, 5 panes (clickable) | `Views/SettingsWindowController.swift` |
| `MenusVI.dc.html` | Menu map + shortcuts; components in Vietnamese | `App/MainMenu.swift`, `Resources/Localization/vi.lproj` |
| `Tools.dc.html` | Open Disk (+ open-for-writing warning), Clone Disk, Split, Concatenate (running), Wipe Securely | `Views/Tools/DiskViews.swift`, `FileToolViews.swift` |
| `Compat.dc.html` | Find bar, Replace row and mode chip: glass (macOS 26 and later) next to material (macOS 15), in light and dark | `Views/GlassBarStyle.swift` |
| `Import.dc.html` | Intel Hex import document: Sections sidebar listing undefined regions, fold rows (normal and with caret), fold rules, View ▸ Fold Undefined Sections item | `HexGrid/HexCanvasView.swift`, `HexEditorView.swift`, `HexerCore/Layout/RowMap.swift` |
| `Welcome.dc.html` | First-launch welcome screen: 4 pages (Welcome, Edit, Find, Disks), when it shows, motion, keyboard and accessibility | `Views/Welcome/*` |
| `Update.dc.html` | Software Update window: update available, downloading, verifying, ready to install, up to date, error, cannot self-replace (dark, Vietnamese) | `Views/SoftwareUpdateView.swift`, `App/SoftwareUpdate.swift` |

Canvas layout: row 1 main window (light/dark) · row 2 search and sheets · row 3 analysis, compare, disks · row 4 Settings, menus, Vietnamese · row 5 file and disk tools, import data with folded regions · row 6 macOS 15 · row 7 first launch (welcome screen) and software update. Board order and positions are in `project/canvas.json`.

## 2. Principles (macOS 27 HIG, June 2026 edition)

Apple restored the Design Principles (Purpose, Agency, Responsibility, Familiarity, Flexibility, Simplicity, Craft, Delight). Applied to Hexer:

1. **System panes, flush with the window edge.** The sidebar is a `NavigationSplitView` with `List(.sidebar)`; the inspector is `.inspector(isPresented:)`. Both run flush to the window edge with content flowing behind them. Never draw the sidebar or inspector as floating glass cards. That is the macOS 26 style the first design wrongly used.
2. **Glass only for controls.** Liquid Glass is only for buttons, capsules and floating bars (find bar, compare capsule, sector navigator, mode chip). Never put glass over the hex grid, tables or status text. Error messages sit on standard material, not glass.
3. **Leave scroll-edge effects to the system.** Do not add `.soft` or decorative scroll-edge effects.
4. **Toolbar has at most 3 groups.** Every toolbar item is also in the menu bar.
5. **No important information at the bottom of the sidebar.**
6. **Sheets and alerts use standard system material.** Default button on the right; Return confirms, Esc cancels.
7. **Settings:** the window title is the name of the open pane; the window fits the pane content exactly.
8. **Safety first:** disks open read-only by default; the boot disk is locked; irreversible operations must say "(cannot be undone)".
9. **Standalone windows open centered on screen**, sized to their real content: tool windows (Open Disk, Clone Disk, Split, Concatenate, Wipe), Software Update, Settings, Hexer Help, Acknowledgements, About, the welcome screen; Statistics is centered the first time, then remembers its position. Windows with SwiftUI content call `NSWindow.centerAtContentSize()` instead of `center()`.

## 3. Tokens

### 3.1 Color

The canvas uses CSS variables. In the app, grid colors live in `HexTheme` (`HexGrid/HexTheme.swift`); everything else uses system colors.

| Token | Light | Dark | In the app |
|---|---|---|---|
| `--accent` | `#0A64D8` | `#4AA3FF` | `Color.accentColor` (follows system) |
| `--accent-soft` (selection in the focused column) | accent 16% | accent 28% | selection in `HexCanvasView` |
| `--accent-dim` (selection in the other column, caret background) | accent 8% | accent 13% | |
| `--ghost` (ghost caret, 1.5 pt border) | accent 55% | accent 70% | |
| `--offset` (offset column, hex digits) | `#0B47B8` | `#7CB9FF` | `HexTheme.offset` |
| `--odd` (odd byte group) | `#7A5652` | `#D1AAA3` | `HexTheme.oddColumn` |
| `--mod` (modified byte, bold) | `#D70015` | `#FF6B63` | `HexTheme.modified` |
| `--hit` (search result) | `#FFC400` 42% | `#FFD60A` 35% | `HexTheme.searchHit` |
| diff (difference when comparing) | `#FF9500` 30% | `#FF9F0A` 35% | `HexTheme.difference` |
| bookmark | system orange | system orange | `HexTheme.bookmark` |
| `--hdr` (column header row) | `#F7F7F9` | `#232326` (app: `#202023`) | `HexTheme.headerBackground` |
| undefined (empty regions when importing) | tertiary label | tertiary label | `HexTheme.undefined` |
| fold (background and text of fold rows) | quaternary system fill · secondary label | same as light | `HexTheme.foldBackground`, `HexTheme.foldText` |
| `--grid` | `#FFFFFF` | `#1B1B1D` | `textBackgroundColor` |
| `--fg` / `--fg2` / `--fg3` | `#1D1D1F` / `#5F5F66` / `#8E8E93` | `#F2F2F5` / `#A8A8AE` / `#77777D` | label / secondary / tertiary |
| `--pane` (sidebar, inspector) | `rgba(244,245,248,.9)` | `rgba(38,38,42,.92)` | drawn by the system |
| `--glass` | white 70% + blur 24 | `rgba(66,66,72,.6)` | `.glassEffect(.regular…)` |

Invalid values in the inspector (`Invalid`) use the regular font in tertiary color; valid values use the mono font.

### 3.2 Type

| Role | Style |
|---|---|
| Hex grid | SF Mono 13 pt (Settings ▸ Format allows 9–28 pt, SF Mono/Menlo/Monaco/Courier New); row height = line height + 5 |
| General content, form labels, buttons | SF Pro 13 |
| Inspector rows, results tables, status bar | 12 (inspector values: mono 12) |
| Group titles (sidebar, inspector, Sums/CRC/Digests columns) | 11 bold, secondary color |
| Captions, chips, shortcuts | 11 |
| Sheet title | headline (13 bold) |

### 3.3 Sizes and spacing

| Component | Value | Source |
|---|---|---|
| Sidebar | min 210 · ideal 240 · max 340 | `DocumentWindowView` |
| Inspector | min 260 · ideal 300 · max 420 | `DocumentWindowView` |
| Glass bar (find bar, compare, sector navigator capsules) | height **36**, corner radius 18, horizontal padding 16 | `GlassBar.height` |
| Icon button in a glass bar | 28 × 28 | `GlassBar.iconSize`, `GlassBarIconButton` |
| Find bar | anchored to the grid's top-right corner: top 34, trailing 16 | `DocumentWindowView` |
| Bottom overlays (compare capsule, sector navigator) | 16 above the grid bottom | |
| Results drawer | height 210 | |
| Status bar | height 30, horizontal padding 14 | `StatusBarView` |
| Sheet | padding 20, vertical spacing 16, min width 380 | `SheetScaffold` |
| Tool windows | padding 20; Open Disk width 680, other windows 600 | `FileToolViews`, `DiskViews` |
| Settings | pane width 520, height fits content (Inspector fixed at 520) | `SettingsWindowController` |
| Sheet buttons | regular control size (28 high on canvas, rounded) | |

## 4. Main window

```
┌─ Sidebar 240 ──┬──────────────── Content ───────────────────────┬─ Inspector 300 ──┐
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

- **On app launch:** if there is no document (no file opened with the app, no restored window), the app immediately shows the system Open panel, like TextEdit. Clicking the Dock icon when no window is left also shows this panel. The app never creates an empty window. Only on the **first** launch without a file does the welcome screen (§6.9) show instead of the Open panel.
- **Window size:** every new document window opens filling the visible frame of the screen it opens on (below the menu bar, beside the Dock); it is not full-screen mode. Sizes are not remembered between windows and there is no cascading. A window that joins a tab group takes the group's frame. Tile and Compare arrange windows afterwards as before.
- **Toolbar (3 groups):** navigation = Open, Save, Undo, Redo · principal = segmented Insert/Overwrite/Read-only (hidden while comparing) · primaryAction = Find, Go to Offset, Inspector. Title is the file name, subtitle is size and mode.
- **Sidebar:**
  - *Bookmarks:* orange dot, offset, shortcut ⌃0–9. When empty, shows a hint line (wraps).
  - *Sections:* regions that have data, with a caption.
  - *Document:* Size, Modified, Encoding, Layout. Only the Modified value is red, and only when nonzero.
- **Hex grid:**
  - Columns: offset (blue), hex split into byte groups (odd groups in `--odd`), decoded text.
  - Header row background `--hdr`; the column holding the caret is tinted in strong accent.
  - Modified bytes in bold red. The caret has an accent underline; the other column shows a ghost caret (outline).
  - An undefined region that fully covers 2 or more rows is folded into one row (see §6.5).
  - No glass in the grid.
- **Drawer:** 3 segmented tabs (an AppKit `NSSegmentedControl` with the macOS 27 `tabs` role, `Views/SegmentedTabs.swift`; the selected tab looks like the system's, as in the toolbar's mode picker). The header row has `minWidth: 0`, so opening the drawer never widens the window (the grid sets the minimum, 1166 pt). On the right, a secondary section:
  - Search Results: "159 matches" + Clear.
  - Checksums: "Expected result" field (240 pt, 140 pt when narrow, hidden when narrower) + Refresh.
  - Close button at the end.
  - Tables:
    - Results: Offset | Excerpt (hex) | Excerpt (text).
    - Checksums: # | Algorithm | Checksum | Usage.
    - Compare: list of differences, or "Not Comparing".
- **Status bar:** `Offset:`, `Block:` (`—` when no selection), `Length:` as `C (12)`, short encoding name, offset base, mode chip (glass with accent tint, clickable). When narrow, field values truncate in the middle (Block shrinks first) instead of widening the window; encoding and base hide first.
- **Inspector:**
  - Header "Data Inspector" + ⋯ menu (Hex, Choose Types… opens Settings ▸ Inspector).
  - Segmented Little/Big endian + Hex checkbox.
  - Groups: Integers, Characters, Floating point, Date & time, Other (GUID), Disassembly (x86-16/32/64, ARM64).
  - Rows follow the order and names set in Settings ▸ Inspector; the six group headings stay in fixed order. The "Step as" menu lists fixed-width types in the same order and with the same names.
  - Compact 12 pt rows. Double-click to edit; tooltip says "Double-click to edit".
  - Footer "Step as Int32 ▾" + 4 step buttons. No hidden button inside the pane (use the toolbar button).

## 5. Components

| Component | Rule |
|---|---|
| `GlassCapsuleButtonStyle` (`.glassCapsule`, `.glassCapsuleProminent`) | All text buttons on glass bars: height 36, padding 16, capsule. Prominent = accent tint, for the primary action (Find All, Replace All). |
| `GlassBarIconButton` | 28 × 28 icon button, borderless, always has `help` (tooltip) and an accessibility label. |
| Group capsule | Related buttons share one capsule (▲▼; Replace ⇄ + Close ✕). Use `GlassEffectContainer` + `glassEffectID` so the Replace row "grows" out of the Find row. |
| Segmented | Mode picker: toolbar size (a value selection). Drawer tabs: regular size, AppKit with the `tabs` role (`SegmentedTabs`), since they switch views. Inspector LE/BE: small. The `hex · dec · oct` base picker: small segmented; changing the base converts the entered value on the spot. |
| Number field (`NumberField`) | Mono font, round border, red text when not a valid number; the default button is disabled until valid. |
| `SheetScaffold` | Headline title → content as a grid with right-aligned labels → Cancel + default button at the right corner. |
| `ToolFooter` | Cancel + primary button. While running: 180 progress bar + % + Stop. Errors show as a sheet on that same window. |
| `FileField` | Path truncated in the middle on a quaternary background + Choose… button. |
| Alert | System alert. Short question-style message ("Open disk6 with write access?") + an explanation of the consequences. Buttons for irreversible actions (Write to Disk, Write Directly, Overwrite, Wipe and Delete, Open for Writing) use `addDestructiveButton` (`App/Alerts.swift`): red, never the default button, Return does not trigger them; Esc still cancels. |
| Table | System `NSTableView`/`Table`, alternating rows; offset column mono in `--offset` color. |
| Settings form | `Form.grouped`: switches and popups at the right edge; steppers placed inside `LabeledContent` so the value sits next to the ⇅ button; captions use `Section` footer. |

## 6. Screens and states

### 6.1 Find & Replace (⌘F, ⌥⌘F)
- **Find row:**
  - [🔍 search field 200 pt · "3 of 159" · data type button "Text ▾"]
  - When the grid is narrow (for example a 1024 pt window, Vietnamese), the search and replace fields shrink to a minimum of 90 pt. Labels inside the capsule (buttons, checkboxes) are always one line (`lineLimit(1)` + `fixedSize`), never wrapping past the capsule. The find bar is 16 pt from both grid edges.
  - [▲ ▼]
  - [Find All] (prominent)
  - [⇄ show Replace · ✕]
- **Replace row:** [☑ Prompt on replace] [⇄ replace field] [Replace] (glass) [Replace All] (prominent).
- **Options popover:**
  - Data type: Text / Hex / Integer / Float.
  - Text: Encoding "Editor (Windows-1252)" or "Unicode UTF-16 LE"; Case sensitive.
  - Hex: a note about ⌘E.
  - Integer: Bit width "(any)", Byte order, Sign Either/Signed/Unsigned.
  - Float: Single / Double / Real48 / Extended with byte counts; Byte order.
  - Direction All / Forward / Backward, with the note "“All” searches the whole file, wrapping around at the end."
- **States:**
  - Empty: placeholder changes with the data type; Find All disabled.
  - Bad pattern: red border + message on material.
  - Searching: spinner + Stop in the capsule; progress shown in the status bar.
  - Prompt on replace: alert "Replace this occurrence at …?", "Occurrence n of N.", buttons Replace / Skip / All / Cancel.

### 6.2 Sheets
- **Go to Offset (⌘L):**
  - Offset + hex/dec/oct.
  - Relative to: Beginning of the file / Current offset (+ or −) / End of the file (backwards).
  - "Destination: …" line.
  - Go button. Remembers base and origin between openings.
- **Select Block (⇧⌘A):** Start offset; popup End offset/Length + number field; Numbers in; line "N bytes" or "The block is empty or outside the file."
- **Insert Bytes (⇧⌘I):** Byte count + base; Fill pattern (repeated hex); a summary sentence of the result.
- **Fill Selection:**
  - Pass list (220 × 150), Add/Remove.
  - Presets: DoD Sanitizing, Zero Bytes.
  - "Pattern of pass n": Hex values, or Random bytes From/to (decimal).
  - "Write directly to disk (cannot be undone)", with a caption that changes with the choice.
- **Filter Characters (View):**
  - Options: All characters / ASCII only (20–7E) / Letters and digits / Custom byte ranges.
  - 16 × 16 preview table in the current encoding.
- **Compare (⌘K):**
  - 1. Data source (current file).
  - 2. Data source (popup + Open File…).
  - Windows: Side by side / One above the other.
  - Scope: Whole files / Selected data, with a caption.

### 6.3 Analysis
- **Generate Checksums (⇧⌘K):**
  - Three columns:
    - Sums: Checksum-8/16/32/64, Custom….
    - CRC: CRC-16, CRC-16/CCITT-FALSE, CRC-32, CRC-32C, Custom CRC….
    - Digests: MD2, MD4, MD5, SHA-1/256/384/512.
  - Custom opens options right below (width, polynomial, init, XOR, reflection).
  - Scope Whole file/Selection; "Compare with expected value" + input field; Calculate.
- **Statistics:**
  - Whole file/Selection, Hide maximum, "256 of 256 values present", Refresh.
  - 256-bar chart; click a bar to keep the selection.
  - "Selected value" panel: Character, Count, Share, Bytes, Entropy.

### 6.4 Compare and disks
- **Compare:**
  - Two windows side by side (or one above the other); the sidebar, inspector and mode picker are hidden to make room.
  - Differing bytes are orange.
  - Bottom capsule: "Difference at 104 · 3 bytes ▲ ▼ ✕"; F6 / ⇧F6.
  - The Compare drawer lists Offset | Length | data from each side.
- **Disk document:**
  - Title "disk4 — HEXER", subtitle "8.4 MB · Read-only"; the mode picker is locked to Read-only.
  - Sector navigator: ⏮ ‹ Sector [n] of N › ⏭.
  - Opening a disk image asks for the sector size (512 / 2048 / 4096).

### 6.5 Import data: folding undefined regions
- After importing Intel Hex/S-Record/ETL, the gaps between records are undefined regions (sidebar ▸ Sections).
- Rows lying entirely inside a region (from `RowMap.minimumFoldedRows` = 2 rows) fold into **one fold row**:
  - Offset column: the first hidden byte.
  - A `foldBackground` capsule spans the hex + text columns, label in a system font 2 pt smaller than the grid, color `foldText`: "▸  1,840 undefined bytes · Click to show".
  - It is not glass; it is grid content.
- Rows that contain defined bytes display normally, with the gaps shown as `??`.
- Click a fold row to expand that region. Go to Offset, Find, a bookmark or the sidebar leading into a folded region expands it automatically.
- ↑ ↓ and Page Up/Down follow the on-screen rows; on reaching a fold row the caret sits on its first hidden byte and the fold row gets a 2 pt accent outline; the next data row gets the caret back in the column it had before the fold row. Home/End do nothing on a fold row.
- View ▸ Fold Undefined Sections (on by default) toggles folding for the whole document; turning it back on re-folds regions that were expanded. Right-clicking inside an expanded region shows **Fold Section** at the top of the grid's context menu, which folds just that region.
- File ▸ Print folds the same rows (at the printed row width): one line per fold with its offset and "▸  1,808 undefined bytes". Export never folds.
- The two compare windows scroll by byte, so they stay aligned even when the two sides fold differently.

### 6.6 Settings (⌘,)
Tabs on the toolbar, each with an icon and label; the window title is the pane name.
- **General:**
  - Notifications: Warn when opening a disk with write access ✓; Confirm file size changes ✓; Tell me when copied text was filtered ✓; Tell me when selected characters were filtered ✗.
  - Safety: Open disks as read-only ✓; Keep a backup (.bak) when saving ✗; New documents open in = Overwrite.
  - Software Update: Check for updates automatically ✓; Include beta versions ✗; Last checked (date and time, or "Never") + Check Now button (opens the Software Update window). For builds that cannot update (run via `swift run`, missing key) this whole section is hidden.
- **Format:** Size (13 pt, stepper), Typeface (SF Mono).
- **View:**
  - Layout: Bytes per row 16, Fit to window width, Byte group size 1, Columns = Hex and Text.
  - Text and numbers: Text encoding = Windows (ANSI), Offset base = Hexadecimal, Lowercase hex digits.
  - Footer: "These defaults apply to newly opened documents…"
- **Inspector:** one section per category (Integers, Characters, Floating point, Date & time, Other, Disassembly); each row is the type's name (a renamed type shows its default name below it in caption/secondary), then a switch (all on by default) and a ⋯ menu, both centered on the row: Rename… (system alert with a text field; placeholder is the default name; empty = default name), Use Default Name, Move Up, Move Down (within the category only; also in the row's context menu and as VoiceOver actions). No drag to reorder: the grouped Form is not a table, so `.onMove` does nothing there. Last section: hint "Use a type’s ⋯ button to rename it or move it within its group." + Restore Defaults (resets order, names and shown types; disabled when nothing differs). Disassembly rows are listed by their short name (x86-16…), as in the inspector. Custom names are user text and are never translated.
- **Export:** Line break determined by (Bytes per line / Characters per line = 80); Motorola S-Record 32 bytes/line; Intel Hex 32 bytes/line.

### 6.7 Tools
- **Open Disk (⌥⌘O):**
  - Table Name | Type | Size | Hardware, grouped into Physical disks / Logical volumes. Icons: lock for the boot disk, disk, volume.
  - ☑ Open as read-only; Refresh button.
  - Caption about the administrator password.
  - Opening for writing shows an alert: **Open Read-only** (default, Return) / Open for Writing (destructive) / Cancel (Esc).
- **Clone Disk:** Source / Target (a disk or "Disk image file" + FileField); overwrite warning; the boot disk cannot be chosen as the target.
- **Split File:**
  - File, Part base name.
  - Part size: floppy / Zip / CD presets, or Custom.
  - Naming: .001 / ask for each name.
  - Line "Creates N parts."
- **Concatenate Files:** numbered list (drag to reorder), Add…/Remove/Clear, Output file.
- **Wipe Securely:** File; Method DoD 5220.22-M (3 passes) / Zero / Random; SSD/APFS warning; "Wipe and Delete" button + confirmation alert.

### 6.8 Menus and shortcuts
Menu order: Hexer · File · Edit · Search · View · Analysis · Tools · Window · Help. Hexer menu: About Hexer, Check for Updates…, Settings… (⌘,), Services, Hide/Show, Quit. Open Recent right after Open… is an AppKit item (AppKit inserts it and fills the list, with the system's Vietnamese strings); do not build this item yourself in `MainMenu.swift`. **Open Recent Disk Image** sits right after Open Disk Image… and is built in `MainMenu.swift` (`App/RecentDiskImagesMenu.swift`): HxD's separate history list of images opened with Open Disk Image, most recent first, at most 10, one entry per file, each with the sector size it was opened with. It lists file names (a name that appears twice gets " — folder"), then a separator and Clear Menu; with no entries only Clear Menu shows, disabled. An entry's tooltip shows its full path and sector size. Choosing one reopens the image fixed-size with that sector size, without asking; a file that is gone shows the usual "could not be opened" alert and leaves the list. Disk images never enter Open Recent; raw disks have no recent list (as in HxD). Wipe Securely removes the file from the list. Main shortcuts:

| Command | Key |
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

The full list is in `App/MainMenu.swift` and the `MenusVI` artboard.

### 6.9 Welcome screen (first launch)
- **When it shows:**
  - The first time the app opens with no document: shown instead of the Open panel. The `WelcomeShown` key in UserDefaults is set the moment the screen appears, so it shows only once.
  - Help ▸ Welcome to Hexer reopens it at any time.
  - Not shown when launched with a file or with `-Hexer…` flags (the key stays unset, so the next empty launch will show it).
- **Window:** 680 × 560 pt, fixed size, close button only; hidden title, transparent title bar, draggable by the background.
- **4 pages:**
  1. *Welcome:* app icon, "Welcome to Hexer", an intro sentence, and a hex row in a card: random bytes "lock in" one by one to `48 65 78 65 72`, the caret following, the word "Hexer" fading in in the text column.
  2. *Edit:* a 3-row mini grid; typing over "hello" turns it into "HEXER" (nibble by nibble, bold red like modified bytes), an Overwrite chip, then a ⌘Z key appears and undoes byte by byte.
  3. *Find:* a 4-row mini grid with 3 occurrences of `FF D8 FF`, a search capsule "1 of 3" and a Data Inspector card (Int8, UInt16, Int32); the current result moves from one to the next.
  4. *Disks:* a disk card "disk4 — HEXER" with a blue lock and a Read-only chip, 2 hex rows of a sector, a sector navigator capsule counting sectors.
  - Each feature page: 520 × 200 illustration, 26 pt bold title, 3 description lines at 14 pt with SF Symbols in the page color.
- **Page colors:** accent (Welcome), red `HexTheme.modified` (Edit), orange (Find), green (Disks). Used for the glow at the top (radial gradient 20%), symbols, page dots and the ripple on page change.
- **Bottom bar:** Skip (borderless, left; Esc) · page dots in the middle (current dot 22 pt long, click to jump to a page) · Back + Continue (prominent, Return), large size. Last page: no Skip, the primary button is "Open a File…".
- **Ending:** "Open a File…" always opens the Open panel. When the screen showed at app launch, Skip, Esc or the close button also lead to the Open panel (as in a launch without the welcome screen); when opened from the Help menu they only close it.
- **Motion:**
  - *Background:* a grid of hex bytes drifts upward slowly (6 pt/s), faded behind the content (an elliptical window-background overlay and one at the bottom), clearer at the edges. Occasionally a diagonal selection band sweeps across; a few bytes flash red as if just overwritten; on page change, a ring in the page color spreads from the center.
  - *Page change:* the old page fades, blurs and slides out; the new page slides in in the direction of travel (forward from the right, back from the left). Elements within the page rise in turn (fade in, shift up 18 pt, spring, 0.08 s delay per element).
  - *Illustrations:* change step by step like the editor when typing, no interpolation between steps (see HANDOFF.md, Architecture (§3), on performance).
- **Reduce Motion:** pages cross-fade, content appears immediately, the background stays still, illustrations keep one representative moment.
- **Keyboard:** Return = Continue/Open a File…, Esc = Skip (last page: close), ← → turn pages.
- **Glass:** only the small capsules inside illustrations (mimicking the find bar, chip, sector navigator) use `barGlass`; buttons are system buttons.

### 6.10 Software Update (Hexer ▸ Check for Updates…)
- **Window:** a regular window (titled, closable, not resizable), 520 pt wide, title "Software Update". Alert-like layout: 64 pt app icon on the left; on the right a bold message (`.headline`), secondary-color details, then a row of buttons at the right edge, the default button last (Return), the cancel button taking Esc. No glass (this is a window, not a floating control). Height fits the content of each state.
- **States:**

| State | Message | Buttons |
|---|---|---|
| Checking (only when the user clicked) | Checking for updates… + indeterminate progress bar | Cancel |
| Update available | Hexer X is available · You have version Y… · What's New box (list from CHANGELOG, max 150 pt then scrolls) + Release Notes on GitHub link | Skip This Version (left) · Remind Me Later · **Install Update** |
| Cannot self-replace (app is translocated) | as above + a warning line with a yellow triangle icon | Skip This Version · Remind Me Later · **Download…** (opens the release page) |
| Needs an administrator (the user can't write to the app or its folder, e.g. an administrator's Applications) | as "Update available" + a secondary line with a lock icon: "Installing in this folder needs an administrator’s name and password." | Skip This Version · Remind Me Later · **Install Update** |
| Downloading | Downloading Hexer X… + progress bar + "2.5 MB of 6.9 MB" | Cancel (returns to "Update available") |
| Verifying | Verifying Hexer X… + an explanatory sentence + indeterminate bar | Cancel |
| Ready | Hexer X is ready to install · Relaunch… or install on quit; when an administrator is needed, a lock line says Hexer asks for the password when it quits; if there are unsaved documents, add the line "Before quitting, Hexer asks whether to save your changes." | Install on Quit · **Relaunch** |
| Up to date | Hexer is up to date · Version X is the newest version available. | **OK** |
| Error | Couldn't check for updates / Couldn't install the update + error message (text selectable) | Open Download Page (for install-time errors) · **OK** |

- **Closing the window** = Remind Me Later; while downloading or verifying it cancels; once ready, the update is still installed on quit.
- **Relaunch** reviews unsaved documents like Quit; cancelling that review keeps Hexer running, with the update still staged for the next quit and no relaunch pending.
- **Administrator:** the password prompt is the system's (AppleScript `do shell script … with administrator privileges`, run in-process), shown while Hexer quits; cancelling it leaves the old version in place.
- **When it shows:** the automatic check never shows anything unless there is a new version; if the (modal) Open panel is open at that moment, it waits for the panel to close before showing. Check for Updates… and Check Now show every result, including skipped versions.
- **What's New** takes the "What's new" / "Có gì mới" section from the release notes (i.e. the version's entry in CHANGELOG.md), per the UI language; inline markdown (bold, code, links) is rendered.

## 7. Localization

- Keys are the English strings in `Text("…")`, `L("…")` and APIs that take `LocalizedStringKey`. Translations are in `Scripts/l10n/vi.py`, which generates `Resources/Localization/vi.lproj/Localizable.strings`.
- `Scripts/l10n_audit.swift` runs in `bundle.sh` and fails the build if any string is untranslated. The audit also covers the helpers `field(…)`, `fact(…)`, `group(…)`, `GlassBarIconButton(_, "…")`, the `placeholder:` parameter and both branches of `Text(condition ? "A" : "B")`. There are currently 705 keys, all translated.
- Errors from HexerCore/HexerPlatform (English; the CLI uses them verbatim) are translated in the app layer in `App/ErrorMessages.swift`; `AppDelegate.application(_:willPresentError:)` applies to every `presentError`, while `NSAlert(error:)` and the find bar's error label use `error.localizedForDisplay` / `error.displayMessage`. The errno description (`strerror`) goes through `L(…)` too: the 35 common ones ("Permission denied", "No space left on device"…) have translations in `vi.py` (section "System error descriptions"); rarer ones stay English.
- Numbers ("6,905,856 bytes") follow the system's **Region** setting (`Locale.current`), as Apple's apps do, not the UI language: a Mac set to Vietnamese language and the United States region shows "6,905,856"; with the Vietnam region "6.905.856". This is by design.
- Do not translate technical type names: Int32, UTF-8, GUID, FILETIME, x86-64, ARM64, Little-endian/Big-endian.
- Agreed translations (the Vietnamese column is data, keep as is):

| English | Vietnamese |
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

- Vietnamese strings are about 20–40% longer than English. Check for truncation with `-AppleLanguages '(vi)'`, especially in the toolbar, find bar, drawer tabs and Settings tabs.

## 8. Accessibility

- The hex grid supports VoiceOver (`HexCanvasView+Accessibility.swift`): reads offset, value and selection.
- Every icon-only button has `help` and an accessibility label. On the canvas these buttons use `aria-label`.
- Every command is reachable by keyboard: in a menu, with a shortcut; sheets use Return/Esc.
- Welcome screen: background and illustrations are hidden from VoiceOver; each page dot reads "Page 2 of 4"; respects Reduce Motion (§6.9).
- Color is never the only signal:
  - Modified bytes are both red and bold.
  - Pattern errors also show a message.
  - Locked disks have a lock icon.

## 9. Do and don't

| Do | Don't |
|---|---|
| Use system panes (sidebar, inspector), system sheets and alerts | Draw floating glass cards for the sidebar or inspector |
| Glass only on floating controls, a uniform 36 pt high | Glass over the grid, tables, status text; mixing 28/32/36 heights on one bar |
| Every toolbar command is in a menu and has a shortcut | Add a 4th toolbar group |
| Safe defaults (read-only, confirm before deleting or writing to disk) | Write to disk before the user clicks Save |
| Update the canvas and DESIGN.md together with the UI code | Let the canvas drift from the app |

## 10. Canvas editing workflow

1. Re-read the files on the artifact (`Artifact` action `read`, `path: project/<File>.dc.html`). The working copy lives in the scratchpad, for example `…/scratchpad/canvas/project/`.
2. Edit the `.dc.html` files under the same root directory. Format rules:
   - `{{hole}}` is only for looking up values.
   - Events are written as `onClick="{{fn}}"`.
   - `<sc-for>`/`<sc-if>` must have `hint-*`.
   - Logic goes in `class Component extends DCLogic` with `renderVals()`.
   - `data-props` is JSON in single quotes.
3. Publish once with `url`, `root`, `file_path`, and `files` for the remaining files. Send `canvas.json` only when adding, removing or resizing boards; re-read `canvas.json` before sending.
4. Do not verify the canvas by rendering or screenshotting it. Verify the real app with `-HexerSnapshot` (see HANDOFF.md, "Scripted app runs").

## 11. Running on macOS 15 (no Liquid Glass)

The app runs on macOS 15 Sequoia and later. Liquid Glass exists only from macOS 26, so every floating control goes through the helpers in `Views/GlassBarStyle.swift`. Never call `glassEffect`, `glassEffectID` or `GlassEffectContainer` directly.

| Helper | macOS 26 and later | macOS 15 |
|---|---|---|
| `.barGlass()` | `glassEffect(.regular.interactive(), in: .capsule)` | `.regularMaterial` capsule, `separator` border 0.5 pt, black shadow 12% (radius 6, offset down 2) |
| `.barGlass(tint:)` | tinted glass (prominent buttons, mode chip) | solid tint background (accent for Find All/Replace All, accent 18% for the chip) |
| `.barGlass(interactive: false)` | non-interactive glass ("Prompt on replace" checkbox) | same as `.barGlass()` |
| `.barGlassID(_:in:)` | `glassEffectID` (Replace row "grows" from the Find row) | does nothing |
| `GlassGroup(spacing:)` | `GlassEffectContainer` | content unchanged |

- Sizes, spacing and the 36 pt height are identical on both OS versions; only the material differs.
- Check the macOS 15 look on a new machine with the `-HexerNoGlass 1` flag. It changes only the glass; it does not emulate other macOS 15 differences (toolbar, sidebar, inspector are drawn by the system).
- Toolbar, sidebar, inspector, sheets and alerts are system-owned, so they follow each macOS version's look automatically.
