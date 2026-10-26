import Foundation

/// Which data inspector types are shown, in which order, and under which names (Settings ▸
/// Inspector). Types are ordered only within their category; the categories keep a fixed order.
///
/// Stored as three preference values: the enabled types (`InspectorTypes`, the list earlier
/// versions saved), the order of every type (`InspectorTypeOrder`) and custom names
/// (`InspectorTypeNames`). Reading tolerates anything: unknown raw values are ignored, and types
/// missing from a stored order (added by a later version) take their default position and are
/// shown.
public struct InspectorLayout: Equatable, Sendable {
    /// Every type, grouped by category in `InspectorType.Category.allCases` order.
    public private(set) var order: [InspectorType]
    public private(set) var enabled: Set<InspectorType>
    /// Custom names, trimmed and never empty.
    public private(set) var names: [InspectorType: String]

    /// HxD's order with every type shown under its default name.
    public static let defaultOrder: [InspectorType] = InspectorType.Category.allCases.flatMap { category in
        InspectorType.allCases.filter { $0.category == category }
    }

    public init() {
        order = Self.defaultOrder
        enabled = Set(InspectorType.allCases)
        names = [:]
    }

    /// Restores a layout from stored values; nil means the value was never saved.
    /// - Parameters:
    ///   - storedOrder: raw values of every type, in the user's order.
    ///   - storedEnabled: raw values of the shown types. Without `storedOrder` (as saved by earlier
    ///     versions) its order is used as the order, and the types missing from it are hidden.
    ///   - storedNames: custom names by raw value.
    public init(storedOrder: [String]?, storedEnabled: [String]?, storedNames: [String: String]?) {
        let known = storedOrder.map { $0.compactMap(InspectorType.init(rawValue:)) }
        let enabledList = storedEnabled.map { $0.compactMap(InspectorType.init(rawValue:)) }
        order = Self.merged(known ?? enabledList ?? [])
        if let enabledList {
            // Types the stored order doesn't know were added later: show them, as by default.
            let unknown = known.map { k in InspectorType.allCases.filter { !k.contains($0) } } ?? []
            enabled = Set(enabledList).union(unknown)
        } else {
            enabled = Set(InspectorType.allCases)
        }
        names = [:]
        for (raw, name) in storedNames ?? [:] {
            if let type = InspectorType(rawValue: raw) { rename(type, to: name) }
        }
    }

    /// `stored` (possibly partial, possibly with duplicates) as a full order: types keep their
    /// stored order inside their category; a missing type goes right after the nearest type that
    /// precedes it by default, or first in its category when none does.
    static func merged(_ stored: [InspectorType]) -> [InspectorType] {
        InspectorType.Category.allCases.flatMap { category -> [InspectorType] in
            var result: [InspectorType] = []
            for type in stored where type.category == category && !result.contains(type) { result.append(type) }
            let defaults = defaultOrder.filter { $0.category == category }
            for (i, type) in defaults.enumerated() where !result.contains(type) {
                let predecessor = defaults[..<i].reversed().first { result.contains($0) }
                let at = predecessor.flatMap { p in result.firstIndex(of: p).map { $0 + 1 } } ?? 0
                result.insert(type, at: at)
            }
            return result
        }
    }

    // MARK: Queries

    /// The shown types, in order.
    public var enabledTypes: [InspectorType] { order.filter(enabled.contains) }

    /// Every type of `category`, in order.
    public func types(in category: InspectorType.Category) -> [InspectorType] {
        order.filter { $0.category == category }
    }

    public func isEnabled(_ type: InspectorType) -> Bool { enabled.contains(type) }

    /// The user's name for `type`, or nil to use its default (localized) name.
    public func customName(for type: InspectorType) -> String? { names[type] }

    public var isDefault: Bool { self == InspectorLayout() }

    // MARK: Changes

    public mutating func setEnabled(_ type: InspectorType, _ on: Bool) {
        if on { enabled.insert(type) } else { enabled.remove(type) }
    }

    /// Sets a custom name; an empty or blank name (or nil) restores the default name.
    public mutating func rename(_ type: InspectorType, to name: String?) {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        names[type] = trimmed.isEmpty ? nil : trimmed
    }

    /// Whether `type` can move `offset` places within its category.
    public func canMove(_ type: InspectorType, by offset: Int) -> Bool {
        let peers = types(in: type.category)
        guard let i = peers.firstIndex(of: type) else { return false }
        return offset != 0 && peers.indices.contains(i + offset)
    }

    /// Moves `type` up (negative) or down (positive) within its category, stopping at the ends.
    public mutating func move(_ type: InspectorType, by offset: Int) {
        let peers = types(in: type.category)
        guard let i = peers.firstIndex(of: type) else { return }
        let target = min(max(i + offset, 0), peers.count - 1)
        guard target != i else { return }
        move(in: type.category, fromOffsets: IndexSet(integer: i), toOffset: target > i ? target + 1 : target)
    }

    /// Moves the types at `source` (indices into `types(in: category)`) before the type at
    /// `destination`, as SwiftUI's `onMove` reports a drag; `destination` may equal the count.
    public mutating func move(in category: InspectorType.Category, fromOffsets source: IndexSet, toOffset destination: Int) {
        var peers = types(in: category)
        let valid = source.filter { peers.indices.contains($0) }
        guard !valid.isEmpty else { return }
        let moving = valid.map { peers[$0] }
        let insertAt = min(max(destination, 0), peers.count) - valid.filter { $0 < destination }.count
        for i in valid.reversed() { peers.remove(at: i) }
        peers.insert(contentsOf: moving, at: insertAt)
        var slots = peers.makeIterator()
        order = order.map { $0.category == category ? slots.next()! : $0 }
    }

    // MARK: Storage

    /// Raw values of every type, in order (`InspectorTypeOrder`).
    public var storedOrder: [String] { order.map(\.rawValue) }
    /// Raw values of the shown types, in order (`InspectorTypes`; earlier versions read it too).
    public var storedEnabled: [String] { enabledTypes.map(\.rawValue) }
    /// Custom names by raw value (`InspectorTypeNames`).
    public var storedNames: [String: String] {
        Dictionary(uniqueKeysWithValues: names.map { ($0.key.rawValue, $0.value) })
    }
}
