/// The result of importing an Intel Hex, Motorola S-Record or ETL Extended file: the data placed at
/// its addresses, with undefined gaps where no record supplied bytes.
///
/// Runs start at address 0 (a first record at a higher address gives a leading gap) and end at
/// the highest address written. When records overlap, the one later in the file wins, as in HxD
/// 2.5, which writes every record into the document in file order.
public struct ImportedImage: Equatable, Sendable {
    public enum Run: Equatable, Sendable {
        case data([UInt8])
        case gap(UInt64)

        public var length: UInt64 {
            switch self {
            case .data(let bytes): UInt64(bytes.count)
            case .gap(let n): n
            }
        }
    }

    /// A non-data record kept for information: S0 headers, ETL X0/X1/X3 text and X2 annotations.
    public struct MetadataRecord: Equatable, Sendable {
        /// The record type as written in the file, e.g. "S0" or "X2".
        public var type: String
        public var address: UInt64
        public var bytes: [UInt8]

        public init(type: String, address: UInt64, bytes: [UInt8]) {
            self.type = type
            self.address = address
            self.bytes = bytes
        }
    }

    public var runs: [Run]
    /// Execution start addresses (Intel Hex 03/05, S-Record S7/S8/S9), in file order. For a type
    /// 03 record this is `CS * 16 + IP`.
    public var startAddresses: [UInt64]
    public var metadata: [MetadataRecord]

    public init(runs: [Run], startAddresses: [UInt64] = [], metadata: [MetadataRecord] = []) {
        self.runs = runs
        self.startAddresses = startAddresses
        self.metadata = metadata
    }

    public var length: UInt64 { runs.reduce(0) { $0 + $1.length } }

    /// All data bytes in address order, without the gaps.
    public var dataBytes: [UInt8] {
        var out: [UInt8] = []
        for case .data(let bytes) in runs { out += bytes }
        return out
    }

    /// The pieces of a document showing this image: data refers to one `MemoryByteSource` holding
    /// all data bytes (registered in `registry`), gaps are undefined pieces.
    public func pieces(registry: SourceRegistry) -> [Piece] {
        let data = dataBytes
        let id: UInt32? = data.isEmpty ? nil : registry.register(MemoryByteSource(data))
        var pieces: [Piece] = []
        var sourceOffset: UInt64 = 0
        for run in runs {
            switch run {
            case .data(let bytes):
                guard !bytes.isEmpty, let id else { continue }
                pieces.append(Piece(.source(id), start: sourceOffset, length: UInt64(bytes.count)))
                sourceOffset += UInt64(bytes.count)
            case .gap(let n):
                if n > 0 { pieces.append(.undefined(length: n)) }
            }
        }
        return pieces
    }

    /// A new document buffer for this image (offset = address).
    public func makeBuffer(registry: SourceRegistry = SourceRegistry()) -> EditableBuffer {
        EditableBuffer(pieces: pieces(registry: registry), registry: registry)
    }
}

/// Collects records into sorted, non-overlapping runs; a write overwrites what it overlaps.
///
/// Records in increasing address order (the usual case) are appended to the last run in O(1).
struct SparseImageBuilder {
    private var starts: [UInt64] = []
    private var chunks: [[UInt8]] = []

    private func end(_ i: Int) -> UInt64 { starts[i] + UInt64(chunks[i].count) }

    mutating func write(_ bytes: UnsafeRawBufferPointer, at address: UInt64) {
        guard !bytes.isEmpty else { return }
        let e = address + UInt64(bytes.count)
        if let last = starts.indices.last {
            let lastEnd = end(last)
            if address == lastEnd {
                chunks[last].append(contentsOf: bytes)
                return
            }
            if address > lastEnd {
                starts.append(address)
                chunks.append(Array(bytes))
                return
            }
        } else {
            starts.append(address)
            chunks.append(Array(bytes))
            return
        }
        // First run ending after `address` and last run starting before `e`: those overlap.
        var lo = 0, hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if end(mid) > address { hi = mid } else { lo = mid + 1 }
        }
        let first = lo
        lo = first
        hi = starts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if starts[mid] < e { lo = mid + 1 } else { hi = mid }
        }
        let last = lo - 1
        if first > last {
            // No overlap: extend the run that ends exactly here, or insert a new one.
            if first > 0 && end(first - 1) == address {
                chunks[first - 1].append(contentsOf: bytes)
            } else {
                starts.insert(address, at: first)
                chunks.insert(Array(bytes), at: first)
            }
            return
        }
        var merged: [UInt8] = []
        let newStart = min(address, starts[first])
        if starts[first] < address { merged += chunks[first][0..<Int(address - starts[first])] }
        merged.append(contentsOf: bytes)
        let lastEnd = end(last)
        if lastEnd > e { merged += chunks[last][Int(e - starts[last])...] }
        starts.replaceSubrange(first...last, with: [newStart])
        chunks.replaceSubrange(first...last, with: [merged])
    }

    /// The runs from address 0, merging runs that touch.
    func runs() -> [ImportedImage.Run] {
        var out: [ImportedImage.Run] = []
        var pos: UInt64 = 0
        var current: [UInt8] = []
        for i in starts.indices {
            if starts[i] > pos {
                if !current.isEmpty { out.append(.data(current)); current = [] }
                out.append(.gap(starts[i] - pos))
            }
            if current.isEmpty { current = chunks[i] } else { current += chunks[i] }
            pos = end(i)
        }
        if !current.isEmpty { out.append(.data(current)) }
        return out
    }
}
