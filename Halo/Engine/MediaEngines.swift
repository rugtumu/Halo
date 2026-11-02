import Foundation

enum MediaEngine {
    static func run(input: URL, output: URL, _ codec: [String]) async throws {
        guard let ffmpeg = Binaries.ffmpeg else { throw HaloError("ffmpeg not found") }
        do {
            try await Shell.run(ffmpeg, ["-hide_banner", "-nostats", "-loglevel", "error", "-y", "-i", input.path]
                + codec + [output.path])
        } catch {
            try? FileManager.default.removeItem(at: output)
            throw error
        }
    }

    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let output = Output.url(for: url, ext: ext)
        try await run(input: url, output: output, codec(for: ext))
        return output
    }

    static func codec(for ext: String) -> [String] {
        // Encoders need even dimensions and 4:2:0 for broad player compatibility.
        let even = ["-vf", "scale=trunc(iw/2)*2:trunc(ih/2)*2", "-pix_fmt", "yuv420p"]
        return switch ext {
        case "mp3": ["-vn", "-c:a", "libmp3lame", "-q:a", "2"]
        case "m4a": ["-vn", "-c:a", "aac", "-b:a", "256k"]
        case "wav": ["-vn", "-c:a", "pcm_s16le"]
        case "aiff": ["-vn", "-c:a", "pcm_s16be"]
        case "flac": ["-vn", "-c:a", "flac"]
        case "ogg": ["-vn", "-c:a", "libvorbis", "-q:a", "6"]
        case "opus": ["-vn", "-c:a", "libopus", "-b:a", "160k"]
        case "wma": ["-vn", "-c:a", "wmav2", "-b:a", "192k"]
        // VideoToolbox keeps H.264 encodes on the media engine instead of the CPU.
        case "mp4": ["-c:v", "h264_videotoolbox", "-q:v", "65", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"] + even
        case "mov", "mkv": ["-c:v", "h264_videotoolbox", "-q:v", "65", "-c:a", "aac", "-b:a", "192k"] + even
        case "webm": ["-c:v", "libvpx-vp9", "-crf", "32", "-b:v", "0", "-row-mt", "1", "-c:a", "libopus"] + even
        case "avi": ["-c:v", "mpeg4", "-q:v", "3", "-c:a", "libmp3lame"] + even
        case "wmv": ["-c:v", "wmv2", "-b:v", "4M", "-c:a", "wmav2"] + even
        case "gif": ["-an", "-vf", "fps=15,scale='min(720,iw)':-2:flags=lanczos,split[a][b];[a]palettegen[p];[b][p]paletteuse"]
        default: []
        }
    }
}

enum ArchiveEngine {
    static func convert(_ url: URL, to ext: String) async throws -> URL {
        let temp = try Output.tempDirectory()
        defer { try? FileManager.default.removeItem(at: temp) }

        if Catalog.normalize(url.pathExtension) == "zip" {
            try await Shell.run(Binaries.ditto, ["-x", "-k", url.path, temp.path])
        } else {
            // bsdtar reads tar, tar.gz and RAR.
            try await Shell.run(Binaries.tar, ["-xf", url.path, "-C", temp.path])
        }

        let output = Output.url(for: url, ext: ext == "gzip" ? "tar.gz" : ext)
        switch ext {
        case "zip": try await Shell.run(Binaries.ditto, ["-c", "-k", "--sequesterRsrc", temp.path, output.path])
        case "tar": try await Shell.run(Binaries.tar, ["-cf", output.path, "-C", temp.path, "."])
        default: try await Shell.run(Binaries.tar, ["-czf", output.path, "-C", temp.path, "."])
        }
        return output
    }
}

enum SubtitleEngine {
    struct Cue {
        let timing: String
        let lines: [String]
    }

    static func convert(_ url: URL, to ext: String) throws -> URL {
        let text = try String(contentsOf: url, encoding: .utf8)
        let result: String
        switch (Catalog.normalize(url.pathExtension), ext) {
        case ("srt", "vtt"): result = srtToVTT(text)
        case ("vtt", "srt"): result = vttToSRT(text)
        case (_, "txt"): result = plainText(text)
        default: throw HaloError("Can't convert \(url.lastPathComponent) to \(ext.uppercased())")
        }
        let output = Output.url(for: url, ext: ext)
        try result.write(to: output, atomically: true, encoding: .utf8)
        return output
    }

    /// Blocks without a "-->" line (WEBVTT header, NOTE, STYLE) are dropped.
    static func cues(_ text: String) -> [Cue] {
        text.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
            .compactMap { block in
                let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
                guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { return nil }
                return Cue(timing: lines[timing], lines: Array(lines[(timing + 1)...]))
            }
    }

    static func srtToVTT(_ text: String) -> String {
        "WEBVTT\n\n" + cues(text).map { stamp($0.timing, separator: ".") + "\n" + $0.lines.joined(separator: "\n") }
            .joined(separator: "\n\n") + "\n"
    }

    static func vttToSRT(_ text: String) -> String {
        cues(text).enumerated().map { i, cue in
            "\(i + 1)\n\(stamp(cue.timing, separator: ","))\n\(cue.lines.joined(separator: "\n"))"
        }.joined(separator: "\n\n") + "\n"
    }

    static func plainText(_ text: String) -> String {
        cues(text).flatMap(\.lines)
            .map { $0.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression) }
            .joined(separator: "\n") + "\n"
    }

    /// Normalises "00:01.5 --> 00:02.0 align:start" to "00:00:01,500 --> ..." style stamps.
    private static func stamp(_ line: String, separator: String) -> String {
        line.components(separatedBy: "-->").prefix(2).map { part in
            var s = part.trimmingCharacters(in: .whitespaces).components(separatedBy: " ").first ?? ""
            s = s.replacingOccurrences(of: ",", with: ".").replacingOccurrences(of: ".", with: separator)
            if s.filter({ $0 == ":" }).count == 1 { s = "00:" + s }
            return s
        }.joined(separator: " --> ")
    }
}
