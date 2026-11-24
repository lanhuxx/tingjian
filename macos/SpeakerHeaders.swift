import Foundation

enum SpeakerHeaders {
    enum Style {
        case timestamped
        case labelOnly
    }

    private static let time = #"(?:[0-9]{2,}:[0-9]{2}:[0-9]{2}(?:[.,][0-9]+)?|--:--:--)"#
    private static let timedLine = try! NSRegularExpression(
        pattern: #"^\h*\[\h*"# + time + #"\h*[-–—]\h*"# + time + #"\h*\]\h+(.+?)\h*$"#
    )
    private static let standaloneLine = try! NSRegularExpression(pattern: #"^\h*(.+?)\h*$"#)
    private static let numbered = try! NSRegularExpression(pattern: #"\ASpeaker\h+[1-9][0-9]*\z"#)

    private static func matches(in draft: String, style: Style, renamed: Set<String>) -> [(label: String, range: NSRange)] {
        let text = draft as NSString
        var lines: [(text: String, offset: Int)] = []
        var cursor = 0
        while cursor < text.length {
            var end = 0
            var contentEnd = 0
            text.getLineStart(nil, end: &end, contentsEnd: &contentEnd, for: NSRange(location: cursor, length: 0))
            lines.append((text.substring(with: NSRange(location: cursor, length: contentEnd - cursor)), cursor))
            cursor = end
        }

        var inTranscript = false
        var firstInParagraph = true
        var found: [(label: String, range: NSRange)] = []
        for (index, line) in lines.enumerated() {
            let trimmed = line.text.trimmingCharacters(in: .whitespaces)
            if !inTranscript {
                inTranscript = trimmed == "一、分段会议记录"
                continue
            }
            if trimmed == "二、完整纯文本" { break }
            if trimmed.isEmpty || trimmed.allSatisfy({ $0 == "=" }) {
                firstInParagraph = true
                continue
            }
            let canBeStandalone = firstInParagraph && index + 1 < lines.count
                && !lines[index + 1].text.trimmingCharacters(in: .whitespaces).isEmpty
            firstInParagraph = false
            if style == .labelOnly && !canBeStandalone { continue }
            let expression = style == .timestamped ? timedLine : standaloneLine
            let bounds = NSRange(line.text.startIndex..., in: line.text)
            guard let match = expression.firstMatch(in: line.text, range: bounds) else { continue }
            let range = match.range(at: 1)
            let label = (line.text as NSString).substring(with: range)
            guard renamed.contains(label)
                || numbered.firstMatch(in: label, range: NSRange(label.startIndex..., in: label)) != nil
            else { continue }
            found.append((label, NSRange(location: line.offset + range.location, length: range.length)))
        }
        return found
    }

    static func labels(in draft: String, style: Style, renamed: Set<String>) -> [String] {
        var seen = Set<String>()
        return matches(in: draft, style: style, renamed: renamed).map(\.label).filter { seen.insert($0).inserted }
    }

    static func replacing(in draft: String, style: Style, renamed: Set<String>, replacements: [String: String]) -> String {
        let result = NSMutableString(string: draft)
        for (label, range) in matches(in: draft, style: style, renamed: renamed).reversed() {
            if let replacement = replacements[label] {
                result.replaceCharacters(in: range, with: replacement)
            }
        }
        return result as String
    }
}
