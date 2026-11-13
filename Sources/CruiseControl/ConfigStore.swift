import AppKit
import CruiseCore

@MainActor
final class ConfigStore: ObservableObject {
    static let directory: URL = {
        let environment = ProcessInfo.processInfo.environment
        let localPath = environment["CRUISE_LOCAL_TEST"] == "1"
            ? environment["CRUISE_LOCAL_CONFIG_DIR"] : nil
        let dir: URL
        if let localPath, localPath.hasPrefix("/") {
            dir = URL(fileURLWithPath: localPath, isDirectory: true).standardizedFileURL
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/CruiseControl", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    let fileURL = ConfigStore.directory.appendingPathComponent("config.json")
    private var loading = false

    @Published var config: Config {
        didSet {
            BrandPalette.shared.theme = config.colorTheme
            if !loading && config != oldValue { save() }
        }
    }

    init() {
        config = Config()
        if let loaded = Self.read(from: fileURL) {
            loading = true
            config = loaded
            loading = false
        }
        if !FileManager.default.fileExists(atPath: fileURL.path)
            || CommandLine.arguments.contains("--import-heyclicky-theme") {
            let domain = ClickyTaskLibrary.preferencesDomain as CFString
            CFPreferencesAppSynchronize(domain)
            if let hex = CFPreferencesCopyAppValue("overlayCursorColorHex" as CFString, domain) as? String {
                if let theme = ColorTheme.heyClickyCursorTheme(hex: hex) {
                    config.colorTheme = theme
                    NSLog("Cruise appearance: imported HeyClicky Cursor color as %@", theme.title)
                } else {
                    NSLog("Cruise appearance: unsupported HeyClicky Cursor color; retaining saved theme")
                }
            }
        }
        BrandPalette.shared.theme = config.colorTheme
        // Rewrite so new keys show up in the file for editing.
        save()
    }

    func reloadFromDisk() {
        guard let loaded = Self.read(from: fileURL), loaded != config else { return }
        loading = true
        config = loaded
        loading = false
    }

    private func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(config) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    private static func read(from url: URL) -> Config? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Config.self, from: data)
    }
}
