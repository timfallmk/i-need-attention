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
        let dir = Self.stateDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // attributes: on createDirectory only applies when the dir is newly created.
        // Unconditionally enforce 0700 so existing dirs with looser perms are tightened.
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        let url = Self.stateURL
        let data = try JSONEncoder().encode(self)
        try data.write(to: url, options: .atomic)
        // 0600: pairKey is the shared secret; restrict to owner read/write only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func clear() throws {
        try FileManager.default.removeItem(at: stateURL)
    }
}
