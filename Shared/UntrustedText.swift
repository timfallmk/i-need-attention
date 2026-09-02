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
    /// The ack emoji comes from a fixed four-item menu in this app's UI, but the field it
    /// lands in is a free-form string any writer can fill.
    static let maxEmojiLength = 4

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

    /// Returns nil rather than "" so callers keep their existing "no emoji" branch.
    ///
    /// Stripping format characters costs ZWJ emoji sequences, which arrive here as their
    /// separate components. That trade is deliberate: the same filter removes U+202E and
    /// friends, and a bidi override in a notification body is worth more than a family
    /// emoji renders intact. None of the app's own four ack emoji use ZWJ.
    static func emoji(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let cleaned = clean(raw, limit: maxEmojiLength)
        return cleaned.isEmpty ? nil : cleaned
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

    /// Built once. Compiling a detector costs more than the match it performs, and this
    /// runs on every parse in the notification service extension, which has a tight time
    /// and memory budget. NSDataDetector is an NSRegularExpression, safe to share.
    private static let linkDetector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
    )

    /// NSDataDetector rather than a hand-rolled pattern, which would need maintaining
    /// against every scheme and encoding trick. It catches schemed URLs reliably — the
    /// shape both abusive records in the container actually used — and bare hosts only
    /// where it recognises the TLD, so it declines RFC 2606 reserved names like
    /// "evil.example". Whatever slips past is bounded by the length cap, which is why
    /// that cap is the guarantee here and link stripping is best effort.
    private static func strippingLinks(from text: String) -> String {
        guard !text.isEmpty, let detector = linkDetector else { return text }
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

extension URL {
    /// CloudKit share URLs are `https://www.icloud.com/share/…`. A scanned QR code is
    /// untrusted input and accepting a share means joining whatever zone it names, so
    /// the destination is bounded here rather than at the call to CloudKit.
    ///
    /// The suffix check is on a leading dot so `icloud.com.evil.example` doesn't pass.
    var isCloudKitShare: Bool {
        guard scheme == "https", let host = host()?.lowercased() else { return false }
        return host == "icloud.com" || host.hasSuffix(".icloud.com")
    }
}
