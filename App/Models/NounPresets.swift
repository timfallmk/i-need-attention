import Foundation

enum NounPresets {
    /// Same cap as the free-form input in `NounPickerSheet`. Presets are sanitized
    /// the same way so user-edited `nouns.json` can't bypass the validation by
    /// embedding newlines or going long.
    static let maxLength = 30

    static let all: [String] = loadFromBundle() ?? sanitize(fallback)

    private static let fallback = ["Hugs", "Kisses", "Some of your time"]

    private struct Payload: Decodable {
        let presets: [String]
    }

    private static func loadFromBundle() -> [String]? {
        guard let url = Bundle.main.url(forResource: "nouns", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            return nil
        }
        let cleaned = sanitize(payload.presets)
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Strip newlines, trim whitespace, and cap a single noun string to `maxLength`.
    /// Returns `nil` if the result is empty. Public so `AppState.sendAttention` can
    /// enforce the same invariant on its central send path, regardless of the caller
    /// (UI picker, watch bridge, future automation hooks).
    static func sanitize(_ s: String) -> String? {
        let stripped = s
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !stripped.isEmpty else { return nil }
        return stripped.count > maxLength ? String(stripped.prefix(maxLength)) : stripped
    }

    /// Strip newlines, trim whitespace, cap to `maxLength`, drop empties, and
    /// de-duplicate while preserving order. SwiftUI's `ForEach(id: \.self)` over
    /// the result needs unique strings.
    private static func sanitize(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for item in raw {
            guard let cleaned = sanitize(item) else { continue }
            if seen.insert(cleaned).inserted {
                out.append(cleaned)
            }
        }
        return out
    }

    /// Lowercase the first letter so a Title-Cased preset reads naturally
    /// after the "needs " prefix ("Some of your time" → "some of your time").
    static func nounForBody(_ preset: String) -> String {
        guard let first = preset.first else { return preset }
        return first.lowercased() + preset.dropFirst()
    }
}
