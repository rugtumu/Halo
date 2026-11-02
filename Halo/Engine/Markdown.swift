import AppKit

/// Just enough Markdown for document conversion: headings, lists, quotes, code, emphasis, links.
enum Markdown {
    static func html(_ markdown: String) -> String {
        var out: [String] = [], paragraph: [String] = []
        var list: String?, inCode = false

        func flushParagraph() {
            if !paragraph.isEmpty { out.append("<p>\(paragraph.map(inline).joined(separator: " "))</p>") }
            paragraph = []
        }
        func closeList() {
            if let tag = list { out.append("</\(tag)>") }
            list = nil
        }
        func listItem(_ tag: String, _ text: String) {
            flushParagraph()
            if list != tag { closeList(); out.append("<\(tag)>"); list = tag }
            out.append("<li>\(inline(text))</li>")
        }

        for raw in markdown.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                flushParagraph(); closeList()
                out.append(inCode ? "</code></pre>" : "<pre><code>")
                inCode.toggle()
                continue
            }
            if inCode { out.append(escape(raw)); continue }
            if line.isEmpty { flushParagraph(); closeList(); continue }

            let hashes = line.prefix { $0 == "#" }.count
            if (1...6).contains(hashes), line.dropFirst(hashes).first == " " {
                flushParagraph(); closeList()
                out.append("<h\(hashes)>\(inline(String(line.dropFirst(hashes + 1))))</h\(hashes)>")
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                listItem("ul", String(line.dropFirst(2)))
            } else if let marker = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                listItem("ol", String(line[marker.upperBound...]))
            } else if line.hasPrefix("> ") {
                flushParagraph(); closeList()
                out.append("<blockquote>\(inline(String(line.dropFirst(2))))</blockquote>")
            } else {
                closeList()
                paragraph.append(line)
            }
        }
        flushParagraph(); closeList()
        if inCode { out.append("</code></pre>") }

        return """
        <html><head><meta charset="utf-8"><style>
        body{font:13px -apple-system,Helvetica;line-height:1.5;color:#111}
        pre{font:12px Menlo;background:#f4f4f4;padding:8px}blockquote{color:#555}
        </style></head><body>\(out.joined(separator: "\n"))</body></html>
        """
    }

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func inline(_ s: String) -> String {
        var t = escape(s)
        let rules = [
            (#"`([^`]+)`"#, "<code>$1</code>"),
            (#"\*\*(.+?)\*\*"#, "<b>$1</b>"),
            (#"\*(.+?)\*"#, "<i>$1</i>"),
            (#"\[([^\]]+)\]\(([^)]+)\)"#, "<a href=\"$2\">$1</a>"),
        ]
        for (pattern, template) in rules {
            t = t.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        return t
    }

    /// Plain text with bold/italic runs marked up; layout beyond that is not preserved.
    static func from(_ text: NSAttributedString) -> String {
        var result = ""
        text.enumerateAttribute(.font, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            let run = (text.string as NSString).substring(with: range)
            let traits = (value as? NSFont)?.fontDescriptor.symbolicTraits ?? []
            let bold = traits.contains(.bold), italic = traits.contains(.italic)
            guard bold || italic else { return result += run }
            let mark = bold && italic ? "***" : bold ? "**" : "*"
            result += run.components(separatedBy: "\n").map { segment in
                let core = segment.trimmingCharacters(in: .whitespaces)
                return core.isEmpty ? segment : segment.replacingOccurrences(of: core, with: mark + core + mark)
            }.joined(separator: "\n")
        }
        return result
    }
}
