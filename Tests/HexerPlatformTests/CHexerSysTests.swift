import CHexerSys
import Foundation
import Testing

@Suite struct CHexerSysTests {
    private func socketPair() throws -> (Int32, Int32) {
        var sv: [Int32] = [-1, -1]
        try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0)
        return (sv[0], sv[1])
    }

    @Test func descriptorRoundTripsOverSocketPair() throws {
        let content = randomBytes(1000, seed: 1)
        let url = try Scratch.file(content)
        defer { try? FileManager.default.removeItem(at: url) }
        let (a, b) = try socketPair()
        defer { close(a); close(b) }
        let original = open(url.path, O_RDONLY)
        try #require(original >= 0)

        // Plain data ahead of the descriptor is skipped.
        #expect(write(a, "hello", 5) == 5)
        #expect(hexer_send_fd(a, original) == 0)
        close(original)
        let received = hexer_recv_fd(b)
        try #require(received >= 0)
        defer { close(received) }
        #expect(fcntl(received, F_GETFD) & FD_CLOEXEC != 0)
        var buffer = [UInt8](repeating: 0, count: content.count)
        #expect(pread(received, &buffer, buffer.count, 0) == content.count)
        #expect(buffer == content)
    }

    @Test func endOfStreamWithoutDescriptorFails() throws {
        let (a, b) = try socketPair()
        defer { close(b) }
        #expect(write(a, "x", 1) == 1)
        close(a)
        let result = hexer_recv_fd(b)
        let code = errno
        #expect(result == -1)
        #expect(code == ENOMSG)
    }

    @Test func diskIoctlsRejectRegularFiles() throws {
        let url = try Scratch.file([1, 2, 3])
        defer { try? FileManager.default.removeItem(at: url) }
        let fd = open(url.path, O_RDONLY)
        defer { close(fd) }
        var size: UInt32 = 0
        var count: UInt64 = 0
        #expect(hexer_block_size(fd, &size) == -1)
        let result = hexer_block_count(fd, &count)
        let code = errno
        #expect(result == -1)
        #expect(code == ENOTTY)
    }
}
