import Foundation

struct ToolRailConfiguration: Codable {
    var workspace: WorkspaceConfig
    var browser: BrowserConfig
    var tools: [ToolItem]
}

struct WorkspaceConfig: Codable {
    var railWidth: Double
    var widthFraction: Double
    var heightFraction: Double
    var minimumWidth: Double
    var minimumHeight: Double
    var appearance: AppearanceMode
    var minimizeOtherRegisteredWindows: Bool
}

enum AppearanceMode: String, Codable {
    case system
    case light
    case dark
}

struct BrowserConfig: Codable {
    var appName: String
    var bundleIdentifier: String?
}

enum ToolKind: String, Codable {
    case app
    case web
}

struct ToolItem: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var kind: ToolKind
    var appName: String?
    var bundleIdentifier: String?
    var url: String?
    var titleContains: [String]?
    var symbolName: String?
    var iconPath: String?
    var hotkeyIndex: Int?
    var enabled: Bool
    var theme: String?
    var backgroundColor: String?

    var resolvedTheme: AppearanceMode {
        if let t = theme?.lowercased() {
            if t == "light" { return .light }
            if t == "dark" { return .dark }
            if t == "system" { return .system }
        }
        switch id.lowercased() {
        case "workbuddy":
            return .dark
        case "wps-lingxi", "wpslingxi", "lingxi":
            return .dark
        default:
            return .dark
        }
    }

    var resolvedBackgroundColor: String {
        if let bg = backgroundColor?.trimmingCharacters(in: .whitespacesAndNewlines), !bg.isEmpty {
            return bg
        }
        switch id.lowercased() {
        case "workbuddy":
            return "#1F1F1F"
        case "wps-lingxi", "wpslingxi", "lingxi":
            return "#121212"
        case "codex", "chatgpt", "chatgpt-app", "chatgpt-mac":
            return "#212121"
        case "antigravity":
            return "#181818"
        case "gemini-web", "gemini":
            return "#131314"
        case "hermes":
            return "#111111"
        case "grok-bot", "grokbot", "grok-web", "grok":
            return "#000000"
        case "chatgpt-web":
            return "#212121"
        default:
            return resolvedTheme == .light ? "#FFFFFF" : "#212121"
        }
    }

    var titleHints: [String] {
        var list = (titleContains ?? []).filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if list.isEmpty {
            list.append(name)
        }
        if kind == .web, let url = url, let host = URL(string: url)?.host {
            let cleanHost = host.replacingOccurrences(of: "www.", with: "")
            if !cleanHost.isEmpty && !list.contains(where: { $0.localizedCaseInsensitiveCompare(cleanHost) == .orderedSame }) {
                list.append(cleanHost)
            }
        }
        return list
    }

    enum CodingKeys: String, CodingKey {
        case id, name, kind, type
        case appName
        case bundleIdentifier, bundleId
        case url
        case titleContains, windowTitleMatch
        case symbolName, icon, iconPath
        case hotkeyIndex
        case enabled
        case theme
        case backgroundColor, bgColor, color
    }

    init(
        id: String,
        name: String,
        kind: ToolKind,
        appName: String? = nil,
        bundleIdentifier: String? = nil,
        url: String? = nil,
        titleContains: [String]? = nil,
        symbolName: String? = nil,
        iconPath: String? = nil,
        hotkeyIndex: Int? = nil,
        enabled: Bool = true,
        theme: String? = nil,
        backgroundColor: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.appName = appName
        self.bundleIdentifier = bundleIdentifier
        self.url = url
        self.titleContains = titleContains
        self.symbolName = symbolName
        self.iconPath = iconPath
        self.hotkeyIndex = hotkeyIndex
        self.enabled = enabled
        self.theme = theme
        self.backgroundColor = backgroundColor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decode(String.self, forKey: .name)
        id = (try? container.decode(String.self, forKey: .id)) ?? name.lowercased().replacingOccurrences(of: " ", with: "-")

        if let k = try? container.decode(ToolKind.self, forKey: .kind) {
            kind = k
        } else if let t = try? container.decode(ToolKind.self, forKey: .type) {
            kind = t
        } else {
            kind = .app
        }

        appName = try? container.decode(String.self, forKey: .appName)
        bundleIdentifier = (try? container.decode(String.self, forKey: .bundleIdentifier)) ?? (try? container.decode(String.self, forKey: .bundleId))
        url = try? container.decode(String.self, forKey: .url)

        var titles = try? container.decode([String].self, forKey: .titleContains)
        if titles == nil {
            if let single = try? container.decode(String.self, forKey: .windowTitleMatch) {
                titles = [single]
            } else {
                titles = try? container.decode([String].self, forKey: .windowTitleMatch)
            }
        }
        titleContains = titles

        let iconVal = try? container.decode(String.self, forKey: .icon)
        let symVal = try? container.decode(String.self, forKey: .symbolName)
        let pathVal = try? container.decode(String.self, forKey: .iconPath)

        if let iconVal, !iconVal.isEmpty {
            if iconVal.hasPrefix("/") || iconVal.hasPrefix("~") {
                iconPath = iconVal
                symbolName = symVal
            } else {
                symbolName = iconVal
                iconPath = pathVal
            }
        } else {
            symbolName = symVal
            iconPath = pathVal
        }

        hotkeyIndex = try? container.decode(Int.self, forKey: .hotkeyIndex)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        theme = try? container.decode(String.self, forKey: .theme)
        backgroundColor = (try? container.decode(String.self, forKey: .backgroundColor))
            ?? (try? container.decode(String.self, forKey: .bgColor))
            ?? (try? container.decode(String.self, forKey: .color))
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(appName, forKey: .appName)
        try container.encodeIfPresent(bundleIdentifier, forKey: .bundleIdentifier)
        try container.encodeIfPresent(url, forKey: .url)
        try container.encodeIfPresent(titleContains, forKey: .titleContains)
        try container.encodeIfPresent(symbolName, forKey: .symbolName)
        try container.encodeIfPresent(iconPath, forKey: .iconPath)
        try container.encodeIfPresent(hotkeyIndex, forKey: .hotkeyIndex)
        try container.encode(enabled, forKey: .enabled)
        try container.encodeIfPresent(theme, forKey: .theme)
        try container.encodeIfPresent(backgroundColor, forKey: .backgroundColor)
    }
}
