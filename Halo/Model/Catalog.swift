import Foundation

enum FileCategory: String, CaseIterable, Identifiable {
    case image, document, spreadsheet, audio, video, archive, subtitle

    var id: String { rawValue }

    var title: String {
        switch self {
        case .image: "Images"
        case .document: "Documents"
        case .spreadsheet: "Spreadsheets"
        case .audio: "Audio"
        case .video: "Video"
        case .archive: "Archives"
        case .subtitle: "Subtitles"
        }
    }

    var symbol: String {
        switch self {
        case .image: "photo"
        case .document: "doc.richtext"
        case .spreadsheet: "tablecells"
        case .audio: "waveform"
        case .video: "film"
        case .archive: "archivebox"
        case .subtitle: "captions.bubble"
        }
    }
}

/// Which source formats Halo can turn into which targets. Only conversions Halo actually performs are listed.
enum Catalog {
    struct Row {
        let category: FileCategory
        let source: String
        let targets: [String]
    }

    struct Matrix: Identifiable {
        let category: FileCategory
        let columns: [String]
        let rows: [Row]
        var id: FileCategory { category }

        /// A nil target list means "every column except the source itself".
        init(_ category: FileCategory, columns: [String], rows: [(String, [String]?)]) {
            self.category = category
            self.columns = columns
            self.rows = rows.map { source, targets in
                Row(category: category, source: source, targets: targets ?? columns.filter { $0 != source })
            }
        }
    }

    struct Selection {
        let category: FileCategory
        let targets: [String]
    }

    static let matrices: [Matrix] = [
        Matrix(.image,
               columns: ["jpg", "png", "webp", "heic", "tiff", "avif", "bmp", "pdf"],
               rows: ["jpg", "png", "webp", "heic", "tiff", "svg", "avif", "bmp"].map { ($0, nil) }),
        Matrix(.document,
               columns: ["pdf", "docx", "txt", "md", "html", "jpg", "png"],
               rows: [
                   ("pdf", ["docx", "txt", "md", "jpg", "png"]),
                   ("docx", nil),
                   ("ppt", ["pdf", "jpg", "png"]),
                   ("pptx", ["pdf", "jpg", "png"]),
                   ("txt", nil), ("md", nil), ("rtf", nil), ("rtfd", nil), ("textclipping", nil),
               ]),
        Matrix(.spreadsheet,
               columns: ["xlsx", "ods", "csv", "tsv", "pdf"],
               rows: ["xlsx", "xls", "ods", "csv", "tsv"].map { ($0, nil) }),
        Matrix(.audio,
               columns: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"],
               rows: ["mp3", "m4a", "wav", "flac", "ogg", "opus", "aiff", "wma"].map { ($0, nil) }),
        Matrix(.video,
               columns: ["mp4", "mov", "mkv", "webm", "avi", "wmv", "gif", "mp3"],
               rows: ["mp4", "mov", "mkv", "webm", "avi", "wmv"].map { ($0, nil) }
                   + [("gif", ["mp4", "mov", "mkv", "webm", "avi", "wmv"])]),
        Matrix(.archive,
               columns: ["zip", "tar", "gzip"],
               rows: ["zip", "tar", "gzip", "rar"].map { ($0, nil) }),
        Matrix(.subtitle,
               columns: ["srt", "vtt", "txt"],
               rows: ["srt", "vtt"].map { ($0, nil) }),
    ]

    private static let index: [String: Row] =
        Dictionary(uniqueKeysWithValues: matrices.flatMap(\.rows).map { ($0.source, $0) })

    static func normalize(_ ext: String) -> String {
        switch ext.lowercased() {
        case "jpeg", "jpe": "jpg"
        case "tif": "tiff"
        case "heif": "heic"
        case "htm": "html"
        case "markdown": "md"
        case "gz", "tgz": "gzip"
        case "aif", "aifc": "aiff"
        case "m4v": "mp4"
        default: ext.lowercased()
        }
    }

    static func row(for url: URL) -> Row? { index[normalize(url.pathExtension)] }

    /// Targets every file in the selection can reach. Mixed categories get nothing.
    static func targets(for urls: [URL]) -> Selection? {
        let rows = urls.map(row(for:))
        guard let first = rows.first ?? nil,
              rows.allSatisfy({ $0?.category == first.category }) else { return nil }
        let common = first.targets.filter { target in rows.allSatisfy { $0?.targets.contains(target) == true } }
        return Selection(category: first.category, targets: common)
    }
}
