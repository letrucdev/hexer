import Foundation
import Testing
@testable import HexerCore

@Suite struct RecentDiskImagesTests {
    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    @Test func mostRecentFirstWithItsSectorSize() {
        var list = RecentDiskImages()
        list.record(url("/images/a.iso"), sectorSize: 2048)
        list.record(url("/images/b.img"), sectorSize: 512)
        #expect(list.entries.map(\.path) == ["/images/b.img", "/images/a.iso"])
        #expect(list.sectorSize(for: url("/images/a.iso")) == 2048)
        #expect(list.sectorSize(for: url("/images/none.img")) == nil)
    }

    @Test func reopeningMovesToTopAndKeepsTheNewSectorSize() {
        var list = RecentDiskImages()
        list.record(url("/images/a.img"), sectorSize: 512)
        list.record(url("/images/b.img"), sectorSize: 512)
        list.record(url("/images/a.img"), sectorSize: 4096)
        #expect(list.entries.map(\.path) == ["/images/a.img", "/images/b.img"])
        #expect(list.entries[0].sectorSize == 4096)
    }

    @Test func sameFileInDifferentSpellingsIsOneEntry() {
        var list = RecentDiskImages()
        list.record(url("/images/a.img"), sectorSize: 512)
        list.record(url("/images/sub/../a.img"), sectorSize: 512)
        list.record(url("/images/./a.img"), sectorSize: 512)
        #expect(list.entries.count == 1)
        list.remove(url("/images/x/../a.img"))
        #expect(list.entries.isEmpty)
    }

    @Test func keepsTheTenMostRecent() {
        var list = RecentDiskImages()
        for i in 0..<15 { list.record(url("/images/\(i).img"), sectorSize: 512) }
        #expect(list.entries.count == RecentDiskImages.capacity && RecentDiskImages.capacity == 10)
        #expect(list.entries.first?.path == "/images/14.img" && list.entries.last?.path == "/images/5.img")
        // A repeat at the cap does not push anything out.
        list.record(url("/images/9.img"), sectorSize: 512)
        #expect(list.entries.count == 10 && list.entries.first?.path == "/images/9.img")
    }

    @Test func removeAndClear() {
        var list = RecentDiskImages()
        list.record(url("/a.img"), sectorSize: 512)
        list.record(url("/b.img"), sectorSize: 512)
        list.remove(url("/a.img"))
        list.remove(url("/not-listed.img"))
        #expect(list.entries.map(\.path) == ["/b.img"])
        list.clear()
        #expect(list.entries.isEmpty)
    }

    @Test func rejectsASectorSizeThatIsNotPositive() {
        var list = RecentDiskImages()
        list.record(url("/a.img"), sectorSize: 0)
        list.record(url("/a.img"), sectorSize: -512)
        #expect(list.entries.isEmpty)
    }

    @Test func titlesAddTheFolderOnlyForRepeatedNames() {
        var list = RecentDiskImages()
        list.record(url("/one/disk.img"), sectorSize: 512)
        list.record(url("/two/disk.img"), sectorSize: 512)
        list.record(url("/one/other.iso"), sectorSize: 2048)
        #expect(list.titles == ["other.iso", "disk.img — two", "disk.img — one"])
    }

    @Test func roundTripsThroughStorage() {
        var list = RecentDiskImages()
        list.record(url("/a b/é.img"), sectorSize: 4096)
        list.record(url("/c.iso"), sectorSize: 2048)
        #expect(RecentDiskImages(decoding: list.encoded()) == list)
    }

    @Test func damagedStorageGivesAnEmptyOrCleanedList() {
        #expect(RecentDiskImages(decoding: nil).entries.isEmpty)
        #expect(RecentDiskImages(decoding: Data("not json".utf8)).entries.isEmpty)
        #expect(RecentDiskImages(decoding: Data("{}".utf8)).entries.isEmpty)
        let json = """
            [{"path":"/a.img","sectorSize":512},{"path":"","sectorSize":512},{"path":"/b.img","sectorSize":0},
             {"path":"/a.img","sectorSize":2048},{"path":"/c.img","sectorSize":2048}]
            """
        let list = RecentDiskImages(decoding: Data(json.utf8))
        #expect(list.entries.map(\.path) == ["/a.img", "/c.img"] && list.entries[0].sectorSize == 512)
        let many = (0..<30).map { #"{"path":"/\#($0).img","sectorSize":512}"# }.joined(separator: ",")
        #expect(RecentDiskImages(decoding: Data("[\(many)]".utf8)).entries.count == 10)
    }
}
