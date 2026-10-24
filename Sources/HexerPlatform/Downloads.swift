import Foundation
import HexerCore

/// HTTPS requests for updates: no cookies, cache or credentials kept (an ephemeral session).
public enum Downloads {
    private static var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return configuration
    }

    /// The body of a response, at most `maxBytes`.
    public static func data(_ request: URLRequest, maxBytes: Int) async throws -> Data {
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        try check(response)
        guard data.count <= maxBytes else { throw UpdateError.tooLarge }
        return data
    }

    /// Downloads to `destination` (replaced if it exists), reporting bytes received and expected
    /// (-1 when unknown). Stops past `maxBytes`. Cancelling the task cancels the download.
    public static func file(_ request: URLRequest, to destination: URL, maxBytes: Int64,
                            progress: @escaping @Sendable (_ received: Int64, _ expected: Int64) -> Void) async throws {
        let delegate = FileDownload(destination: destination, maxBytes: maxBytes, progress: progress)
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: request)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                delegate.continuation = continuation
                task.resume()
            }
        } onCancel: {
            task.cancel()
        }
    }

    /// Throws unless an HTTP response is 200 (file URLs have no status).
    static func check(_ response: URLResponse?) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200: return
        case 403, 429: throw UpdateError.rateLimited
        case let status: throw UpdateError.serverStatus(status)
        }
    }
}

private final class FileDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let maxBytes: Int64
    let progress: @Sendable (Int64, Int64) -> Void
    // URLSession calls the delegate on its serial queue, one call at a time.
    var continuation: CheckedContinuation<Void, Error>?
    private var failure: Error?

    init(destination: URL, maxBytes: Int64, progress: @escaping @Sendable (Int64, Int64) -> Void) {
        self.destination = destination
        self.maxBytes = maxBytes
        self.progress = progress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= maxBytes else {
            failure = UpdateError.tooLarge
            downloadTask.cancel()
            return
        }
        progress(totalBytesWritten, totalBytesExpectedToWrite)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this returns.
        do {
            try Downloads.check(downloadTask.response)
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failure = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Error?
        if let failure {
            result = failure
        } else if let error = error as? URLError, error.code == .cancelled {
            result = CancellationError()
        } else {
            result = error
        }
        if let result { continuation?.resume(throwing: result) } else { continuation?.resume() }
        continuation = nil
    }
}
