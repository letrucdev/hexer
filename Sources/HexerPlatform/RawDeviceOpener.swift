import CHexerSys
import Foundation
import Security

/// Why a raw disk device could not be opened.
public enum RawDeviceError: Error, Equatable, Sendable, LocalizedError {
    /// Not a BSD disk name like "disk4" or "disk4s1".
    case invalidName(String)
    /// The user dismissed the administrator authorization dialog.
    case cancelled(path: String)
    /// Authorization was refused (wrong password, not an administrator, or interaction not allowed).
    case denied(path: String)
    case authorizationFailed(path: String, status: Int32)
    /// `open(2)` failed with `code` (errno), e.g. EBUSY when writing to a disk with mounted volumes.
    case openFailed(path: String, code: Int32)
    /// `/usr/libexec/authopen` did not return a descriptor; `status` is its exit status.
    case helperFailed(path: String, status: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case .invalidName(let name):
            "“\(name)” is not a disk identifier such as disk4 or disk4s1."
        case .cancelled(let path):
            "Opening \(path) was cancelled."
        case .denied(let path):
            "You are not allowed to open \(path). Opening a disk requires an administrator’s name and password."
        case .authorizationFailed(let path, let status):
            "Could not get authorization to open \(path): \(Self.message(for: status))."
        case .openFailed(let path, EBUSY):
            "\(path) is in use. Unmount its volumes before writing to it."
        case .openFailed(let path, ENOENT):
            "\(path) does not exist. The disk may have been ejected."
        case .openFailed(let path, let code):
            "Could not open \(path): \(errorString(code))."
        case .helperFailed(let path, let status, let message):
            message.isEmpty
                ? "authopen could not open \(path) (exit status \(status))."
                : "authopen could not open \(path): \(message)"
        }
    }

    private static func message(for status: Int32) -> String {
        (SecCopyErrorMessageString(status, nil) as String?) ?? "error \(status)"
    }
}

/// Opens `/dev/rdiskN` for reading or writing, asking for administrator authorization when the
/// user may not open it directly.
///
/// The privileged open is done by `/usr/libexec/authopen`, which receives a pre-authorized
/// `AuthorizationRef` in external form on stdin (`-extauth`) and passes the descriptor back over
/// a UNIX socket (`-stdoutpipe`, SCM_RIGHTS). `-w` is never used: it would truncate.
public enum RawDeviceOpener {
    public static let authopenPath = "/usr/libexec/authopen"

    /// Opens the raw device of `bsdName` ("disk4", "disk4s1") read-only or read-write and returns
    /// a descriptor the caller owns (FD_CLOEXEC is set). Blocks a background thread, not the
    /// caller, while the authorization dialog is up.
    ///
    /// - Parameter allowAuthorization: When `false`, a permission error is thrown as
    ///   `openFailed` instead of showing the authorization dialog.
    public static func open(bsdName: String, writable: Bool, allowAuthorization: Bool = true) async throws -> Int32 {
        let path = try devicePath(forBSDName: bsdName)
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result {
                    try openDevice(path: path, writable: writable, allowAuthorization: allowAuthorization)
                })
            }
        }
    }

    /// "/dev/rdisk4" for "disk4"; throws `invalidName` for anything that is not a disk identifier.
    public static func devicePath(forBSDName bsdName: String) throws -> String {
        guard isValidBSDName(bsdName) else { throw RawDeviceError.invalidName(bsdName) }
        return "/dev/r" + bsdName
    }

    static func isValidBSDName(_ name: String) -> Bool {
        name.wholeMatch(of: /disk[0-9]+(s[0-9]+)*/) != nil
    }

    static func openDevice(path: String, writable: Bool, allowAuthorization: Bool) throws -> Int32 {
        let fd = Darwin.open(path, (writable ? O_RDWR : O_RDONLY) | O_CLOEXEC)
        if fd >= 0 { return fd }
        let code = errno
        guard allowAuthorization, code == EACCES || code == EPERM else {
            throw RawDeviceError.openFailed(path: path, code: code)
        }
        let token = try authorize(path: path, writable: writable)
        let received = try receiveDescriptor(helper: authopenPath, arguments: authopenArguments(path: path, writable: writable),
                                             input: token, path: path)
        // Make sure the helper handed back the device we asked for.
        var expected = stat(), actual = stat()
        guard stat(path, &expected) == 0, fstat(received, &actual) == 0,
              actual.st_rdev == expected.st_rdev, actual.st_mode & S_IFMT == expected.st_mode & S_IFMT else {
            close(received)
            throw RawDeviceError.helperFailed(path: path, status: 0, message: "It returned a different file.")
        }
        return received
    }

    static func rightName(path: String, writable: Bool) -> String {
        "sys.openfile.\(writable ? "readwrite" : "readonly").\(path)"
    }

    static func authopenArguments(path: String, writable: Bool) -> [String] {
        ["-stdoutpipe", "-extauth", "-o", String(writable ? O_RDWR : O_RDONLY), path]
    }

    static func authorizationError(status: OSStatus, path: String) -> RawDeviceError {
        switch status {
        case errAuthorizationCanceled: .cancelled(path: path)
        case errAuthorizationDenied, errAuthorizationInteractionNotAllowed: .denied(path: path)
        default: .authorizationFailed(path: path, status: status)
        }
    }

    /// Obtains the `sys.openfile` right for `path` (showing the dialog) and returns the
    /// authorization in external form for authopen.
    private static func authorize(path: String, writable: Bool) throws -> [UInt8] {
        var auth: AuthorizationRef?
        var status = AuthorizationCreate(nil, nil, [], &auth)
        guard status == errAuthorizationSuccess, let auth else { throw authorizationError(status: status, path: path) }
        defer { AuthorizationFree(auth, []) }
        status = rightName(path: path, writable: writable).withCString { name in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { item in
                var rights = AuthorizationRights(count: 1, items: item)
                return AuthorizationCopyRights(auth, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else { throw authorizationError(status: status, path: path) }
        var external = AuthorizationExternalForm()
        status = AuthorizationMakeExternalForm(auth, &external)
        guard status == errAuthorizationSuccess else { throw authorizationError(status: status, path: path) }
        return withUnsafeBytes(of: external) { Array($0) }
    }

    /// Runs `helper` with `input` on stdin and a socket on stdout, and returns the descriptor it
    /// sends back with SCM_RIGHTS. Its stderr becomes the error message when none arrives.
    static func receiveDescriptor(helper: String, arguments: [String], input: [UInt8], path: String) throws -> Int32 {
        var sockets: [Int32] = [-1, -1], stdinPipe: [Int32] = [-1, -1], stderrPipe: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets) == 0 else {
            throw RawDeviceError.openFailed(path: path, code: errno)
        }
        guard pipe(&stdinPipe) == 0 else {
            let code = errno
            sockets.forEach { close($0) }
            throw RawDeviceError.openFailed(path: path, code: code)
        }
        guard pipe(&stderrPipe) == 0 else {
            let code = errno
            (sockets + stdinPipe).forEach { close($0) }
            throw RawDeviceError.openFailed(path: path, code: code)
        }
        for fd in sockets + stdinPipe + stderrPipe { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        // Our ends; the child's ends are closed as soon as it has been spawned.
        let (socket, stdinWrite, stderrRead) = (sockets[0], stdinPipe[1], stderrPipe[0])
        defer { [socket, stderrRead].forEach { close($0) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, sockets[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], STDERR_FILENO)
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // Only the three descriptors above reach the child.
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))

        let argv = ([helper] + arguments).map { strdup($0) } + [nil]
        let envp = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let spawned = posix_spawn(&pid, helper, &actions, &attributes, argv, envp)
        [stdinPipe[0], sockets[1], stderrPipe[1]].forEach { close($0) }
        guard spawned == 0 else {
            close(stdinWrite)
            throw RawDeviceError.helperFailed(path: path, status: -1, message: "\(helper): \(errorString(spawned))")
        }

        _ = fcntl(stdinWrite, F_SETNOSIGPIPE, 1)  // the helper may exit without reading
        input.withUnsafeBytes { bytes in
            var done = 0
            while done < bytes.count {
                let n = Darwin.write(stdinWrite, bytes.baseAddress! + done, bytes.count - done)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                done += n
            }
        }
        close(stdinWrite)
        let received = hexer_recv_fd(socket)

        var message = [UInt8]()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while message.count < 65536 {
            let n = chunk.withUnsafeMutableBytes { Darwin.read(stderrRead, $0.baseAddress!, $0.count) }
            if n < 0 && errno == EINTR { continue }
            if n <= 0 { break }
            message += chunk[0..<n]
        }
        var status: Int32 = 0
        while waitpid(pid, &status, 0) < 0 && errno == EINTR {}
        if received >= 0 { return received }

        // WIFEXITED / WEXITSTATUS are macros Swift cannot see.
        let exitStatus = status & 0x7F == 0 ? (status >> 8) & 0xFF : 128 + (status & 0x7F)
        let text = String(decoding: message, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        throw RawDeviceError.helperFailed(path: path, status: exitStatus,
                                          message: text.isEmpty && exitStatus == 0 ? "It returned no descriptor." : text)
    }
}
