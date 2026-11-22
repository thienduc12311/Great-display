import Foundation
import AppKit
import CryptoKit
import os

private let updateLog = Logger(subsystem: "app.greatdisplay.GreatDisplay", category: "update")

/// Checks GitHub for a newer release, downloads it, verifies it and replaces
/// the running app.
///
/// Releases come from `.github/workflows/release.yml`: each has
/// `GreatDisplay-<version>.zip` and `SHA256SUMS.txt`. An update is installed
/// only when the zip matches its published checksum, the app inside passes
/// `codesign --verify`, and it has this app's bundle identifier and the
/// release's version. The swap happens in a small shell helper after this
/// process quits, so the old bundle is never replaced while it is running.
@MainActor
public final class UpdateController: ObservableObject {
    public static let shared = UpdateController()

    public struct Release: Equatable {
        public let version: String
        public let name: String
        public let notes: String
        public let pageURL: URL
        let zipURL: URL
        let zipName: String
        let checksumsURL: URL?
    }

    public enum State: Equatable {
        case idle
        case checking
        case upToDate(checkedAt: Date)
        case available(Release)
        case downloading(Release, progress: Double)
        case installing(Release)
        case failed(String)
    }

    @Published public private(set) var state: State = .idle
    /// The newest release when it is newer than this app, kept while
    /// downloading or after a failed install so the UI can offer it again.
    @Published public private(set) var availableRelease: Release?

    public static let repository = "thienduc12311/Great-display"
    private static let lastCheckKey = "GDLastUpdateCheck"
    private static let skippedVersionKey = "GDSkippedUpdateVersion"
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    /// Called when an automatic (launch or daily) check finds a release the
    /// user has not skipped. The app shows its update prompt from here.
    public var onUpdateFound: ((Release) -> Void)?

    private var timer: Timer?
    private var downloadTask: Task<Void, Never>?

    private init() {}

    public var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    public var isBusy: Bool {
        switch state {
        case .checking, .downloading, .installing: return true
        default: return false
        }
    }

    // MARK: Scheduling

    /// Checks at every launch (after `launchDelay`) and then once a day,
    /// while the setting is on.
    public func startAutomaticChecks(launchDelay: TimeInterval = 5) {
        timer?.invalidate()
        timer = nil
        guard SettingsStore.shared.state.general.automaticallyCheckForUpdates else { return }
        timer = Timer.scheduledTimer(withTimeInterval: launchDelay, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.check(userInitiated: false)
                self.startAutomaticChecks(launchDelay: Self.checkInterval)
            }
        }
    }

    /// The version the user chose to skip in the update prompt.
    public var skippedVersion: String? {
        get { UserDefaults.standard.string(forKey: Self.skippedVersionKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.skippedVersionKey) }
    }

    // MARK: Checking

    /// Asks GitHub for the latest (non pre-release) release.
    public func check(userInitiated: Bool = true) {
        guard !isBusy else { return }
        state = .checking
        Task {
            do {
                let release = try await Self.fetchLatestRelease()
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if let release, Self.isVersion(release.version, newerThan: currentVersion) {
                    updateLog.notice("update available: \(release.version, privacy: .public)")
                    availableRelease = release
                    state = .available(release)
                    if !userInitiated && release.version != skippedVersion {
                        onUpdateFound?(release)
                    }
                } else {
                    availableRelease = nil
                    state = .upToDate(checkedAt: Date())
                }
            } catch {
                updateLog.error("update check failed: \(error.localizedDescription, privacy: .public)")
                // Background checks fail quietly (offline, rate limited).
                state = userInitiated ? .failed("Could not check for updates: \(error.localizedDescription)") : .idle
            }
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }

    private static func fetchLatestRelease() async throws -> Release? {
        let url = URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("GreatDisplay-Updater", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw UpdateError("No response from GitHub") }
        if http.statusCode == 404 { return nil }
        guard http.statusCode == 200 else { throw UpdateError("GitHub answered \(http.statusCode)") }
        let release = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard !release.draft, !release.prerelease else { return nil }
        let version = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        guard let zip = release.assets.first(where: { $0.name == "GreatDisplay-\(version).zip" })
                ?? release.assets.first(where: { $0.name.hasSuffix(".zip") }) else {
            throw UpdateError("Release \(version) has no app download")
        }
        let sums = release.assets.first { $0.name == "SHA256SUMS.txt" }
        return Release(version: version, name: release.name ?? "Great Display \(version)",
                       notes: release.body ?? "", pageURL: release.html_url,
                       zipURL: zip.browser_download_url, zipName: zip.name,
                       checksumsURL: sums?.browser_download_url)
    }

    /// Numeric comparison of dotted versions; a pre-release suffix sorts
    /// before the plain version (1.3.0-beta.1 < 1.3.0).
    nonisolated public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        func parts(_ version: String) -> (numbers: [Int], pre: Bool) {
            let core = version.split(separator: "-", maxSplits: 1)
            let numbers = core.first.map { $0.split(separator: ".").map { Int($0) ?? 0 } } ?? []
            return (numbers, core.count > 1)
        }
        let a = parts(candidate), b = parts(current)
        for index in 0..<max(a.numbers.count, b.numbers.count) {
            let x = index < a.numbers.count ? a.numbers[index] : 0
            let y = index < b.numbers.count ? b.numbers[index] : 0
            if x != y { return x > y }
        }
        return !a.pre && b.pre
    }

    // MARK: Installing

    /// Where the running app lives, and whether it can be replaced in place.
    public var installLocation: URL { Bundle.main.bundleURL }

    public var canInstallInPlace: Bool {
        let parent = installLocation.deletingLastPathComponent().path
        return installLocation.pathExtension == "app"
            && FileManager.default.isWritableFile(atPath: parent)
            && !installLocation.path.hasPrefix("/Volumes/")
    }

    /// Downloads, verifies and installs the available release, then relaunches.
    public func downloadAndInstall() {
        guard let release = availableRelease, !isBusy else { return }
        guard canInstallInPlace else {
            state = .failed("Great Display can't replace itself at \(installLocation.deletingLastPathComponent().path). Move it to Applications, or download the update from the release page.")
            return
        }
        state = .downloading(release, progress: 0)
        downloadTask = Task {
            do {
                let staged = try await stage(release)
                state = .installing(release)
                try launchInstaller(newApp: staged)
                updateLog.notice("installing \(release.version, privacy: .public); quitting")
                // Give the UI a moment to show "Installing…".
                try? await Task.sleep(nanoseconds: 400_000_000)
                NSApp.terminate(nil)
            } catch is CancellationError {
                state = .available(release)
            } catch {
                updateLog.error("update failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(error.localizedDescription)
            }
        }
    }

    public func cancelDownload() {
        downloadTask?.cancel()
    }

    /// Downloads and verifies the release; returns the unpacked app bundle.
    private func stage(_ release: Release) async throws -> URL {
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("GreatDisplayUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)

        let zip = work.appendingPathComponent(release.zipName)
        try await download(release.zipURL, to: zip) { [weak self] fraction in
            self?.state = .downloading(release, progress: fraction)
        }
        try Task.checkCancellation()

        // Checksum from the release's SHA256SUMS.txt.
        guard let sumsURL = release.checksumsURL else { throw UpdateError("The release has no SHA256SUMS.txt to verify the download") }
        var request = URLRequest(url: sumsURL, timeoutInterval: 30)
        request.setValue("GreatDisplay-Updater", forHTTPHeaderField: "User-Agent")
        let (sumsData, _) = try await URLSession.shared.data(for: request)
        let sums = String(decoding: sumsData, as: UTF8.self)
        guard let expected = sums.split(whereSeparator: \.isNewline)
                .map({ $0.split(separator: " ", omittingEmptySubsequences: true) })
                .first(where: { $0.count >= 2 && $0.last.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "*")) } == release.zipName })?
                .first.map({ String($0).lowercased() }) else {
            throw UpdateError("SHA256SUMS.txt has no entry for \(release.zipName)")
        }
        let actual = try await Task.detached { try Self.sha256(of: zip) }.value
        guard actual == expected else { throw UpdateError("The download does not match its published checksum") }

        // Unpack and check the app inside.
        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try FileManager.default.createDirectory(at: unpacked, withIntermediateDirectories: true)
        try await Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let app = try FileManager.default.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil)
                .first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app) else {
            throw UpdateError("The download does not contain an app")
        }
        guard bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError("The downloaded app is not Great Display")
        }
        let version = bundle.infoDictionary?["CFBundleShortVersionString"] as? String
        guard version == release.version else {
            throw UpdateError("The downloaded app is version \(version ?? "?"), expected \(release.version)")
        }
        try await Self.run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
        // Downloaded through URLSession, so normally not quarantined; clear it
        // anyway so the relaunch is not blocked.
        _ = try? await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
        return app
    }

    private func download(_ url: URL, to destination: URL,
                          progress: @escaping @MainActor (Double) -> Void) async throws {
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.setValue("GreatDisplay-Updater", forHTTPHeaderField: "User-Agent")
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw UpdateError("Download failed (\((response as? HTTPURLResponse)?.statusCode ?? 0))")
        }
        let total = max(1, response.expectedContentLength)
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        var buffer = Data()
        buffer.reserveCapacity(1 << 16)
        var written: Int64 = 0
        var lastReported = 0.0
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 1 << 16 {
                try handle.write(contentsOf: buffer)
                written += Int64(buffer.count)
                buffer.removeAll(keepingCapacity: true)
                let fraction = Double(written) / Double(total)
                if fraction - lastReported > 0.01 {
                    lastReported = fraction
                    progress(min(1, fraction))
                }
                try Task.checkCancellation()
            }
        }
        if !buffer.isEmpty { try handle.write(contentsOf: buffer) }
        progress(1)
    }

    nonisolated private static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Starts a helper that waits for this process to quit, swaps the bundle
    /// (keeping the old one until the new one is in place) and relaunches.
    private func launchInstaller(newApp: URL) throws {
        let target = installLocation
        let backup = newApp.deletingLastPathComponent().appendingPathComponent("previous.app")
        let script = """
        #!/bin/bash
        # Great Display updater: waits for the app to quit, then replaces it.
        pid="$1"; new="$2"; target="$3"; backup="$4"
        for _ in $(seq 1 300); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
        if /bin/mv "$target" "$backup" && /usr/bin/ditto "$new" "$target"; then
            /bin/rm -rf "$backup"
        else
            /bin/rm -rf "$target"
            /bin/mv "$backup" "$target"
        fi
        /usr/bin/open "$target"
        """
        let scriptURL = newApp.deletingLastPathComponent().appendingPathComponent("install.sh")
        try script.write(to: scriptURL, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, String(ProcessInfo.processInfo.processIdentifier),
                             newApp.path, target.path, backup.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: output, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                let name = (tool as NSString).lastPathComponent
                throw UpdateError("\(name) failed: \(text.trimmingCharacters(in: .whitespacesAndNewlines))")
            }
            return text
        }.value
    }
}

struct UpdateError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
