import Foundation

enum WheelAction {
    case convert(String)
    case tool(Tool)
    case quick(QuickAction)
}

struct WheelItem: Identifiable {
    let id: String
    let title: String
    let symbol: String?
    let action: WheelAction
}

enum Tool: String, CaseIterable {
    case compress, metadata, edit, annotate, addBackground, crop, resize, redact, trim, channels, bleep

    static let imageTools: [Tool] = [.compress, .metadata, .edit, .annotate, .addBackground, .crop, .resize, .redact]

    var title: String {
        switch self {
        case .compress: "Compress"
        case .metadata: "Metadata"
        case .edit: "Edit"
        case .annotate: "Annotate"
        case .addBackground: "Add BG"
        case .crop: "Crop"
        case .resize: "Resize"
        case .redact: "Redact"
        case .trim: "Trim"
        case .channels: "Channels"
        case .bleep: "Bleep"
        }
    }

    var progressTitle: String {
        switch self {
        case .compress: "Compressing"
        case .resize: "Resizing"
        case .metadata: "Removing metadata"
        default: "Saving"
        }
    }

    var symbol: String {
        switch self {
        case .compress: "arrow.down.right.and.arrow.up.left"
        case .metadata: "tag"
        case .edit: "slider.horizontal.3"
        case .annotate: "pencil.tip.crop.circle"
        case .addBackground: "photo.on.rectangle"
        case .crop: "crop"
        case .resize: "arrow.up.left.and.arrow.down.right"
        case .redact: "eye.slash"
        case .trim: "scissors"
        case .channels: "hifispeaker.2"
        case .bleep: "speaker.slash"
        }
    }

    /// These open an editor window instead of running straight away.
    var isImageEditor: Bool { [.metadata, .edit, .annotate, .addBackground, .crop, .redact].contains(self) }
    var isMediaEditor: Bool { [.trim, .channels, .bleep].contains(self) }
}

enum QuickAction: String, CaseIterable {
    case airdrop, float, copy, move, copyPath, terminal

    var title: String {
        switch self {
        case .airdrop: "AirDrop"
        case .float: "Float"
        case .copy: "Copy"
        case .move: "Move"
        case .copyPath: "Copy Path"
        case .terminal: "Terminal"
        }
    }

    var symbol: String {
        switch self {
        case .airdrop: "antenna.radiowaves.left.and.right"
        case .float: "pin"
        case .copy: "doc.on.doc"
        case .move: "folder"
        case .copyPath: "link"
        case .terminal: "terminal"
        }
    }
}

enum WheelBuilder {
    static func items(_ kind: WheelKind, for urls: [URL]) -> [WheelItem] {
        switch kind {
        case .conversion:
            guard let selection = Catalog.targets(for: urls) else { return [] }
            let disabled = Prefs.disabledFormats
            return selection.targets
                .filter { target in
                    !disabled.contains("\(selection.category.rawValue).\(target)")
                        && urls.allSatisfy {
                            Converter.isAvailable(selection.category, from: Catalog.normalize($0.pathExtension), to: target)
                        }
                }
                .map { WheelItem(id: $0, title: $0.uppercased(), symbol: nil, action: .convert($0)) }
                .orderedFor(.conversion, selection.category)
        case .tools:
            let perFile = urls.map(ToolEngine.tools(for:))
            guard let first = perFile.first else { return [] }
            return first
                .filter { tool in perFile.allSatisfy { $0.contains(tool) } }
                .map { WheelItem(id: $0.rawValue, title: $0.title, symbol: $0.symbol, action: .tool($0)) }
                .orderedFor(.tools, urls.first.flatMap { Catalog.row(for: $0)?.category })
        case .actions:
            return QuickAction.allCases.map {
                WheelItem(id: $0.rawValue, title: $0.title, symbol: $0.symbol, action: .quick($0))
            }
            .orderedFor(.actions, nil)
        }
    }
}

extension Tool {
    /// Default wheel order per file kind; ToolEngine narrows it to what the file supports.
    static func defaults(for category: FileCategory) -> [Tool] {
        switch category {
        case .image: imageTools
        case .audio: [.compress, .metadata, .trim, .channels, .bleep]
        case .video: [.compress, .resize, .metadata, .trim, .channels, .bleep]
        case .document: [.compress]
        default: []
        }
    }
}

/// User-defined wheel order, stored per wheel and file kind as comma-separated item ids.
enum WheelOrder {
    static func key(_ kind: WheelKind, _ category: FileCategory?) -> String {
        (["order", kind.rawValue] + (category.map { [$0.rawValue] } ?? [])).joined(separator: ".")
    }

    static func saved(_ key: String) -> [String] {
        (UserDefaults.standard.string(forKey: key) ?? "").split(separator: ",").map(String.init)
    }

    static func defaultIDs(_ kind: WheelKind, _ category: FileCategory?) -> [String] {
        switch kind {
        case .conversion: Catalog.matrices.first { $0.category == category }?.columns ?? []
        case .tools: category.map { Tool.defaults(for: $0).map(\.rawValue) } ?? []
        case .actions: QuickAction.allCases.map(\.rawValue)
        }
    }

    /// Saved positions first; items the user never placed (e.g. added in an update) keep their default order after them.
    static func ordered(_ ids: [String], saved: [String]) -> [String] {
        let rank = Dictionary(saved.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        return ids.enumerated()
            .sorted { (rank[$0.element] ?? saved.count + $0.offset) < (rank[$1.element] ?? saved.count + $1.offset) }
            .map(\.element)
    }

    static func apply(_ items: [WheelItem], _ kind: WheelKind, _ category: FileCategory?) -> [WheelItem] {
        let order = ordered(items.map(\.id), saved: saved(key(kind, category)))
        return order.compactMap { id in items.first { $0.id == id } }
    }
}

extension WheelBuilder {
    /// Builds a single item from its id, for previews of a saved order.
    static func item(_ id: String, kind: WheelKind) -> WheelItem? {
        switch kind {
        case .conversion: WheelItem(id: id, title: id.uppercased(), symbol: nil, action: .convert(id))
        case .tools: Tool(rawValue: id).map { WheelItem(id: id, title: $0.title, symbol: $0.symbol, action: .tool($0)) }
        case .actions: QuickAction(rawValue: id).map { WheelItem(id: id, title: $0.title, symbol: $0.symbol, action: .quick($0)) }
        }
    }
}

private extension Array where Element == WheelItem {
    func orderedFor(_ kind: WheelKind, _ category: FileCategory?) -> [WheelItem] { WheelOrder.apply(self, kind, category) }
}
