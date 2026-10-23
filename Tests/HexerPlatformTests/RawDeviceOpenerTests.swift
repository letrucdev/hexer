import Foundation
import Security
import Testing
@testable import HexerPlatform

/// A Python with `socket.send_fds` stands in for authopen: it reads stdin and sends a descriptor back.
private let python: String? = {
    for path in ["/usr/bin/python3", "/opt/homebrew/bin/python3", "/usr/local/bin/python3"]
    where FileManager.default.isExecutableFile(atPath: path) {
        if run(path, ["-c", "import socket; socket.send_fds"]).status == 0 { return path }
    }
    return nil
}()

@Suite struct RawDeviceOpenerTests {
    @Test func validatesBSDNames() throws {
        #expect(try RawDeviceOpener.devicePath(forBSDName: "disk4") == "/dev/rdisk4")
        #expect(try RawDeviceOpener.devicePath(forBSDName: "disk3s1s1") == "/dev/rdisk3s1s1")
        for bad in ["", "disk", "rdisk4", "disk4s", "disk4/../../etc/passwd", "/dev/disk4", "disk 4", "Disk4"] {
            #expect(throws: RawDeviceError.invalidName(bad)) { try RawDeviceOpener.devicePath(forBSDName: bad) }
        }
    }

    @Test func authopenRequestNeverTruncates() {
        #expect(RawDeviceOpener.rightName(path: "/dev/rdisk4", writable: false) == "sys.openfile.readonly./dev/rdisk4")
        #expect(RawDeviceOpener.rightName(path: "/dev/rdisk4", writable: true) == "sys.openfile.readwrite./dev/rdisk4")
        #expect(RawDeviceOpener.authopenArguments(path: "/dev/rdisk4", writable: false)
            == ["-stdoutpipe", "-extauth", "-o", "0", "/dev/rdisk4"])
        #expect(RawDeviceOpener.authopenArguments(path: "/dev/rdisk4", writable: true)
            == ["-stdoutpipe", "-extauth", "-o", "2", "/dev/rdisk4"])
        for writable in [false, true] {
            let args = RawDeviceOpener.authopenArguments(path: "/dev/rdisk4", writable: writable)
            #expect(!args.contains("-w") && !args.contains("-c") && !args.contains("-a"))
        }
    }

    @Test func authorizationFailuresAreClassified() {
        let path = "/dev/rdisk4"
        #expect(RawDeviceOpener.authorizationError(status: errAuthorizationCanceled, path: path) == .cancelled(path: path))
        #expect(RawDeviceOpener.authorizationError(status: errAuthorizationDenied, path: path) == .denied(path: path))
        #expect(RawDeviceOpener.authorizationError(status: errAuthorizationInteractionNotAllowed, path: path)
            == .denied(path: path))
        #expect(RawDeviceOpener.authorizationError(status: errAuthorizationInternal, path: path)
            == .authorizationFailed(path: path, status: errAuthorizationInternal))
        for error in [RawDeviceError.cancelled(path: path), .denied(path: path), .openFailed(path: path, code: EBUSY),
                      .helperFailed(path: path, status: 1, message: ""), .invalidName("x"),
                      .authorizationFailed(path: path, status: errAuthorizationInternal)] {
            #expect(error.errorDescription?.isEmpty == false)
        }
        #expect(RawDeviceError.openFailed(path: path, code: EBUSY).errorDescription!.contains("Unmount"))
    }

    @Test func permissionErrorsDoNotPromptWhenAuthorizationIsDisallowed() async throws {
        let path = "/dev/rdisk0"
        try #require(FileManager.default.fileExists(atPath: path))
        guard access(path, R_OK) != 0 else { return }  // running as root or operator: nothing to test
        // EACCES normally; EPERM inside a sandbox.
        let error = await #expect(throws: RawDeviceError.self) {
            try await RawDeviceOpener.open(bsdName: "disk0", writable: false, allowAuthorization: false)
        }
        #expect(error == .openFailed(path: path, code: EACCES) || error == .openFailed(path: path, code: EPERM))
    }

    @Test(.enabled(if: python != nil, "needs a python3 with socket.send_fds"))
    func receivesTheDescriptorTheHelperSends() throws {
        let content = randomBytes(3000, seed: 9)
        let file = try Scratch.file(content)
        let echo = Scratch.url("stdin.bin")
        defer { [file, echo].forEach { try? FileManager.default.removeItem(at: $0) } }
        let script = """
            import os, socket, sys
            data = sys.stdin.buffer.read()
            open(sys.argv[2], "wb").write(data)
            fd = os.open(sys.argv[1], os.O_RDONLY)
            socket.send_fds(socket.socket(fileno=1), [b"!"], [fd])
            """
        let token = randomBytes(32, seed: 10)
        let fd = try RawDeviceOpener.receiveDescriptor(helper: python!, arguments: ["-c", script, file.path, echo.path],
                                                       input: token, path: file.path)
        defer { close(fd) }
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        #expect(preadAll("/dev/fd/\(fd)", count: 4000) == content)
        #expect(try [UInt8](Data(contentsOf: echo)) == token)
    }

    @Test func helperFailuresCarryItsMessage() throws {
        #expect(throws: RawDeviceError.helperFailed(path: "/dev/rdisk9", status: 3, message: "not authorized")) {
            try RawDeviceOpener.receiveDescriptor(helper: "/bin/sh", arguments: ["-c", "cat >/dev/null; echo not authorized >&2; exit 3"],
                                                  input: [1, 2, 3], path: "/dev/rdisk9")
        }
        #expect(throws: RawDeviceError.helperFailed(path: "/dev/rdisk9", status: 0, message: "It returned no descriptor.")) {
            try RawDeviceOpener.receiveDescriptor(helper: "/usr/bin/true", arguments: [], input: [], path: "/dev/rdisk9")
        }
        #expect(throws: RawDeviceError.self) {
            try RawDeviceOpener.receiveDescriptor(helper: "/nonexistent/authopen", arguments: [], input: [1], path: "/dev/rdisk9")
        }
    }
}
