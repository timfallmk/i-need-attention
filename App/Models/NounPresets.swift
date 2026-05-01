import Foundation

enum NounPresets {
    static let all: [String] = loadFromBundle() ?? fallback

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
        let cleaned = payload.presets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return cleaned.isEmpty ? nil : cleaned
    }

    /// Lowercase the first letter so a Title-Cased preset reads naturally
    /// after the "needs " prefix ("Some of your time" → "some of your time").
    static func nounForBody(_ preset: String) -> String {
        guard let first = preset.first else { return preset }
        return first.lowercased() + preset.dropFirst()
    }
}
