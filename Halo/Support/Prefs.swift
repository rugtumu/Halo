import AppKit

enum WheelKind: String, CaseIterable, Identifiable {
    case conversion, tools, actions

    var id: String { rawValue }

    var title: String {
        switch self {
        case .conversion: "Conversion wheel"
        case .tools: "Tools wheel"
        case .actions: "Actions wheel"
        }
    }

    var defaultModifier: ModifierKey {
        switch self {
        case .conversion: .shift
        case .tools: .command
        case .actions: .control
        }
    }
}

enum ModifierKey: String, CaseIterable, Identifiable {
    case shift, command, control, option

    var id: String { rawValue }

    var flag: CGEventFlags {
        switch self {
        case .shift: .maskShift
        case .command: .maskCommand
        case .control: .maskControl
        case .option: .maskAlternate
        }
    }

    var label: String {
        switch self {
        case .shift: "⇧ Shift"
        case .command: "⌘ Cmd"
        case .control: "⌃ Ctrl"
        case .option: "⌥ Option"
        }
    }
}

enum WheelStyle: String { case glass, solid }
enum FloatBehaviour: String { case new, existing }

enum Prefs {
    enum Key {
        static let style = "style"
        static let showMenuBar = "showMenuBar"
        static let sound = "sound"
        static let haptic = "haptic"
        static let reveal = "revealResults"
        static let outputMode = "outputMode"
        static let outputFolder = "outputFolder"
        static let floatBehaviour = "floatBehaviour"
        static let terminalApp = "terminalApp"
        static let disabledFormats = "disabledFormats"
        static func modifier(_ kind: WheelKind) -> String { "modifier.\(kind.rawValue)" }
    }

    static let defaultTerminal = "/System/Applications/Utilities/Terminal.app"
    private static var defaults: UserDefaults { .standard }

    static func registerDefaults() {
        var values: [String: Any] = [
            Key.style: WheelStyle.glass.rawValue,
            Key.showMenuBar: true,
            Key.sound: true,
            Key.haptic: true,
            Key.reveal: false,
            Key.outputMode: "source",
            Key.floatBehaviour: FloatBehaviour.new.rawValue,
            Key.terminalApp: defaultTerminal,
            Key.disabledFormats: "",
        ]
        for kind in WheelKind.allCases { values[Key.modifier(kind)] = kind.defaultModifier.rawValue }
        defaults.register(defaults: values)
    }

    static func modifier(for kind: WheelKind) -> ModifierKey {
        ModifierKey(rawValue: defaults.string(forKey: Key.modifier(kind)) ?? "") ?? kind.defaultModifier
    }

    static var style: WheelStyle { WheelStyle(rawValue: defaults.string(forKey: Key.style) ?? "") ?? .glass }
    static var sound: Bool { defaults.bool(forKey: Key.sound) }
    static var haptic: Bool { defaults.bool(forKey: Key.haptic) }
    static var reveal: Bool { defaults.bool(forKey: Key.reveal) }
    static var floatBehaviour: FloatBehaviour { FloatBehaviour(rawValue: defaults.string(forKey: Key.floatBehaviour) ?? "") ?? .new }
    static var terminalApp: URL { URL(fileURLWithPath: defaults.string(forKey: Key.terminalApp) ?? defaultTerminal) }

    /// nil means "next to the original file".
    static var outputFolder: URL? {
        guard defaults.string(forKey: Key.outputMode) == "custom",
              let path = defaults.string(forKey: Key.outputFolder), !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Keys look like "image.webp" so the same target can be hidden per category.
    static var disabledFormats: Set<String> {
        Set((defaults.string(forKey: Key.disabledFormats) ?? "").split(separator: ",").map(String.init))
    }
}
