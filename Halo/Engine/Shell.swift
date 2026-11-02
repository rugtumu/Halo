import Foundation

struct HaloError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

enum Binaries {
    /// Bundled static build first, then Homebrew.
    static let ffmpeg: URL? = Bundle.main.url(forResource: "ffmpeg", withExtension: nil)
        ?? firstExisting(["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"])

    static let soffice: URL? = firstExisting([
        "/Applications/LibreOffice.app/Contents/MacOS/soffice",
        "/opt/homebrew/bin/soffice",
        "/usr/local/bin/soffice",
    ])

    static let ditto = URL(fileURLWithPath: "/usr/bin/ditto")
    static let tar = URL(fileURLWithPath: "/usr/bin/tar")

    private static func firstExisting(_ paths: [String]) -> URL? {
        paths.first { FileManager.default.isExecutableFile(atPath: $0) }.map { URL(fileURLWithPath: $0) }
    }
}

enum Shell {
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String]) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            process.terminationHandler = { process in
                let output = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                let errors = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if process.terminationStatus == 0 {
                    continuation.resume(returning: output)
                } else {
                    let last = errors.split(separator: "\n").last.map(String.init)
                    continuation.resume(throwing: HaloError(
                        last ?? "\(executable.lastPathComponent) failed (\(process.terminationStatus))"))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }
}

enum Output {
    /// Where a result goes: next to the source (or the custom folder), never overwriting anything.
    static func url(for source: URL, ext: String, suffix: String? = nil,
                    folder: URL? = Prefs.outputFolder) -> URL {
        let directory = folder ?? source.deletingLastPathComponent()
        var base = source.deletingPathExtension().lastPathComponent
        if base.lowercased().hasSuffix(".tar") { base = String(base.dropLast(4)) }
        if let suffix { base += " (\(suffix))" }
        return unique(directory.appendingPathComponent("\(base).\(ext)"))
    }

    static func unique(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let directory = url.deletingLastPathComponent()
        let name = url.lastPathComponent
        // Split at the first dot so "a.tar.gz" becomes "a 2.tar.gz".
        let dot = name.firstIndex(of: ".") ?? name.endIndex
        let stem = name[..<dot], ext = name[dot...]
        var n = 2
        while true {
            let candidate = directory.appendingPathComponent("\(stem) \(n)\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            n += 1
        }
    }

    static func tempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Halo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func size(_ url: URL) -> Int { (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
}
