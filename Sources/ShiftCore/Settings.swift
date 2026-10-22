import Foundation

/// The keys you hold while dragging files to bring up the action bar.
public struct TriggerModifiers: OptionSet, Codable, Hashable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let control = TriggerModifiers(rawValue: 1 << 0)
    public static let option = TriggerModifiers(rawValue: 1 << 1)
    public static let shift = TriggerModifiers(rawValue: 1 << 2)
    public static let command = TriggerModifiers(rawValue: 1 << 3)
    public static let function = TriggerModifiers(rawValue: 1 << 4)

    /// In the order macOS writes them: ⌃⌥⇧⌘, then fn.
    public static let all: [(key: TriggerModifiers, symbol: String, name: String)] = [
        (.control, "⌃", "Control"), (.option, "⌥", "Option"), (.shift, "⇧", "Shift"),
        (.command, "⌘", "Command"), (.function, "fn", "Fn"),
    ]

    public var symbols: String { Self.all.filter { contains($0.key) }.map(\.symbol).joined() }
    public var names: String { Self.all.filter { contains($0.key) }.map(\.name).joined(separator: " + ") }
    /// "⇧ Shift", "⌥⇧ Option + Shift".
    public var label: String { "\(symbols) \(names)" }
}

/// One action in a file kind's list: shown or hidden, in the order of the array.
public struct ActionEntry: Codable, Hashable, Sendable {
    public var id: String
    public var enabled: Bool

    public init(id: String, enabled: Bool) {
        self.id = id
        self.enabled = enabled
    }
}

/// Everything you set in Shift's settings. Stored as JSON in user defaults, shared by the app and the CLI.
public struct ShiftSettings: Codable, Equatable, Sendable {
    public var imagePresets: [ImagePreset]
    public var videoPresets: [VideoPreset]
    public var pdfPresets: [PDFPreset]
    /// Per `FileKind.rawValue`: which actions appear in the bar, in order.
    public var layout: [String: [ActionEntry]]
    public var outputDirectory: String?
    /// Save results next to each original instead of in the output folder.
    public var saveNextToOriginal: Bool
    public var copyResultsToClipboard: Bool
    public var triggerModifiers: TriggerModifiers
    /// What the Crop… form starts with: new copies or replacing originals, compressed or not.
    public var cropDefaults: CropOptions

    public static let defaults = ShiftSettings(
        imagePresets: Presets.defaultImage,
        videoPresets: Presets.defaultVideo,
        pdfPresets: Presets.defaultPDF,
        layout: defaultLayout,
        outputDirectory: nil,
        saveNextToOriginal: false,
        copyResultsToClipboard: false,
        triggerModifiers: .shift,
        cropDefaults: CropOptions()
    )

    /// Off until you turn them on: rarely needed formats.
    static let hiddenByDefault: Set<String> = ["convert-avif", "convert-heic", "convert-tiff", "preset-half"]

    static let defaultLayout: [String: [ActionEntry]] = {
        let order: [FileKind: [String]] = [
            .image: ["preset-web", "convert-jpeg", "convert-png", "convert-webp", "preset-compress", "crop", "preset-half",
                     "preset-1920", "preset-1280", "preset-640", "images-to-pdf", "markdown-image",
                     "convert-avif", "convert-heic", "convert-tiff"],
            .document: ["text-to-pdf", "markdown-document", "text-to-txt"],
            .pdf: ["preset-pdf-compress", "markdown-pdf", "pdf-to-png", "pdf-to-jpeg"],
            .video: ["preset-video-1080", "preset-video-720", "video-mp4", "extract-audio", "markdown-video"],
            .audio: ["audio-m4a", "markdown-audio"],
        ]
        return Dictionary(uniqueKeysWithValues: order.map { kind, ids in
            (kind.rawValue, ids.map { ActionEntry(id: $0, enabled: !hiddenByDefault.contains($0)) })
        })
    }()

    public init(imagePresets: [ImagePreset], videoPresets: [VideoPreset], pdfPresets: [PDFPreset],
                layout: [String: [ActionEntry]], outputDirectory: String?, saveNextToOriginal: Bool, copyResultsToClipboard: Bool,
                triggerModifiers: TriggerModifiers, cropDefaults: CropOptions) {
        self.imagePresets = imagePresets
        self.videoPresets = videoPresets
        self.pdfPresets = pdfPresets
        self.layout = layout
        self.outputDirectory = outputDirectory
        self.saveNextToOriginal = saveNextToOriginal
        self.copyResultsToClipboard = copyResultsToClipboard
        self.triggerModifiers = triggerModifiers
        self.cropDefaults = cropDefaults
    }

    /// Missing keys fall back to the defaults, so settings survive new fields in later versions.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Self.defaults
        imagePresets = try c.decodeIfPresent([ImagePreset].self, forKey: .imagePresets) ?? d.imagePresets
        videoPresets = try c.decodeIfPresent([VideoPreset].self, forKey: .videoPresets) ?? d.videoPresets
        pdfPresets = try c.decodeIfPresent([PDFPreset].self, forKey: .pdfPresets) ?? d.pdfPresets
        layout = try c.decodeIfPresent([String: [ActionEntry]].self, forKey: .layout) ?? d.layout
        outputDirectory = try c.decodeIfPresent(String.self, forKey: .outputDirectory)
        saveNextToOriginal = try c.decodeIfPresent(Bool.self, forKey: .saveNextToOriginal) ?? d.saveNextToOriginal
        copyResultsToClipboard = try c.decodeIfPresent(Bool.self, forKey: .copyResultsToClipboard) ?? d.copyResultsToClipboard
        let trigger = try c.decodeIfPresent(TriggerModifiers.self, forKey: .triggerModifiers) ?? d.triggerModifiers
        triggerModifiers = trigger.isEmpty ? d.triggerModifiers : trigger
        cropDefaults = try c.decodeIfPresent(CropOptions.self, forKey: .cropDefaults) ?? d.cropDefaults
    }

    // MARK: Storage

    private static let key = "settings"

    /// The app reads its own defaults domain; the CLI reads the app's domain by name.
    static var store: UserDefaults {
        Bundle.main.bundleIdentifier == "men.stuur.shift" ? .standard : UserDefaults(suiteName: "men.stuur.shift") ?? .standard
    }

    public static func load() -> ShiftSettings {
        guard let data = store.data(forKey: key), let settings = try? JSONDecoder().decode(ShiftSettings.self, from: data) else {
            var settings = defaults
            // Output folder chosen before settings existed.
            settings.outputDirectory = store.url(forKey: "outputDirectory")?.path
            return settings
        }
        return settings
    }

    public func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Self.store.set(data, forKey: Self.key)
    }

    public var outputURL: URL {
        outputDirectory.map { URL(fileURLWithPath: $0) } ?? Processor.defaultOutputDirectory
    }

    /// Where results go: the output folder, or nil for next to each original.
    public var resultDirectory: URL? { saveNextToOriginal ? nil : outputURL }

    // MARK: Actions

    /// Built-in actions plus your presets for a kind.
    public func availableActions(for kind: FileKind) -> [ShiftAction] {
        let presets: [ShiftAction]
        switch kind {
        case .image: presets = imagePresets.map { .imagePreset($0) }
        case .video: presets = videoPresets.map { .videoPreset($0) }
        case .pdf: presets = pdfPresets.map { .pdfPreset($0) }
        default: presets = []
        }
        return presets + ShiftAction.builtIns(for: kind)
    }

    /// Every action for a kind in your order. Actions you have not placed yet (a new preset) go at the end, shown.
    public func orderedEntries(for kind: FileKind) -> [(action: ShiftAction, enabled: Bool)] {
        let available = availableActions(for: kind)
        let byID = Dictionary(available.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [(action: ShiftAction, enabled: Bool)] = []
        for entry in layout[kind.rawValue] ?? [] {
            if let action = byID[entry.id], seen.insert(entry.id).inserted { result.append((action, entry.enabled)) }
        }
        for action in available where !seen.contains(action.id) {
            result.append((action, !Self.hiddenByDefault.contains(action.id)))
        }
        return result
    }

    /// Looks up an action by id, presets included. "web" still works for the web preset.
    public func action(id: String) -> ShiftAction? {
        let id = id == "web" ? "preset-web" : id
        return FileKind.allCases.lazy.flatMap { availableActions(for: $0) }.first { $0.id == id }
    }

    public mutating func setEnabled(_ enabled: Bool, actionID: String, kind: FileKind) {
        var entries = orderedEntries(for: kind).map { ActionEntry(id: $0.action.id, enabled: $0.enabled) }
        if let index = entries.firstIndex(where: { $0.id == actionID }) { entries[index].enabled = enabled }
        layout[kind.rawValue] = entries
    }

    public mutating func moveActions(kind: FileKind, from source: IndexSet, to destination: Int) {
        var entries = orderedEntries(for: kind).map { ActionEntry(id: $0.action.id, enabled: $0.enabled) }
        let moving = source.sorted().map { entries[$0] }
        for index in source.sorted(by: >) { entries.remove(at: index) }
        let shift = source.filter { $0 < destination }.count
        entries.insert(contentsOf: moving, at: min(destination - shift, entries.count))
        layout[kind.rawValue] = entries
    }

    public mutating func resetLayout(kind: FileKind) {
        layout[kind.rawValue] = Self.defaultLayout[kind.rawValue]
    }
}
