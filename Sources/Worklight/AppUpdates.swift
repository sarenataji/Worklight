import AppKit
import CryptoKit
import Foundation

struct AppVersion: Comparable, Equatable {
    let parts: [Int]
    init?(_ value: String) {
        let raw = value.hasPrefix("v") ? String(value.dropFirst()) : value
        let fields = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }), fields.allSatisfy({ Int($0) != nil }) else { return nil }
        parts = fields.map { Int($0)! }
    }
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.parts.lexicographicallyPrecedes(rhs.parts) }
}

struct AppRelease: Decodable {
    struct Asset: Decodable {
        let name: String
        let digest: String?
    }
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    let assets: [Asset]
    var package: Asset? { assets.first { $0.name == "Worklight-macOS-universal.zip" } }
    func isNewer(than version: String) -> Bool {
        guard !draft, !prerelease, package != nil, let candidate = AppVersion(tag_name), let current = AppVersion(version) else { return false }
        return candidate > current
    }
}

struct UpdateFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Private releases use the user's existing gh authentication; no tokens are stored by Worklight.
enum AppUpdateService {
    static let repository = "sarenataji/Worklight"
    static let cache = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches/dev.worklight.mac/Updates")
    static var gh: String? { ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) } }
    static func check(current: String) throws -> AppRelease? {
        guard let gh else { throw UpdateFailure(message: "Update checks need GitHub CLI signed in to this private repository. Run gh auth login, then refresh.") }
        let result = run(gh, ["api", "repos/\(repository)/releases?per_page=100"], timeout: 30)
        guard result.status == 0 else { throw UpdateFailure(message: "Couldn’t check releases. Check your connection and GitHub CLI access to Worklight.") }
        let releases = try JSONDecoder().decode([AppRelease].self, from: Data(result.output.utf8))
        return releases.filter { $0.isNewer(than: current) }.max { AppVersion($0.tag_name)! < AppVersion($1.tag_name)! }
    }
    static func validArchivePaths(_ listing: String) -> Bool {
        let paths = listing.split(separator: "\n")
        return !paths.isEmpty && paths.allSatisfy { entry in
            let path = String(entry)
            return (path == "Worklight.app/" || path.hasPrefix("Worklight.app/")) && !path.split(separator: "/").contains("..") && !path.contains("\\")
        }
    }
    static func verifyBundle(_ app: URL, expectedVersion: String) throws {
        let info = app.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: info),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["CFBundleIdentifier"] as? String == "dev.worklight.mac",
              plist["CFBundleExecutable"] as? String == "Worklight",
              let version = plist["CFBundleShortVersionString"] as? String,
              AppVersion(version) == AppVersion(expectedVersion), AppVersion(version) != nil else {
            throw UpdateFailure(message: "The downloaded app’s identity or version did not match the release.")
        }
        guard run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]).status == 0 else {
            throw UpdateFailure(message: "The downloaded app failed its signature integrity check.")
        }
        let arch = run("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/Worklight").path])
        guard arch.status == 0, arch.output.contains("arm64"), arch.output.contains("x86_64") else {
            throw UpdateFailure(message: "The update is not a universal Mac build.")
        }
    }
    static func prepare(_ release: AppRelease, target: URL) throws -> URL {
        let fm = FileManager.default
        guard target.pathExtension == "app", fm.isWritableFile(atPath: target.deletingLastPathComponent().path) else {
            throw UpdateFailure(message: "Move Worklight to your Applications folder before installing updates.")
        }
        guard let gh, let package = release.package, AppVersion(release.tag_name) != nil,
              let digest = package.digest, digest.hasPrefix("sha256:"), digest.count == 71 else {
            throw UpdateFailure(message: "This release has no verifiable universal app package.")
        }
        let staging = cache.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        let download = run(gh, ["release", "download", release.tag_name, "--repo", repository, "--pattern", package.name, "--dir", staging.path], timeout: 180)
        guard download.status == 0 else { throw UpdateFailure(message: "Update download failed. Your installed app has not changed.") }
        let archive = staging.appendingPathComponent(package.name)
        let hash = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        guard "sha256:" + hash == digest.lowercased() else { throw UpdateFailure(message: "Update checksum did not match. Your installed app has not changed.") }
        let names = run("/usr/bin/unzip", ["-Z", "-1", archive.path])
        let types = run("/usr/bin/zipinfo", ["-l", archive.path])
        guard names.status == 0, types.status == 0, validArchivePaths(names.output), !types.output.split(separator: "\n").contains(where: { $0.hasPrefix("l") }) else {
            throw UpdateFailure(message: "The update archive contains unexpected paths or links.")
        }
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path], timeout: 60).status == 0 else {
            throw UpdateFailure(message: "Couldn’t unpack the update.")
        }
        let app = staging.appendingPathComponent("Worklight.app")
        try verifyBundle(app, expectedVersion: release.tag_name)
        let prepared = target.deletingLastPathComponent().appendingPathComponent(".Worklight-update-\(UUID().uuidString).app")
        do {
            try fm.copyItem(at: app, to: prepared)
            try verifyBundle(prepared, expectedVersion: release.tag_name)
        } catch { try? fm.removeItem(at: prepared); throw error }
        return prepared
    }
    static func replace(prepared: URL, target: URL, launch: (URL) -> Bool) throws {
        let fm = FileManager.default
        let backup = target.deletingLastPathComponent().appendingPathComponent(".Worklight-backup-\(UUID().uuidString).app")
        try fm.moveItem(at: target, to: backup)
        do {
            try fm.moveItem(at: prepared, to: target)
            guard launch(target) else { throw UpdateFailure(message: "Updated app could not be opened.") }
        } catch {
            try? fm.removeItem(at: target)
            do { try fm.moveItem(at: backup, to: target) }
            catch { throw UpdateFailure(message: "Update recovery needs attention. The previous app is preserved at \(backup.path).") }
            _ = launch(target)
            throw error
        }
        try? fm.removeItem(at: backup)
    }
    /// Executed by a copy of the current app binary, after the UI has prepared the update.
    static func apply(arguments: [String]) -> Int32 {
        guard arguments.count == 4, let pid = Int32(arguments[0]) else { return 1 }
        let prepared = URL(fileURLWithPath: arguments[1])
        let target = URL(fileURLWithPath: arguments[2])
        let version = arguments[3]
        let fm = FileManager.default
        do {
            guard prepared.deletingLastPathComponent() == target.deletingLastPathComponent(), prepared.lastPathComponent.hasPrefix(".Worklight-update-"), target.pathExtension == "app" else {
                throw UpdateFailure(message: "Invalid update destination.")
            }
            try verifyBundle(prepared, expectedVersion: version)
            let deadline = Date().addingTimeInterval(60)
            while kill(pid, 0) == 0 && Date() < deadline { Thread.sleep(forTimeInterval: 0.25) }
            guard kill(pid, 0) != 0 else { throw UpdateFailure(message: "Worklight did not quit; update was cancelled.") }
            guard let info = NSDictionary(contentsOf: target.appendingPathComponent("Contents/Info.plist")), info["CFBundleIdentifier"] as? String == "dev.worklight.mac" else {
                throw UpdateFailure(message: "Installed app identity does not match Worklight.")
            }
            try replace(prepared: prepared, target: target) { run("/usr/bin/open", [$0.path]).status == 0 }
            return 0
        } catch {
            try? fm.createDirectory(at: cache, withIntermediateDirectories: true)
            try? error.localizedDescription.write(to: cache.appendingPathComponent("last-error.txt"), atomically: true, encoding: .utf8)
            if prepared.deletingLastPathComponent() == target.deletingLastPathComponent(), prepared.lastPathComponent.hasPrefix(".Worklight-update-") {
                try? fm.removeItem(at: prepared)
            }
            return 1
        }
    }
}

@MainActor
final class AppUpdater: ObservableObject {
    static let shared = AppUpdater()
    @Published private(set) var release: AppRelease?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    init() {
        let errorFile = AppUpdateService.cache.appendingPathComponent("last-error.txt")
        if let error = try? String(contentsOf: errorFile, encoding: .utf8) {
            message = "Last update failed: " + error
            try? FileManager.default.removeItem(at: errorFile)
        }
    }
    func check() {
        guard !busy else { return }
        busy = true; message = "Checking app updates…"; release = nil
        let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.3.0"
        Task {
            do {
                release = try await Task.detached(priority: .utility) { try AppUpdateService.check(current: current) }.value
                message = release == nil ? "No newer published update" : "Update \(release!.tag_name) available"
            } catch { message = error.localizedDescription }
            busy = false
        }
    }
    func install() {
        guard !busy, let release else { return }
        busy = true; message = "Downloading and verifying update…"
        let target = Bundle.main.bundleURL
        Task {
            do {
                let prepared = try await Task.detached(priority: .utility) { try AppUpdateService.prepare(release, target: target) }.value
                let helper = AppUpdateService.cache.appendingPathComponent("helper-\(UUID().uuidString)")
                do {
                    guard let executable = Bundle.main.executableURL else { throw UpdateFailure(message: "Cannot locate the updater executable.") }
                    try FileManager.default.copyItem(at: executable, to: helper)
                    let process = Process()
                    process.executableURL = helper
                    process.arguments = ["--apply-update", String(ProcessInfo.processInfo.processIdentifier), prepared.path, target.path, release.tag_name]
                    try process.run()
                    WorkTimeTracker.shared.stop()
                    NSApplication.shared.terminate(nil)
                } catch {
                    try? FileManager.default.removeItem(at: prepared)
                    try? FileManager.default.removeItem(at: helper)
                    throw error
                }
            } catch { message = error.localizedDescription; busy = false }
        }
    }
}
