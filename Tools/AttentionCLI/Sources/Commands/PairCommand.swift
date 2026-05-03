import CoreImage
import CoreImage.CIFilterBuiltins
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum PairCommand {
    static func run(_ args: [String]) async throws {
        guard let sub = args.first else {
            fputs("usage: attention-cli pair <invite|join|status|forget>\n", stderr)
            exit(1)
        }
        let rest = Array(args.dropFirst())
        switch sub {
        case "invite": try await invite(Args(rest))
        case "join":   try await join(Args(rest))
        case "status": status()
        case "forget": forget()
        default:
            fputs("unknown pair subcommand: \(sub)\n", stderr)
            exit(1)
        }
    }

    // MARK: - invite

    private static func invite(_ args: Args) async throws {
        let name = args["name"] ?? defaultName()
        let myDeviceID = UUID().uuidString
        let invite = PairingInvite.generate(myDeviceID: myDeviceID, myName: name)

        let client = CLIClient()
        print("Creating pair record on iCloud…")
        _ = try await client.createPair(invite: invite)

        let stateDir = CLIState.stateDirectory
        try FileManager.default.createDirectory(
            at: stateDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let pngURL = stateDir.appendingPathComponent("invite.png")
        try generateQRCode(from: invite.qrPayload, to: pngURL)
        // invite.png encodes the pairKey; restrict to owner read/write only.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pngURL.path)

        let openProc = Process()
        openProc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        openProc.arguments = [pngURL.path]
        // Non-fatal: headless / SSH sessions have no GUI. The payload and path are printed below.
        try? openProc.run()

        print("Payload:  \(invite.qrPayload)")
        print("QR image: \(pngURL.path)")
        print("Waiting for partner to scan (timeout 120s)…")

        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            try await Task.sleep(nanoseconds: 2_000_000_000)
            guard let updated = try await client.fetchPair(pairKey: invite.pairKey) else { continue }
            let deviceB = (updated[Constants.PairField.deviceB] as? String) ?? ""
            let nameB   = (updated[Constants.PairField.nameB]   as? String) ?? ""
            guard !deviceB.isEmpty else { continue }
            let state = CLIState(
                pairKey: invite.pairKey,
                myDeviceID: myDeviceID,
                myName: name,
                partnerDeviceID: deviceB,
                partnerName: nameB
            )
            try state.save()
            print("Joined by \(nameB) (\(deviceB))")
            return
        }
        fputs("Timed out waiting for partner (120s).\n", stderr)
        exit(1)
    }

    // MARK: - join

    private static func join(_ args: Args) async throws {
        guard let payload = args["payload"] else {
            fputs("usage: attention-cli pair join --payload <attention://...> [--name NAME]\n", stderr)
            exit(1)
        }
        let name = args["name"] ?? defaultName()
        guard let invite = PairingInvite.from(qrPayload: payload) else { throw CLIError.invalidPayload }

        let myDeviceID = UUID().uuidString
        let client = CLIClient()
        guard let record = try await client.fetchPair(pairKey: invite.pairKey) else { throw CLIError.pairNotFound }
        _ = try await client.joinPair(record: record, joinerDeviceID: myDeviceID, joinerName: name)

        let state = CLIState(
            pairKey: invite.pairKey,
            myDeviceID: myDeviceID,
            myName: name,
            partnerDeviceID: invite.inviterDeviceID,
            partnerName: invite.inviterName
        )
        try state.save()
        print("Joined pair with \(invite.inviterName)")
    }

    // MARK: - status

    private static func status() {
        guard let state = CLIState.load() else {
            print("No pair state. Run 'pair invite' or 'pair join' first.")
            return
        }
        print("pairKey:         \(state.pairKey)")
        print("myDeviceID:      \(state.myDeviceID)")
        print("myName:          \(state.myName)")
        print("partnerDeviceID: \(state.partnerDeviceID)")
        print("partnerName:     \(state.partnerName)")
    }

    // MARK: - forget

    private static func forget() {
        do {
            try CLIState.clear()
            print("State file deleted.")
        } catch let error as CocoaError where error.code == .fileNoSuchFile {
            print("No state file found.")
        } catch {
            fputs("error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    // MARK: - QR helpers

    private static func generateQRCode(from payload: String, to url: URL) throws {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(payload.utf8)
        filter.correctionLevel = "M"
        guard let raw = filter.outputImage else { throw CLIError.qrCodeFailed }
        let scale: CGFloat = 10
        let scaled = raw.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { throw CLIError.qrCodeFailed }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw CLIError.qrCodeFailed }
        CGImageDestinationAddImage(dest, cgImage, nil)
        guard CGImageDestinationFinalize(dest) else { throw CLIError.qrCodeFailed }
    }

    private static func defaultName() -> String {
        Host.current().localizedName ?? "AttentionCLI"
    }
}
