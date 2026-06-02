import Foundation

/// Strips obvious PII from text before it leaves the device (i.e. before it
/// gets pasted into the prompt we send to Pi → ChatGPT).
///
/// Covers the bread-and-butter cases that show up in OCR'd screens:
/// emails, phone numbers, credit cards, SSNs, common API keys (OpenAI,
/// Anthropic, GitHub, AWS, generic Bearer), and IP addresses.
///
/// Not a substitute for a real DLP product — a determined leak still gets
/// through (e.g. PII spelled out in prose). The goal is to catch the
/// obvious surface area when the user toggles the shield in the input bar.
enum PIIRedactor {

    /// Replace every match in `text` with `[REDACTED:<kind>]`. Order matters —
    /// run the longest / most specific patterns first so e.g. a credit card
    /// doesn't get caught by the generic-number rule.
    static func redact(_ text: String) -> String {
        var out = text
        for rule in rules {
            out = applyRegex(rule.pattern, to: out, replacement: "[REDACTED:\(rule.label)]")
        }
        return out
    }

    private struct Rule { let label: String; let pattern: String }

    private static let rules: [Rule] = [
        // — API keys / tokens (run first so they aren't shredded by smaller patterns)
        .init(label: "anthropic-key", pattern: #"sk-ant-[A-Za-z0-9_-]{20,}"#),
        .init(label: "openai-key",    pattern: #"sk-[A-Za-z0-9_-]{20,}"#),
        .init(label: "github-token",  pattern: #"gh[pousr]_[A-Za-z0-9]{36,}"#),
        .init(label: "aws-key-id",    pattern: #"AKIA[0-9A-Z]{16}"#),
        .init(label: "jwt",           pattern: #"eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}"#),
        .init(label: "bearer",        pattern: #"(?i)bearer\s+[A-Za-z0-9._\-]{20,}"#),

        // — Financial
        .init(label: "credit-card",   pattern: #"\b(?:\d{4}[ -]?){3}\d{4}\b"#),
        .init(label: "ssn",           pattern: #"\b\d{3}-\d{2}-\d{4}\b"#),

        // — Contact info
        .init(label: "email",         pattern: #"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b"#),
        // International phone: optional +, 7-15 digits, with separators
        .init(label: "phone",         pattern: #"\+?\d[\d\s\-().]{8,}\d"#),

        // — Network
        .init(label: "ipv4",          pattern: #"\b(?:\d{1,3}\.){3}\d{1,3}\b"#),
    ]

    private static func applyRegex(_ pattern: String, to text: String, replacement: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return text
        }
        let range = NSRange(text.startIndex..., in: text)
        return re.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: replacement)
    }
}
