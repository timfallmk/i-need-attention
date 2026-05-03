import Foundation

struct CLIState: Codable {
    var pairKey: String
    var myDeviceID: String
    var myName: String
    var partnerDeviceID: String
    var partnerName: String

    static var stateDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".attention-cli")
    }

    private static var stateURL: URL {
        stateDirectory.appendingPathComponent("state.json")
    }

    static func load() -> CLIState? {
        guard let data = try? Data(contentsOf: stateURL) else { return nil }
        return try? JSONDecoder().decode(CLIState.self, from: data)
    }

    func save() throws {
        try FileManager.default.createDirectory(at: Self.stateDirectory, withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(self)
        try data.write(to: Self.stateURL, options: .atomic)
    }

    static func clear() throws {
        try FileManager.default.removeItem(at: stateURL)
    }
}
