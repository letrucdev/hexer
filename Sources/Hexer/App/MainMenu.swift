import AppKit
import HexerCore

/// Builds the menu bar in code (there are no nibs without Xcode).
///
/// Items have no target, so the responder chain routes them: the grid handles editing, the
/// window controller handles view options, documents handle saving.
enum MainMenu {
    private static func item(_ title: String, _ action: String?, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: L(title), action: action.map { Selector($0) }, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.tag = tag
        return item
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let top = NSMenuItem(title: L(title), action: nil, keyEquivalent: "")
        let m = NSMenu(title: L(title))
        items.forEach(m.addItem)
        top.submenu = m
        return top
    }

    private static func sub(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem { menu(title, items) }

    private static var sep: NSMenuItem { .separator() }

    private static func fkey(_ code: Int) -> String { String(Character(UnicodeScalar(code)!)) }

    static func build() -> NSMenu {
        let main = NSMenu()
        let appName = "Hexer"

        let services = NSMenu()
        let servicesItem = NSMenuItem(title: L("Services"), action: nil, keyEquivalent: "")
        servicesItem.submenu = services
        NSApp.servicesMenu = services
        let appMenu = menu(appName, [
            NSMenuItem(title: L("About %@", appName), action: #selector(AppDelegate.showAbout(_:)), keyEquivalent: ""),
            sep,
            item("Settings…", "showSettingsWindow:", ","),
            sep,
            servicesItem,
            sep,
            NSMenuItem(title: L("Hide %@", appName), action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"),
            item("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
            item("Show All", "unhideAllApplications:"),
            sep,
            NSMenuItem(title: L("Quit %@", appName), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"),
        ])

        let recent = item("Open Recent", nil)
        let recentMenu = NSMenu(title: L("Open Recent"))
        recentMenu.addItem(item("Clear Menu", "clearRecentDocuments:"))
        recent.submenu = recentMenu

        let fileMenu = menu("File", [
            item("New", "newDocument:", "n"),
            item("Open…", "openDocument:", "o"),
            item("Open Disk…", "openDisk:", "o", [.command, .option]),
            item("Open Disk Image…", "openDiskImage:"),
            recent,
            sep,
            item("Close", "performClose:", "w"),
            item("Close All", "closeAllDocuments:", "w", [.command, .option]),
            item("Save", "saveDocument:", "s"),
            item("Save As…", "saveDocumentAs:", "s", [.command, .shift]),
            item("Save All", "saveAllDocuments:", "s", [.command, .option]),
            item("Save Selection As…", "saveSelectionAs:"),
            item("Reload from Disk", "reloadFromDisk:", "r"),
            sep,
            sub("Import", [
                item("Intel Hex…", "importIntelHex:"),
                item("Motorola S-Record…", "importSRecord:"),
                item("ETL Extended…", "importETLExtended:"),
            ]),
            sub("Export", exportItems(action: "exportAs:")),
            sep,
            item("Page Setup…", "runPageLayout:", "p", [.command, .shift]),
            item("Print…", "printDocument:", "p"),
        ])

        let editMenu = menu("Edit", [
            item("Undo", "undo:", "z"),
            item("Redo", "redo:", "z", [.command, .shift]),
            sep,
            item("Cut", "cut:", "x"),
            item("Copy", "copy:", "c"),
            sub("Copy As", exportItems(action: "copyAs:", sourceCodeAndFormattedOnly: true)),
            item("Copy Offset", "copyOffset:", "c", [.command, .option]),
            item("Paste Insert", "paste:", "v"),
            item("Paste Overwrite", "pasteOverwrite:", "b"),
            item("Delete", "delete:", fkey(NSBackspaceCharacter), []),
            sep,
            item("Insert Bytes…", "insertBytes:", "i", [.command, .shift]),
            item("Fill Selection…", "fillSelection:"),
            sep,
            item("Select All", "selectAll:", "a"),
            item("Select Block…", "selectBlock:", "a", [.command, .shift]),
            sep,
            item("Insert Mode", "setEditMode:", tag: 0),
            item("Overwrite Mode", "setEditMode:", tag: 1),
            item("Read-only", "setEditMode:", tag: 2),
            item("Toggle Insert/Overwrite", "toggleInsertMode:", "i"),
        ])

        var setBookmarks: [NSMenuItem] = []
        var goBookmarks: [NSMenuItem] = []
        for n in 0...9 {
            setBookmarks.append(item(L("Bookmark %lld", n), "setBookmark:", "\(n)", [.control, .shift], tag: n))
            goBookmarks.append(item(L("Bookmark %lld", n), "goToBookmark:", "\(n)", [.control], tag: n))
        }
        let searchMenu = menu("Search", [
            item("Find…", "showFind:", "f"),
            item("Replace…", "showReplace:", "f", [.command, .option]),
            item("Find Next", "findNext:", "g"),
            item("Find Previous", "findPrevious:", "g", [.command, .shift]),
            item("Use Selection for Find", "useSelectionForFind:", "e"),
            sep,
            item("Go to Offset…", "goToOffset:", "l"),
            sep,
            sub("Set Bookmark", setBookmarks),
            sub("Go to Bookmark", goBookmarks),
        ])

        let bytesPerRow = [8, 16, 24, 32, 48, 64, 128, 256, 512, 1024, 4096].map { item("\($0)", "setBytesPerRow:", tag: $0) }
            + [sep, item("Custom…", "setBytesPerRow:", tag: 0)]
        let viewMenu = menu("View", [
            item("Show Sidebar", "toggleSidebar:", "s", [.command, .control]),
            item("Show Inspector", "toggleInspector:", "i", [.command, .option]),
            item("Search Results", "showDrawerPane:", "1", [.command, .option], tag: 0),
            item("Checksums", "showDrawerPane:", "2", [.command, .option], tag: 1),
            item("Compare", "showDrawerPane:", "3", [.command, .option], tag: 2),
            sep,
            sub("Bytes per Row", bytesPerRow),
            item("Fit to Window Width", "toggleFitToWidth:"),
            sub("Byte Group Size", [1, 2, 4, 8, 16].map { item("\($0)", "setGroupSize:", tag: $0) }),
            sub("Columns", [
                item("Hex and Text", "setVisibleColumns:", tag: 0),
                item("Hex Only", "setVisibleColumns:", tag: 1),
                item("Text Only", "setVisibleColumns:", tag: 2),
            ]),
            sub("Offset Base", [
                item("Hexadecimal", "setOffsetBase:", tag: 16),
                item("Decimal", "setOffsetBase:", tag: 10),
                item("Octal", "setOffsetBase:", tag: 8),
            ]),
            sub("Text Encoding", TextEncoding.allCases.enumerated().map { i, e in item(e.displayName, "setTextEncoding:", tag: i) }),
            item("Lowercase Hex Digits", "toggleLowercaseHex:"),
            item("Filter Characters…", "filterCharacters:"),
            item("Fold Undefined Sections", "toggleFoldUndefinedSections:"),
            sep,
            item("Enter Full Screen", "toggleFullScreen:", "f", [.command, .control]),
        ])

        let analysisMenu = menu("Analysis", [
            item("Statistics", "showStatistics:"),
            item("Checksums…", "generateChecksums:", "k", [.command, .shift]),
            sep,
            item("Compare…", "compareDocuments:", "k"),
            item("Next Difference", "nextDifference:", fkey(NSF6FunctionKey), []),
            item("Previous Difference", "previousDifference:", fkey(NSF6FunctionKey), [.shift]),
        ])

        let toolsMenu = menu("Tools", [
            item("Concatenate Files…", "concatenateFiles:"),
            item("Split File…", "splitFile:"),
            item("Wipe Securely…", "wipeFile:"),
            sep,
            item("Clone Disk…", "cloneDisk:"),
        ])

        var tabItems: [NSMenuItem] = []
        for n in 1...9 { tabItems.append(item(L("Tab %lld", n), "selectTabByNumber:", "\(n)", tag: n - 1)) }
        let windowMenu = menu("Window", [
            item("Minimize", "performMiniaturize:", "m"),
            item("Zoom", "performZoom:"),
            sep,
            item("Tile Vertically", "tileWindows:", tag: 0),
            item("Tile Horizontally", "tileWindows:", tag: 1),
            sep,
        ] + tabItems + [
            sep,
            item("Bring All to Front", "arrangeInFront:"),
        ])
        NSApp.windowsMenu = windowMenu.submenu

        let helpMenu = menu("Help", [
            item("Hexer Help", "showHelp:", "?"),
            item("Acknowledgements", "showAcknowledgements:"),
        ])
        NSApp.helpMenu = helpMenu.submenu

        [appMenu, fileMenu, editMenu, searchMenu, viewMenu, analysisMenu, toolsMenu, windowMenu, helpMenu].forEach(main.addItem)
        return main
    }

    /// Export formats in HxD's order; Copy As omits the raw/hex/record formats.
    static func exportItems(action: String, sourceCodeAndFormattedOnly: Bool = false) -> [NSMenuItem] {
        let formats: [(String, Int)] = [
            ("Raw Data", 1), ("Hexadecimal Values", 2), ("Decoded Text", 3), ("-", 0),
            ("Pascal", 10), ("C", 11), ("C#", 12), ("Java", 13), ("Visual Basic .NET", 14), ("PureBasic", 15), ("-", 0),
            ("Editor View", 20), ("HTML", 21), ("Rich Text", 22), ("TeX", 23), ("-", 0),
            ("Motorola S19", 30), ("Motorola S28", 31), ("Motorola S37", 32),
            ("Intel Hex (16-bit)", 33), ("Intel Hex (20-bit)", 34), ("Intel Hex (32-bit)", 35),
        ]
        var out: [NSMenuItem] = []
        for (title, tag) in formats {
            if sourceCodeAndFormattedOnly && (tag < 10 && tag != 0 || tag >= 30) { continue }
            if title == "-" {
                if out.last?.isSeparatorItem == false { out.append(.separator()) }
            } else {
                out.append(item(title, action, tag: tag))
            }
        }
        if out.last?.isSeparatorItem == true { out.removeLast() }
        return out
    }

    static func contextMenu() -> NSMenu {
        let m = NSMenu()
        [item("Cut", "cut:"), item("Copy", "copy:"), sub("Copy As", exportItems(action: "copyAs:", sourceCodeAndFormattedOnly: true)),
         item("Copy Offset", "copyOffset:"), item("Paste Insert", "paste:"), item("Paste Overwrite", "pasteOverwrite:"),
         item("Delete", "delete:"), sep, item("Fill Selection…", "fillSelection:"), item("Select All", "selectAll:"),
         item("Select Block…", "selectBlock:")].forEach(m.addItem)
        return m
    }
}
