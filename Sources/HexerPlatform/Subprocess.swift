import Foundation
import Synchronization

/// Runs a command-line tool and collects its output.
///
/// It waits for the tool to exit, not for the end of its output: a helper the tool leaves running
/// (such as one serving an attached disk image) may inherit the pipes and keep them open, so
/// reading to end of file could wait forever. A tool still running after `timeout` is terminated.
enum Subprocess {
    struct Result {
        var status: Int32
        var output: Data
        var error: String
        var timedOut: Bool
    }

    private struct Collected {
        var output = Data()
        var error = Data()
        var pipesAtEnd = 0
    }

    static func run(_ tool: String, _ arguments: [String], timeout: TimeInterval = 120) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        let collected = Mutex(Collected())
        func collect(_ pipe: Pipe, isError: Bool) {
            pipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                // At end of file the handler would keep firing with no data.
                if data.isEmpty { handle.readabilityHandler = nil }
                collected.withLock { c in
                    if data.isEmpty {
                        c.pipesAtEnd += 1
                    } else if isError {
                        c.error.append(data)
                    } else {
                        c.output.append(data)
                    }
                }
            }
        }
        collect(out, isError: false)
        collect(err, isError: true)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return Result(status: -1, output: Data(), error: error.localizedDescription, timedOut: false)
        }
        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.terminate()
            _ = exited.wait(timeout: .now() + 5)
        }
        // What the tool wrote before exiting reaches the handlers within moments; pipes a helper
        // keeps open never reach their end, so wait at most a second.
        for _ in 0..<100 where collected.withLock({ $0.pipesAtEnd }) < 2 { Thread.sleep(forTimeInterval: 0.01) }
        out.fileHandleForReading.readabilityHandler = nil
        err.fileHandleForReading.readabilityHandler = nil
        let result = collected.withLock { $0 }
        let message = String(decoding: result.error, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return Result(status: process.isRunning ? -1 : process.terminationStatus, output: result.output, error: message,
                      timedOut: timedOut)
    }
}
