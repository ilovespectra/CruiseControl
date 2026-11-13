import AppKit
import CryptoKit
import CruiseCore

@MainActor
final class AppUpdates: ObservableObject {
    static let shared = AppUpdates()
    static let repository = "ilovespectra/CruiseControl"
    @Published private(set) var available: Release?
    @Published private(set) var status = "Updates have not been checked."
    @Published private(set) var busy = false
    private var timer: Timer?
    var installedVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }
    var isLocalTesting: Bool { Bundle.main.object(forInfoDictionaryKey: "CruiseControlLocalTesting") as? Bool == true }
    var versionDescription: String { isLocalTesting ? "\(installedVersion) (local testing)" : installedVersion }

    struct Asset: Decodable {
        let name: String
        let browser_download_url: URL
    }
    struct Release: Decodable {
        let tag_name: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]
    }
    struct Manifest: Decodable {
        let version: String
        let commit: String
        let package: String
        let sha256: String
        let notarized: Bool
    }

    func start() {
        guard !isLocalTesting else {
            status = "Local testing build. GitHub release checks and installation are disabled."
            return
        }
        Task { await check() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in await self.check() }
        }
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 else {
            throw UpdateError.invalid("Download failed or no public release is available.")
        }
        return data
    }

    func check() async {
        guard !isLocalTesting else {
            available = nil
            status = "Local testing build. GitHub release checks and installation are disabled."
            return
        }
        guard !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let url = URL(string: "https://api.github.com/repos/\(Self.repository)/releases/latest")!
            let release = try JSONDecoder().decode(Release.self, from: await fetch(url))
            guard !release.draft, !release.prerelease, let version = ReleaseVersion(release.tag_name),
                  let current = ReleaseVersion(installedVersion) else {
                throw UpdateError.invalid("The release version is invalid.")
            }
            available = version > current ? release : nil
            status = available == nil ? "Cruise Control \(installedVersion) is up to date." : "Update Available: \(release.tag_name)"
        } catch {
            status = "Could not check for updates: \(error.localizedDescription)"
        }
    }

    private func asset(_ name: String, release: Release) throws -> URL {
        let matches = release.assets.filter { $0.name == name }
        guard matches.count == 1, let url = matches.first?.browser_download_url,
              url.scheme == "https", url.host == "github.com",
              url.path.hasPrefix("/\(Self.repository)/releases/download/\(release.tag_name)/") else {
            throw UpdateError.invalid("Missing or untrusted release asset: \(name)")
        }
        return url
    }

    func install() async {
        guard !isLocalTesting else {
            status = "Local testing builds cannot install public releases. Rebuild the checkout instead."
            return
        }
        guard !busy, let release = available else { return }
        let alert = NSAlert()
        alert.messageText = "Download and install \(release.tag_name)?"
        alert.informativeText = """
        The package may be unsigned and not notarized. macOS can block it or warn about its publisher.
        Cruise Control verifies its SHA-256 against the GitHub release, not an Apple-certified identity.
        Only proceed if you trust this project. Installer will ask for permission; your settings remain intact.
        If blocked, review System Settings > Privacy & Security. Security protections are not disabled.
        """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Download package")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        busy = true
        defer { busy = false }
        do {
            status = "Downloading release metadata…"
            let manifest = try JSONDecoder().decode(Manifest.self, from: await fetch(asset("release.json", release: release)))
            guard ReleaseVersion(manifest.version) == ReleaseVersion(release.tag_name),
                  manifest.commit.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil,
                  manifest.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
                  manifest.package == "CruiseControl.pkg" else {
                throw UpdateError.invalid("Release metadata does not match this version.")
            }
            status = "Downloading \(manifest.package)…"
            let data = try await fetch(asset(manifest.package, release: release))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == manifest.sha256 else { throw UpdateError.invalid("Package checksum mismatch. Installation cancelled.") }
            let directory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Caches/CruiseControl/Updates/\(manifest.version)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let destination = directory.appendingPathComponent(manifest.package)
            try data.write(to: destination, options: .atomic)
            guard NSWorkspace.shared.open(destination) else { throw UpdateError.invalid("Could not open the macOS installer.") }
            status = "Verified package opened in Installer. Complete installation to update."
        } catch {
            status = "Update failed: \(error.localizedDescription)"
        }
    }

    enum UpdateError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { switch self { case .invalid(let message): return message } }
    }
}
