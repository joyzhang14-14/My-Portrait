import SwiftUI
import AppKit

/// Streaming-friendly Markdown renderer.
///
/// Hand-rolled parser covering the subset assistant replies actually use:
///   - Fenced code blocks (```lang\n...\n```) with a copy button
///   - ATX headings (#, ##, ###)
///   - Bullet and numbered lists
///   - Blockquotes
///   - Tables (pipe syntax)
///   - Paragraphs with **bold**, *italic*, `inline code`, [text](url)
///
/// Each block is its own SwiftUI view so a long answer doesn't re-render the
/// whole document when one new token lands at the tail.
struct MarkdownView: View {
    let source: String

    var body: some View {
        let blocks = MarkdownParser.parse(source)
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                renderBlock(block)
            }
        }
    }

    @ViewBuilder
    private func renderBlock(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(MDInline.attributed(text))
                .font(.system(size: [22, 18, 16, 15, 14, 13][min(level - 1, 5)],
                              weight: .semibold))
                .foregroundStyle(.white.opacity(0.97))
                .padding(.top, 4)

        case .paragraph(let text):
            Text(MDInline.attributed(text))
                .font(.system(size: 15))
                .foregroundStyle(.white.opacity(0.96))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(5)

        case .codeBlock(let lang, let code):
            CodeBlockView(language: lang, code: code)

        case .bulletList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(.white.opacity(0.55))
                        Text(MDInline.attributed(item))
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.96))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numberedList(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.55))
                        Text(MDInline.attributed(item))
                            .font(.system(size: 15))
                            .foregroundStyle(.white.opacity(0.96))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .blockquote(let text):
            HStack(spacing: 0) {
                RoundedRectangle(cornerRadius: 1).fill(Color.purple.opacity(0.5))
                    .frame(width: 3)
                Text(MDInline.attributed(text))
                    .font(.system(size: 14))
                    .italic()
                    .foregroundStyle(.white.opacity(0.78))
                    .padding(.horizontal, 10)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .table(let headers, let rows):
            TableView(headers: headers, rows: rows)

        case .horizontalRule:
            Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1)
                .padding(.vertical, 4)
        }
    }
}

// MARK: - Code block

private struct CodeBlockView: View {
    let language: String
    let code: String
    @State private var copied = false
    @State private var hover = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text(language.isEmpty ? "code" : language)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(0.6)
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button(action: copyToClipboard) {
                    HStack(spacing: 4) {
                        Image(systemName: copied ? "checkmark" : "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                        Text(copied ? "Copied" : "Copy")
                            .font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(.white.opacity(hover || copied ? 0.95 : 0.55))
                }
                .buttonStyle(.bouncyIcon)
            }
            .padding(.horizontal, 12).padding(.vertical, 7)

            Divider().background(Color.white.opacity(0.08))

            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(size: 12.5, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.92))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .fixedSize(horizontal: true, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.white.opacity(0.04))
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 0.7)
                )
        )
        .onHover { hover = $0 }
    }

    private func copyToClipboard() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(code, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { copied = false }
    }
}

// MARK: - Table

private struct TableView: View {
    let headers: [String]
    let rows: [[String]]
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            row(cells: headers, isHeader: true)
            Divider().background(Color.white.opacity(0.10))
            ForEach(Array(rows.enumerated()), id: \.offset) { idx, r in
                row(cells: r, isHeader: false)
                if idx < rows.count - 1 {
                    Divider().background(Color.white.opacity(0.06))
                }
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.white.opacity(0.03))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.white.opacity(0.10), lineWidth: 0.7)
                )
        )
    }

    private func row(cells: [String], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { _, cell in
                Text(MDInline.attributed(cell))
                    .font(.system(size: isHeader ? 12 : 13,
                                  weight: isHeader ? .semibold : .regular))
                    .foregroundStyle(.white.opacity(isHeader ? 0.85 : 0.92))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10).padding(.vertical, 7)
            }
        }
    }
}

// MARK: - Inline parser

/// Builds an `AttributedString` for one paragraph / list-item / table-cell
/// line. Supports **bold**, *italic*, `code`, [text](url) — the things that
/// commonly appear inside assistant replies. Anything fancier (HTML, footnotes)
/// renders as plain text.
enum MDInline {
    static func attributed(_ s: String) -> AttributedString {
        var out = AttributedString()
        var i = s.startIndex
        var plain = ""
        func flushPlain() {
            guard !plain.isEmpty else { return }
            out += AttributedString(plain)
            plain = ""
        }
        while i < s.endIndex {
            let ch = s[i]
            // **bold**
            if ch == "*",
               let end = matchPair(in: s, from: i, delim: "**") {
                flushPlain()
                let inner = String(s[s.index(i, offsetBy: 2)..<end])
                var a = attributed(inner)
                a.font = .system(size: 15, weight: .semibold)
                out += a
                i = s.index(end, offsetBy: 2)
                continue
            }
            // *italic*
            if ch == "*",
               let end = matchPair(in: s, from: i, delim: "*") {
                flushPlain()
                let inner = String(s[s.index(i, offsetBy: 1)..<end])
                var a = attributed(inner)
                a.font = .system(size: 15).italic()
                out += a
                i = s.index(end, offsetBy: 1)
                continue
            }
            // `code`
            if ch == "`",
               let end = s[s.index(after: i)...].firstIndex(of: "`") {
                flushPlain()
                let inner = String(s[s.index(after: i)..<end])
                var a = AttributedString(inner)
                a.font = .system(size: 13.5, design: .monospaced)
                a.backgroundColor = .white.opacity(0.08)
                out += a
                i = s.index(after: end)
                continue
            }
            // [text](url)
            if ch == "[",
               let closeBracket = s[s.index(after: i)...].firstIndex(of: "]"),
               s.index(after: closeBracket) < s.endIndex,
               s[s.index(after: closeBracket)] == "(",
               let closeParen = s[s.index(closeBracket, offsetBy: 2)...].firstIndex(of: ")") {
                flushPlain()
                let text = String(s[s.index(after: i)..<closeBracket])
                let url  = String(s[s.index(closeBracket, offsetBy: 2)..<closeParen])
                var a = AttributedString(text)
                a.foregroundColor = .cyan
                a.underlineStyle = .single
                if let u = URL(string: url) { a.link = u }
                out += a
                i = s.index(after: closeParen)
                continue
            }
            plain.append(ch)
            i = s.index(after: i)
        }
        flushPlain()
        return out
    }

    /// Finds the next occurrence of `delim` after `from + delim.count`.
    private static func matchPair(in s: String, from: String.Index, delim: String) -> String.Index? {
        let startSearch = s.index(from, offsetBy: delim.count, limitedBy: s.endIndex) ?? s.endIndex
        guard startSearch < s.endIndex else { return nil }
        return s.range(of: delim, range: startSearch..<s.endIndex)?.lowerBound
    }
}

// MARK: - Block parser

enum MDBlock {
    case heading(level: Int, text: String)
    case paragraph(String)
    case codeBlock(language: String, code: String)
    case bulletList([String])
    case numberedList([String])
    case blockquote(String)
    case table(headers: [String], rows: [[String]])
    case horizontalRule
}

enum MarkdownParser {
    static func parse(_ source: String) -> [MDBlock] {
        var blocks: [MDBlock] = []
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block
            if trimmed.hasPrefix("```") {
                let lang = String(trimmed.dropFirst(3))
                var code = ""
                i += 1
                while i < lines.count, !lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code += lines[i] + "\n"
                    i += 1
                }
                // Skip closing fence (if present)
                if i < lines.count { i += 1 }
                if code.hasSuffix("\n") { code.removeLast() }
                blocks.append(.codeBlock(language: lang, code: code))
                continue
            }
            // Heading
            if let h = parseHeading(trimmed) {
                blocks.append(h); i += 1; continue
            }
            // Horizontal rule
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                blocks.append(.horizontalRule); i += 1; continue
            }
            // Bullet list
            if isBullet(trimmed) {
                var items: [String] = []
                while i < lines.count, isBullet(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripBullet(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.bulletList(items))
                continue
            }
            // Numbered list
            if isNumbered(trimmed) {
                var items: [String] = []
                while i < lines.count, isNumbered(lines[i].trimmingCharacters(in: .whitespaces)) {
                    items.append(stripNumbered(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.numberedList(items))
                continue
            }
            // Blockquote
            if trimmed.hasPrefix(">") {
                var quoted: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quoted.append(lines[i].trimmingCharacters(in: .whitespaces)
                        .dropFirst().trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.blockquote(quoted.joined(separator: "\n")))
                continue
            }
            // Table (header line | sep line | rows…)
            if trimmed.contains("|"),
               i + 1 < lines.count,
               lines[i + 1].trimmingCharacters(in: .whitespaces).contains("|"),
               lines[i + 1].replacingOccurrences(of: " ", with: "").contains("|--") ||
               lines[i + 1].replacingOccurrences(of: " ", with: "").contains("--|") ||
               lines[i + 1].trimmingCharacters(in: .whitespaces).hasPrefix("|---") {
                let headers = splitRow(trimmed)
                i += 2  // skip sep
                var rows: [[String]] = []
                while i < lines.count, lines[i].contains("|"), !lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    rows.append(splitRow(lines[i].trimmingCharacters(in: .whitespaces)))
                    i += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }
            // Empty line — paragraph boundary
            if trimmed.isEmpty { i += 1; continue }
            // Default: paragraph (gather contiguous non-empty non-special lines)
            var paragraph: [String] = []
            while i < lines.count {
                let t = lines[i].trimmingCharacters(in: .whitespaces)
                if t.isEmpty || t.hasPrefix("```") || parseHeading(t) != nil ||
                   isBullet(t) || isNumbered(t) || t.hasPrefix(">") ||
                   t == "---" || t == "***" || t == "___" {
                    break
                }
                paragraph.append(lines[i])
                i += 1
            }
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
            }
        }
        return blocks
    }

    // MARK: - line predicates

    private static func parseHeading(_ s: String) -> MDBlock? {
        for level in (1...6).reversed() {
            let prefix = String(repeating: "#", count: level) + " "
            if s.hasPrefix(prefix) {
                return .heading(level: level, text: String(s.dropFirst(prefix.count)))
            }
        }
        return nil
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }
    private static func stripBullet(_ s: String) -> String {
        String(s.dropFirst(2))
    }
    private static func isNumbered(_ s: String) -> Bool {
        guard let firstSpace = s.firstIndex(of: " ") else { return false }
        let head = s[..<firstSpace]
        return head.hasSuffix(".") && head.dropLast().allSatisfy { $0.isNumber }
    }
    private static func stripNumbered(_ s: String) -> String {
        guard let firstSpace = s.firstIndex(of: " ") else { return s }
        return String(s[s.index(after: firstSpace)...])
    }
    private static func splitRow(_ s: String) -> [String] {
        var t = s
        if t.hasPrefix("|") { t.removeFirst() }
        if t.hasSuffix("|") { t.removeLast() }
        return t.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }
}
