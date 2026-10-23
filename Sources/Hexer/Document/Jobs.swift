import Foundation
import Observation
import Synchronization

/// Cancellation flag and progress of one background job, usable from any thread.
nonisolated final class JobContext: Sendable {
    private let cancelled = Atomic<Bool>(false)
    private let fraction = Mutex<Double>(0)

    var isCancelled: Bool { cancelled.load(ordering: .relaxed) }
    func cancel() { cancelled.store(true, ordering: .relaxed) }

    /// Records progress in 0…1; the status bar picks it up a few times per second.
    func report(_ progress: Double) { fraction.withLock { $0 = progress } }
    var progress: Double { fraction.withLock { $0 } }
}

/// A long-running operation (search all, checksums, export…) shown in the status bar.
@Observable
final class Job: Identifiable {
    let id = UUID()
    let title: String
    @ObservationIgnored let context = JobContext()
    var progress: Double = 0

    init(title: String) { self.title = title }

    func cancel() { context.cancel() }
}

/// Runs the jobs of one window off the main thread and publishes their progress.
@Observable
final class JobCenter {
    private(set) var jobs: [Job] = []

    var isBusy: Bool { !jobs.isEmpty }

    /// Runs `work` on a background thread. Returns nil when the user cancelled the job.
    func run<T: Sendable>(_ title: String, _ work: @escaping @Sendable (JobContext) throws -> T) async throws -> T? {
        let job = Job(title: title)
        jobs.append(job)
        let ticker = Task { [weak job] in
            while !Task.isCancelled, let job {
                job.progress = job.context.progress
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
        defer {
            ticker.cancel()
            jobs.removeAll { $0 === job }
        }
        let context = job.context
        let result = try await Task.detached(priority: .userInitiated) { try work(context) }.value
        return context.isCancelled ? nil : result
    }

    func cancelAll() { jobs.forEach { $0.cancel() } }
}
