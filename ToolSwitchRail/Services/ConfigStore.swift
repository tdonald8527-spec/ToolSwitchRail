import Foundation
import AppKit

@MainActor
final class ConfigStore: ObservableObject {
    @Published private(set) var configuration: ToolRailConfiguration
    @Published private(set) var configURL: URL

    private var timer: Timer?
    private var lastModificationDate: Date?

    init() {
        let fm = FileManager.default
        let support = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = support.appendingPathComponent("ToolSwitchRail", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let resolvedConfigURL = folder.appendingPathComponent("config.json")

        if !fm.fileExists(atPath: resolvedConfigURL.path),
           let bundled = Bundle.main.url(forResource: "default-config", withExtension: "json") {
            try? fm.copyItem(at: bundled, to: resolvedConfigURL)
        }

        self.configURL = resolvedConfigURL
        self.configuration = Self.load(from: resolvedConfigURL) ?? Self.fallbackConfiguration()
        self.lastModificationDate = Self.modificationDate(of: resolvedConfigURL)
        startWatching()
    }

    deinit {
        timer?.invalidate()
    }

    func reload() {
        guard let newConfig = Self.load(from: configURL) else { return }
        configuration = newConfig
        lastModificationDate = Self.modificationDate(of: configURL)
    }

    func openConfigFile() {
        NSWorkspace.shared.open(configURL)
    }

    func revealConfigFile() {
        NSWorkspace.shared.activateFileViewerSelecting([configURL])
    }

    func reorderTools(sourceID: String, targetID: String) {
        var updated = configuration.tools
        guard sourceID != targetID,
              let sourceIndex = updated.firstIndex(where: { $0.id == sourceID }),
              let targetIndex = updated.firstIndex(where: { $0.id == targetID }) else { return }

        let item = updated.remove(at: sourceIndex)
        updated.insert(item, at: targetIndex)

        // Reassign hotkeyIndex 1...N for enabled tools
        var counter = 1
        for i in 0..<updated.count {
            if updated[i].enabled {
                updated[i].hotkeyIndex = (counter <= 9) ? counter : nil
                counter += 1
            }
        }

        configuration.tools = updated
        save()
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(configuration) else { return }
        try? data.write(to: configURL)
        lastModificationDate = Self.modificationDate(of: configURL)
    }

    private func startWatching() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let date = Self.modificationDate(of: self.configURL)
                if date != self.lastModificationDate {
                    self.reload()
                }
            }
        }
    }

    private static func modificationDate(of url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date
    }

    private static func load(from url: URL) -> ToolRailConfiguration? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        return try? decoder.decode(ToolRailConfiguration.self, from: data)
    }

    private static func fallbackConfiguration() -> ToolRailConfiguration {
        ToolRailConfiguration(
            workspace: WorkspaceConfig(
                railWidth: 56,
                widthFraction: 0.84,
                heightFraction: 0.82,
                minimumWidth: 960,
                minimumHeight: 680,
                appearance: .system,
                minimizeOtherRegisteredWindows: true
            ),
            browser: BrowserConfig(appName: "Google Chrome", bundleIdentifier: "com.google.Chrome"),
            tools: []
        )
    }
}
