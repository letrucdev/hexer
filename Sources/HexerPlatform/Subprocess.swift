import Foundation
import Synchronization

/// Runs a command-line tool and collects its output.
///
/// It waits for the tool to exit, not for the end of its output: a helper the tool leaves running
/// (such as the diskimages-helper serving an attached disk image) may inherit the pipes and keep
/// them open, so reading to end of file could wait forever. Reads never block for the same reason
/// (`FileHandle.availableData` would). A tool still running after `timeout` is terminated.
enum Subprocess {
    struct Result {
        var status: Int32
        var output: Data
        var error: String
        var timedOut: Bool
    }

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let queue = DispatchQueue(label: "Subprocess")
        let readers = [PipeReader(out, queue: queue), PipeReader(err, queue: queue)]
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            readers.forEach { $0.stop() }
            return Result(status: -1, output: Data(), error: error.localizedDescription, timedOut: false)
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
        }
        // What the tool wrote before exiting arrives within moments; pipes a helper keeps open never
        // reach their end, so wait at most a second for that.
        for _ in 0..<100 where !readers.allSatisfy(\.atEnd) { Thread.sleep(forTimeInterval: 0.01) }
        readers.forEach { $0.stop() }
        let message = String(decoding: readers[1].data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: process.isRunning ? -1 : process.terminationStatus, output: readers[0].data,
                      error: message, timedOut: timedOut)
    }
}

/// Collects a pipe's data with non-blocking reads as it becomes readable. Unchecked: the read
/// source is only touched on its own serial queue after `init`.
private final class PipeReader: @unchecked Sendable {
    private let fd: Int32
    private let queue: DispatchQueue
    private let source: DispatchSourceRead
    private let state = Mutex<(data: Data, atEnd: Bool)>((Data(), false))

    init(_ pipe: Pipe, queue: DispatchQueue) {
        fd = pipe.fileHandleForReading.fileDescriptor
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [self] in
            if drain() { source.cancel() }
        }
        source.resume()
    }

    var data: Data { state.withLock { $0.data } }
    var atEnd: Bool { state.withLock { $0.atEnd } }

    /// Stops reading, after taking what the pipe holds now. The pipe (owned by the caller) must
    /// still be open.
    func stop() {
        // On the source's queue, so no read runs at the same time.
        queue.sync {
            source.cancel()
            _ = drain()
        }
    }

    /// Reads until the pipe is empty; true at end of file.
    private func drain() -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1 << 16)
        while true {
            let n = read(fd, &buffer, buffer.count)
            if n > 0 {
                state.withLock { $0.data.append(buffer, count: n) }
            } else {
                // 0: end of file. -1 with EAGAIN: nothing more for now.
                if n == 0 { state.withLock { $0.atEnd = true } }
                return n == 0
            }
        }
    }
}
