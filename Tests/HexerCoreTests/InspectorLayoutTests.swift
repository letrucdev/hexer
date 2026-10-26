import Foundation
import Testing
@testable import HexerCore

@Suite struct InspectorLayoutTests {
    @Test func defaultShowsEveryTypeInHxDOrder() {
        let layout = InspectorLayout()
        #expect(layout.order == InspectorType.allCases)
        #expect(layout.enabledTypes == InspectorType.allCases)
        #expect(layout.isDefault)
        #expect(InspectorLayout(storedOrder: nil, storedEnabled: nil, storedNames: nil) == layout)
        #expect(layout.types(in: .disassembly) == [.x86_16, .x86_32, .x86_64, .arm64])
    }

    @Test func legacyEnabledListIsHonored() {
        // Saved by versions before reordering: shown types only, in default order.
        let layout = InspectorLayout(storedOrder: nil, storedEnabled: ["int8", "int32", "guid", "x86_64"], storedNames: nil)
        #expect(layout.enabledTypes == [.int8, .int32, .guid, .x86_64])
        #expect(layout.order == InspectorType.allCases)
        #expect(!layout.isEnabled(.uint8))
    }

    @Test func legacyListOrderIsUsedWithinCategories() {
        let layout = InspectorLayout(storedOrder: nil, storedEnabled: ["guid", "int32", "int8"], storedNames: nil)
        #expect(layout.enabledTypes == [.int32, .int8, .guid])
        // Hidden types keep their default neighbours: uint8 follows int8, int32's successor follows int32.
        let ints = layout.types(in: .integers)
        #expect(ints.firstIndex(of: .uint32)! == ints.firstIndex(of: .int32)! + 1)
        #expect(ints.firstIndex(of: .uint8)! == ints.firstIndex(of: .int8)! + 1)
    }

    @Test func unknownRawValuesAndDuplicatesAreIgnored() {
        let layout = InspectorLayout(storedOrder: ["float64", "bogus", "float32", "float64"],
                                     storedEnabled: ["float32", "nope"], storedNames: ["nope": "X", "guid": "Id"])
        #expect(layout.types(in: .floatingPoint) == [.float64, .float32])
        #expect(Set(layout.enabledTypes).isSubset(of: Set(InspectorType.allCases)))
        #expect(layout.isEnabled(.float32) && !layout.isEnabled(.float64))
        #expect(layout.storedNames == ["guid": "Id"])
        #expect(layout.order.count == InspectorType.allCases.count)
        #expect(Set(layout.order) == Set(InspectorType.allCases))
    }

    @Test func typesMissingFromStoredOrderTakeTheirDefaultPlaceAndShow() {
        // A stored order from a version without uint16 and arm64 (as if they were added later).
        var stored = InspectorType.allCases.filter { $0 != .uint16 && $0 != .arm64 }.map(\.rawValue)
        stored.swapAt(stored.firstIndex(of: "int8")!, stored.firstIndex(of: "binary")!)
        let enabled = ["int8", "int16"]
        let layout = InspectorLayout(storedOrder: stored, storedEnabled: enabled, storedNames: nil)
        let ints = layout.types(in: .integers)
        #expect(ints.prefix(5) == [.int8, .binary, .uint8, .int16, .uint16])
        #expect(layout.types(in: .disassembly).last == .arm64)
        #expect(layout.enabledTypes == [.int8, .int16, .uint16, .arm64])
    }

    @Test func missingTypeWithoutPredecessorGoesFirst() {
        let order = InspectorLayout.merged([.wideChar, .utf8CodePoint])
        #expect(order.filter { $0.category == .characters } == [.ansiChar, .wideChar, .utf8CodePoint])
        let reversed = InspectorLayout.merged([.utf8CodePoint, .ansiChar])
        #expect(reversed.filter { $0.category == .characters } == [.utf8CodePoint, .ansiChar, .wideChar])
    }

    @Test func movesStayWithinCategory() {
        var layout = InspectorLayout()
        #expect(!layout.canMove(.binary, by: -1))
        #expect(layout.canMove(.binary, by: 1))
        #expect(!layout.canMove(.uleb128, by: 1))  // last integer: the next row is a character type
        layout.move(.uleb128, by: 1)
        #expect(layout.isDefault)
        layout.move(.uint64, by: -1)
        #expect(layout.types(in: .integers).suffix(4) == [.uint64, .int64, .sleb128, .uleb128])
        layout.move(.arm64, by: -10)
        #expect(layout.types(in: .disassembly) == [.arm64, .x86_16, .x86_32, .x86_64])
        #expect(layout.types(in: .characters) == [.ansiChar, .wideChar, .utf8CodePoint])
        #expect(layout.order.count == InspectorType.allCases.count)
    }

    @Test func dragMovesFollowOnMoveSemantics() {
        var layout = InspectorLayout()
        // Drag x86-16 to the end (destination = count).
        layout.move(in: .disassembly, fromOffsets: IndexSet(integer: 0), toOffset: 4)
        #expect(layout.types(in: .disassembly) == [.x86_32, .x86_64, .arm64, .x86_16])
        // Drag rows 1 and 3 before row 0.
        layout.move(in: .disassembly, fromOffsets: IndexSet([1, 3]), toOffset: 0)
        #expect(layout.types(in: .disassembly) == [.x86_64, .x86_16, .x86_32, .arm64])
        // Out-of-range offsets change nothing.
        let before = layout
        layout.move(in: .disassembly, fromOffsets: IndexSet(integer: 9), toOffset: 0)
        #expect(layout == before)
    }

    @Test func namesAreTrimmedAndBlankRestoresDefault() {
        var layout = InspectorLayout()
        layout.rename(.int32, to: "  Length ")
        #expect(layout.customName(for: .int32) == "Length")
        #expect(!layout.isDefault)
        layout.rename(.int32, to: "   ")
        #expect(layout.customName(for: .int32) == nil)
        layout.rename(.guid, to: "CLSID")
        layout.rename(.guid, to: nil)
        #expect(layout.isDefault)
    }

    @Test func roundTripsThroughStoredValues() {
        var layout = InspectorLayout()
        layout.move(.float64, by: -1)
        layout.move(.guid, by: 1)
        layout.setEnabled(.binary, false)
        layout.setEnabled(.x86_16, false)
        layout.rename(.x86_64, to: "amd64")
        layout.rename(.uint32, to: "Magic")
        let restored = InspectorLayout(storedOrder: layout.storedOrder, storedEnabled: layout.storedEnabled,
                                       storedNames: layout.storedNames)
        #expect(restored == layout)
        #expect(layout.storedEnabled.first == "int8")
        #expect(layout.storedOrder.firstIndex(of: "float64")! < layout.storedOrder.firstIndex(of: "float32")!)
        #expect(layout.storedNames == ["x86_64": "amd64", "uint32": "Magic"])
    }

    @Test func storedEnabledListWorksForEarlierVersions() {
        // Earlier versions group the stored list by category and keep its order inside each.
        var layout = InspectorLayout()
        layout.move(.uint8, by: -2)
        layout.setEnabled(.int8, false)
        #expect(layout.storedEnabled.prefix(3) == ["uint8", "binary", "int16"])
    }
}
