import SwiftUI

@main
struct PublisherApp: App {
    @StateObject private var publisher = BinaryPublisher()

    var body: some Scene {
        WindowGroup("Cruise Control Publisher") {
            VStack(alignment: .leading, spacing: 16) {
                Text("Repackage binaries").font(.title2.bold())
                Text("Persistent local web console — not included in the public Cruise Control app.")
                    .foregroundStyle(.secondary)
                Text("Commit and push changes to the production branch first. Builds use an isolated workspace that is cleaned afterward. GitHub drafts require the official repository owner's admin permission; other users get local previews only.")
                HStack {
                    TextField("CruiseControl source folder", text: $publisher.repositoryPath)
                    Button("Choose…") { publisher.chooseRepository() }
                }.disabled(publisher.running)
                HStack {
                    Button("Open developer console") { publisher.openConsole() }
                    if publisher.running { ProgressView().controlSize(.small) }
                }.disabled(publisher.running)
                ScrollView {
                    Text(publisher.log.isEmpty ? "Ready. Requires Swift, Python 3 and authenticated GitHub CLI." : publisher.log)
                        .font(.system(size: 12, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(24)
            .frame(minWidth: 700, minHeight: 460)
        }
    }
}
