import Foundation
import Testing
@testable import HexerPlatform

@Suite struct SubprocessTests {
    @Test func collectsOutputAndStatus() {
        let r = Subprocess.run("/bin/sh", ["-c", "printf 'out'; printf 'err\\n' >&2; exit 3"])
        #expect(r.status == 3 && !r.timedOut)
        #expect(String(decoding: r.output, as: UTF8.self) == "out")
        #expect(r.error == "err")
    }

    /// A helper the tool leaves behind keeps the pipes open, as one serving an attached disk image
    /// can: the run ends when the tool exits, not when its output does (here 30 s later).
    @Test func doesNotWaitForPipesAHelperKeepsOpen() {
        let start = Date.now
        let r = Subprocess.run("/bin/sh", ["-c", "printf 'plist'; (sleep 30 &); exit 0"])
        #expect(Date.now.timeIntervalSince(start) < 10)
        #expect(r.status == 0 && String(decoding: r.output, as: UTF8.self) == "plist")
    }

    @Test func stopsAToolThatRunsTooLong() {
        let start = Date.now
        let r = Subprocess.run("/bin/sleep", ["10"], timeout: 0.5)
        #expect(r.timedOut && r.status != 0)
        #expect(Date.now.timeIntervalSince(start) < 4)
    }

    @Test func reportsAToolThatCannotStart() {
        let r = Subprocess.run("/nonexistent/tool", [])
        #expect(r.status == -1 && !r.error.isEmpty)
    }

    /// Large output arrives whole (more than a pipe buffer holds).
    @Test func collectsLargeOutput() {
        let r = Subprocess.run("/bin/sh", ["-c", "head -c 1000000 /dev/zero"])
        #expect(r.status == 0 && r.output.count == 1_000_000)
    }
}
