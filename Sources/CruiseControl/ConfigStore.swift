import AppKit
import CruiseCore

@MainActor
final class ConfigStore: ObservableObject {
    static let directory: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CruiseControl", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()

    let fileURL = ConfigStore.directory.appendingPathComponent("config.json")
    private var loading = false

    @Published var config: Config {
        didSet {
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
