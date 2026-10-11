import Foundation
import NaturalLanguage

/// How the final text is written. Applied instantly on the device, no AI involved.
enum WritingStyle: String, CaseIterable {
    /// Capitals, full punctuation, no contractions or slang ("don't" → "do not", "gonna" → "going to").
    case veryFormal
    /// Exactly as spoken, with normal capitals and punctuation.
    case casual
    /// All lowercase (acronyms kept) and no final period.
    case veryCasual

    var title: String {
        switch self {
        case .veryFormal: "Very formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        }
    }

    func apply(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        switch self {
        case .casual:
            return text
        case .veryFormal:
            var result = Self.isEnglish(text) ? Self.expandContractions(text) : text
            if let first = result.first, first.isLowercase { result = first.uppercased() + result.dropFirst() }
            if let last = result.last, last.isLetter || last.isNumber { result += Self.looksLikeQuestion(result) ? "?" : "." }
            return result
        case .veryCasual:
            var result = Self.lowercasedKeepingAcronyms(text)
            while result.hasSuffix(".") { result.removeLast() }
            return result
        }
    }

    // MARK: - Very formal

    private static let questionStarts: Set<String> = [
        "can", "could", "would", "will", "should", "shall", "do", "does", "did", "is", "are", "was", "were",
        "have", "has", "what", "why", "how", "when", "where", "who", "which", "may",
    ]

    /// Only used when the sentence has no punctuation at all.
    private static func looksLikeQuestion(_ text: String) -> Bool {
        let lastSentence = text.components(separatedBy: CharacterSet(charactersIn: ".!?")).last ?? text
        let first = lastSentence.split(separator: " ").first.map { $0.lowercased() } ?? ""
        return questionStarts.contains(first)
    }

    private static let slang: [String: String] = [
        "gonna": "going to", "wanna": "want to", "gotta": "have to", "kinda": "kind of",
        "sorta": "sort of", "lemme": "let me", "gimme": "give me", "yeah": "yes", "y'all": "you all",
    ]

    private static let pronounsWithIs: Set<String> = [
        "it", "that", "there", "here", "what", "where", "who", "he", "she", "how", "when", "why",
    ]

    private static func expandContractions(_ text: String) -> String {
        let pattern = #"\b[A-Za-z]+(?:['’][A-Za-z]+)?\b(?:\s+(been|better|got))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let ns = text as NSString
        var result = ""
        var cursor = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: cursor, length: match.range.location - cursor))
            let original = ns.substring(with: match.range)
            let parts = original.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            let word = String(parts.first ?? "")
            let next = parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : nil
            if let expanded = expand(word, next: next?.lowercased()) {
                result += matchCase(expanded, to: word) + (next.map { " " + $0 } ?? "")
            } else {
                result += original
            }
            cursor = match.range.location + match.range.length
        }
        result += ns.substring(from: cursor)
        return result
    }

    private static func expand(_ word: String, next: String?) -> String? {
        let w = word.lowercased().replacingOccurrences(of: "’", with: "'")
        if let replacement = slang[w] { return replacement }
        switch w {
        case "can't": return "cannot"
        case "won't": return "will not"
        case "shan't": return "shall not"
        case "let's", "o'clock", "ain't": return nil
        default: break
        }
        guard let apostrophe = w.firstIndex(of: "'") else { return nil }
        let stem = String(w[..<apostrophe])
        let suffix = String(w[w.index(after: apostrophe)...])
        if suffix == "t", stem.hasSuffix("n") { return String(stem.dropLast()) + " not" }
        switch suffix {
        case "m": return stem + " am"
        case "re": return stem + " are"
        case "ve": return stem + " have"
        case "ll": return stem + " will"
        case "d": return stem + (next == "been" || next == "better" ? " had" : " would")
        case "s" where pronounsWithIs.contains(stem):
            return stem + (next == "been" || next == "got" ? " has" : " is")
        default: return nil
        }
    }

    private static func matchCase(_ replacement: String, to original: String) -> String {
        if original.count > 1, original == original.uppercased() { return replacement.uppercased() }
        if original.first?.isUppercase == true { return replacement.prefix(1).uppercased() + replacement.dropFirst() }
        return replacement
    }

    private static func isEnglish(_ text: String) -> Bool {
        let language = NLLanguageRecognizer.dominantLanguage(for: text)
        return language == nil || language == .english
    }

    // MARK: - Very casual

    /// Lowercases everything except acronyms like "API" or "CSV".
    private static func lowercasedKeepingAcronyms(_ text: String) -> String {
        text.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let letters = token.filter(\.isLetter)
            let isAcronym = letters.count >= 2 && letters.allSatisfy(\.isUppercase)
            return isAcronym ? String(token) : token.lowercased()
        }.joined(separator: " ")
    }
}
