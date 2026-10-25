import AppKit
import HexerCore
import HexerPlatform
import Observation

/// Finds new releases in the update feeds (tried in turn, so one host being slow, blocked or out of
/// requests doesn't stop updates), then downloads, verifies and installs one when the user agrees.
///
/// Checks run a few seconds after launch and then hourly, at most once a day (none on the first
/// launch). A verified update waits in a temporary folder on the app's volume and replaces the app
/// when Hexer quits; Relaunch quits right away and opens the new version.
@Observable
final class SoftwareUpdate {
    static let shared = SoftwareUpdate()

    enum Phase: Equatable {
        case idle
        case checking
        case upToDate
        case available(UpdateRelease)
        case downloading(UpdateRelease, received: Int64, expected: Int64)
        case verifying(UpdateRelease)
        case ready(UpdateRelease)
        /// The message; the release when installing it failed (nil when checking did).
        case failed(String, release: UpdateRelease?)
    }

    private enum Keys {
        static let automatic = "CheckForUpdatesAutomatically"
        static let betas = "UpdateIncludesBetas"
        static let lastCheck = "LastUpdateCheck"
        static let firstLaunch = "UpdateChecksSince"
        static let skipped = "SkippedUpdateVersion"
        static let stagingFolder = "UpdateStagingFolder"
    }

    private(set) var phase: Phase = .idle
    var checksAutomatically: Bool { didSet { defaults.set(checksAutomatically, forKey: Keys.automatic) } }
    var includesBetas: Bool { didSet { defaults.set(includesBetas, forKey: Keys.betas) } }
    private(set) var lastCheck: Date? { didSet { defaults.set(lastCheck, forKey: Keys.lastCheck) } }

    /// The running version; nil when it can't be updated (no version, feed or key, e.g. `swift run`).
    let currentVersion: AppVersion?
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private let feedURLs: [URL]
    @ObservationIgnored private let publicKey: String?
    @ObservationIgnored private let bundleURL = Bundle.main.bundleURL
    @ObservationIgnored private var work: Task<Void, Never>?
    /// The verified new app, swapped in when Hexer quits.
    @ObservationIgnored private var staged: URL?
    @ObservationIgnored private var relaunchesAfterInstall = false

    private init() {
        defaults.register(defaults: [Keys.automatic: true, Keys.betas: false])
        checksAutomatically = defaults.bool(forKey: Keys.automatic)
        includesBetas = defaults.bool(forKey: Keys.betas)
        lastCheck = defaults.object(forKey: Keys.lastCheck) as? Date
        let info = Bundle.main.infoDictionary ?? [:]
        let feeds = DebugLaunchArguments.updateFeed.map { [$0] }
            ?? (info["HexerUpdateFeedURLs"] as? [String] ?? []).compactMap(URL.init(string:))
        let key = info["HexerUpdatePublicKey"] as? String
        let version = (info["CFBundleShortVersionString"] as? String).flatMap(AppVersion.init)
        let complete = Bundle.main.bundleIdentifier != nil && !feeds.isEmpty && key?.isEmpty == false
        feedURLs = feeds
        publicKey = key
        currentVersion = complete ? version : nil
    }

    var canUpdate: Bool { currentVersion != nil }

    // MARK: Checking

    /// Starts the automatic checks. Scripted runs check only when given a feed (`-HexerUpdateFeed`).
    func start() {
        removeStagingFolder()
        guard canUpdate, !DebugLaunchArguments.isScripted || DebugLaunchArguments.updateFeed != nil else { return }
        // The first launch has just been installed; check from the next day on.
        if defaults.object(forKey: Keys.firstLaunch) == nil { defaults.set(Date.now, forKey: Keys.firstLaunch) }
        Task {
            try? await Task.sleep(for: .seconds(5))
            while true {
                checkIfDue()
                try? await Task.sleep(for: .seconds(60 * 60))
            }
        }
    }

    private func checkIfDue() {
        let settled = switch phase {
        case .idle, .upToDate, .failed: true
        default: false
        }
        let since = max(lastCheck ?? .distantPast, defaults.object(forKey: Keys.firstLaunch) as? Date ?? .distantPast)
        guard checksAutomatically, settled, !SoftwareUpdateWindowController.isVisible,
              Date.now.timeIntervalSince(since) >= 24 * 60 * 60 else { return }
        check(userInitiated: false)
    }

    /// Hexer ▸ Check for Updates… and Settings' Check Now: shows the window and, unless an update
    /// is already on its way, checks.
    func checkForUpdates() {
        switch phase {
        case .available, .downloading, .verifying, .ready: break
        default: check(userInitiated: true)
        }
        SoftwareUpdateWindowController.show()
    }

    /// A check the user asked for shows every outcome and offers a skipped version again; an
    /// automatic one only speaks up when there is an update.
    private func check(userInitiated: Bool) {
        guard let currentVersion, !feedURLs.isEmpty else { return }
        let feedURLs = feedURLs
        work?.cancel()
        if userInitiated { phase = .checking }
        let skipped = userInitiated ? nil : defaults.string(forKey: Keys.skipped).flatMap(AppVersion.init)
        let betas = includesBetas || currentVersion.isPrerelease
        work = Task {
            do {
                let releases = try await Self.releases(from: feedURLs, userAgent: "Hexer/\(currentVersion)")
                try Task.checkCancellation()
                lastCheck = .now
                if let release = UpdateFeed.newest(in: releases, after: currentVersion, includingPrereleases: betas, skipping: skipped) {
                    phase = .available(release)
                    if !userInitiated { SoftwareUpdateWindowController.present() }
                } else {
                    phase = userInitiated ? .upToDate : .idle
                }
            } catch is CancellationError {
            } catch {
                phase = userInitiated ? .failed(error.displayMessage, release: nil) : .idle
            }
        }
    }

    /// The releases of the first feed that answers with a readable manifest; when none does, the
    /// last feed's error (so a blocked first host doesn't hide why the others failed).
    private static func releases(from feeds: [URL], userAgent: String) async throws -> [UpdateRelease] {
        var failure: Error = UpdateError.invalidFeed
        for feed in feeds {
            do {
                var request = URLRequest(url: feed)
                request.setValue("application/json", forHTTPHeaderField: "Accept")
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                let data = try await Downloads.data(request, maxBytes: 8 << 20)
                return try UpdateManifest.releases(from: data, allowingFileURLs: feed.isFileURL)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error
            }
        }
        throw failure
    }

    // MARK: Installing

    /// Why the app can't replace itself where it is (translocated), if it can't.
    var installProblem: String? {
        guard !needsAdministrator else { return nil }
        do {
            try AppBundleInstaller.checkReplaceable(bundleURL)
            return nil
        } catch {
            return error.displayMessage
        }
    }

    /// Replacing the app takes an administrator's name and password (it is in a folder the
    /// user can't write to, such as an administrator's Applications folder).
    var needsAdministrator: Bool { AppBundleInstaller.needsPrivileges(bundleURL) }

    /// Downloads the update, checks it and stages it for installing.
    func install() {
        guard case .available(let release) = phase, let publicKey, let identifier = Bundle.main.bundleIdentifier else { return }
        let bundleURL = bundleURL
        phase = .downloading(release, received: 0, expected: release.diskImageSize)
        work = Task {
            do {
                let folder = try stagingFolder()
                let image = folder.appendingPathComponent(UpdateRelease.diskImageName(release.version.description))
                // Each place the image is offered in turn; the signature is checked on whichever delivers.
                var failure: Error = UpdateError.invalidFeed
                var downloaded = false
                for url in release.diskImageURLs where !downloaded {
                    do {
                        try await Downloads.file(URLRequest(url: url), to: image, maxBytes: 512 << 20) { received, expected in
                            Task { @MainActor in
                                guard case .downloading = SoftwareUpdate.shared.phase else { return }
                                SoftwareUpdate.shared.phase = .downloading(release, received: received, expected: expected)
                            }
                        }
                        downloaded = true
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch {
                        failure = error
                    }
                }
                if !downloaded { throw failure }
                phase = .verifying(release)
                staged = try await Task.detached {
                    let staged = try UpdateStaging.stage(diskImage: image, signature: release.signature, version: release.version.description,
                                                         publicKey: publicKey, replacing: bundleURL, bundleIdentifier: identifier,
                                                         in: folder)
                    try? FileManager.default.removeItem(at: image)
                    return staged
                }.value
                try Task.checkCancellation()
                phase = .ready(release)
            } catch is CancellationError {
                staged = nil
                removeStagingFolder()
            } catch {
                staged = nil
                removeStagingFolder()
                phase = .failed(error.displayMessage, release: release)
            }
        }
    }

    /// Stops a check or a download (the window's Cancel).
    func cancel() {
        work?.cancel()
        work = nil
        switch phase {
        case .downloading(let release, _, _), .verifying(let release): phase = .available(release)
        case .checking: phase = .idle
        default: break
        }
    }

    func skipThisVersion() {
        if case .available(let release) = phase { defaults.set(release.version.description, forKey: Keys.skipped) }
        phase = .idle
    }

    /// Closes the offer; the next automatic check brings it back.
    func dismiss() {
        switch phase {
        case .downloading, .verifying, .checking: cancel()
        default: break
        }
        if case .ready = phase { return }   // installs when Hexer quits
        phase = .idle
    }

    /// Quits, installs and opens the new version. Documents with changes are reviewed first, as
    /// when quitting; cancelling that keeps Hexer running with the update still staged (and
    /// `quitCancelled` forgets the relaunch).
    func relaunch() {
        relaunchesAfterInstall = true
        NSApp.terminate(nil)
    }

    /// Quitting was cancelled in the review of unsaved documents (`AppDelegate`).
    func quitCancelled() {
        relaunchesAfterInstall = false
    }

    /// Swaps the staged update in once Hexer is quitting (`applicationWillTerminate`), asking
    /// for an administrator's password where the user can't write, then reopens Hexer if
    /// Relaunch was chosen. A failure leaves the old version in place.
    func applicationWillTerminate() {
        guard let staged else { return }
        do {
            if needsAdministrator {
                try PrivilegedShell.run(AppBundleInstaller.replaceScript(bundleURL, with: staged))
            } else {
                try AppBundleInstaller.replace(bundleURL, with: staged)
            }
            // So Launch Services knows the new version (and its icon) at this path, and not at the
            // staging folder it saw the copy in, which is deleted next.
            LaunchServicesRecords.forget(staged)
            LSRegisterURL(bundleURL as CFURL, true)
        } catch PrivilegedShell.Failure.cancelled {
            NSLog("Hexer: installing the update was cancelled at the password prompt")
        } catch {
            NSLog("Hexer: installing the update failed: %@", String(describing: error))
        }
        removeStagingFolder()
        guard relaunchesAfterInstall else { return }
        // Opens the app once this process has exited; it survives Hexer quitting.
        let reopen = Process()
        reopen.executableURL = URL(fileURLWithPath: "/bin/sh")
        reopen.arguments = ["-c", "while /bin/kill -0 \"$1\" 2>/dev/null; do /bin/sleep 0.2; done; exec /usr/bin/open \"$2\"",
                            "sh", String(ProcessInfo.processInfo.processIdentifier), bundleURL.path]
        try? reopen.run()
    }

    /// A temporary folder on the app's volume, so the new app can be moved into place; remembered
    /// so a launch can remove one left behind.
    private func stagingFolder() throws -> URL {
        removeStagingFolder()
        let folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask,
                                                 appropriateFor: bundleURL, create: true)
        defaults.set(folder.path, forKey: Keys.stagingFolder)
        return folder
    }

    private func removeStagingFolder() {
        guard let path = defaults.string(forKey: Keys.stagingFolder) else { return }
        let copy = URL(fileURLWithPath: path).appendingPathComponent(UpdateStaging.appName)
        if FileManager.default.fileExists(atPath: copy.path) { LaunchServicesRecords.forget(copy) }
        try? FileManager.default.removeItem(atPath: path)
        defaults.removeObject(forKey: Keys.stagingFolder)
    }

    /// Scripted snapshots (`-HexerUpdatePreview`) show each phase without a network.
    func preview(_ phase: Phase) { self.phase = phase }
}
