import Foundation

/// Bounds text that arrives from somewhere this app does not control before it is shown
/// to a person: a scanned QR, a tapped invite link, or the `senderName` / `message` fields
/// of a CloudKit record, which any signed-in iCloud user can write to the public database.
///
/// Both halves of a push notification are attacker-reachable. The title especially, since
/// a name is rendered as the notification's apparent source — unbounded text there reads
/// as system UI. The container has live examples: Pair records whose `nameA` carries ad
/// copy and bare URLs.
///
/// Sanitizing on the way out is politeness. Sanitizing on the way *in* is the defence — a
/// hostile partner writes to CloudKit directly and never runs this app's UI. So the calls
/// that matter are in `AlertRecord.init(record:)`, `PairingInvite.from(qrPayload:)`, and
/// the notification service extension.
enum UntrustedText {
    /// Room for a real name, not for a sentence with a link in it.
    static let maxNameLength = 30
    /// The body is "needs <noun>" in practice; `NounPresets.maxLength` caps the noun at 30
    /// on the way out, and this bounds what an arbitrary writer can put there on the way in.
    static let maxMessageLength = 60

    static func name(_ raw: String) -> String { clean(raw, limit: maxNameLength) }
    static func message(_ raw: String) -> String { clean(raw, limit: maxMessageLength) }

    static func name(_ raw: String?, fallback: String) -> String {
        let cleaned = name(raw ?? "")
        return cleaned.isEmpty ? fallback : cleaned
    }

    static func message(_ raw: String?, fallback: String) -> String {
        let cleaned = message(raw ?? "")
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func clean(_ raw: String, limit: Int) -> String {
        // Newlines and control characters let one field fake several lines of notification.
        var text = String(raw.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0)
        })
        text = strippingLinks(from: text)
        text = text
            .replacingOccurrences(of: "\\s{2,}", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        return String(text.prefix(limit)).trimmingCharacters(in: .whitespaces)
    }

    /// NSDataDetector rather than a hand-rolled pattern: it catches bare hosts like
    /// "example.com" that a scheme-based check misses, which is the shape the abuse
    /// already in the container actually took.
    private static func strippingLinks(from text: String) -> String {
        guard !text.isEmpty,
              let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        else { return text }
        let matches = detector.matches(in: text, range: NSRange(text.startIndex..., in: text))
        guard !matches.isEmpty else { return text }
        var out = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            out.replaceSubrange(range, with: " ")
        }
        return out
    }
}
